#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#define ZELDA_FSC_ANALYSIS_ONLY 1
#include "../host/nvn_shader_math.h"
#include "../host/nvn_fullscreen_compute.inc"

// Shaders in the shape SPIRV-Cross gives the v1.4.3 fullscreen passes: attributes and uniforms through the descriptor
// set, implicit-LOD samples, derivatives, the window position, facing, flat and no_perspective inputs, discard, MRT.
static NSString *const vertex_source =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
    @"template<typename T>\n[[clang::optnone]] T spvFMul(T l, T r)\n{\n    return fma(l, r, T(0));\n}\n\n"
    @"struct UBO\n{\n    float4 scale;\n    int4 mode;\n};\n\n"
    @"struct spvDescriptorSetBuffer0\n{\n    constant UBO* vp_c1 [[id(0)]];\n};\n\n"
    @"struct main0_out\n{\n    float4 m_20 [[user(locn0)]];\n    float4 m_21 [[user(locn1)]];\n    int m_22 [[user(locn2)]];\n"
    @"    float4 gl_Position [[position]];\n    float gl_PointSize [[point_size]];\n};\n\n"
    @"struct main0_in\n{\n    float4 m_30 [[attribute(0)]];\n    float2 m_31 [[attribute(1)]];\n};\n\n"
    @"vertex main0_out main0(constant float& zelda_point_size [[buffer(15)]], main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], uint gl_VertexIndex [[vertex_id]])\n{\n"
    @"    main0_out out = {};\n    out.gl_PointSize = zelda_point_size;\n    float w = in.m_30.w;\n"
    @"    out.gl_Position = float4((in.m_30.xy * (*spvDescriptorSet0.vp_c1).scale.xy + (*spvDescriptorSet0.vp_c1).scale.zw) * w, in.m_30.z * w, w);\n"
    @"    out.m_20 = float4(in.m_31, in.m_31 * 2.0);\n    out.m_21 = float4(in.m_31.yx, float(gl_VertexIndex), 1.0);\n"
    @"    out.m_22 = int(gl_VertexIndex) + 1;\n    return out;\n}\n";
static NSString *const fragment_source =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
    @"template<typename T>\n[[clang::optnone]] T spvFMul(T l, T r)\n{\n    return fma(l, r, T(0));\n}\n\n"
    @"struct UBO\n{\n    float4 scale;\n    int4 mode;\n};\n\n"
    @"struct spvDescriptorSetBuffer0\n{\n    constant UBO* fp_c1 [[id(0)]];\n    texture2d<float> fp_t [[id(1)]];\n    sampler fp_s [[id(2)]];\n};\n\n"
    @"struct main0_out\n{\n    float4 m_0 [[color(0)]];\n    float4 m_1 [[color(1)]];\n};\n\n"
    @"struct main0_in\n{\n    float4 m_10 [[user(locn0)]];\n    float4 m_11 [[user(locn1), center_no_perspective]];\n    int m_12 [[user(locn2), flat]];\n};\n\n"
    @"fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], float4 gl_FragCoord [[position]], bool gl_FrontFacing [[front_facing]])\n{\n"
    @"    main0_out out = {};\n    float2 _1 = in.m_10.xy;\n"
    @"    float4 _2 = spvDescriptorSet0.fp_t.sample(spvDescriptorSet0.fp_s, select(_1, float2(0.0), isnan(_1))).xyzw;\n"
    @"    float4 _3 = spvDescriptorSet0.fp_t.sample(spvDescriptorSet0.fp_s, in.m_11.xy * 0.5, level(1.0));\n"
    @"    float d = dfdx(in.m_10.x) * 100.0 + dfdy(in.m_10.y) * 10.0 + fwidth(in.m_11.x);\n"
    @"    if ((*spvDescriptorSet0.fp_c1).mode.x != 0 && fmod(floor(gl_FragCoord.x) + floor(gl_FragCoord.y), 3.0) == 0.0)\n    {\n        discard_fragment();\n    }\n"
    @"    out.m_0 = _2 * 0.7 + _3 * 0.3 + float4(d, gl_FragCoord.z, gl_FragCoord.w * 0.1, gl_FrontFacing ? 0.25 : 0.75) * 0.1;\n"
    @"    out.m_1 = float4(in.m_11.zw * 0.1, float(in.m_12) / 8.0, fract(spvFMul(gl_FragCoord.x, 0.142857)));\n    return out;\n}\n";

