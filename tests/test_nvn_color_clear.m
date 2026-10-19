#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../host/nvn_query_msl.h"

// Conditional colour clears drawn inside a two-target pass: the predicate compares the counter words at +0 and +16,
// words marked known are taken as zero (a pending timestamp report), and only the clear's slot is written.
typedef struct { float color[4]; uint32_t mode, known; uint32_t pad[2]; } Params;

static void end_encoder(id encoder) {
    [encoder barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [encoder endEncoding];
}
// Compare a separate conditional clear with an in-pass clear followed by a blended read from other mip levels.
static void test_mip_clear(id<MTLDevice> device, MTLPixelFormat format, int base, float lod, int target, int enabled) {
    NSError *error = nil;
    NSString *source = [@(zelda_query_msl) stringByAppendingString:
        @"fragment float4 read_mip(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s,float2(0.5)); }\n"];
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error]; assert(library);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"clear_vertex"];
    pd.fragmentFunction = [library newFunctionWithName:@"clear_if"]; pd.colorAttachments[0].pixelFormat = format;
    id<MTLRenderPipelineState> clear = [device newRenderPipelineStateWithDescriptor:pd error:&error]; assert(clear);
    pd.fragmentFunction = [library newFunctionWithName:@"read_mip"];
    pd.colorAttachments[0].blendingEnabled = YES;
    pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    id<MTLRenderPipelineState> sample = [device newRenderPipelineStateWithDescriptor:pd error:&error]; assert(sample);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:16 height:16 mipmapped:YES];
    td.storageMode = MTLStorageModeShared; td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> textures[] = {[device newTextureWithDescriptor:td], [device newTextureWithDescriptor:td]};
    id<MTLTexture> views[2];
    for (int i = 0; i < 2; i++) views[i] = [textures[i] newTextureViewWithPixelFormat:format textureType:MTLTextureType2D
        levels:NSMakeRange(base, 5 - base) slices:NSMakeRange(0, 1)];
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear; sd.mipFilter = MTLSamplerMipFilterLinear;
    sd.lodMinClamp = sd.lodMaxClamp = lod;
    id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:sd]; assert(sampler);
    id<MTLBuffer> queries = [device newBufferWithLength:32 options:MTLResourceStorageModeShared];
    memset(queries.contents, 0, 32); ((uint64_t *)queries.contents)[2] = enabled;
    id<MTLBuffer> parameters = [device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    *(Params *)parameters.contents = (Params){{0, 0.125f, 0, 0}, 1, 0, {0, 0}};
    if (enabled == 2) { ((Params *)parameters.contents)->mode = 0; ((Params *)parameters.contents)->known = 3; }
    *(Params *)((char *)parameters.contents + 32) = (Params){{0}, 0, 3, {0, 0}}; // always draw the sample
    id<MTLResidencySet> residency = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    for (id<MTLAllocation> r in @[textures[0], textures[1], queries, parameters]) [residency addAllocation:r];
    [residency commit];
    id<MTL4CommandQueue> queue = [device newMTL4CommandQueue]; [queue addResidencySet:residency];
    id<MTL4CommandAllocator> allocator = [device newCommandAllocator]; id<MTL4CommandBuffer> command = [device newCommandBuffer];
    [command beginCommandBufferWithAllocator:allocator];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new];
    ad.maxBufferBindCount = 2; ad.maxTextureBindCount = ad.maxSamplerStateBindCount = 1;
    id<MTL4ArgumentTable> table = [device newArgumentTableWithDescriptor:ad error:&error]; assert(table);
    [table setAddress:queries.gpuAddress atIndex:0]; [table setSamplerState:sampler.gpuResourceID atIndex:0];
    NSMutableArray *patches = [NSMutableArray array];
    for (int version = 0; version < 2; version++) {
        for (unsigned level = 0; level < 5; level++) {
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
            pass.colorAttachments[0].texture = textures[version]; pass.colorAttachments[0].level = level;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake((level + 1) / 16.0, 0, 0.125, 1);
            id e = [command renderCommandEncoderWithDescriptor:pass]; end_encoder(e);
        }
        [table setTexture:views[version].gpuResourceID atIndex:0];
        id<MTL4RenderCommandEncoder> encoder = nil; unsigned width = 16 >> target;
        for (int draw = 0; draw < 2; draw++) {
            if (!version && !draw && enabled == 2) {
                // Reference: the old partial-clear path clears a temporary texture, then copies the rectangle.
                MTLTextureDescriptor *patch_desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                    width:MAX(width / 2, 1) height:width mipmapped:NO];
                patch_desc.usage = MTLTextureUsageRenderTarget; patch_desc.storageMode = MTLStorageModePrivate;
                id<MTLTexture> patch = [device newTextureWithDescriptor:patch_desc]; assert(patch);
                [patches addObject:patch]; [residency addAllocation:patch]; [residency commit];
                MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
                pass.colorAttachments[0].texture = patch; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0.125, 0, 0);
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                id e = [command renderCommandEncoderWithDescriptor:pass]; end_encoder(e);
                id<MTL4ComputeCommandEncoder> copy = [command computeCommandEncoder];
                [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
                [copy copyFromTexture:patch sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                    sourceSize:MTLSizeMake(patch.width,patch.height,1) toTexture:textures[version] destinationSlice:0
                    destinationLevel:target destinationOrigin:MTLOriginMake(0,0,0)];
                end_encoder(copy); continue;
            }
            if (!encoder) {
                MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
                pass.colorAttachments[0].texture = textures[version]; pass.colorAttachments[0].level = target;
                pass.colorAttachments[0].loadAction = MTLLoadActionLoad; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                encoder = [command renderCommandEncoderWithDescriptor:pass];
                [encoder barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
                [encoder setViewport:(MTLViewport){0, 0, width, width, 0, 1}];
            }
            [table setAddress:parameters.gpuAddress + 32 * draw atIndex:1];
            [encoder setArgumentTable:table atStages:MTLRenderStageVertex | MTLRenderStageFragment];
            [encoder setScissorRect:(MTLScissorRect){0, 0, draw ? width : MAX(width / 2, 1), width}];
            [encoder setRenderPipelineState:draw ? sample : clear];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            if (!version || draw) { end_encoder(encoder); encoder = nil; }
        }
    }
    [command endCommandBuffer];
    dispatch_semaphore_t done = dispatch_semaphore_create(0); MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> f) { assert(!f.error); dispatch_semaphore_signal(done); }];
    id<MTL4CommandBuffer> batch[] = {command}; [queue commit:batch count:1 options:options];
    assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    for (unsigned level = 0; level < 5; level++) {
        uint8_t data[2][16 * 16 * 4]; unsigned width = 16 >> level;
        for (int v = 0; v < 2; v++) [textures[v] getBytes:data[v] bytesPerRow:width * 4
            fromRegion:MTLRegionMake2D(0, 0, width, width) mipmapLevel:level];
        assert(!memcmp(data[0], data[1], width * width * 4));
    }
}

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:@(zelda_query_msl) options:nil error:&error]; assert(library);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"clear_vertex"]; pd.fragmentFunction = [library newFunctionWithName:@"clear_if1"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; pd.colorAttachments[0].writeMask = MTLColorWriteMaskNone;
    pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&error]; assert(pipeline);
    // Cases: {q0, q2, mode, known, cleared?}. mode 1 renders when the words differ, mode 0 when they are equal.
    const struct { uint64_t q0, q2; uint32_t mode, known; int cleared; } cases[] = {
        {5, 5, 1, 0, 0}, {5, 5, 1, 1, 1}, {0, 7, 1, 2, 0}, {3, 3, 0, 0, 1}, {3, 9, 0, 3, 1}, {3, 9, 0, 1, 0},
    };
    enum { N = sizeof cases / sizeof *cases };
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLBuffer> queries = [device newBufferWithLength:N * 32 options:MTLResourceStorageModeShared];
    id<MTLBuffer> parameters = [device newBufferWithLength:N * sizeof(Params) options:MTLResourceStorageModeShared];
    id<MTLTexture> targets[N][2];
    for (unsigned i = 0; i < N; i++) {
        uint64_t *q = (uint64_t *)((uint8_t *)queries.contents + 32 * i); q[0] = cases[i].q0; q[1] = 77; q[2] = cases[i].q2; q[3] = 88;
        Params *p = (Params *)parameters.contents + i; *p = (Params){{1, 0, 0, 1}, cases[i].mode, cases[i].known, {0, 0}};
        for (int k = 0; k < 2; k++) targets[i][k] = [device newTextureWithDescriptor:td];
    }
    id<MTLResidencySet> residency = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    [residency addAllocation:queries]; [residency addAllocation:parameters];
    for (unsigned i = 0; i < N; i++) for (int k = 0; k < 2; k++) [residency addAllocation:targets[i][k]];
    [residency commit];
    id<MTL4CommandQueue> queue = [device newMTL4CommandQueue]; [queue addResidencySet:residency];
    id<MTL4CommandAllocator> allocator = [device newCommandAllocator]; id<MTL4CommandBuffer> command = [device newCommandBuffer];
    [command beginCommandBufferWithAllocator:allocator];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 2;
    id<MTL4ArgumentTable> table = [device newArgumentTableWithDescriptor:ad error:&error]; assert(table);
    for (unsigned i = 0; i < N; i++) {
        MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new];
        for (int k = 0; k < 2; k++) {
            pass.colorAttachments[k].texture = targets[i][k]; pass.colorAttachments[k].loadAction = MTLLoadActionClear;
            pass.colorAttachments[k].clearColor = MTLClearColorMake(0, 0, 1, 1); pass.colorAttachments[k].storeAction = MTLStoreActionStore;
        }
        id<MTL4RenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline];
        [table setAddress:queries.gpuAddress + 32 * i atIndex:0]; [table setAddress:parameters.gpuAddress + sizeof(Params) * i atIndex:1];
        [encoder setArgumentTable:table atStages:MTLRenderStageVertex | MTLRenderStageFragment];
        [encoder setViewport:(MTLViewport){0, 0, 4, 4, 0, 1}]; [encoder setScissorRect:(MTLScissorRect){1, 1, 2, 2}];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
    }
    [command endCommandBuffer];
    dispatch_semaphore_t done = dispatch_semaphore_create(0); MTL4CommitOptions *options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { assert(!feedback.error); dispatch_semaphore_signal(done); }];
    id<MTL4CommandBuffer> batch[] = {command}; [queue commit:batch count:1 options:options];
    assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    for (unsigned i = 0; i < N; i++) for (int k = 0; k < 2; k++) {
        uint8_t pixels[4 * 4 * 4]; [targets[i][k] getBytes:pixels bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
        for (unsigned y = 0; y < 4; y++) for (unsigned x = 0; x < 4; x++) {
            const uint8_t *p = pixels + 16 * y + 4 * x;
            int red = k == 1 && cases[i].cleared && x >= 1 && x < 3 && y >= 1 && y < 3;
            assert(p[0] == (red ? 255 : 0) && p[1] == 0 && p[2] == (red ? 0 : 255) && p[3] == 255);
        }
    }
    const MTLPixelFormat formats[] = {MTLPixelFormatRGBA8Unorm, MTLPixelFormatRG11B10Float, MTLPixelFormatRG16Float, MTLPixelFormatRGBA8Unorm_sRGB};
    for (unsigned format = 0; format < sizeof formats / sizeof *formats; format++) for (int enabled = 0; enabled < 3; enabled++) {
        MTLPixelFormat f = formats[format];
        test_mip_clear(device, f, 0, 1, 2, enabled);
        test_mip_clear(device, f, 1, 0, 0, enabled);
        test_mip_clear(device, f, 0, 1.5, 3, enabled);
        test_mip_clear(device, f, 1, 100, 0, enabled);
    }
    puts("Conditional colour clear: predicates, scissor, slots and separate versus shared-pass mip sampling passed");
} }
