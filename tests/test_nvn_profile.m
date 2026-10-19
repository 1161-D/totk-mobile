#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../host/nvn_query_msl.h"

static id<MTLDevice> g_dev;
static id<MTL4CommandBuffer> command;
static _Atomic uint64_t g_cur_frame = 42;
static uint64_t g_stat_pass = 7, g_stat_draw;
static unsigned waits;
static int mtl_wait(uint64_t fence, uint64_t timeout) { assert(fence == 1 && timeout == UINT64_MAX); waits++; return 1; }
static void ser_gate(void) {}
static void args_dirty_all(void) {}
static id<MTL4ComputeCommandEncoder> enc_c_begin(MTLComputePassDescriptor *descriptor);
#define MDIE(...) do { fprintf(stderr, __VA_ARGS__); abort(); } while (0)
#include "../host/nvn_profile_gpu.inc"
static id<MTL4ComputeCommandEncoder> enc_c_begin(MTLComputePassDescriptor *descriptor) {
    (void)descriptor;
    id<MTL4ComputeCommandEncoder> e = [command computeCommandEncoder];
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    zelda_profile_begin(e, nil); return e;
}
int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2); setenv("DM_NVN_PASSGPU", argv[1], 1);
    g_dev = MTLCreateSystemDefaultDevice(); assert(g_dev);
    NSError *error = nil;
    id<MTL4CommandQueue> queue = [g_dev newMTL4CommandQueue];
    command = [g_dev newCommandBuffer];
    id<MTL4CommandAllocator> allocator = [g_dev newCommandAllocator];
    assert(queue && command && allocator);
    id<MTLLibrary> library = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 vs(uint i [[vertex_id]]) { float2 p[]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\nfragment float4 fs(){return float4(1,0,0,1);}" options:nil error:&error];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"vs"]; pd.fragmentFunction = [library newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline = [g_dev newRenderPipelineStateWithDescriptor:pd error:&error]; assert(pipeline);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [g_dev newTextureWithDescriptor:td];
    id<MTLBuffer> buffer = [g_dev newBufferWithLength:16 << 20 options:MTLResourceStorageModeShared];
    id<MTLBuffer> query = [g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    id<MTLBuffer> parameters = [g_dev newBufferWithLength:128 options:MTLResourceStorageModeShared];
    id<MTLBuffer> result = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    ((uint64_t *)result.contents)[1] = 0xa5a5a5a5a5a5a5a5ull;
    uint64_t expected = 0xb4b4b4b4b4b4b4b4ull;
    uint64_t *q = query.contents; q[0] = 0; q[1] = 123; q[2] = expected; q[3] = 456;
    memset(parameters.contents, 0, parameters.length);
    uint64_t *parameters_words = parameters.contents; parameters_words[0] = 2;
    parameters_words[1] = buffer.gpuAddress; parameters_words[2] = buffer.gpuAddress + 8;
    parameters_words[8] = 1; parameters_words[9] = query.gpuAddress;
    id<MTLLibrary> query_library = [g_dev newLibraryWithSource:@(zelda_query_msl) options:nil error:&error]; assert(query_library);
    id<MTLComputePipelineState> sum = [g_dev newComputePipelineStateWithFunction:[query_library newFunctionWithName:@"query_sum"] error:&error];
    MTL4ArgumentTableDescriptor *arguments = [MTL4ArgumentTableDescriptor new]; arguments.maxBufferBindCount = 3;
    id<MTL4ArgumentTable> table = [g_dev newArgumentTableWithDescriptor:arguments error:&error]; assert(sum && table);
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
    id<MTLResidencySet> residency = [g_dev newResidencySetWithDescriptor:rd error:&error];
    [residency addAllocation:texture]; [residency addAllocation:buffer];
    [residency addAllocation:query]; [residency addAllocation:parameters]; [residency addAllocation:result];
    [residency commit]; [queue addResidencySet:residency];
    [command beginCommandBufferWithAllocator:allocator]; pg_sub_begin(1);
    MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
    pass.colorAttachments[0].texture = texture; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTL4RenderCommandEncoder> render = [command renderCommandEncoderWithDescriptor:pass];
    zelda_profile_begin(render, pass); [render setRenderPipelineState:pipeline];
    zelda_profile_draw("0123456789abcdef", "fedcba9876543210");
    zelda_profile_draw("later vertex", "later fragment");
    [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; g_stat_draw++;
    zelda_profile_end(render);
    [render barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [render endEncoding];
    id<MTL4ComputeCommandEncoder> compute = pg_compute();
    [compute fillBuffer:buffer range:NSMakeRange(0, buffer.length) value:0x5a];
    [compute barrierAfterEncoderStages:(MTLStageDispatch | MTLStageBlit) beforeEncoderStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
    [compute setArgumentTable:table]; [table setAddress:query.gpuAddress atIndex:0];
    [table setAddress:parameters.gpuAddress atIndex:1];
    [compute setComputePipelineState:sum]; [compute dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
    [compute barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:(MTLStageDispatch | MTLStageBlit) visibilityOptions:MTL4VisibilityOptionDevice];
    [table setAddress:parameters.gpuAddress + 64 atIndex:1]; [table setAddress:result.gpuAddress atIndex:0];
    [compute setComputePipelineState:sum]; [compute dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
    [compute barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    [compute fillBuffer:query range:NSMakeRange(24,8) value:0];
    zelda_profile_end(compute);
    [compute barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [compute endEncoding];
    dispatch_block_t profile = zelda_profile_commit(); assert(profile && z_profile_count == 2 && z_profile_used == 6);
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block double gpu_ms;
    MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        assert(!feedback.error); gpu_ms = (feedback.GPUEndTime - feedback.GPUStartTime) * 1000;
        profile(); dispatch_semaphore_signal(finished);
    }];
    [command endCommandBuffer]; id<MTL4CommandBuffer> commands[] = {command}; [queue commit:commands count:1 options:options];
    assert(!dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    assert(((uint8_t *)buffer.contents)[0] == 0x5a && ((uint8_t *)buffer.contents)[buffer.length - 1] == 0x5a);
    assert(q[0] == expected && q[1] == 123 && q[2] == expected && q[3] == 0);
    assert(((uint64_t *)result.contents)[0] == expected && ((uint64_t *)result.contents)[1] == 0xa5a5a5a5a5a5a5a5ull);
    NSData *data = [z_profile_heaps[1] resolveCounterRange:NSMakeRange(0, 6)]; assert(data.length == 6 * sizeof(MTL4TimestampHeapEntry));
    const MTL4TimestampHeapEntry *ts = data.bytes;
    assert(ts[0].timestamp && ts[2].timestamp >= ts[0].timestamp && ts[3].timestamp >= ts[1].timestamp);
    assert(ts[4].timestamp && ts[5].timestamp >= ts[4].timestamp);
    double span_ms = (ts[5].timestamp - ts[0].timestamp) * 1000.0 / z_profile_frequency;
    assert(gpu_ms > 0 && span_ms > gpu_ms * .1 && span_ms < gpu_ms * 2);
    assert(z_profile_entries[0].width == 64 && z_profile_entries[0].draws == 1 && z_profile_entries[1].kind == 'C');
    assert(!strcmp(z_profile_entries[0].first_vs,"0123456789abcdef") && !strcmp(z_profile_entries[0].first_fs,"fedcba9876543210"));
    pg_sub_begin(9); assert(waits == 1 && !z_profile_count && z_profile_open == -1);
    data = [z_profile_heaps[1] resolveCounterRange:NSMakeRange(0, 6)]; ts = data.bytes;
    for (unsigned i = 0; i < 6; i++) assert(!ts[i].timestamp);
    fclose(z_profile_file); z_profile_file = NULL;
    printf("Metal 4 render/compute timestamp and heap reuse checks passed (%.3f / %.3f ms)\n", span_ms, gpu_ms);
} }
