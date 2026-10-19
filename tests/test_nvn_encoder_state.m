#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <math.h>

@interface TestEncoder : NSObject {
@public unsigned calls[9];
    MTLViewport viewport; MTLScissorRect scissor;
    MTLCullMode cull; MTLWinding winding; MTLTriangleFillMode fill;
    MTLDepthClipMode clip; uint32_t stencil; float bias[3], blend[4];
}
- (void)setViewport:(MTLViewport)v;
- (void)setScissorRect:(MTLScissorRect)v;
- (void)setCullMode:(MTLCullMode)v;
- (void)setFrontFacingWinding:(MTLWinding)v;
- (void)setTriangleFillMode:(MTLTriangleFillMode)v;
- (void)setDepthBias:(float)u slopeScale:(float)s clamp:(float)c;
- (void)setDepthClipMode:(MTLDepthClipMode)v;
- (void)setStencilReferenceValue:(uint32_t)v;
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a;
@end
@implementation TestEncoder
- (void)setViewport:(MTLViewport)v { calls[0]++; viewport=v; }
- (void)setScissorRect:(MTLScissorRect)v { calls[1]++; scissor=v; }
- (void)setCullMode:(MTLCullMode)v { calls[2]++; cull=v; }
- (void)setFrontFacingWinding:(MTLWinding)v { calls[3]++; winding=v; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)v { calls[4]++; fill=v; }
- (void)setDepthBias:(float)u slopeScale:(float)s clamp:(float)c { calls[5]++; bias[0]=u; bias[1]=s; bias[2]=c; }
- (void)setDepthClipMode:(MTLDepthClipMode)v { calls[6]++; clip=v; }
- (void)setStencilReferenceValue:(uint32_t)v { calls[7]++; stencil=v; }
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a { calls[8]++; blend[0]=r; blend[1]=g; blend[2]=b; blend[3]=a; }
@end
@interface TestArguments : NSObject { @public unsigned calls; uint64_t values[32]; }
- (void)setAddress:(uint64_t)address atIndex:(NSUInteger)index;
@end
@implementation TestArguments
- (void)setAddress:(uint64_t)address atIndex:(NSUInteger)index { assert(index < 32); values[index]=address; calls++; }
@end
typedef id RENC;
#include "../host/nvn_encoder_state.inc"

