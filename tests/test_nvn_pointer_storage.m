#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include "nvn_obj.h"
#include "nvn_refl.h"

int nvn_refl_from_json(NSDictionary *j, nvn_refl *o, char *err, int errlen);
#include "../host/nvn_pointer_storage.inc"

// Binding half: the backend state and address translation it relies on.
static struct { p_bind_buf ubo[6][16]; } S;
static id<MTLBuffer> pools[2];
static int pending, red, logged;
static int g_red_once[64];
#define RED_ONCE(k, ...) do { if (!g_red_once[k]++) red++; } while (0)
#define MLOG(...) (logged++)
#define MDIE(...) do { fprintf(stderr, __VA_ARGS__); abort(); } while (0)
static int pend_hits(uint64_t a, uint64_t n) { (void)a; (void)n; return pending; }
static int mtl_addr(uint64_t address, uint64_t length, void **buffer, uint64_t *offset) {
    for (int i = 0; i < 2; i++) {
        uint64_t base = (uintptr_t)pools[i].contents;
        if (address >= base && address + length <= base + pools[i].length) { *buffer = (__bridge void *)pools[i]; *offset = address - base; return 1; }
    }
    return 0;
}
static int mtl_gpu_addr(uint64_t address, uint64_t length, void **buffer, uint64_t *offset, uint64_t *gpu) {
    if (!mtl_addr(address, length, buffer, offset)) return 0;
    *gpu = ((__bridge id<MTLBuffer>)*buffer).gpuAddress + *offset; return 1;
}
static void use_rec(const char *kind, uint64_t address, uint64_t length, int tid, const tex_t *texture) { (void)kind; (void)address; (void)length; (void)tid; (void)texture; }
static uint64_t fence, done;
static uint64_t mtl_last_fence(void) { return fence; }
static int mtl_wait(uint64_t f, uint64_t timeout) { (void)timeout; return done >= f; }
uint64_t nvn_canonical_address(uint64_t address, uint64_t length) { (void)length; return address; }
#define ZELDA_POINTER_STORAGE_BIND 1
#include "../host/nvn_pointer_storage.inc"

static NSDictionary *reflection(NSDictionary *storage) {
    return @{@"route": @"B", @"bindings": @[@{@"kind": @"cbuf", @"reg": @3, @"arg_id": @0, @"msl_name": @"vp_c6"}, storage]};
}

