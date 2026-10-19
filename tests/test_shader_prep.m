#include "../host/shader_prep.h"
#include <assert.h>
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    NSString *identity = [NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSString *directory = [@"work/tmp/shader-prep-" stringByAppendingString:identity];
    assert([NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:NULL]);
    NSString *function = [@"prepare_" stringByAppendingString:identity];
    NSString *source = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nkernel void %@(device uint *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i] = i * 7 + 3; }\n", function];
    assert([source writeToFile:[directory stringByAppendingPathComponent:@"valid.metallib"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    assert([@"invalid source" writeToFile:[directory stringByAppendingPathComponent:@"invalid.metallib"] atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
    // The prepass leaves binary libraries to the normal loader, rather than treating them as source.
    assert([[@"MTLB" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[directory stringByAppendingPathComponent:@"binary.metallib"] atomically:YES]);
    for (unsigned pass = 0; pass < 2; pass++) {
        __block _Atomic unsigned finished = 0;
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        unsigned failed = shader_prep_run(device, directory, ^(unsigned count, unsigned total) {
            assert(total == 3 && count <= total); atomic_store(&finished, count);
        });
        assert(failed == 1 && atomic_load(&finished) == 3);
        fprintf(stderr, "Shader preparation pass %u: %.3f ms\n", pass, (CFAbsoluteTimeGetCurrent() - start) * 1000);
    }
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent(); NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error]; assert(library && !error);
    fprintf(stderr, "Prepared source reloaded: %.3f ms\n", (CFAbsoluteTimeGetCurrent() - start) * 1000);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:function] error:&error]; assert(pipeline);
    id<MTLBuffer> output = [device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [device newCommandQueue]; id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline]; [encoder setBuffer:output offset:0 atIndex:0];
    [encoder dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted]; assert(!command.error);
    for (unsigned i = 0; i < 64; i++) assert(((uint32_t *)output.contents)[i] == i * 7 + 3);
    assert([NSFileManager.defaultManager removeItemAtPath:directory error:NULL]);
    assert(shader_prep_run(device, directory, ^(unsigned a, unsigned b) { (void)a; (void)b; }) == 1);
    // Startup screen model: stage names from the shared status, then one forward-only bar across all stages.
    ZeldaShaderStatus idle = {0};
    assert(shader_screen_state(false, true, 0, idle).stage == SCREEN_CHECKING);
    assert(shader_screen_state(false, true, 0, (ZeldaShaderStatus){.phase = SHADER_LIBRARIES}).stage == SCREEN_CHECKING);
    ShaderScreenState compiling = shader_screen_state(false, true, 0, (ZeldaShaderStatus){.phase = SHADER_LIBRARIES, .completed = 50, .total = 100});
    assert(compiling.stage == SCREEN_COMPILING && compiling.completed == 50 && compiling.total == 100);
    ZeldaShaderStatus warm[] = {
        {.runs = 1}, {.phase = SHADER_CHECKING, .runs = 1}, {.phase = SHADER_LIBRARIES, .completed = 10, .total = 20, .runs = 1},
        {.phase = SHADER_PIPELINES, .runs = 1}, {.phase = SHADER_PIPELINES, .completed = 3, .total = 4, .runs = 1}, {.runs = 2}};
    ShaderScreenStage stages[] = {SCREEN_STARTING, SCREEN_READING, SCREEN_LOADING, SCREEN_DESCRIBING, SCREEN_BUILDING, SCREEN_READY};
    for (unsigned i = 0; i < 6; i++) assert(shader_screen_state(true, true, 1, warm[i]).stage == stages[i]);
    assert(shader_screen_state(true, false, 1, (ZeldaShaderStatus){.runs = 1}).stage == SCREEN_READY);
    // Uncounted stages creep toward the end of their share without reaching it; counted ones fill it; never backwards.
    ShaderScreenBar bar = {.warm = true, .stage = -1};
    double at = 0, last = 0, value = shader_screen_advance(&bar, shader_screen_state(false, true, 0, idle), at);
    assert(value == 0);
    for (at = 0.5; at <= 5; at += 0.5) {
        value = shader_screen_advance(&bar, shader_screen_state(false, true, 0, idle), at);
        assert(value > last && value < 0.25); last = value;
    }
    for (unsigned i = 0; i < 6; i++, at += 1) {
        double before = value;
        value = shader_screen_advance(&bar, shader_screen_state(true, true, 1, warm[i]), at);
        value = shader_screen_advance(&bar, shader_screen_state(true, true, 1, warm[i]), at + 0.5);
        assert(value >= before && value <= 1);
    }
    assert(value == 1);
    // Counted progress maps onto the stage's share: compilation owns 85% of what is left when a warm-up follows.
    ShaderScreenBar cold = {.warm = true, .stage = -1};
    shader_screen_advance(&cold, shader_screen_state(false, true, 0, idle), 0);
    value = shader_screen_advance(&cold, compiling, 1);
    assert(fabs(value - 0.85 * 0.5) < 1e-9);
    value = shader_screen_advance(&cold, shader_screen_state(false, true, 0, (ZeldaShaderStatus){.phase = SHADER_LIBRARIES, .completed = 10, .total = 100}), 2);
    assert(fabs(value - 0.85 * 0.5) < 1e-9);
    puts("Shader preparation: cold fixture, warm reload, failure accounting, progress, startup screen model and GPU output passed");
} }
