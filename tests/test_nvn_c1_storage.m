#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <os/lock.h>
#include <assert.h>
#include <stdio.h>
#include "nvn_refl.h"

#define C1_DECL_SIZE 65536u
#define MDIE(...) do { fprintf(stderr, __VA_ARGS__); abort(); } while (0)
static id<MTLDevice> g_dev;
static id<MTLResidencySet> residency;
static size_t g_c1_alloc_bytes;
static uint64_t g_c1_exclusive;
static os_unfair_lock g_c1_lock = OS_UNFAIR_LOCK_INIT;
static void res_add(id<MTLResource> resource) { [residency addAllocation:(id<MTLAllocation>)resource]; }
#include "../host/nvn_c1_storage.inc"

int main(int argc, const char **argv) { @autoreleasepool {
    int reuse = argc == 1 || strcmp(argv[1], "off");
    setenv("ZELDA_C1_REUSE", reuse ? "1" : "0", 1);
    g_dev = MTLCreateSystemDefaultDevice(); assert(g_dev);
    residency = [g_dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:NULL]; assert(residency);
    uint8_t bytes[4096] = {1, 2, 3, 4};
    id<MTLBuffer> first = zelda_c1_buffer(bytes, 4);
    id<MTLBuffer> padded = zelda_c1_buffer(bytes, sizeof bytes);
    assert((first == padded) == reuse);
    assert(first.length == C1_DECL_SIZE && padded.length == C1_DECL_SIZE);
    assert(!memcmp(first.contents, padded.contents, C1_DECL_SIZE));
    bytes[4095] = 77;
    id<MTLBuffer> other = zelda_c1_buffer(bytes, sizeof bytes);
    assert(other != first && ((uint8_t *)first.contents)[4095] == 0);
    assert(((uint8_t *)other.contents)[4095] == 77);
    memset(bytes, 0, sizeof bytes);
    id<MTLBuffer> zero = zelda_c1_buffer(bytes, sizeof bytes);
    assert(zero != first && zero != other);
    // New shaders and warm-up loads must see one initialized buffer under the production lock.
    dispatch_apply(32, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
        (void)i;
        @autoreleasepool {
            uint8_t data[] = {1, 2, 3, 4, 0, 0};
            os_unfair_lock_lock(&g_c1_lock);
            id<MTLBuffer> shared = zelda_c1_buffer(data, sizeof data);
            assert((shared == first) == reuse);
            assert(!memcmp(shared.contents, data, sizeof data));
            os_unfair_lock_unlock(&g_c1_lock);
        }
    });
    assert(g_c1_exclusive == (reuse ? 3 : 36));
    assert(g_c1_alloc_bytes == g_c1_exclusive * C1_DECL_SIZE);
    assert(z_c1_hits == (reuse ? 33 : 0));
    id<MTLBuffer> output = [g_dev newBufferWithLength:3 * C1_DECL_SIZE options:MTLResourceStorageModeShared];
    memset(output.contents, 0xff, output.length); res_add(output); [residency commit];
    id<MTL4CommandQueue> queue = [g_dev newMTL4CommandQueue]; [queue addResidencySet:residency];
    id<MTL4CommandAllocator> allocator = [g_dev newCommandAllocator];
    id<MTL4CommandBuffer> command = [g_dev newCommandBuffer];
    [command beginCommandBufferWithAllocator:allocator];
    id<MTL4ComputeCommandEncoder> encoder = [command computeCommandEncoder];
    id<MTLBuffer> inputs[] = {padded, other, zero};
    for (unsigned i = 0; i < 3; i++)
        [encoder copyFromBuffer:inputs[i] sourceOffset:0 toBuffer:output destinationOffset:i * C1_DECL_SIZE size:C1_DECL_SIZE];
    [encoder endEncoding]; [command endCommandBuffer];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { assert(!feedback.error); dispatch_semaphore_signal(done); }];
    id<MTL4CommandBuffer> batch[] = {command}; [queue commit:batch count:1 options:options];
    assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    for (unsigned i = 0; i < output.length; i++) {
        unsigned offset = i % C1_DECL_SIZE, group = i / C1_DECL_SIZE;
        uint8_t expected = group < 2 && offset < 4 ? offset + 1 : group == 1 && offset == 4095 ? 77 : 0;
        assert(((uint8_t *)output.contents)[i] == expected);
    }
    // The lookup table must not add permanent ownership if a shader's resource is retired later.
    __weak id<MTLBuffer> retired;
    @autoreleasepool {
        uint8_t data[] = {99}; id<MTLBuffer> temporary = zelda_c1_buffer(data, sizeof data);
        retired = temporary; [residency removeAllocation:temporary]; [residency commit];
    }
    assert(!retired);
    printf("c1 constants (%s): equal/trailing-zero sharing, distinct data, concurrent lookup, full 64 KiB GPU read and weak lifetime passed\n", reuse ? "reuse" : "exclusive");
} }
