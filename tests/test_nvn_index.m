#import <Metal/Metal.h>
#include "../host/nvn_index_msl.h"
#include <assert.h>
#include <string.h>

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:@(zelda_index_msl) options:nil error:&error]; assert(library);
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"expand_index"] error:&error]; assert(pipeline);
        uint8_t data[257]; for (unsigned i = 0; i < sizeof data; i++) data[i] = (uint8_t)(i ^ 17);
        id<MTLBuffer> staging = [device newBufferWithBytes:data length:sizeof data options:MTLResourceStorageModeShared];
        id<MTLBuffer> source = [device newBufferWithLength:sizeof data options:MTLResourceStorageModePrivate];
        id<MTLBuffer> target = [device newBufferWithLength:520 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue = [device newCommandQueue]; assert(staging && source && target && queue);
        const uint32_t counts[] = {1, 127, 128, 129, 257};
        for (unsigned j = 0; j < sizeof counts / sizeof *counts; j++) {
            uint32_t count = counts[j]; memset(target.contents, 0xa5, target.length);
            id<MTLCommandBuffer> commands = [queue commandBuffer];
            id<MTLBlitCommandEncoder> copy = [commands blitCommandEncoder];
            [copy copyFromBuffer:staging sourceOffset:0 toBuffer:source destinationOffset:0 size:sizeof data]; [copy endEncoding];
            id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
            [encoder setComputePipelineState:pipeline]; [encoder setBuffer:source offset:0 atIndex:0];
            [encoder setBuffer:target offset:0 atIndex:1]; [encoder setBytes:&count length:4 atIndex:2];
            [encoder dispatchThreadgroups:MTLSizeMake((count + 127) / 128, 1, 1) threadsPerThreadgroup:MTLSizeMake(128, 1, 1)];
            [encoder endEncoding]; [commands commit]; [commands waitUntilCompleted]; assert(!commands.error);
            const uint16_t *out = target.contents;
            for (unsigned i = 0; i < count; i++) assert(out[i] == data[i]);
            for (unsigned i = count; i < 260; i++) assert(out[i] == 0xa5a5);
        }
    }
}
