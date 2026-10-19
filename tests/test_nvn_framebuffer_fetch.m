#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#define ZELDA_FETCH_ANALYSIS_ONLY 1
#define MLOG(...) ((void)0)
#include "../host/nvn_framebuffer_fetch.inc"
#define ZELDA_SAMPLE_RANGE_ANALYSIS_ONLY 1
#include "../host/nvn_sample_range.inc"

// Shapes taken from the v1.4.3 G-buffer decal pair (vertex 7becc8ea2daf0248, fragment 4068fe1fc7111834).
static NSString *const vertex_source =
    @"struct main0_out\n{\n    float4 m_48 [[user(locn0)]];\n    float4 m_56 [[user(locn5)]];\n    float4 gl_Position [[position]];\n};\n\n"
    @"vertex main0_out main0(main0_in in [[stage_in]])\n{\n    main0_out out = {};\n"
    @"    out.gl_Position.x = 0.0;\n    out.gl_Position.y = 0.0;\n    out.gl_Position.w = 1.0;\n"
    @"    float _338 = spvFAdd(_328, c[10].w);\n    float _340 = spvFAdd(_330, c[7].w);\n    float _342 = spvFAdd(_332, c[8].w);\n"
    @"    out.gl_Position.w = _338;\n    out.gl_Position.x = _340;\n    out.gl_Position.y = _342;\n"
    @"    float _344 = spvFAdd(_338, _340);\n    float _346 = -_342;\n    float _348 = spvFAdd(_338, _346);\n"
    @"    out.m_56.w = _338;\n    float _350 = spvFMul(_344, 0.5);\n    float _352 = spvFMul(_348, 0.5);\n"
    @"    out.m_56.x = _350;\n    out.m_56.y = _352;\n    out.m_48.x = _350;\n    out.m_48.y = _344;\n    out.m_48.w = _338;\n    return out;\n}\n";
static NSString *const fragment_source =
    @"struct _16\n{\n    float4 _m0[4096];\n};\n\n"
    @"struct spvDescriptorSet0\n{\n    constant _16* fp_c1 [[id(0)]];\n    texture2d<float> fp_t_tcb_A [[id(7)]];\n    sampler fp_t_tcb_ASmplr [[id(8)]];\n"
    @"    texture2d<float> fp_t_tcb_8 [[id(9)]];\n    sampler fp_t_tcb_8Smplr [[id(10)]];\n    texture2d<float> fp_t_tcb_9 [[id(11)]];\n    sampler fp_t_tcb_9Smplr [[id(12)]];\n};\n\n"
    @"struct main0_out\n{\n    float4 m_52 [[color(1)]];\n    float4 m_54 [[color(3)]];\n};\n\n"
    @"struct main0_in\n{\n    float4 m_39 [[user(locn0)]];\n    float4 m_43 [[user(locn5)]];\n};\n\n"
    @"fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSet0& spvDescriptorSet0 [[buffer(0)]])\n{\n    main0_out out = {};\n"
    @"    float _78 = in.m_43.w;\n    float _80 = in.m_43.x;\n    float _82 = in.m_43.y;\n    float _84 = 1.0 / _78;\n"
    @"    float _86 = spvFMul(_80, _84);\n    float _88 = spvFMul(_82, _84);\n    float2 _623 = float2(_86, _88);\n"
    @"    float4 _111 = spvDescriptorSet0.fp_t_tcb_A.sample(spvDescriptorSet0.fp_t_tcb_ASmplr, select(_623, float2(0.0), isnan(_623))).xyzw;\n"
    @"    if (_111.x > 0.5)\n    {\n        float2 _650 = float2(_86, _88);\n"
    @"        float3 _125 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_650, float2(0.0), isnan(_650))).xyz;\n"
    @"        out.m_54 = float4(_125, 1.0);\n    }\n"
    @"    float2 _700 = float2(in.m_39.x, _88);\n"
    @"    float4 _701 = spvDescriptorSet0.fp_t_tcb_9.sample(spvDescriptorSet0.fp_t_tcb_9Smplr, select(_700, float2(0.0), isnan(_700)));\n"
    @"    out.m_52 = _111 + _701;\n    return out;\n}\n";

static NSString *replace(NSString *source, NSString *from, NSString *to) {
    assert([source rangeOfString:from].location != NSNotFound);
    return [source stringByReplacingOccurrencesOfString:from withString:to];
}

