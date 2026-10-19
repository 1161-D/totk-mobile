#import <Metal/Metal.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvn_obj.h"
#include "../host/nvn_query_msl.h"
#include "../host/nvn_depth_clear.h"

static id<MTLDevice> g_dev;
static id<MTLLibrary> z_query_library;
static id<MTL4RenderCommandEncoder> g_enc;
static id<MTL4ArgumentTable> z_query_args, g_vt, g_ft;
static id<MTLRenderPipelineState> g_enc_pso;
static id<MTLDepthStencilState> g_enc_dss;
static struct { uint32_t cfmt[8], dfmt, sfmt; int hd, hs; NSUInteger tw, th; } g_pass;
static struct { int depth, wrote; } g_sd[2];
static int g_nsd = 2, g_enc_vis, g_pso_dirty, g_dss_dirty, dirty;
static int z_pass_depth_written;
static void args_dirty_all(void) { dirty++; }
#define MDIE(...) do { fprintf(stderr, __VA_ARGS__); abort(); } while (0)
#define enc_r_pso(e,p) [(e) setRenderPipelineState:(p)]
#define enc_r_dss(e,s) [(e) setDepthStencilState:(s)]
#define enc_r_viewport(e,...) [(e) setViewport:__VA_ARGS__]
#define enc_r_scissor(e,...) [(e) setScissorRect:__VA_ARGS__]
#define enc_r_cull(e,m) [(e) setCullMode:(m)]
#define enc_r_fill(e,m) [(e) setTriangleFillMode:(m)]
#define enc_r_depth_bias(e,u,s,c) [(e) setDepthBias:(u) slopeScale:(s) clamp:(c)]
#define enc_r_depth_clip(e,v) [(e) setDepthClipMode:(v) ? MTLDepthClipModeClip : MTLDepthClipModeClamp]
#define enc_r_stencil_ref(e,f,b) [(e) setStencilReferenceValue:(f)]
#define enc_r_visibility(e,m,o) [(e) setVisibilityResultMode:(m) offset:(o)]
#include "../host/nvn_depth_clear.inc"

