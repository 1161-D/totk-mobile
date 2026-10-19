#import <Metal/Metal.h>
#include <assert.h>
#include "nvn_obj.h"
#include "../host/nvn_query_msl.h"
#include "../host/nvn_conditional_draw.h"

static void end_encoder(id e) {
    [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}
int main(void) { @autoreleasepool {
    enum { CASES = 24, ROW = 768, HEIGHT = 8 };
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device); NSError *error = nil;
    NSString *draw = @"\nstruct V { float4 p [[position]]; uint value [[flat]]; };\n"
        "vertex V vs(uint v [[vertex_id]], uint i [[instance_id]]) {\n"
        " float2 p[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};\n"
        " bool valid = v >= 5 && v < 8 && i >= 7 && i < 9;\n"
        " return {float4(valid ? p[(v-5)%3] : float2(2),0,1),i-6}; }\n"
        "fragment uint4 fs(V v [[stage_in]]) { return uint4(v.value,17,29,255); }\n";
    id<MTLLibrary> library = [device newLibraryWithSource:[@(zelda_conditional_msl) stringByAppendingString:draw] options:nil error:&error];
    if (!library) NSLog(@"%@", error); assert(library);
    id<MTLComputePipelineState> predicate = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"conditional_draw"] error:&error]; assert(predicate);
    id<MTLLibrary> query_library = [device newLibraryWithSource:@(zelda_query_msl) options:nil error:&error]; assert(query_library);
    id<MTLComputePipelineState> sum = [device newComputePipelineStateWithFunction:[query_library newFunctionWithName:@"query_sum"] error:&error]; assert(sum);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"vs"]; pd.fragmentFunction = [library newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Uint;
    id<MTLRenderPipelineState> render = [device newRenderPipelineStateWithDescriptor:pd error:&error]; assert(render);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Uint width:CASES*8 height:HEIGHT mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:td];
    id<MTLBuffer> inputs = [device newBufferWithLength:CASES*sizeof(zelda_conditional_input) options:MTLResourceStorageModeShared];
    id<MTLBuffer> outputs = [device newBufferWithLength:CASES*sizeof(zelda_conditional_output) options:MTLResourceStorageModeShared];
    id<MTLBuffer> queries = [device newBufferWithLength:CASES*32 options:MTLResourceStorageModeShared];
    id<MTLBuffer> values = [device newBufferWithLength:CASES*16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> sums = [device newBufferWithLength:CASES*32 options:MTLResourceStorageModeShared];
    id<MTLBuffer> indices = [device newBufferWithLength:32 options:MTLResourceStorageModeShared];
    id<MTLBuffer> visibility = [device newBufferWithLength:CASES*8 options:MTLResourceStorageModeShared];
    id<MTLBuffer> pixels = [device newBufferWithLength:ROW*HEIGHT options:MTLResourceStorageModeShared];
    uint16_t short_indices[] = {99,10,11,12}; uint32_t long_indices[] = {99,10,11,12};
    memcpy(indices.contents, short_indices, sizeof short_indices); memcpy((uint8_t *)indices.contents+16, long_indices, sizeof long_indices);
    id<MTLResidencySet> residency = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    for (id<MTLAllocation> r in @[target,inputs,outputs,queries,values,sums,indices,visibility,pixels]) [residency addAllocation:r];
    [residency commit]; id<MTL4CommandQueue> queue = [device newMTL4CommandQueue]; [queue addResidencySet:residency];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 2;
    id<MTL4ArgumentTable> table = [device newArgumentTableWithDescriptor:ad error:&error]; assert(table);
    for (unsigned round = 0; round < 3; round++) {
        memset(queries.contents,0xa5,queries.length); memset(outputs.contents,0xa5,outputs.length); memset(visibility.contents,0xa5,visibility.length); // Zero-count draws must overwrite stale query slots.
        zelda_conditional_input *p = inputs.contents;
        for (unsigned i = 0; i < CASES; i++) {
            unsigned kind = i % 3, mode = i/3 % 2, pair = i/6;
            uint64_t a[] = {0,1,0,0x100000007ull}, b[] = {0,0,1,0x100000007ull};
            ((uint64_t *)values.contents)[2*i] = a[pair] ^ (round ? 0x100000000ull : 0);
            ((uint64_t *)values.contents)[2*i+1] = b[pair];
            uint64_t *q = (uint64_t *)sums.contents + 4*i;
            q[0]=q[2]=1; q[1]=values.gpuAddress+16*i; q[3]=q[1]+8;
            p[i]=(zelda_conditional_input){.predicate=queries.gpuAddress+32*i,.mode=mode,.indexed=kind!=0,
                .args={3,2,kind?1:5,kind?(uint32_t)-5:7,kind?7:0}};
        }
        id<MTL4CommandAllocator> allocator = [device newCommandAllocator]; id<MTL4CommandBuffer> command = [device newCommandBuffer];
        NSMutableArray *previous = [NSMutableArray array];
        [command beginCommandBufferWithAllocator:allocator];
        id<MTL4ComputeCommandEncoder> compute = [command computeCommandEncoder];
        [compute barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        [compute setArgumentTable:table]; [compute setComputePipelineState:sum];
        for (unsigned i = 0; i < CASES; i++) for (unsigned side = 0; side < 2; side++) {
            [table setAddress:queries.gpuAddress+32*i+16*side atIndex:0]; [table setAddress:sums.gpuAddress+32*i+16*side atIndex:1];
            [compute dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
        }
        if (round == 2) {
            end_encoder(compute); [command endCommandBuffer];
            [previous addObject:allocator]; [previous addObject:command];
            MTL4CommitOptions *first = [MTL4CommitOptions new];
            [first addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { assert(!feedback.error); }];
            id<MTL4CommandBuffer> batch[] = {command}; [queue commit:batch count:1 options:first];
            allocator = [device newCommandAllocator]; command = [device newCommandBuffer];
            [command beginCommandBufferWithAllocator:allocator]; compute = [command computeCommandEncoder];
            [compute barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
            [compute setArgumentTable:table];
        }
        [compute barrierAfterEncoderStages:MTLStageDispatch beforeEncoderStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
        [table setAddress:inputs.gpuAddress atIndex:0]; [table setAddress:outputs.gpuAddress atIndex:1]; [compute setComputePipelineState:predicate];
        // Same kernel covers the simple (one item) and batched paths.
        if (!round) for (unsigned i=0;i<CASES;i++) {
            [table setAddress:inputs.gpuAddress+i*sizeof(*p) atIndex:0]; [table setAddress:outputs.gpuAddress+i*sizeof(zelda_conditional_output) atIndex:1];
            [compute dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
        } else [compute dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(CASES,1,1)];
        end_encoder(compute);
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new]; pass.colorAttachments[0].texture=target;
        pass.colorAttachments[0].loadAction=MTLLoadActionClear; pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
        pass.colorAttachments[0].storeAction=MTLStoreActionStore; pass.visibilityResultBuffer=visibility;
        id<MTL4RenderCommandEncoder> e = [command renderCommandEncoderWithDescriptor:pass];
        [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [e setRenderPipelineState:render];
        for (unsigned i=0;i<CASES;i++) {
            unsigned kind=i%3; uint64_t address=outputs.gpuAddress+i*sizeof(zelda_conditional_output);
            [e setViewport:(MTLViewport){i*8,0,8,8,0,1}]; [e setScissorRect:(MTLScissorRect){i*8,0,8,8}];
            [e setVisibilityResultMode:MTLVisibilityResultModeCounting offset:i*8];
            if (!kind) [e drawPrimitives:MTLPrimitiveTypeTriangle indirectBuffer:address];
            else [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:kind==1?MTLIndexTypeUInt16:MTLIndexTypeUInt32
                indexBuffer:indices.gpuAddress+(kind==1?0:16) indexBufferLength:kind==1?8:16 indirectBuffer:address];
        }
        end_encoder(e);
        id<MTL4ComputeCommandEncoder> copy=[command computeCommandEncoder];
        [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
        [copy copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(CASES*8,HEIGHT,1)
            toBuffer:pixels destinationOffset:0 destinationBytesPerRow:ROW destinationBytesPerImage:ROW*HEIGHT]; end_encoder(copy);
        [command endCommandBuffer]; dispatch_semaphore_t done=dispatch_semaphore_create(0);
        MTL4CommitOptions *options=[MTL4CommitOptions new]; [options addFeedbackHandler:^(id<MTL4CommitFeedback> f){assert(!f.error);dispatch_semaphore_signal(done);}];
        id<MTL4CommandBuffer> batch[]={command}; [queue commit:batch count:1 options:options];
        assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
        [previous removeAllObjects]; // The earlier allocator stays alive until the dependent command buffer finishes.
        const zelda_conditional_output *out=outputs.contents;
        for(unsigned i=0;i<CASES;i++) {
            uint64_t *q=(uint64_t *)queries.contents+4*i;
            p_render_enable state={.address=1,.mode=p[i].mode}; int enabled=nvn_render_test(&state,q);
            assert(out[i].enabled==(unsigned)enabled && out[i].left==q[0] && out[i].right==q[2]);
            assert(q[0]==((uint64_t *)values.contents)[2*i] && q[2]==((uint64_t *)values.contents)[2*i+1]);
            assert(q[1]==0xa5a5a5a5a5a5a5a5ull && q[3]==q[1]);
            for(unsigned k=0;k<5;k++) assert(out[i].args[k]==(k==0&&!enabled?0:p[i].args[k]));
            assert(((uint64_t *)visibility.contents)[i]==(enabled?128:0));
            for(unsigned y=0;y<HEIGHT;y++) for(unsigned x=i*8;x<(i+1)*8;x++) {
                const uint8_t *pixel=(uint8_t *)pixels.contents+y*ROW+4*x;
                assert(pixel[0]==(enabled?2:0) && pixel[1]==(enabled?17:0) && pixel[2]==(enabled?29:0) && pixel[3]==(enabled?255:0));
            }
        }
    }
    puts("Metal 4 conditional draws: 72 GPU-query cases including cross-submit counts, equal/not-equal, 64-bit counts, indirect U16/U32/nonindexed, starts/base vertex/base instance, visibility and pixels passed");
} }
