#import <Metal/Metal.h>
#include "../host/nvn_query_msl.h"
#include <assert.h>
#include <string.h>

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:@(zelda_query_msl) options:nil error:&error];
    if (!library) NSLog(@"%@", error); assert(library);
    id<MTLComputePipelineState> sum = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"query_sum"] error:&error]; assert(sum);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"clear_vertex"]; pd.fragmentFunction = [library newFunctionWithName:@"clear_if"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> clear = [device newRenderPipelineStateWithDescriptor:pd error:&error]; assert(clear);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    uint64_t numbers[] = {0x100000001ull, 7, 9, 13};
    id<MTLBuffer> staging = [device newBufferWithBytes:numbers length:sizeof numbers options:MTLResourceStorageModeShared];
    id<MTLBuffer> slots = [device newBufferWithLength:sizeof numbers options:MTLResourceStorageModePrivate];
    id<MTLBuffer> query = [device newBufferWithLength:48 options:MTLResourceStorageModeShared];
    id<MTLBuffer> readback = [device newBufferWithLength:4 * 256 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:td];
    for (unsigned test = 0; test < 5; test++) {
        memset(query.contents, 0xa5, query.length);
        uint64_t *values = query.contents; values[2] = test == 2 ? 0 : 0x100000015ull;
        uint64_t parameters[] = {test == 2 ? 0 : 3, slots.gpuAddress, slots.gpuAddress + 8, slots.gpuAddress + 24};
        struct { float rgba[4]; uint32_t mode, reserved[3]; } color = {{1, 0, 0, 1}, test == 1 || test == 4 ? 1 : 0, {0}};
        id<MTLCommandBuffer> commands = [queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [commands blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0 toBuffer:slots destinationOffset:0 size:sizeof numbers]; [blit endEncoding];
        id<MTLComputeCommandEncoder> compute = [commands computeCommandEncoder];
        [compute setComputePipelineState:sum]; [compute setBuffer:query offset:0 atIndex:0];
        [compute setBytes:parameters length:sizeof parameters atIndex:1]; [compute useResource:slots usage:MTLResourceUsageRead];
        [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [compute endEncoding];
        if (test >= 3) {
            // A second query in the same command buffer must be visible to the following clear.
            parameters[0] = 1; parameters[1] = slots.gpuAddress + 8;
            compute = [commands computeCommandEncoder]; [compute setComputePipelineState:sum];
            [compute setBuffer:query offset:0 atIndex:0]; [compute setBytes:parameters length:sizeof parameters atIndex:1];
            [compute useResource:slots usage:MTLResourceUsageRead];
            [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [compute endEncoding];
        }
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
        pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
        id<MTLRenderCommandEncoder> render = [commands renderCommandEncoderWithDescriptor:pass];
        [render setRenderPipelineState:clear]; [render setVertexBuffer:query offset:0 atIndex:0];
        [render setVertexBytes:&color length:sizeof color atIndex:1];
        [render setFragmentBytes:&color length:sizeof color atIndex:1]; [render setScissorRect:(MTLScissorRect){1, 1, 2, 2}];
        [render drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [render endEncoding];
        blit = [commands blitCommandEncoder];
        [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1)
            toBuffer:readback destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024]; [blit endEncoding];
        [commands commit]; [commands waitUntilCompleted]; assert(!commands.error);
        assert(values[0] == (test == 2 ? 0 : test >= 3 ? 7 : 0x100000015ull));
        assert(values[1] == 0xa5a5a5a5a5a5a5a5ull && values[3] == values[1] && values[5] == values[1]);
        for (unsigned y = 0; y < 4; y++) for (unsigned x = 0; x < 4; x++) {
            BOOL red = (test == 0 || test == 2 || test == 4) && x >= 1 && x <= 2 && y >= 1 && y <= 2;
            uint8_t *pixel = (uint8_t *)readback.contents + 256 * y + 4 * x;
            assert(pixel[0] == (red ? 255 : 0) && pixel[1] == (red ? 0 : 255) && pixel[2] == 0 && pixel[3] == 255);

        }
    }
    puts("GPU query and conditional-clear ordering checks passed");
} }