int main(void) { @autoreleasepool {
    g_dev = MTLCreateSystemDefaultDevice(); assert(g_dev);
    NSError *error = nil;
    z_query_library = [g_dev newLibraryWithSource:@(zelda_query_msl) options:nil error:&error]; assert(z_query_library);
    id<MTLLibrary> draw_library = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; vertex float4 vs(uint i [[vertex_id]]) { float2 p[]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0.5,1); } fragment float4 fs(){ return float4(1,0,0,1); }" options:nil error:&error]; assert(draw_library);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [draw_library newFunctionWithName:@"vs"]; pd.fragmentFunction = [draw_library newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    pd.depthAttachmentPixelFormat = pd.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    id<MTLRenderPipelineState> draw_pipeline = [g_dev newRenderPipelineStateWithDescriptor:pd error:&error]; assert(draw_pipeline);
    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new]; ds.depthCompareFunction = MTLCompareFunctionLess;
    id<MTLDepthStencilState> draw_depth = [g_dev newDepthStencilStateWithDescriptor:ds];
    pd.vertexFunction = [z_query_library newFunctionWithName:@"clear_vertex"];
    pd.fragmentFunction = [z_query_library newFunctionWithName:@"clear_if0"];
    id<MTLRenderPipelineState> color_clear = [g_dev newRenderPipelineStateWithDescriptor:pd error:&error]; assert(color_clear);
    ds.depthCompareFunction = MTLCompareFunctionAlways;
    id<MTLDepthStencilState> color_depth = [g_dev newDepthStencilStateWithDescriptor:ds];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 3;
    z_query_args = [g_dev newArgumentTableWithDescriptor:ad error:&error];
    g_vt = [g_dev newArgumentTableWithDescriptor:ad error:&error]; g_ft = [g_dev newArgumentTableWithDescriptor:ad error:&error];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> color = [g_dev newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    id<MTLTexture> depth = [g_dev newTextureWithDescriptor:td];
    id<MTLBuffer> parameters = [g_dev newBufferWithLength:512 options:MTLResourceStorageModeShared];
    id<MTLBuffer> query = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    uint64_t sample = 0x100000007ull;
    id<MTLBuffer> staging = [g_dev newBufferWithBytes:&sample length:8 options:MTLResourceStorageModeShared];
    id<MTLBuffer> pixels = [g_dev newBufferWithLength:3 * 2048 options:MTLResourceStorageModeShared];
    id<MTLBuffer> visibility = [g_dev newBufferWithLength:8 options:MTLResourceStorageModeShared];
    id<MTL4CommandQueue> queue = [g_dev newMTL4CommandQueue];
    id<MTL4CommandAllocator> allocator = [g_dev newCommandAllocator];
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
    id<MTLResidencySet> residency = [g_dev newResidencySetWithDescriptor:rd error:&error];
    for (id<MTLAllocation> resource in @[color, depth, parameters, query, staging, pixels, visibility]) [residency addAllocation:resource];
    [residency commit]; [queue addResidencySet:residency];
    for (int test = 0; test < 14; test++) {
        memset(parameters.contents, 0, parameters.length); ((float *)parameters.contents)[0] = .25f;
        ((uint32_t *)parameters.contents)[4] = test == 1 || test == 7 ? 1 : 0;
        ((uint32_t *)parameters.contents)[5] = test >= 7 && test < 10 ? test - 6 : 0;
        uint64_t *q = query.contents; q[0] = q[4] = 0; q[2] = test == 2 || test >= 12 ? 9 : sample;
        q[6] = test == 11 || test == 12 ? 0 : 9;
        float *rgba = (float *)((uint8_t *)parameters.contents + 256); rgba[2] = rgba[3] = 1;
        ((uint32_t *)rgba)[5] = 1; // The later timestamp's known zero need not overwrite the earlier predicate yet.
        *(uint64_t *)visibility.contents = 0;
        id<MTL4CommandBuffer> command = [g_dev newCommandBuffer]; [command beginCommandBufferWithAllocator:allocator];
        id<MTL4ComputeCommandEncoder> compute = [command computeCommandEncoder];
        // The vertex predicate must observe a query value produced on the GPU.
        [compute copyFromBuffer:staging sourceOffset:0 toBuffer:query destinationOffset:0 size:8];
        [compute copyFromBuffer:staging sourceOffset:0 toBuffer:query destinationOffset:32 size:8];
        [compute barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [compute endEncoding];
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1); pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = MTLLoadActionClear;
        pass.depthAttachment.clearDepth = .75; pass.depthAttachment.storeAction = MTLStoreActionStore;
        pass.stencilAttachment.texture = depth; pass.stencilAttachment.loadAction = MTLLoadActionClear;
        pass.stencilAttachment.clearStencil = 0xa5; pass.stencilAttachment.storeAction = MTLStoreActionStore;
        pass.visibilityResultBuffer = visibility;
        if (test == 6) pass.colorAttachments[0].texture = nil;
        g_enc = [command renderCommandEncoderWithDescriptor:pass];
        [g_enc barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        g_pass = (typeof(g_pass)){.cfmt={MTLPixelFormatRGBA8Unorm}, .dfmt=td.pixelFormat, .sfmt=td.pixelFormat, .hd=1, .hs=1, .tw=8, .th=8};
        if (test == 6) g_pass.cfmt[0] = 0;
        g_sd[0] = (typeof(g_sd[0])){.depth=1}; g_sd[1] = (typeof(g_sd[1])){.depth=2};
        z_depth_clear = (typeof(z_depth_clear)){.pending=1, .has_scissor=test != 5, .parameters=parameters.gpuAddress, .query=query.gpuAddress,
            .clear={.depth=.25, .depth_mask=test != 3, .stencil=0x3c, .stencil_mask=0x0f},
            .scissor={2, 2, test == 4 ? 0 : 4, 4}};
        dirty = g_pso_dirty = g_dss_dirty = z_pass_depth_written = 0; zelda_depth_clear_encode();
        assert(!z_depth_clear.pending);
        assert(z_pass_depth_written == (test != 4));
        if (test != 4) assert(dirty && g_pso_dirty && g_dss_dirty && !g_enc_pso && !g_enc_dss && !g_enc_vis);
        if (test == 6) {
            // A forced flush writes only depth/stencil; subsequent geometry loads those results.
            [g_enc barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [g_enc endEncoding];
            pass.depthAttachment.loadAction = pass.stencilAttachment.loadAction = MTLLoadActionLoad;
            pass.colorAttachments[0].texture = color;
            g_enc = [command renderCommandEncoderWithDescriptor:pass];
            [g_enc barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
            [g_enc setArgumentTable:g_vt atStages:MTLRenderStageVertex]; [g_enc setArgumentTable:g_ft atStages:MTLRenderStageFragment];
        }
        if (test >= 10) {
            // Independent colour and depth predicates share a pass; their disjoint writes commute.
            [z_query_args setAddress:query.gpuAddress + 32 atIndex:0];
            [z_query_args setAddress:parameters.gpuAddress + 256 atIndex:1];
            [g_enc setArgumentTable:z_query_args atStages:(MTLRenderStageVertex | MTLRenderStageFragment)];
            [g_enc setRenderPipelineState:color_clear]; [g_enc setDepthStencilState:color_depth];
            [g_enc setScissorRect:(MTLScissorRect){2, 2, 4, 4}];
            [g_enc setVisibilityResultMode:MTLVisibilityResultModeDisabled offset:0];
            [g_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [g_enc setArgumentTable:g_vt atStages:MTLRenderStageVertex]; [g_enc setArgumentTable:g_ft atStages:MTLRenderStageFragment];
        }
        // Real geometry follows the clear in the same encoder, with restored bindings and depth state.
        [g_enc setRenderPipelineState:draw_pipeline]; [g_enc setDepthStencilState:draw_depth];
        [g_enc setViewport:(MTLViewport){0, 0, 8, 8, 0, 1}]; [g_enc setScissorRect:(MTLScissorRect){0, 0, 8, 8}];
        if (test >= 10) [g_enc setScissorRect:(MTLScissorRect){0, 0, 4, 8}];
        [g_enc setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
        [g_enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [g_enc barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [g_enc endEncoding];
        compute = [command computeCommandEncoder];
        [compute barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        for (int plane = 0; plane < 3; plane++)
            [compute copyFromTexture:plane ? depth : color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(8,8,1) toBuffer:pixels destinationOffset:plane * 2048 destinationBytesPerRow:256 destinationBytesPerImage:2048
                options:plane == 0 ? MTLBlitOptionNone : plane == 1 ? MTLBlitOptionDepthFromDepthStencil : MTLBlitOptionStencilFromDepthStencil];
        [compute barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [compute endEncoding];
        [command endCommandBuffer]; id<MTL4CommandBuffer> commands[] = {command};
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        MTL4CommitOptions *options = [MTL4CommitOptions new];
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { assert(!feedback.error); dispatch_semaphore_signal(done); }];
        [queue commit:commands count:1 options:options];
        assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        unsigned visible = 0;
        for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) {
            int inside = test == 5 || (test != 4 && x >= 2 && x < 6 && y >= 2 && y < 6);
            int cleared = inside && test != 1 && test != 2 && test != 8 && test < 12;
            int changed_depth = cleared && test != 3;
            uint8_t *p = (uint8_t *)pixels.contents + y * 256;
            assert(fabsf(*(float *)(p + 2048 + 4 * x) - (changed_depth ? .25f : .75f)) < 1e-6);
            assert(p[4096 + x] == (cleared ? 0xac : 0xa5));
            int drawn = !changed_depth && (test < 10 || x < 4), blue = inside && (test == 11 || test == 12);
            assert(p[4*x] == (drawn ? 255 : 0) && p[4*x+1] == (!drawn && !blue ? 255 : 0) && p[4*x+2] == (!drawn && blue ? 255 : 0));
            visible += drawn;
        }
        assert(*(uint64_t *)visibility.contents == visible);
        [allocator reset];
    }
    puts("Metal 4 inline conditional colour/depth/stencil, independent predicates, masks, scissor, following draw and visibility checks passed");
} }
