#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
#define ZELDA_DEPTH_OUTPUT_ANALYSIS_ONLY 1
#include "../host/nvn_depth_output.inc"

// SPIR-V-Cross shape of the v1.4.3 material fragment shaders that write depth (e.g. 7a47fae4973858f4).
static NSString *const fragment_source =
    @"#include <metal_stdlib>\nusing namespace metal;\n\n"
    @"struct main0_out\n{\n    float4 m_55 [[color(0)]];\n    float gl_FragDepth [[depth(any)]];\n};\n\n"
    @"fragment main0_out main0(float4 gl_FragCoord [[position]])\n{\n    main0_out out = {};\n"
    @"    uint _291 = as_type<uint>(gl_FragCoord.x * 0.125);\n"
    @"    out.m_55 = float4(gl_FragCoord.xy * 0.25, 0.5, 1.0);\n"
    @"    out.gl_FragDepth = as_type<float>(_291);\n    return out;\n}\n";
static NSString *const vertex_source =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
    @"vertex float4 fullscreen(uint id [[vertex_id]]) { float2 p = float2((id << 1) & 2, id & 2); return float4(p * 2.0 - 1.0, 0.5, 1.0); }\n";

static id<MTLRenderPipelineState> pipeline(id<MTLDevice> device, NSString *fragment, MTLPixelFormat depth, NSError **error) {
    id<MTLLibrary> vl = [device newLibraryWithSource:vertex_source options:nil error:error];
    id<MTLLibrary> fl = [device newLibraryWithSource:fragment options:nil error:error];
    if (!vl || !fl) return nil;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [vl newFunctionWithName:@"fullscreen"]; d.fragmentFunction = [fl newFunctionWithName:@"main0"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; d.depthAttachmentPixelFormat = depth;
    return [device newRenderPipelineStateWithDescriptor:d error:error];
}

static void render(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLRenderPipelineState> state, int with_depth, uint8_t out[64]) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> color = [device newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLDepthStencilState> ds = nil;
    if (with_depth) {
        MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:4 height:4 mipmapped:NO];
        dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate;
        pass.depthAttachment.texture = [device newTextureWithDescriptor:dd];
        pass.depthAttachment.loadAction = MTLLoadActionClear; pass.depthAttachment.storeAction = MTLStoreActionDontCare;
        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];   // NVN depth test and write off
        dsd.depthCompareFunction = MTLCompareFunctionAlways; dsd.depthWriteEnabled = NO;
        ds = [device newDepthStencilStateWithDescriptor:dsd];
    }
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:state]; if (ds) [enc setDepthStencilState:ds];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding]; [cb commit]; [cb waitUntilCompleted];
    assert(cb.status == MTLCommandBufferStatusCompleted);
    [color getBytes:out bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
}

int main(void) {
    @autoreleasepool {
        NSString *stripped = zelda_depthless_source(fragment_source);
        assert(stripped);
        assert([stripped rangeOfString:@"gl_FragDepth"].location == NSNotFound);
        assert([stripped rangeOfString:@"[[depth("].location == NSNotFound);
        assert([stripped rangeOfString:@"(void)(as_type<float>(_291));"].location != NSNotFound);
        assert([stripped rangeOfString:@"float4 m_55 [[color(0)]];"].location != NSNotFound);
        // Anything but exactly one recognised depth member is refused (the caller then stops with a clear error).
        assert(!zelda_depthless_source(@"struct main0_out { float4 c [[color(0)]]; };"));
        NSString *twice = [fragment_source stringByReplacingOccurrencesOfString:@"    float gl_FragDepth [[depth(any)]];\n"
            withString:@"    float gl_FragDepth [[depth(any)]];\n    float gl_FragDepth [[depth(any)]];\n"];
        assert(!zelda_depthless_source(twice));
        assert(!zelda_depthless_source([fragment_source stringByAppendingString:@"// gl_FragDepth = 1;\n"]));

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        NSError *error = nil;
        // Metal refuses the original without a depth attachment (the in-game failure) and accepts the copy.
        assert(!pipeline(device, fragment_source, MTLPixelFormatInvalid, &error));
        id<MTLRenderPipelineState> without = pipeline(device, stripped, MTLPixelFormatInvalid, &error);
        assert(without);
        id<MTLRenderPipelineState> with = pipeline(device, fragment_source, MTLPixelFormatDepth32Float, &error);
        assert(with);
        uint8_t a[64], b[64];
        render(device, queue, without, 0, a); render(device, queue, with, 1, b);
        assert(!memcmp(a, b, sizeof a));

        // Optional corpus check: ZELDA_DEPTH_CORPUS=<shader directory> strips and compiles every shipped depth writer.
        const char *corpus = getenv("ZELDA_DEPTH_CORPUS");
        if (corpus) {
            NSString *dir = @(corpus); int total = 0, failed = 0;
            for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
                if (![name hasSuffix:@".metallib"]) continue;
                NSString *text = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];
                if (!text || [text rangeOfString:@"[[depth("].location == NSNotFound) continue;
                total++;
                NSString *copy = zelda_depthless_source(text);
                id<MTLLibrary> library = copy ? [device newLibraryWithSource:copy options:nil error:&error] : nil;
                if (!library) { failed++; fprintf(stderr, "depth-free copy failed: %s\n", name.UTF8String); }
            }
            printf("depth corpus: %d depth writers, %d failed\n", total, failed);
            assert(total > 0 && !failed);
        }
        printf("nvn depth output: ok\n");
    }
    return 0;
}