int main(void) { @autoreleasepool {
    NSDictionary *storage = @{@"kind": @"sbuf_cb", @"reg": @3, @"offset": @8, @"rw": @NO, @"arg_id": @1, @"msl_name": @"vp_s0"};
    nvn_refl rf; char error[200];
    assert(nvn_refl_from_json(reflection(storage), &rf, error, sizeof error));   // the upstream parser alone refuses the kind
    assert(!zelda_refl_from_json(reflection(storage), &rf, error, sizeof error));
    assert(rf.nb == 2 && rf.b[0].kind == NVN_RB_CBUF && rf.b[0].reg == 3);
    assert(rf.b[1].kind == ZELDA_RB_SBUF_CB && rf.b[1].reg == 3 && rf.b[1].aid == 1 && (rf.b[1].dtt | rf.b[1].dpf << 8) == 8 && !rf.b[1].rw);
    NSDictionary *bad[] = {
        @{@"kind": @"sbuf_cb", @"reg": @3, @"offset": @8, @"rw": @YES, @"arg_id": @1, @"msl_name": @"vp_s0"},
        @{@"kind": @"sbuf_cb", @"reg": @16, @"offset": @8, @"rw": @NO, @"arg_id": @1, @"msl_name": @"vp_s0"},
        @{@"kind": @"sbuf_cb", @"reg": @3, @"offset": @4, @"rw": @NO, @"arg_id": @1, @"msl_name": @"vp_s0"},
        @{@"kind": @"sbuf_cb", @"offset": @8, @"rw": @NO, @"arg_id": @1, @"msl_name": @"vp_s0"},
    };
    for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++) assert(zelda_refl_from_json(reflection(bad[i]), &rf, error, sizeof error));

    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    pools[0] = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];   // uniform buffers
    pools[1] = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];   // storage the address points at
    uint32_t *values = pools[1].contents; for (int i = 0; i < 1024; i++) values[i] = 0x1000 + i;
    uint64_t uniform = (uintptr_t)pools[0].contents + 256, target = (uintptr_t)pools[1].contents + 64;
    memcpy((uint8_t *)uniform + 8, &target, 8);
    assert(!zelda_refl_from_json(reflection(storage), &rf, error, sizeof error));
    void *buffer = NULL;
    assert(!zelda_pointer_storage(0, &rf.b[1], "test", &buffer) && !logged);   // slot unbound: reads 0 through a dummy
    S.ubo[0][3] = (p_bind_buf){0, 3, uniform, 12};
    assert(!zelda_pointer_storage(0, &rf.b[1], "test", &buffer));               // the address does not fit the bound size
    S.ubo[0][3].size = 64;
    uint64_t gpu = zelda_pointer_storage(0, &rf.b[1], "test", &buffer);
    assert(gpu == pools[1].gpuAddress + 64 && buffer == (__bridge void *)pools[1] && logged == 1);
    uint64_t outside = 0x10; memcpy((uint8_t *)uniform + 8, &outside, 8);
    assert(!zelda_pointer_storage(0, &rf.b[1], "test", &buffer) && red == 1);
    memset((uint8_t *)uniform + 8, 0, 8); assert(!zelda_pointer_storage(0, &rf.b[1], "test", &buffer) && red == 1);

    // A uniform update whose GPU copy has not run yet (this submission or one still on the GPU) is what the draw sees.
    uint64_t other = target + 512; struct { uint64_t destination, length; uint64_t payload; } update = {uniform, 64, 0};
    uint8_t record[16 + 64] = {0}; memcpy(record, &update, 16); memcpy(record + 16 + 8, &other, 8);
    memcpy((uint8_t *)uniform + 8, &target, 8); fence = 4; done = 3;
    zelda_update_log_op(OP_UPDATE_UB, record);                        // completes with fence 5
    assert(zelda_pointer_storage(0, &rf.b[1], "test", &buffer) == pools[1].gpuAddress + 576);
    fence = 5; done = 4;                                               // next submission, previous one still running
    assert(zelda_pointer_storage(0, &rf.b[1], "test", &buffer) == pools[1].gpuAddress + 576);
    done = 5;                                                          // the copy ran: memory is the truth again
    assert(zelda_pointer_storage(0, &rf.b[1], "test", &buffer) == pools[1].gpuAddress + 64);
    uint64_t counter[3] = {uniform + 16, 0, 0}; zelda_update_log_op(OP_REPORT_COUNTER, counter);   // elsewhere: ignored
    assert(zelda_pointer_storage(0, &rf.b[1], "test", &buffer) == pools[1].gpuAddress + 64);

    // The GPU reads the storage through the translated address.
    memcpy((uint8_t *)uniform + 8, &target, 8); gpu = zelda_pointer_storage(0, &rf.b[1], "test", &buffer);
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\nstruct Arguments { const device uint *storage [[id(0)]]; };\n"
        @"kernel void read_storage(constant Arguments &arguments [[buffer(0)]], device uint *out [[buffer(1)]]) { out[0] = arguments.storage[3]; }\n";
    NSError *failure = nil; id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&failure]; assert(library);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"read_storage"] error:&failure];
    assert(pipeline);
    id<MTLBuffer> arguments = [device newBufferWithLength:16 options:MTLResourceStorageModeShared], out = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    memcpy(arguments.contents, &gpu, 8);
    id<MTLCommandQueue> queue = [device newCommandQueue]; id<MTLCommandBuffer> commands = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
    [encoder setComputePipelineState:pipeline]; [encoder setBuffer:arguments offset:0 atIndex:0]; [encoder setBuffer:out offset:0 atIndex:1];
    [encoder useResource:pools[1] usage:MTLResourceUsageRead];
    [encoder dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [encoder endEncoding];
    [commands commit]; [commands waitUntilCompleted];
    assert(((uint32_t *)out.contents)[0] == 0x1000 + 16 + 3);
    (void)pending;
    puts("Uniform-held storage address: reflection retag, rejected forms, unbound and outside addresses, pending GPU updates, GPU read passed");
} }