int main(int argc, char **argv) { @autoreleasepool {
    assert(zelda_fetch_record_key(@"0123456789abcdef_b"));
    for (NSString *bad in @[@"", @"../0123456789abcdef_b", @"0123456789abcdef_x", @"0123456789abcdeg_b", @"0123456789abcde_b"])
        assert(!zelda_fetch_record_key(bad));
    NSDictionary *record_mapping = @{@"fp_t_tcb_A": @1, @"fp_t_tcb_8": @3};
    NSString *record = zelda_fetch_record_identity(record_mapping);
    assert([record isEqualToString:@"fp_t_tcb_8=c3;fp_t_tcb_A=c1;"]);
    NSDictionary *restored = zelda_fetch_record_mapping(record);
    assert([restored isEqualToDictionary:record_mapping]);
    assert([zelda_fetch_source(fragment_source, restored) isEqualToString:zelda_fetch_source(fragment_source, record_mapping)]);
    for (NSString *bad in @[@"", @"t=c8;", @"t=c-1;", @"t=c10;", @"t=c0", @"t=c0;extra", @" t=c0;",
                           @"t=c0;\n", @"t=c0;t=c1;", @"1t=c0;", @"b=c0;a=c1;", @"t=c0;;"])
        assert(!zelda_fetch_record_mapping(bad));
    if (argc == 3) {   // Diagnostics: analyse a real vertex / fragment MSL pair.
        NSString *vs = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:nil];
        NSString *fs = [NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:nil];
        printf("vertex screen outputs %s\nfragment reads %s\n", zelda_fetch_screen_outputs_in(vs).description.UTF8String,
            zelda_fetch_reads_in(fs).description.UTF8String);
        return 0;
    }
    NSSet *outputs = zelda_fetch_screen_outputs_in(vertex_source);
    assert([outputs isEqualToSet:[NSSet setWithObject:@5]]);   // m_48 is not a screen position
    NSDictionary *reads = zelda_fetch_reads_in(fragment_source);
    assert(reads.count == 2 && [reads[@7][0] isEqualToString:@"fp_t_tcb_A"] && [reads[@9][0] isEqualToString:@"fp_t_tcb_8"]);
    assert([reads[@7][1] isEqualToArray:@[@5]] && !reads[@11]);   // tcb_9 samples a mixed coordinate
    assert([reads[@7][2] unsignedIntValue] == 15 && [reads[@9][2] unsignedIntValue] == 7);   // components used: .xyzw, .xyz

    // Mip range proof accepts any coordinate, but only implicit samples through the corresponding bound sampler.
    NSDictionary *mips = zelda_sample_mip_bindings(fragment_source);
    assert(([mips isEqualToDictionary:@{@7:@8, @9:@10, @11:@12}]));
    assert(!zelda_sample_mip_bindings(nil).count);
    assert(!zelda_sample_mip_bindings(replace(fragment_source, @"out.m_52 = _111 + _701;",
        @"out.m_52 = _111 + _701 + spvDescriptorSet0.fp_t_tcb_A.read(uint2(0));"))[@7]);
    assert(!zelda_sample_mip_bindings(replace(fragment_source, @"fp_t_tcb_ASmplr,", @"fp_t_tcb_8Smplr,"))[@7]);
    assert(!zelda_sample_mip_bindings(replace(fragment_source, @"isnan(_623))).xyzw", @"isnan(_623)), min_lod_clamp(4.0)).xyzw"))[@7]);
    assert(!zelda_sample_mip_bindings(replace(fragment_source, @"out.m_52 = _111 + _701;",
        @"out.m_52 = helper(spvDescriptorSet0.fp_t_tcb_A);"))[@7]);
    assert(zelda_mip_disjoint(5, 0, 5, 2, 1, 1));
    assert(!zelda_mip_disjoint(5, 0, 5, 1, 1, 1));
    assert(!zelda_mip_disjoint(5, 0, 5, 2, 1.25f, 1.25f));  // trilinear neighbour
    assert(!zelda_mip_disjoint(5, 1, 3, 2, 1, 1));          // view-relative LOD
    assert(zelda_mip_disjoint(5, 1, 3, 1, 1, 1));
    assert(!zelda_mip_disjoint(5, 1, 3, 3, 100, 100));     // hardware clamps to last view mip
    assert(!zelda_mip_disjoint(5, 0, 5, 0, -1000, 1000));
    assert(!zelda_mip_disjoint(5, 0, 5, 2, NAN, 2));
    assert(!zelda_mip_disjoint(5, 0, 5, 2, 3, 2));
    assert(!zelda_mip_disjoint(5, 0, 5, 2, 0, INFINITY));
    assert(!zelda_mip_disjoint(5, 2, 5, 1, 0, 0));
    assert(!zelda_mip_disjoint(5, -1, 3, 1, 0, 0));
    assert(!zelda_mip_disjoint(5, 0, 0, 1, 0, 0));

    // Anything that breaks the proof leaves the shader alone.
    assert(!zelda_fetch_screen_outputs_in(replace(vertex_source, @"float _346 = -_342;", @"float _346 = _342;")).count);
    assert(!zelda_fetch_screen_outputs_in(replace(vertex_source, @"    out.m_56.w = _338;", @"    out.m_56.w = _340;")).count);
    assert(!zelda_fetch_screen_outputs_in([vertex_source stringByAppendingString:@"        out.gl_Position.x = _350;\n"]).count);
    assert(!zelda_fetch_screen_outputs_in(replace(vertex_source, @"    return out;", @"    out.gl_Position.x = 0.0;\n    return out;")).count);
    assert(!zelda_fetch_screen_outputs_in(replace(vertex_source, @"    return out;", @"    out.m_56.xy = float2(0.0);\n    return out;")).count);
    assert(!zelda_fetch_reads_in(replace(fragment_source, @"    float _84 = 1.0 / _78;", @"    float _84 = 1.0 / _78;\n    _84 = 2.0;")).count);
    assert(!zelda_fetch_reads_in(replace(fragment_source, @"float _80 = in.m_43.x;", @"float _80 = in.m_39.x;"))[@7]);
    assert(!zelda_fetch_reads_in(replace(fragment_source, @"out.m_52 = _111 + _701;", @"out.m_52 = _111 + _701 + spvDescriptorSet0.fp_t_tcb_A.read(uint2(0));"))[@7]);
    assert(!zelda_fetch_reads_in(replace(fragment_source, @"[[buffer(0)]])", @"[[buffer(0)]], float4 c1 [[color(1)]])")).count);

    // The variant reads the attachments in place of the samples and compiles.
    NSString *variant = zelda_fetch_source(fragment_source, @{@"fp_t_tcb_A": @3, @"fp_t_tcb_8": @1});
    assert(variant && [variant containsString:@"float4 _111 = zfb_3.xyzw;"] && [variant containsString:@"float3 _125 = zfb_1.xyz;"]);
    assert([variant containsString:@"[[buffer(0)]], float4 zfb_1 [[color(1)]], float4 zfb_3 [[color(3)]])"] ||
           [variant containsString:@"[[buffer(0)]], float4 zfb_3 [[color(3)]], float4 zfb_1 [[color(1)]])"]);
    assert([variant containsString:@"spvDescriptorSet0.fp_t_tcb_9.sample("]);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device) {
        NSString *prelude = @"#include <metal_stdlib>\nusing namespace metal;\n"
            @"template<typename T> T spvFMul(T l, T r) { return fma(l, r, T(0)); }\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:[prelude stringByAppendingString:variant] options:nil error:&error];
        if (!library) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        assert(library && [library newFunctionWithName:@"main0"]);
        NSString *vertex = @"\nstruct WarmV { float4 p [[position]]; float4 a [[user(locn0)]]; float4 b [[user(locn5)]]; };\n"
            "vertex WarmV warm_v(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return {float4(p[i],0,1),float4(0),float4(0,0,0,1)}; }\n";
        library = [device newLibraryWithSource:[[prelude stringByAppendingString:variant] stringByAppendingString:vertex] options:nil error:&error];
        assert(library);
        for (unsigned optional = 0; optional < 4; optional++) {
            MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
            d.vertexFunction = [library newFunctionWithName:@"warm_v"]; d.fragmentFunction = [library newFunctionWithName:@"main0"];
            d.colorAttachments[1].pixelFormat = d.colorAttachments[3].pixelFormat = MTLPixelFormatRGBA8Unorm;
            d.colorAttachments[0].pixelFormat = optional & 1 ? MTLPixelFormatRGBA8Unorm : MTLPixelFormatInvalid;
            d.colorAttachments[5].pixelFormat = optional & 2 ? MTLPixelFormatRG11B10Float : MTLPixelFormatInvalid;
            d.colorAttachments[0].writeMask = d.colorAttachments[5].writeMask = MTLColorWriteMaskNone;
            id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:d error:&error];
            if (!pipeline) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
            assert(pipeline);
        }
    }
    puts("Framebuffer-fetch proof: projected screen reads, vertex screen outputs, rejected shapes and variant source passed");
} }
