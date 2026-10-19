#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../host/nvn_shader_math.h"
#include "../host/nvn_cube_source.h"

static void fail(NSString *message) {
    fprintf(stderr, "%s\n", message.UTF8String);
    exit(1);
}

static void report(id value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:&error];
    if (!data) fail(error.description);
    fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 4 || argc > 5) {
        fprintf(stderr, "usage: shader_library_probe export source output [cube]\n"
                        "       shader_library_probe bench source binary [binary-first]\n");
        return 2;
    }
    NSString *mode = @(argv[1]);
    NSError *error = nil;
    if ([mode isEqualToString:@"export"]) {
        NSString *source = [NSString stringWithContentsOfFile:@(argv[2]) encoding:NSUTF8StringEncoding error:&error];
        if (!source) fail(error.description);
        if (argc == 5) {
            if (strcmp(argv[4], "cube")) return 2;
            source = zelda_cube_source(source);
            if (!source) fail(@"Unsupported layered source");
        }
        if (![source writeToFile:[@(argv[3]) stringByAppendingString:@".raw.metal"] atomically:YES
                        encoding:NSUTF8StringEncoding error:&error]) fail(error.description);
        MTLCompileOptions *options = nil;
        source = zelda_shader_math(source, &options);
        if (![source writeToFile:@(argv[3]) atomically:YES encoding:NSUTF8StringEncoding error:&error]) fail(error.description);
        report(@{@"strict_math": @(options != nil), @"source_bytes": @([source lengthOfBytesUsingEncoding:NSUTF8StringEncoding])});
        return 0;
    }
    if (![mode isEqualToString:@"bench"] || (argc == 5 && strcmp(argv[4], "binary-first"))) return 2;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) fail(@"Metal device unavailable");
    NSMutableArray *samples = [NSMutableArray array];
    NSArray *expected = nil;
    for (unsigned repeat = 0; repeat < 3; repeat++) for (unsigned position = 0; position < 2; position++) { @autoreleasepool {
        BOOL binary = (position != 0) != (argc == 5);
        double start = CACurrentMediaTime();
        NSData *data = [NSData dataWithContentsOfFile:@(argv[binary ? 3 : 2]) options:0 error:&error];
        if (!data) fail(error.description);
        double read = CACurrentMediaTime();
        id<MTLLibrary> library = nil;
        double prepared = read;
        if (binary) {
            dispatch_data_t bytes = dispatch_data_create(data.bytes, data.length, nil, ^{ (void)data; });
            library = [device newLibraryWithData:bytes error:&error];
        } else {
            NSString *source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!source) fail(@"Invalid source encoding");
            MTLCompileOptions *options = nil;
            source = zelda_shader_math(source, &options);
            prepared = CACurrentMediaTime();
            library = [device newLibraryWithSource:source options:options error:&error];
        }
        double loaded = CACurrentMediaTime();
        if (!library) fail(error.description);
        NSMutableArray *functions = [NSMutableArray array];
        double function_ms = 0, pipeline_ms = 0;
        for (NSString *name in [library.functionNames sortedArrayUsingSelector:@selector(compare:)]) {
            double before = CACurrentMediaTime();
            id<MTLFunction> function = [library newFunctionWithName:name];
            function_ms += (CACurrentMediaTime() - before) * 1000;
            if (!function) fail(@"Library function unavailable");
            [functions addObject:@[name, @(function.functionType)]];
            if (function.functionType == MTLFunctionTypeKernel) {
                double before = CACurrentMediaTime();
                id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
                if (!pipeline) fail(error.description);
                pipeline_ms += (CACurrentMediaTime() - before) * 1000;
            }
        }
        if (expected && ![functions isEqualToArray:expected]) fail(@"Source and binary function signatures differ");
        expected = [functions copy];
        [samples addObject:@{@"mode": binary ? @"binary" : @"source", @"repeat": @(repeat),
            @"read_ms": @((read - start) * 1000), @"transform_ms": @((prepared - read) * 1000),
            @"library_ms": @((loaded - prepared) * 1000), @"function_ms": @(function_ms),
            @"pipeline_ms": @(pipeline_ms), @"total_ms": @((CACurrentMediaTime() - start) * 1000), @"bytes": @(data.length)}];
    } }
    report(@{@"gpu": device.name, @"functions": expected, @"samples": samples});
    return 0;
} }