typedef struct { float scale[4]; int32_t mode[4]; } ubo_t;
typedef struct { float pos[4]; uint16_t uv[2]; } vertex_t;

static id<MTLDevice> dev; static id<MTLCommandQueue> queue;

static id<MTLFunction> function(NSString *source, NSString *name) {
    NSError *error = nil; MTLCompileOptions *options = nil;
    source = zelda_shader_math(source, &options);   // as the backend compiles game shaders
    assert(options);
    id<MTLLibrary> lib = [dev newLibraryWithSource:source options:options error:&error];
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); exit(1); }
    return [lib newFunctionWithName:name];
}
static id<MTLBuffer> arguments(id<MTLFunction> f, id<MTLBuffer> ubo, id<MTLTexture> t, id<MTLSamplerState> s) {
    id<MTLArgumentEncoder> e = [f newArgumentEncoderWithBufferIndex:0];
    id<MTLBuffer> b = [dev newBufferWithLength:MAX(e.encodedLength, 16u) options:MTLResourceStorageModeShared];
    [e setArgumentBuffer:b offset:0]; [e setBuffer:ubo offset:0 atIndex:0];
    if (t) { [e setTexture:t atIndex:1]; [e setSamplerState:s atIndex:2]; }
    return b;
}
static id<MTLTexture> target(MTLPixelFormat format, int w, int h, const uint8_t *fill) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    unsigned bpp = format == MTLPixelFormatRGBA16Float ? 8 : 4;
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:fill bytesPerRow:w * bpp];
    return t;
}

typedef struct {
    const char *name; MTLPixelFormat f0, f1; int w, h;
    int nvert; vertex_t v[6];
    float vp[6]; int sc[4]; int cull, ccw, clip, discard;
    int single;   // implicit-LOD source is a single-level texture (what the runtime requires off the affine case)
    int clip_cut; // depth clipping cuts the triangle
} test_case;

