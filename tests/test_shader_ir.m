#include "../host/shader_prep.h"
#include "shader_ir_identity.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <CommonCrypto/CommonDigest.h>

static void write_record(NSString *path, id record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    assert(data && [data writeToFile:path atomically:YES]);
}

static void expect_preparation(id<MTLDevice> device, NSString *directory, unsigned expected) {
    __block unsigned completed = ~0u;
    assert(shader_prep_run(device, directory, ^(unsigned n, unsigned total) {
        assert(total == expected && n <= total); completed = n;
    }) == 0);
    assert(completed == expected);
}

int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2);
    NSString *path = @(argv[1]), *directory = path.stringByDeletingLastPathComponent;
    NSString *cache = [[[directory.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"ir-macos"]
        stringByAppendingPathComponent:directory.lastPathComponent] stringByAppendingPathComponent:@ZELDA_SHADER_IR_CONTRACT];
    NSString *metadata = [cache stringByAppendingPathComponent:@"fixture.json"];
    NSString *binary = [cache stringByAppendingPathComponent:@"fixture.metallib"];
    NSData *source = [NSData dataWithContentsOfFile:path]; assert(source);
    NSDictionary *record = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:metadata] options:0 error:nil]; assert(record);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    expect_preparation(device, directory, 0);
    setenv("ZELDA_SHADER_PREP_ALL", "1", 1); expect_preparation(device, directory, 1); unsetenv("ZELDA_SHADER_PREP_ALL");
    setenv("ZELDA_SHADER_IR", "0", 1); expect_preparation(device, directory, 1); unsetenv("ZELDA_SHADER_IR");
    for (NSString *missing in @[metadata, binary, cache]) {
        NSString *hidden = [missing stringByAppendingString:@".hidden"];
        assert([NSFileManager.defaultManager moveItemAtPath:missing toPath:hidden error:nil]);
        expect_preparation(device, directory, 1);
        assert([NSFileManager.defaultManager moveItemAtPath:hidden toPath:missing error:nil]);
        expect_preparation(device, directory, 0);
    }
    NSString *added = [directory stringByAppendingPathComponent:@"new.metallib"];
    assert([source writeToFile:added atomically:YES]);
    expect_preparation(device, directory, 1);
    assert([NSFileManager.defaultManager removeItemAtPath:added error:nil]);
    // Both layered libraries must retain their prepass until every variant has files.
    NSString *vertex = @"#include <metal_stdlib>\nusing namespace metal;\nstruct main0_out\n{\n"
        "    float4 position [[position]];\n};\nvertex main0_out main0(uint i [[vertex_id]]) {\n"
        "    main0_out out; out.position = float4(float(i), 0, 0, 1);\n    return out;\n}\n";
    for (NSString *key in @[@"48e3901f9b4eb169_b", @"c3960b272d349125_b"]) {
        NSString *file = [directory stringByAppendingPathComponent:[key stringByAppendingString:@".metallib"]];
        assert([vertex writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil]);
        NSMutableArray *created = [NSMutableArray arrayWithObject:file];
        for (NSString *suffix in @[@".metallib", @".json", @"-cube.metallib", @"-cube.json"]) {
            NSString *candidate = [cache stringByAppendingPathComponent:[key stringByAppendingString:suffix]];
            assert([NSFileManager.defaultManager copyItemAtPath:[suffix hasSuffix:@".json"] ? metadata : binary toPath:candidate error:nil]);
            [created addObject:candidate];
            expect_preparation(device, directory, created.count == 5 ? 0 : 1);
        }
        NSData *bytes = [vertex dataUsingEncoding:NSUTF8StringEncoding];
        assert(!shader_ir_load(device, file, bytes.bytes, bytes.length, false));
        assert(!shader_ir_load(device, file, bytes.bytes, bytes.length, true));
        for (NSString *candidate in created) assert([NSFileManager.defaultManager removeItemAtPath:candidate error:nil]);
    }
    id<MTLLibrary> library = shader_ir_load(device, path, source.bytes, source.length, false); assert(library);
    id<MTLFunction> function = [library newFunctionWithName:@"fixture"]; assert(function);
    id<MTLArgumentEncoder> args = [function newArgumentEncoderWithBufferIndex:0]; assert(args.encodedLength == 8);
    id<MTLLibrary> runtime = [device newLibraryWithSource:[[NSString alloc] initWithData:source encoding:NSUTF8StringEncoding] options:nil error:nil]; assert(runtime);
    assert([[runtime newFunctionWithName:@"fixture"] newArgumentEncoderWithBufferIndex:0].encodedLength == args.encodedLength);
    id<MTLBuffer> output = [device newBufferWithLength:1024 options:MTLResourceStorageModeShared];
    id<MTLBuffer> bindings = [device newBufferWithLength:args.encodedLength options:MTLResourceStorageModeShared];
    [args setArgumentBuffer:bindings offset:0]; [args setBuffer:output offset:0 atIndex:0];
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:nil]; assert(pipeline);
    id<MTLCommandQueue> queue = [device newCommandQueue]; id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    [encoder setComputePipelineState:pipeline]; [encoder setBuffer:bindings offset:0 atIndex:0];
    [encoder useResource:output usage:MTLResourceUsageWrite];
    [encoder dispatchThreads:MTLSizeMake(256, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [encoder endEncoding]; [command commit]; [command waitUntilCompleted]; assert(!command.error);
    for (unsigned i = 0; i < 256; i++) assert(((uint32_t *)output.contents)[i] == i * 7 + 3);
    for (NSString *field in @[@"source_sha256", @"binary_sha256", @"contract", @"target", @"language", @"format", @"layered"]) {
        NSMutableDictionary *changed = [record mutableCopy]; changed[field] = @"invalid"; write_record(metadata, changed);
        assert(!shader_ir_load(device, path, source.bytes, source.length, false));
    }
    write_record(metadata, @[]); assert(!shader_ir_load(device, path, source.bytes, source.length, false));
    assert([[NSMutableData dataWithLength:8192] writeToFile:metadata atomically:YES]);
    assert(!shader_ir_load(device, path, source.bytes, source.length, false));
    write_record(metadata, record);
    NSMutableData *changed = [source mutableCopy]; [changed appendBytes:" " length:1];
    assert(!shader_ir_load(device, path, changed.bytes, changed.length, false));
    assert(!shader_ir_load(device, path, source.bytes, source.length, true));
    setenv("ZELDA_SHADER_IR", "0", 1);
    assert(!shader_ir_load(device, path, source.bytes, source.length, false)); unsetenv("ZELDA_SHADER_IR");
    assert([[@"MTLBbroken" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:binary atomically:YES]);
    assert(!shader_ir_load(device, path, source.bytes, source.length, false));
    unsigned char digest[32]; char hash[65]; CC_SHA256("MTLBbroken", 10, digest);
    for (unsigned i = 0; i < sizeof digest; i++) snprintf(hash + i * 2, 3, "%02x", digest[i]);
    NSMutableDictionary *corrupt = [record mutableCopy]; corrupt[@"binary_sha256"] = @(hash); write_record(metadata, corrupt);
    assert(!shader_ir_load(device, path, source.bytes, source.length, false));
    expect_preparation(device, directory, 0);
    setenv("ZELDA_SHADER_PREP_ALL", "1", 1); expect_preparation(device, directory, 1); unsetenv("ZELDA_SHADER_PREP_ALL");
    assert([NSFileManager.defaultManager removeItemAtPath:metadata error:nil]);
    expect_preparation(device, directory, 1);
    assert(!shader_ir_load(device, path, source.bytes, source.length, false));
    shader_ir_report("test");
    puts("Shader IR: deferred preparation, partial/layered caches, GPU output, argument layout, identity/corruption rejection and source fallback passed");
} }
