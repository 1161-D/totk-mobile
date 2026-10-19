#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../host/nvn_query_msl.h"
#include "../host/nvn_index_msl.h"

// A constant update issued between two passes is written by the second pass's first (rasterization-free) draw,
// behind an in-pass vertex -> vertex/fragment barrier. The first pass must still read the old value; the second
// pass must read the new one in both its vertex and fragment stages, and the copy covers every word.
static const char *reader =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 position [[position]]; float from_vertex; };\n"
    "vertex V read_vertex(uint id [[vertex_id]], const device float *u [[buffer(0)]]) {\n"
    "    float2 p = float2((id << 1) & 2, id & 2); return {float4(p * 2 - 1, 0, 1), u[63]}; }\n"
    "fragment float4 read_fragment(V in [[stage_in]], const device float *u [[buffer(0)]]) {\n"
    "    return float4(in.from_vertex, u[0], u[31], 1); }\n";

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    NSError *error = nil;
    id<MTLLibrary> writes = [device newLibraryWithSource:@(zelda_query_msl) options:nil error:&error]; assert(writes);
    id<MTLLibrary> reads = [device newLibraryWithSource:@(reader) options:nil error:&error]; assert(reads);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [writes newFunctionWithName:@"buffer_write"]; pd.rasterizationEnabled = NO;
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float; pd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
    id<MTLRenderPipelineState> write = [device newRenderPipelineStateWithDescriptor:pd error:&error]; assert(write);
    id<MTLLibrary> indices = [device newLibraryWithSource:@(zelda_index_msl) options:nil error:&error]; assert(indices);
    pd.vertexFunction = [indices newFunctionWithName:@"expand_index_vertex"];
    id<MTLRenderPipelineState> expand = [device newRenderPipelineStateWithDescriptor:pd error:&error]; assert(expand);
    pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [reads newFunctionWithName:@"read_vertex"]; pd.fragmentFunction = [reads newFunctionWithName:@"read_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> read = [device newRenderPipelineStateWithDescriptor:pd error:&error]; assert(read);

    id<MTLBuffer> uniforms = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> update = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    for (int i = 0; i < 64; i++) { ((float *)uniforms.contents)[i] = 1; ((float *)update.contents)[i] = 2 + i; }
    id<MTLBuffer> bytes = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> shorts = [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    memcpy(bytes.contents, (uint8_t[]){0, 1, 2}, 3); memset(shorts.contents, 0, 16);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> before = [device newTextureWithDescriptor:td], after = [device newTextureWithDescriptor:td];
    id<MTLResidencySet> residency = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    for (id<MTLAllocation> a in @[uniforms, update, before, after, bytes, shorts]) [residency addAllocation:a];
    [residency commit];
    id<MTL4CommandQueue> queue = [device newMTL4CommandQueue]; [queue addResidencySet:residency];
    id<MTL4CommandAllocator> allocator = [device newCommandAllocator]; id<MTL4CommandBuffer> command = [device newCommandBuffer];
    [command beginCommandBufferWithAllocator:allocator];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 2;
    id<MTL4ArgumentTable> table = [device newArgumentTableWithDescriptor:ad error:&error]; assert(table);
    id<MTL4ArgumentTable> copy = [device newArgumentTableWithDescriptor:ad error:&error]; assert(copy);
    [table setAddress:uniforms.gpuAddress atIndex:0];
    for (int pass = 0; pass < 2; pass++) {
        MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
        rp.colorAttachments[0].texture = pass ? after : before; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTL4RenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:rp];
        [encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        if (pass) {   // The pending update: 64 words written at the start of the second pass.
            [encoder setRenderPipelineState:write];
            [copy setAddress:uniforms.gpuAddress atIndex:0]; [copy setAddress:update.gpuAddress atIndex:1];
            [encoder setArgumentTable:copy atStages:MTLRenderStageVertex];
            [encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:64];
            [encoder barrierAfterEncoderStages:MTLStageVertex beforeEncoderStages:(MTLStageVertex | MTLStageFragment) visibilityOptions:MTL4VisibilityOptionDevice];
            [encoder setRenderPipelineState:expand];
            [copy setAddress:bytes.gpuAddress atIndex:0]; [copy setAddress:shorts.gpuAddress atIndex:1];
            [encoder setArgumentTable:copy atStages:MTLRenderStageVertex];
            [encoder drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:3];
            [encoder barrierAfterEncoderStages:MTLStageVertex beforeEncoderStages:MTLStageVertex visibilityOptions:MTL4VisibilityOptionDevice];
        }
        [encoder setRenderPipelineState:read];
        [encoder setArgumentTable:table atStages:(MTLRenderStageVertex | MTLRenderStageFragment)];
        [encoder setViewport:(MTLViewport){0, 0, 4, 4, 0, 1}];
        if (pass) [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:3 indexType:MTLIndexTypeUInt16
                                     indexBuffer:shorts.gpuAddress indexBufferLength:6];
        else [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
    }
    [command endCommandBuffer];
    dispatch_semaphore_t done = dispatch_semaphore_create(0); MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { assert(!feedback.error); dispatch_semaphore_signal(done); }];
    id<MTL4CommandBuffer> batch[] = {command}; [queue commit:batch count:1 options:options];
    assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    for (int pass = 0; pass < 2; pass++) {
        float pixels[4 * 4 * 4]; [(pass ? after : before) getBytes:pixels bytesPerRow:64 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
        for (int i = 0; i < 16; i++) {
            const float *p = pixels + 4 * i;
            if (pass) assert(p[0] == 65 && p[1] == 2 && p[2] == 33);   // u[63], u[0], u[31] after the update
            else assert(p[0] == 1 && p[1] == 1 && p[2] == 1);
        }
    }
    for (int i = 0; i < 64; i++) assert(((float *)uniforms.contents)[i] == 2 + i);
    assert(!memcmp(shorts.contents, (uint16_t[]){0, 1, 2}, 6));
    puts("Pass constant writes: old value before the update, new value in vertex and fragment of the next pass, every word; in-pass 8-bit index conversion before an indexed draw passed");
} }