static void run(const test_case *c, id<MTLTexture> mipmapped, id<MTLTexture> single, id<MTLSamplerState> sampler) {
    id<MTLTexture> source = c->single ? single : mipmapped;
    @autoreleasepool {
    size_t bytes = (size_t)c->w * c->h * 8;
    uint8_t *fill = malloc(bytes); for (size_t i = 0; i < bytes; i++) fill[i] = (uint8_t)(rand() >> 4);
    // Finite floats only: tile loads and stores canonicalize NaNs in pixels a draw does not touch.
    if (c->f1 == MTLPixelFormatRG11B10Float)
        for (size_t i = 0; i + 4 <= bytes; i += 4) { uint32_t w = (uint32_t)(rand() % (30 << 6)) | (uint32_t)(rand() % (30 << 6)) << 11 | (uint32_t)(rand() % (30 << 5)) << 22; memcpy(fill + i, &w, 4); }
    if (c->f1 == MTLPixelFormatRGBA16Float) for (size_t i = 1; i < bytes; i += 2) fill[i] &= 0x3b;
    id<MTLTexture> r0 = target(c->f0, c->w, c->h, fill), r1 = target(c->f1, c->w, c->h, fill);
    id<MTLTexture> k0 = target(c->f0, c->w, c->h, fill), k1 = target(c->f1, c->w, c->h, fill);
    ubo_t u = {{0.9f, 1.1f, 0.05f, -0.1f}, {c->discard, 0, 0, 0}};
    id<MTLBuffer> ubo = [dev newBufferWithBytes:&u length:sizeof u options:MTLResourceStorageModeShared];
    id<MTLBuffer> vb = [dev newBufferWithBytes:c->v length:sizeof c->v options:MTLResourceStorageModeShared];
    id<MTLBuffer> counted = [dev newBufferWithLength:8 options:MTLResourceStorageModeShared], visible = [dev newBufferWithLength:8 options:MTLResourceStorageModeShared];
    memset(counted.contents, 0xcd, 8);   // the setup kernel zeroes the slot
    float point = 1; id<MTLBuffer> pb = [dev newBufferWithBytes:&point length:4 options:MTLResourceStorageModeShared];

    // Render pipeline path.
    id<MTLFunction> vf = function(vertex_source, @"main0"), ff = function(fragment_source, @"main0");
    MTLRenderPipelineDescriptor *rd = [MTLRenderPipelineDescriptor new];
    rd.vertexFunction = vf; rd.fragmentFunction = ff;
    rd.colorAttachments[0].pixelFormat = c->f0; rd.colorAttachments[1].pixelFormat = c->f1;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
    vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].bufferIndex = 16;
    vd.attributes[1].format = MTLVertexFormatUShort2Normalized; vd.attributes[1].offset = 16; vd.attributes[1].bufferIndex = 16;
    vd.layouts[16].stride = sizeof(vertex_t);
    rd.vertexDescriptor = vd;
    NSError *error = nil; id<MTLRenderPipelineState> rps = [dev newRenderPipelineStateWithDescriptor:rd error:&error];
    assert(rps);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    MTLRenderPassDescriptor *pd = [MTLRenderPassDescriptor new];
    pd.colorAttachments[0].texture = r0; pd.colorAttachments[0].loadAction = MTLLoadActionLoad; pd.colorAttachments[0].storeAction = MTLStoreActionStore;
    pd.colorAttachments[1].texture = r1; pd.colorAttachments[1].loadAction = MTLLoadActionLoad; pd.colorAttachments[1].storeAction = MTLStoreActionStore;
    pd.visibilityResultBuffer = visible;
    id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pd];
    [re setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
    [re setRenderPipelineState:rps];
    [re setViewport:(MTLViewport){c->vp[0], c->vp[1], c->vp[2], c->vp[3], c->vp[4], c->vp[5]}];
    [re setScissorRect:(MTLScissorRect){c->sc[0], c->sc[1], c->sc[2], c->sc[3]}];
    [re setCullMode:c->cull == 1 ? MTLCullModeFront : c->cull == 2 ? MTLCullModeBack : MTLCullModeNone];
    [re setFrontFacingWinding:c->ccw ? MTLWindingCounterClockwise : MTLWindingClockwise];
    [re setDepthClipMode:c->clip ? MTLDepthClipModeClip : MTLDepthClipModeClamp];
    id<MTLBuffer> va = arguments(vf, ubo, nil, nil), fa = arguments(ff, ubo, source, sampler);
    [re setVertexBuffer:va offset:0 atIndex:0]; [re setVertexBuffer:pb offset:0 atIndex:15]; [re setVertexBuffer:vb offset:0 atIndex:16];
    [re setFragmentBuffer:fa offset:0 atIndex:0];
    [re useResource:ubo usage:MTLResourceUsageRead stages:MTLRenderStageVertex | MTLRenderStageFragment];
    [re useResource:source usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:c->nvert];
    [re endEncoding];

    // Kernel path.
    NSString *vk = zelda_fsc_vertex_kernel(vertex_source), *fk = zelda_fsc_fragment_kernel(fragment_source, 3, [NSMutableArray array]);
    assert(vk && fk);
    id<MTLFunction> vkf = function(vk, @"zfc_vertex"), fkf = function(fk, @"zfc_fragment");
    assert([vkf newArgumentEncoderWithBufferIndex:0].encodedLength == [vf newArgumentEncoderWithBufferIndex:0].encodedLength);
    assert([fkf newArgumentEncoderWithBufferIndex:0].encodedLength == [ff newArgumentEncoderWithBufferIndex:0].encodedLength);
    id<MTLComputePipelineState> vps = [dev newComputePipelineStateWithFunction:vkf error:&error], fps = [dev newComputePipelineStateWithFunction:fkf error:&error];
    assert(vps && fps);
    zfc_fetch_t fetch = {0};
    fetch.a[0] = (zfc_attr_t){vb.gpuAddress, sizeof(vertex_t), MTLVertexFormatFloat4};
    fetch.a[1] = (zfc_attr_t){vb.gpuAddress + 16, sizeof(vertex_t), MTLVertexFormatUShort2Normalized};
    fetch.count = (uint32_t)c->nvert; fetch.clip = (uint32_t)c->clip;
    for (int k = 0; k < c->nvert; k++) fetch.vid[k] = (uint32_t)k;
    id<MTLBuffer> clipped = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    fetch.clipped = clipped.gpuAddress;
    fetch.samples = counted.gpuAddress;
    id<MTLBuffer> fb = [dev newBufferWithBytes:&fetch length:sizeof fetch options:MTLResourceStorageModeShared];
    id<MTLBuffer> verts = [dev newBufferWithLength:6 * 272 options:MTLResourceStorageModePrivate];
    zfc_params_t p = {{c->vp[0], c->vp[1], c->vp[2], c->vp[3]}, {c->vp[4], c->vp[5]}, {0, 0}, {0, 0}, {0, 0},
                      (uint32_t)c->nvert / 3, (uint32_t)c->cull, (uint32_t)c->ccw, (uint32_t)c->clip, {0, 1, 2, 3, 4, 5}, 0};
    long scissor[4] = {c->sc[0], c->sc[1], c->sc[2], c->sc[3]};
    assert(zelda_fsc_bounds(p.vp, scissor, c->w, c->h, p.org, p.lo, p.hi));
    p.samples = counted.gpuAddress;
    id<MTLBuffer> params = [dev newBufferWithBytes:&p length:sizeof p options:MTLResourceStorageModeShared];
    id<MTLBuffer> vka = arguments(vkf, ubo, nil, nil), fka = arguments(fkf, ubo, source, sampler);
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:vps];
    [ce setBuffer:vka offset:0 atIndex:0]; [ce setBuffer:pb offset:0 atIndex:15]; [ce setBuffer:fb offset:0 atIndex:ZFC_SLOT_FETCH]; [ce setBuffer:verts offset:0 atIndex:ZFC_SLOT_VERTICES];
    [ce useResource:ubo usage:MTLResourceUsageRead]; [ce useResource:vb usage:MTLResourceUsageRead];
    [ce useResource:clipped usage:MTLResourceUsageWrite]; [ce useResource:counted usage:MTLResourceUsageWrite];
    [ce dispatchThreads:MTLSizeMake(c->nvert, 1, 1) threadsPerThreadgroup:MTLSizeMake(c->nvert, 1, 1)];
    [ce memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [ce setComputePipelineState:fps];
    [ce setBuffer:fka offset:0 atIndex:0]; [ce setBuffer:params offset:0 atIndex:ZFC_SLOT_PARAMS]; [ce setBuffer:verts offset:0 atIndex:ZFC_SLOT_VERTICES];
    [ce setTexture:k0 atIndex:0]; [ce setTexture:k1 atIndex:1];
    [ce useResource:source usage:MTLResourceUsageRead];
    [ce dispatchThreadgroups:MTLSizeMake((p.hi[0] - p.org[0] + 7) / 8, (p.hi[1] - p.org[1] + 7) / 8, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [ce endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    assert(!cb.error);
    assert((*(uint32_t *)clipped.contents != 0) == (c->clip_cut != 0));   // the setup kernel reports clipped vertices
    // Samples passed: the kernel counts what the render pass counts (edge pixels aside for partial coverage).
    uint64_t hw = *(uint64_t *)visible.contents, kc = *(uint64_t *)counted.contents;
    printf("  samples passed: render %llu, kernel %llu\n", (unsigned long long)hw, (unsigned long long)kc);
    if (!c->clip_cut && hw == (uint64_t)c->w * c->h) assert(kc == hw);   // a covering draw writes every pixel
    assert(kc <= hw + hw / 50 + 2 && hw <= kc + kc / 50 + 2);

    // Differences per channel value: bytes for 8-bit formats, ulps for half floats and RG11B10 fields.
    unsigned diff[2] = {0, 0}, maxd[2] = {0, 0}, values[2] = {0, 0}, changed = 0;
    id<MTLTexture> rs[2] = {r0, r1}, ks[2] = {k0, k1};
    for (int t = 0; t < 2; t++) {
        MTLPixelFormat f = rs[t].pixelFormat;
        unsigned bpp = f == MTLPixelFormatRGBA16Float ? 8 : 4;
        uint8_t *a = malloc(bytes), *b = malloc(bytes);
        [rs[t] getBytes:a bytesPerRow:c->w * bpp fromRegion:MTLRegionMake2D(0, 0, c->w, c->h) mipmapLevel:0];
        [ks[t] getBytes:b bytesPerRow:c->w * bpp fromRegion:MTLRegionMake2D(0, 0, c->w, c->h) mipmapLevel:0];
        for (size_t i = 0; i < (size_t)c->w * c->h * bpp; i++) if (t == 0 && a[i] != fill[i]) changed++;
        for (size_t px = 0; px < (size_t)c->w * c->h; px++) {
            unsigned n = 4, va[4], vb[4];
            if (f == MTLPixelFormatRGBA16Float) for (int k = 0; k < 4; k++) { va[k] = ((uint16_t *)a)[4 * px + k]; vb[k] = ((uint16_t *)b)[4 * px + k]; }
            else if (f == MTLPixelFormatRG11B10Float) { uint32_t x = ((uint32_t *)a)[px], y = ((uint32_t *)b)[px]; n = 3;
                va[0] = x & 2047; va[1] = x >> 11 & 2047; va[2] = x >> 22; vb[0] = y & 2047; vb[1] = y >> 11 & 2047; vb[2] = y >> 22; }
            else for (int k = 0; k < 4; k++) { va[k] = a[4 * px + k]; vb[k] = b[4 * px + k]; }
            for (unsigned k = 0; k < n; k++) { values[t]++; if (va[k] != vb[k]) { unsigned d = va[k] > vb[k] ? va[k] - vb[k] : vb[k] - va[k]; diff[t]++; if (d > maxd[t]) maxd[t] = d; } }
        }
        free(a); free(b);
    }
    printf("%-36s changed %6u bytes; values differing c0 %4u/%u (max %u), c1 %4u/%u (max %u)\n", c->name, changed, diff[0], values[0], maxd[0], diff[1], values[1], maxd[1]);
    free(fill);
    // Coverage, derivatives and LOD agree; interpolation is not bit-identical to the fixed-function unit (about 40% of
    // raw float values match, the rest within ~1e-6), which shows as single-step rounding where a bilinear weight
    // sits on a rounding boundary (this random texture is the worst case for that). Depth
    // clipping is approximated per pixel (hardware clips the polygon and interpolates through the new vertices).
    for (int t = 0; t < 2; t++) {
        if (c->clip_cut) assert(diff[t] * 10 <= values[t]);
        else assert(maxd[t] <= 2 && diff[t] * 7 <= values[t]);
    }
    }
}

int main(void) {
    @autoreleasepool {
        dev = MTLCreateSystemDefaultDevice(); queue = [dev newCommandQueue];
        // Rewrites: unsupported constructs are rejected, supported ones keep the argument layout.
        assert(zelda_fsc_channels(MTLPixelFormatRG11B10Float) == 3 && zelda_fsc_channels(MTLPixelFormatRGBA8Unorm_sRGB) == 4 &&
               zelda_fsc_channels(MTLPixelFormatR16Float) == 1 && !zelda_fsc_channels(MTLPixelFormatRGB9E5Float) && !zelda_fsc_channels(MTLPixelFormatDepth32Float));
        assert(zelda_fsc_vertex_size(MTLVertexFormatFloat3) == 12 && zelda_fsc_vertex_size(MTLVertexFormatUShort2Normalized) == 4 &&
               zelda_fsc_vertex_size(MTLVertexFormatHalf) == 2 && zelda_fsc_vertex_size(MTLVertexFormatUChar4Normalized_BGRA) == 4 &&
               !zelda_fsc_vertex_size(MTLVertexFormatInvalid));
        NSMutableArray *implicit = [NSMutableArray array];
        assert(!zelda_fsc_fragment_kernel([fragment_source stringByReplacingOccurrencesOfString:@"level(1.0)" withString:@"bias(1.0)"], 1, implicit));
        assert(!zelda_fsc_fragment_kernel([fragment_source stringByReplacingOccurrencesOfString:@"float4 gl_FragCoord [[position]]" withString:@"uint gl_SampleID [[sample_id]]"], 1, implicit));
        assert(!zelda_fsc_fragment_kernel(fragment_source, 4, implicit));   // no [[color(2)]]
        assert(!zelda_fsc_vertex_kernel([vertex_source stringByReplacingOccurrencesOfString:@"float gl_PointSize [[point_size]];" withString:@"float gl_ClipDistance [[clip_distance]] [1];"]));
        [implicit removeAllObjects];
        NSString *g = zelda_fsc_fragment_kernel(fragment_source, 1, implicit);
        // fp_t / fp_s for both samples; the level(1) one is explicit
        assert(implicit.count == 2 && [implicit[0][0] intValue] == 1 && [implicit[0][1] intValue] == 2 && [implicit[0][2] intValue] == 1 && [implicit[1][2] intValue] == 0);
        assert([g containsString:@"gradient2d(zfc_dx(select(_1, float2(0.0), isnan(_1)), zql), zfc_dy(select(_1, float2(0.0), isnan(_1)), zql))"]);
        assert([g containsString:@"in.m_11.xy * 0.5, level(1.0))"]);

        MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:YES];
        sd.storageMode = MTLStorageModeShared;
        id<MTLTexture> source = [dev newTextureWithDescriptor:sd];
        srand(7);
        for (NSUInteger l = 0; l < source.mipmapLevelCount; l++) {
            NSUInteger w = MAX(256u >> l, 1u); uint8_t *px = malloc(w * w * 4);
            for (NSUInteger i = 0; i < w * w * 4; i++) px[i] = (uint8_t)(rand() >> 3);
            [source replaceRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:l withBytes:px bytesPerRow:w * 4]; free(px);
        }
        MTLTextureDescriptor *one = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
        one.storageMode = MTLStorageModeShared;
        id<MTLTexture> single = [dev newTextureWithDescriptor:one];
        { uint8_t *px = malloc(256 * 256 * 4); for (int i = 0; i < 256 * 256 * 4; i++) px[i] = (uint8_t)(rand() >> 3);
          [single replaceRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0 withBytes:px bytesPerRow:256 * 4]; free(px); }
        MTLSamplerDescriptor *smd = [MTLSamplerDescriptor new];
        smd.minFilter = MTLSamplerMinMagFilterLinear; smd.magFilter = MTLSamplerMinMagFilterLinear; smd.mipFilter = MTLSamplerMipFilterLinear;
        smd.sAddressMode = smd.tAddressMode = MTLSamplerAddressModeClampToEdge; smd.supportArgumentBuffers = YES;
        id<MTLSamplerState> sampler = [dev newSamplerStateWithDescriptor:smd];
        const uint16_t o = 0, f = 65535, half = 32768;
        test_case cases[] = {
            {"fullscreen triangle 81x45", MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float, 81, 45, 3,
             {{{-1, -1, 0.5f, 1}, {o, f}}, {{3, -1, 0.5f, 1}, {f + 0u, f}}, {{-1, 3, 0.5f, 1}, {o, o}}},
             {0, 0, 81, 45, 0, 1}, {0, 0, 81, 45}, 0, 0, 1, 0, 0, 0},
            {"quad, perspective, viewport+scissor", MTLPixelFormatRGBA8Unorm_sRGB, MTLPixelFormatRG11B10Float, 120, 67, 6,
             {{{-1, -1, 0.2f, 1}, {o, f}}, {{1, -1, 0.4f, 2}, {f, f}}, {{1, 1, 0.6f, 0.5f}, {f, o}},
              {{-1, -1, 0.2f, 1}, {o, f}}, {{1, 1, 0.6f, 0.5f}, {f, o}}, {{-1, 1, 0.3f, 1.5f}, {o, o}}},
             {10, 5, 100, 50, 0.1f, 0.9f}, {5, 3, 101, 51}, 0, 0, 1, 1, 1, 0},
            {"partial triangle, cull back cw", MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float, 64, 48, 3,
             {{{-0.8f, -0.7f, 0.5f, 1}, {o, f}}, {{-0.6f, 0.9f, 0.5f, 1}, {half, o}}, {{0.9f, -0.2f, 0.5f, 1}, {f, f}}},
             {0, 0, 64, 48, 0, 1}, {0, 0, 64, 48}, 2, 0, 1, 1, 1, 0},
            {"partial triangle, cull back ccw", MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float, 64, 48, 3,
             {{{-0.8f, -0.7f, 0.5f, 1}, {o, f}}, {{-0.6f, 0.9f, 0.5f, 1}, {half, o}}, {{0.9f, -0.2f, 0.5f, 1}, {f, f}}},
             {0, 0, 64, 48, 0, 1}, {0, 0, 64, 48}, 2, 1, 1, 1, 1, 0},
            {"cull front ccw, depth clip", MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float, 64, 48, 3,
             {{{-0.8f, -0.7f, -0.4f, 1}, {o, f}}, {{-0.6f, 0.9f, 0.5f, 1}, {half, o}}, {{0.9f, -0.2f, 1.6f, 1}, {f, f}}},
             {0, 0, 64, 48, 0, 1}, {0, 0, 64, 48}, 1, 1, 1, 0, 1, 1},
            {"viewport inside target and scissor", MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float, 64, 48, 3,
             {{{-1, -1, 0.5f, 1}, {o, f}}, {{3, -1, 0.5f, 1}, {f, f}}, {{-1, 3, 0.5f, 1}, {o, o}}},
             {8.5f, 4, 40, 30, 0, 1}, {0, 0, 64, 48}, 0, 0, 1, 0, 0, 0},
            // The v1.4.3 quarter-resolution passes: one triangle at depth exactly 1 with depth clipping on.
            {"fullscreen triangle at depth 1 400x224", MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float, 400, 224, 3,
             {{{-1, 1, 1, 1}, {o, o}}, {{-1, -3, 1, 1}, {o, f}}, {{3, 1, 1, 1}, {f, o}}},
             {0, 0, 400, 224, 0, 1}, {0, 0, 400, 224}, 2, 1, 1, 0, 0, 0},
            {"flipped viewport, odd size", MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA16Float, 37, 23, 3,
             {{{-1, -1, 0.5f, 1}, {o, f}}, {{3, -1, 0.5f, 1}, {f, f}}, {{-1, 3, 0.5f, 1}, {o, o}}},
             {0, 23, 37, -23, 0, 1}, {0, 0, 37, 23}, 0, 0, 1, 0, 0, 0},
        };
        for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) run(&cases[i], source, single, sampler);
        puts("fullscreen compute: render pipeline and kernels agree");
    }
    return 0;
}