static void state(id e, unsigned n) {
    enc_r_viewport(e, (MTLViewport){1+n,2,32,32,0,1});
    enc_r_scissor(e, (MTLScissorRect){n,2,8,8});
    enc_r_cull(e, n ? MTLCullModeBack : MTLCullModeNone);
    enc_r_winding(e, n ? MTLWindingClockwise : MTLWindingCounterClockwise);
    enc_r_fill(e, n ? MTLTriangleFillModeLines : MTLTriangleFillModeFill);
    enc_r_depth_bias(e, 0, n, 0);
    enc_r_depth_clip(e, n != 0);
    enc_r_stencil_ref(e, n, 99);
    enc_r_blend_color(e, 1, .5, .25, n);
}
static void gpu_check(void) {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); assert(device);
    NSError *error=nil;
    id<MTLLibrary> library=[device newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 v(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\nfragment float4 f(){return float4(1,1,1,1);}" options:nil error:&error]; assert(library);
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
    pd.vertexFunction=[library newFunctionWithName:@"v"]; pd.fragmentFunction=[library newFunctionWithName:@"f"];
    pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    pd.colorAttachments[0].blendingEnabled=YES; pd.colorAttachments[0].sourceRGBBlendFactor=MTLBlendFactorBlendColor;
    pd.colorAttachments[0].destinationRGBBlendFactor=MTLBlendFactorZero;
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd error:&error]; assert(pipeline);
    id<MTL4CommandQueue> queue=[device newMTL4CommandQueue];
    id<MTL4CommandAllocator> allocator=[device newCommandAllocator];
    id<MTLResidencySet> residency=[device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    [queue addResidencySet:residency];
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:NO];
    td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> texture=[device newTextureWithDescriptor:td];assert(texture);
    id<MTLBuffer> output=[device newBufferWithLength:2*32*256 options:MTLResourceStorageModeShared];assert(output);
    [residency addAllocation:texture];[residency addAllocation:output];[residency commit];
    memset(output.contents,0,output.length);
    id<MTL4CommandBuffer> cb=[device newCommandBuffer];[cb beginCommandBufferWithAllocator:allocator];
    for(unsigned mode=0;mode<2;mode++) {
        z_encoder_state_enabled=mode;zelda_encoder_state_reset();
        MTL4RenderPassDescriptor *pass=[MTL4RenderPassDescriptor new];
        pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;
        id<MTL4RenderCommandEncoder> e=[cb renderCommandEncoderWithDescriptor:pass];
        [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        [e setRenderPipelineState:pipeline];
        for(unsigned i=0;i<40;i++) {
            state(e,(i/10)&1);
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];[e endEncoding];
        id<MTL4ComputeCommandEncoder> copy=[cb computeCommandEncoder];
        [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        [copy copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(32,32,1)
            toBuffer:output destinationOffset:mode*32*256 destinationBytesPerRow:256 destinationBytesPerImage:32*256];
        [copy barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];[copy endEncoding];
    }
    [cb endCommandBuffer];dispatch_semaphore_t done=dispatch_semaphore_create(0);
    MTL4CommitOptions *options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> f){assert(!f.error);dispatch_semaphore_signal(done);}];
    id<MTL4CommandBuffer> batch[]={cb};[queue commit:batch count:1 options:options];
    assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    assert(!memcmp(output.contents,(uint8_t *)output.contents+32*256,32*256));
    unsigned nonzero=0;for(unsigned i=0;i<32*256;i++)nonzero+=((uint8_t *)output.contents)[i]!=0;assert(nonzero);
}
int main(void) { @autoreleasepool {
    setenv("ZELDA_ENCODER_STATE_CACHE", "1", 1);
    TestEncoder *e=[TestEncoder new]; zelda_encoder_state_reset();
    for(unsigned i=0;i<100;i++) state(e,0);
    assert(z_encoder_state_sent==9 && z_encoder_state_reused==891);
    state(e,1); for(unsigned i=0;i<9;i++) assert(e->calls[i]==2);
    assert(e->viewport.originX==2 && e->scissor.x==1 && e->cull==MTLCullModeBack);
    assert(e->winding==MTLWindingClockwise && e->fill==MTLTriangleFillModeLines && e->bias[1]==1);
    assert(e->clip==MTLDepthClipModeClip && e->stencil==1 && e->blend[3]==1);
    state(e,0); state(e,1); // A helper changes state; returning to the game must restore it.
    for(unsigned i=0;i<9;i++) assert(e->calls[i]==4);
    zelda_encoder_state_reset(); state(e,1); // Same object address, fresh pass defaults.
    for(unsigned i=0;i<9;i++) assert(e->calls[i]==5);
    enc_r_depth_bias(e,-0.0f,1,0); assert(e->calls[5]==6 && signbit(e->bias[0]));
    z_encoder_state_enabled=0; state(e,1); state(e,1);
    for(unsigned i=0;i<9;i++) assert(e->calls[i]==(i==5 ? 8u : 7u));
    TestArguments *vertex=[TestArguments new], *fragment=[TestArguments new];
    z_encoder_state_enabled=1;zelda_encoder_state_reset();
    for(unsigned i=0;i<20;i++) {
        zelda_encoder_buffer((id)vertex,0,30,0x1000);
        zelda_encoder_buffer((id)fragment,1,30,0x2000);
    }
    assert(vertex->calls==1 && fragment->calls==1 && fragment->values[30]==0x2000);
    zelda_encoder_buffer((id)vertex,0,30,0x3000);assert(vertex->calls==2 && vertex->values[30]==0x3000);
    zelda_encoder_state_reset();zelda_encoder_buffer((id)vertex,0,30,0x3000);assert(vertex->calls==3);
    zelda_encoder_buffer((id)vertex,0,31,0x4000);zelda_encoder_buffer((id)vertex,0,31,0x4000);assert(vertex->calls==5);
    z_encoder_state_enabled=0;
    zelda_encoder_buffer((id)vertex,0,30,0x3000);zelda_encoder_buffer((id)vertex,0,30,0x3000);assert(vertex->calls==7);
    gpu_check();
    puts("Encoder state: exact reuse, changed values, helper restoration, new pass and identical Metal readback passed");
} }
