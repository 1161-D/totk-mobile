#include "../host/shader_prep.h"
#include <assert.h>
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
    puts("Shader preparation: cold fixture, warm reload, failure accounting, progress and GPU output passed");
} }
