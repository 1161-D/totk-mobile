#import <Metal/Metal.h>
#include <assert.h>
#include "nvn_obj.h"
#include "../host/nvn_cube_pass.h"
static void end_encoder(id encoder) {
    [encoder barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
}
int main(void) { @autoreleasepool {
    tex_t t={.serial=1,.d={.target=NVN_TEXTURE_TARGET_CUBEMAP,.format=92}};
    p_set_rt rt={.n=1,.color={&t},.has_cview={1},.cview={{.set_layers=1,.nlayers=1}}},other=rt;
    z_cube_active=1;other.cview[0].min_layer=5;assert(zelda_cube_same(&rt,&other));
    other.cview[0].min_layer=6;assert(zelda_cube_face(&other)<0);other=rt;
    other.cview[0].set_levels=1;other.cview[0].base_level=1;assert(!zelda_cube_same(&rt,&other));other=rt;
    other.depth=&t;assert(zelda_cube_face(&other)<0);other=rt;
    other.cview[0].set_format=1;other.cview[0].format=1;assert(zelda_cube_face(&other)<0);
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);NSError *error=nil;
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal; struct main0_out\n{ float4 p [[position]];\n    float gl_PointSize [[point_size]];\n}; vertex main0_out main0(uint i [[vertex_id]],constant float& zelda_point_size [[buffer(15)]]){main0_out out;\n    out.gl_PointSize = zelda_point_size;\n out.p=float4(i==1?3.0:-1.0,i==2?3.0:-1.0,0,1);\n    return out;\n} fragment uint4 fs(constant uint& value [[buffer(0)]]){return uint4(value,11,22,255);}";
    assert(!zelda_cube_source(@"unknown"));assert(zelda_cube_source(source));
    id<MTLLibrary> libraries[]={ [device newLibraryWithSource:source options:nil error:&error],
        [device newLibraryWithSource:zelda_cube_source(source) options:nil error:&error] };
    id<MTLRenderPipelineState> pipelines[2];id<MTLTexture> textures[2];
    MTLTextureDescriptor *td=[MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Uint size:8 mipmapped:YES];td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageRenderTarget;
    for(unsigned i=0;i<2;i++){
        assert(libraries[i]);MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.inputPrimitiveTopology=i?MTLPrimitiveTopologyClassTriangle:MTLPrimitiveTopologyClassUnspecified;
        pd.vertexFunction=[libraries[i] newFunctionWithName:@"main0"];pd.fragmentFunction=[libraries[i] newFunctionWithName:@"fs"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Uint;
        pipelines[i]=[device newRenderPipelineStateWithDescriptor:pd error:&error];assert(pipelines[i]);textures[i]=[device newTextureWithDescriptor:td];assert(textures[i]);
    }
    id<MTLBuffer> values=[device newBufferWithLength:6*256 options:MTLResourceStorageModeShared],output=[device newBufferWithLength:2*6*6*256 options:MTLResourceStorageModeShared];
    // Occlusion counting stays on in game scenes: per-face passes count into one slot each; the layered pass keeps one
    // slot until a report switches it (here after face 2), and the sums must match.
    id<MTLBuffer> visibility=[device newBufferWithLength:8*8 options:MTLResourceStorageModeShared];memset(visibility.contents,0,visibility.length);
    for(unsigned i=0;i<6;i++){uint32_t *v=(uint32_t*)((uint8_t*)values.contents+256*i);v[0]=i;v[1]=i+1;}
    memset(output.contents,0xa5,output.length);
    id<MTLResidencySet> residency=[device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];for(id<MTLAllocation> r in @[textures[0],textures[1],values,output,visibility])[residency addAllocation:r];[residency commit];
    id<MTL4CommandQueue> queue=[device newMTL4CommandQueue];[queue addResidencySet:residency];
    id<MTL4CommandAllocator> allocator=[device newCommandAllocator];id<MTL4CommandBuffer> command=[device newCommandBuffer];[command beginCommandBufferWithAllocator:allocator];
    MTL4ArgumentTableDescriptor *ad=[MTL4ArgumentTableDescriptor new];ad.maxBufferBindCount=16;id<MTL4ArgumentTable> table=[device newArgumentTableWithDescriptor:ad error:&error];
    for(unsigned version=0;version<2;version++){
        for(unsigned level=1;level<=2;level++)for(unsigned face=0;face<6;face++){
            MTL4RenderPassDescriptor *pass=[MTL4RenderPassDescriptor new];pass.colorAttachments[0].texture=textures[version];pass.colorAttachments[0].level=level;pass.colorAttachments[0].slice=face;
            pass.colorAttachments[0].loadAction=MTLLoadActionClear;pass.colorAttachments[0].clearColor=MTLClearColorMake(7,7,7,7);pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            z_cube_requested=face;zelda_cube_descriptor(pass,1);assert(!z_cube_active&&pass.renderTargetArrayLength<=1);
            id e=[command renderCommandEncoderWithDescriptor:pass];[e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];end_encoder(e);
        }
        id<MTL4RenderCommandEncoder> encoder=nil;
        for(unsigned face=0;face<6;face++){
            if(!encoder){
                MTL4RenderPassDescriptor *pass=[MTL4RenderPassDescriptor new];pass.colorAttachments[0].texture=textures[version];pass.colorAttachments[0].level=1;pass.colorAttachments[0].slice=face;
                pass.colorAttachments[0].loadAction=MTLLoadActionLoad;pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.visibilityResultBuffer=visibility;
                z_cube_requested=version?face:-1;zelda_cube_descriptor(pass,1);assert(z_cube_active==(version==1));
                encoder=[command renderCommandEncoderWithDescriptor:pass];[encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
                [encoder setRenderPipelineState:pipelines[version]];[encoder setViewport:(MTLViewport){0,0,4,4,0,1}];[encoder setScissorRect:(MTLScissorRect){1,1,2,2}];
            }
            [table setAddress:values.gpuAddress atIndex:15];[table setAddress:values.gpuAddress+256*face atIndex:14];[table setAddress:values.gpuAddress+256*face+4 atIndex:0];
            if(!version||face==0||face==3)[encoder setVisibilityResultMode:MTLVisibilityResultModeCounting offset:8*(version?6+(face>2):face)];
            [encoder setArgumentTable:table atStages:MTLRenderStageVertex|MTLRenderStageFragment];[encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            if(!version){end_encoder(encoder);encoder=nil;}
        }
        if(encoder)end_encoder(encoder);
        id<MTL4ComputeCommandEncoder> copy=[command computeCommandEncoder];[copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        for(unsigned face=0;face<6;face++)for(unsigned level=1;level<=2;level++){
            unsigned width=8>>level,offset=(version*36+face*6+(level==1?0:4))*256;
            [copy copyFromTexture:textures[version] sourceSlice:face sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,width,1) toBuffer:output destinationOffset:offset destinationBytesPerRow:256 destinationBytesPerImage:256*width];
        }
        end_encoder(copy);
    }
    [command endCommandBuffer];dispatch_semaphore_t done=dispatch_semaphore_create(0);MTL4CommitOptions *options=[MTL4CommitOptions new];[options addFeedbackHandler:^(id<MTL4CommitFeedback> f){assert(!f.error);dispatch_semaphore_signal(done);}];id<MTL4CommandBuffer> batch[]={command};[queue commit:batch count:1 options:options];assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    assert(!memcmp(output.contents,(uint8_t*)output.contents+36*256,36*256));
    for(unsigned face=0;face<6;face++)for(unsigned y=0;y<4;y++)for(unsigned x=0;x<4;x++){
        uint8_t *p=(uint8_t*)output.contents+(face*6+y)*256+4*x;int inside=x>=1&&x<3&&y>=1&&y<3;
        assert(p[0]==(inside?face+1:7)&&p[1]==(inside?11:7)&&p[2]==(inside?22:7)&&p[3]==(inside?255:7));
    }
    const uint64_t *counts=visibility.contents;
    for(unsigned face=0;face<6;face++)assert(counts[face]==4);
    assert(counts[6]==counts[0]+counts[1]+counts[2]&&counts[7]==counts[3]+counts[4]+counts[5]);
    assert(z_cube_passes==1&&!z_cube_draws);
    puts("Metal 4 cube batching: six original draws, layer routing, scissor, load preservation, other mip and fallback guards, occlusion counts across layers passed");
} }
