#import <Metal/Metal.h>
#include <assert.h>
#include <math.h>
#pragma clang attribute push(__attribute__((objc_externally_retained)), apply_to = function)
#include "../host/nvn_wide_line.h"
#pragma clang attribute pop

static void end_encoder(id e) {
    [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [e endEncoding];
}

int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device); NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct spvDescriptorSetBuffer0 { constant float4 *shape [[id(0)]]; };\n"
        "struct main0_out { float4 gl_Position [[position]];\n    float gl_PointSize [[point_size]];\n};\n"
        "struct main0_in { float4 m_24 [[attribute(0)]]; };\n"
        "vertex main0_out main0(constant float& zelda_point_size [[buffer(15)]], main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]]) {\n"
        "    main0_out out = {};\n    out.gl_PointSize = zelda_point_size;\n"
        "    out.gl_Position = float4(in.m_24.x * spvDescriptorSet0.shape[0].xy + spvDescriptorSet0.shape[0].zw, 0.5, 1);\n"
        "    return out;\n}\n";
    assert(!zelda_line_source(@"unknown"));
    assert(zelda_line_source_matches(@"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    assert(!zelda_line_source_matches(@"abd", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    assert(!zelda_line_source_matches(nil, ""));
    if (argc > 1) {
        NSString *actual = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
        assert(zelda_line_source_matches(actual, "d701863d2649371dea680b3ed4c2a938f3809f82cee6168704d336ce1a62260d"));
        id<MTLLibrary> library = [device newLibraryWithSource:zelda_line_source(actual) options:nil error:&error];
        if (!library) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        assert(library); assert([library newFunctionWithName:@"main0"]);
    }
    NSString *extra = @"\nvertex float4 reference(uint i [[vertex_id]], device const float4 *p [[buffer(1)]]) { return p[i]; }\n"
        "fragment float4 fs() { return float4(0.125, 0, 0, 0.125); }\n";
    id<MTLLibrary> library = [device newLibraryWithSource:[zelda_line_source(source) stringByAppendingString:extra] options:nil error:&error];
    if (!library) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    assert(library);
    id<MTLRenderPipelineState> pipelines[2]; id<MTLTexture> textures[2];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:64 height:48 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageRenderTarget;
    for (unsigned v = 0; v < 2; v++) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassLine;
        pd.vertexFunction = [library newFunctionWithName:v ? @"main0" : @"reference"]; pd.fragmentFunction = [library newFunctionWithName:@"fs"];
        pd.colorAttachments[0].pixelFormat = td.pixelFormat; pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].sourceAlphaBlendFactor = pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
        pipelines[v] = [device newRenderPipelineStateWithDescriptor:pd error:&error]; assert(pipelines[v]);
        textures[v] = [device newTextureWithDescriptor:td]; assert(textures[v]);
    }
    id<MTLLibrary> native = [device newLibraryWithSource:[source stringByAppendingString:extra] options:nil error:&error]; assert(native);
    MTLRenderPipelineDescriptor *np = [MTLRenderPipelineDescriptor new];
    np.vertexFunction = [native newFunctionWithName:@"main0"]; np.fragmentFunction = [native newFunctionWithName:@"fs"];
    np.colorAttachments[0].pixelFormat = td.pixelFormat; np.colorAttachments[0].blendingEnabled = YES;
    np.colorAttachments[0].sourceRGBBlendFactor = np.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
    np.colorAttachments[0].sourceAlphaBlendFactor = np.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    np.vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    np.vertexDescriptor.attributes[0].format = MTLVertexFormatUCharNormalized;
    np.vertexDescriptor.attributes[0].offset = 1; np.vertexDescriptor.attributes[0].bufferIndex = 16;
    np.vertexDescriptor.layouts[16].stride = 3;
    id<MTLRenderPipelineState> native_pipeline = [device newRenderPipelineStateWithDescriptor:np error:&error]; assert(native_pipeline);
    id<MTLBuffer> parameters = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> vertices = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> indices = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> reference = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLBuffer> shape = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> args = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [device newBufferWithLength:2 * 64 * 48 * 16 options:MTLResourceStorageModeShared];
    id<MTLArgumentEncoder> ae = [[library newFunctionWithName:@"main0"] newArgumentEncoderWithBufferIndex:0];
    [ae setArgumentBuffer:args offset:0]; [ae setBuffer:shape offset:0 atIndex:0];
    id<MTLResidencySet> residency = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    for (id<MTLAllocation> r in @[textures[0], textures[1], parameters, vertices, indices, reference, shape, args, output]) [residency addAllocation:r];
    [residency commit]; id<MTL4CommandQueue> queue = [device newMTL4CommandQueue]; [queue addResidencySet:residency];
    MTL4ArgumentTableDescriptor *ad = [MTL4ArgumentTableDescriptor new]; ad.maxBufferBindCount = 17;
    id<MTL4ArgumentTable> table = [device newArgumentTableWithDescriptor:ad error:&error]; assert(table);
    for (unsigned test = 0; test < 64; test++) {
        float inputs[] = {-0.75, -0.5, 0, 0.5, 0.75, 0.875, 1, 1.5};
        const uint8_t bytes[] = {0, 32, 64, 96, 128, 160, 224, 255};
        int unorm = test >= 32;
        for (unsigned i = 0; i < 8; i++) {
            if (unorm) { ((uint8_t *)vertices.contents)[3*i+1] = bytes[i]; inputs[i] = (float)bytes[i] / 255.0f; }
            else ((float *)vertices.contents)[2*i+1] = inputs[i];
        }
        unsigned index_size = (unsigned[]){0, 1, 2, 4}[test % 4], width = test & 16 ? 1 : 5;
        float *s = shape.contents; s[0] = test & 4 ? 0.25 : 1; s[1] = test & 4 ? 1 : 0;
        s[2] = 1.0 / 64 - (unorm ? 0.5 : 0); s[3] = 1.0 / 48;
        s[4] = 1;
        zelda_line_params p = {.vertices=vertices.gpuAddress, .indices=indices.gpuAddress, .vertex_bytes=64,
            .stride=unorm?3:8, .offset=unorm?1:4, .first=index_size?0:1, .count=5, .base_vertex=index_size?-4:0,
            .index_size=index_size, .primitive=test & 8 ? 1 : 3, .width=width, .viewport={64,48},
            .restart_index=255, .restart=index_size && !(test & 8), .vertex_size=unorm?1:4};
        uint32_t sequence[] = {5, 6, p.restart ? 255 : 4, 4, 7};
        for (unsigned i = 0; i < 5; i++) {
            if (index_size == 1) ((uint8_t *)indices.contents)[i] = sequence[i];
            if (index_size == 2) ((uint16_t *)indices.contents)[i] = sequence[i];
            if (index_size == 4) ((uint32_t *)indices.contents)[i] = sequence[i];
        }
        memcpy(parameters.contents, &p, sizeof p);
        float *ref = reference.contents; unsigned count = 0, segments = p.primitive == 1 ? 2 : 4;
        for (unsigned j = 0; j < segments; j++) {
            unsigned n = p.primitive == 1 ? j*2 : j;
            if (p.restart && (sequence[n] == 255 || sequence[n+1] == 255)) continue;
            float a = inputs[index_size ? sequence[n]-4 : n+1], b = inputs[index_size ? sequence[n+1]-4 : n+2];
            float start[] = {a*s[0]+s[2], a*s[1]+s[3], 0.5, 1}, end[] = {b*s[0]+s[2], b*s[1]+s[3], 0.5, 1};
            unsigned axis = fabsf((end[0]-start[0])*64) >= fabsf((end[1]-start[1])*48) ? 1 : 0;
            for (unsigned copy = 0; copy < width; copy++) for (unsigned vertex = 0; vertex < 2; vertex++) {
                memcpy(ref+4*count, vertex ? end : start, 16);
                ref[4*count+axis] += 2 * ((float)copy - (width-1)*0.5f) / p.viewport[axis]; count++;
            }
        }
        id<MTL4CommandAllocator> allocator = [device newCommandAllocator]; id<MTL4CommandBuffer> command = [device newCommandBuffer];
        [command beginCommandBufferWithAllocator:allocator];
        for (unsigned version = 0; version < 2; version++) {
            MTL4RenderPassDescriptor *pass = [MTL4RenderPassDescriptor new]; pass.colorAttachments[0].texture = textures[version];
            pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTL4RenderCommandEncoder> e = [command renderCommandEncoderWithDescriptor:pass];
            [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
            int native_reference = !version && unorm && width == 1 && !index_size;
            [e setRenderPipelineState:native_reference ? native_pipeline : pipelines[version]]; [e setViewport:(MTLViewport){0,0,64,48,0,1}];
            [e setScissorRect:(MTLScissorRect){8,4,48,40}];
            [table setAddress:args.gpuAddress atIndex:0]; [table setAddress:reference.gpuAddress atIndex:1]; [table setAddress:parameters.gpuAddress atIndex:14];
            [table setAddress:shape.gpuAddress+16 atIndex:15]; [table setAddress:vertices.gpuAddress atIndex:16];
            [e setArgumentTable:table atStages:MTLRenderStageVertex];
            if (native_reference) [e drawPrimitives:p.primitive == 1 ? MTLPrimitiveTypeLine : MTLPrimitiveTypeLineStrip vertexStart:1 vertexCount:5 instanceCount:2 baseInstance:0];
            else [e drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:version ? 2*width : count instanceCount:version ? segments*2 : 2 baseInstance:0];
            end_encoder(e);
            id<MTL4ComputeCommandEncoder> copy = [command computeCommandEncoder];
            [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
            [copy copyFromTexture:textures[version] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(64,48,1)
                toBuffer:output destinationOffset:version*64*48*16 destinationBytesPerRow:64*16 destinationBytesPerImage:64*48*16];
            end_encoder(copy);
        }
        [command endCommandBuffer]; dispatch_semaphore_t done = dispatch_semaphore_create(0);
        MTL4CommitOptions *options = [MTL4CommitOptions new]; [options addFeedbackHandler:^(id<MTL4CommitFeedback> f){assert(!f.error);dispatch_semaphore_signal(done);}];
        id<MTL4CommandBuffer> batch[] = {command}; [queue commit:batch count:1 options:options];
        assert(!dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
        assert(!memcmp(output.contents,(uint8_t *)output.contents+64*48*16,64*48*16));
        unsigned pixels = 0; for (unsigned i=0;i<64*48;i++) pixels += ((float *)output.contents)[4*i] > 0;
        assert(pixels > 0);
        if (!(test & 4) && !index_size && !unorm) {
            unsigned rows = 0; for (unsigned y=0;y<48;y++) rows += ((float *)output.contents)[4*(y*64+24)] > 0;
            assert(rows == width);
        }
    }
    puts("Metal 4 wide lines: 64 readbacks, float and UNORM8 (native fetch comparison), 1/5 pixel coverage, minor axis, strip/list, U8/U16/U32, signed base, restart, instances, blending and scissor passed");
} }
