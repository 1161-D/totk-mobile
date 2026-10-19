#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
static id<MTLBuffer> arena;
static size_t used;
static uint64_t g_sub_serial = 1;
static size_t arena_alloc(size_t bytes, id<MTLBuffer> *buffer) {
    size_t offset=used;used+=(bytes+255)&~255ul;assert(used<=arena.length);*buffer=arena;return offset;
}
#include "../host/nvn_point_params.inc"
int main(void) { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);NSError *error=nil;
    id<MTLLibrary> library=[device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; kernel void read_params(device const uint2 *in [[buffer(0)]], device uint2 *out [[buffer(1)]]) {*out=*in;}" options:nil error:&error];assert(library);
    id<MTLComputePipelineState> pipeline=[device newComputePipelineStateWithFunction:[library newFunctionWithName:@"read_params"] error:&error];assert(pipeline);
    id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> command=[queue commandBuffer];
    arena=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLComputeCommandEncoder> encoder=[command computeCommandEncoder];[encoder setComputePipelineState:pipeline];
    const uint32_t words[][2]={{0x3f800000,0},{0x3f800000,0},{0x3f800000,5},{0x3f800000,5},
        {0,0},{0x80000000,0},{0x7fc01234,0},{0x7fc01234,0},{0x7fc04321,0}};
    uint64_t previous=0;
    for(unsigned i=0;i<sizeof words/sizeof words[0];i++) {
        float point;memcpy(&point,&words[i][0],4);uint64_t gpu=zelda_point_params(point,words[i][1]);
        if(i==1||i==3||i==7)assert(gpu==previous);else assert(gpu!=previous);
        [encoder setBuffer:arena offset:gpu-arena.gpuAddress atIndex:0];
        [encoder setBuffer:output offset:8*i atIndex:1];
        [encoder dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];previous=gpu;
    }
    assert(z_point_params_created==6&&z_point_params_reused==3&&used==6*256);
    [encoder endEncoding];[command commit];[command waitUntilCompleted];assert(!command.error);
    assert(!memcmp(output.contents,words,sizeof words));
    // A new slice may use another arena, even if the last value is identical.
    id<MTLBuffer> first=arena;arena=[device newBufferWithLength:4096 options:MTLResourceStorageModeShared];used=0;g_sub_serial++;
    float last;memcpy(&last,&words[8][0],4);uint64_t fresh=zelda_point_params(last,0);
    assert(fresh==arena.gpuAddress&&fresh!=previous&&used==256);
    assert(!memcmp(arena.contents,words[8],8));assert(first);
    z_point_params_reuse=0;assert(zelda_point_params(last,0)!=fresh&&used==512);
    puts("Driver parameters: GPU readback, immutable earlier draws, layer indices, signed zero, NaN payloads and slice lifetime passed");
} }
