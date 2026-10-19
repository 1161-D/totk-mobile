#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "nvn_fmt_mtl.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

#define MDIE(...) do { fprintf(stderr, __VA_ARGS__); abort(); } while (0)
#pragma clang attribute push(__attribute__((objc_externally_retained)), apply_to = function)
#include "../host/nvn_texture_swizzle.inc"
#pragma clang attribute pop

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void read_pixels(texture2d<float, access::read> t [[texture(0)]], "
        "device float4 *out [[buffer(0)]], uint i [[thread_position_in_grid]]) { out[i]=t.read(uint2(i%256,i/256)); }";
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error]; assert(library);
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:
        [library newFunctionWithName:@"read_pixels"] error:&error]; assert(pipeline);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLBuffer> output = [device newBufferWithLength:65536 * 4 * sizeof(float) options:MTLResourceStorageModeShared];
    uint16_t *words = malloc(65536 * sizeof *words); assert(words);
    for (unsigned i = 0; i < 65536; i++) words[i] = i;
    const int formats[] = {0x3a, 0x3b, 0x3c};
    const unsigned selectors[] = {0, 0x8000 | 2 | (3 << 3) | (4 << 6) | (5 << 9),
        0x8000 | 3 | (2 << 3) | (1 << 6), 0x8000};
    for (unsigned f = 0; f < sizeof formats / sizeof *formats; f++) {
        uint32_t pixel_format; assert(nvn_fmt_to_mtl(formats[f], &pixel_format, NULL));
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            (MTLPixelFormat)pixel_format width:256 height:256 mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared; descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor]; assert(texture);
        [texture replaceRegion:MTLRegionMake2D(0, 0, 256, 256) mipmapLevel:0 withBytes:words bytesPerRow:512];
        for (unsigned mode = 0; mode < sizeof selectors / sizeof *selectors; mode++) {
            id<MTLTexture> view = zelda_texture_swizzle(texture, formats[f], selectors[mode]);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [cb computeCommandEncoder];
            [encoder setComputePipelineState:pipeline]; [encoder setTexture:view atIndex:0];
            [encoder setBuffer:output offset:0 atIndex:0];
            [encoder dispatchThreads:MTLSizeMake(65536, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [encoder endEncoding]; [cb commit]; [cb waitUntilCompleted]; assert(!cb.error);
            float *pixels = output.contents;
            for (unsigned i = 0; i < 65536; i++) {
                float rgb[4] = {(i & 31) / 31.0f, ((i >> 5) & 31) / 31.0f, ((i >> 10) & 31) / 31.0f,
                    formats[f] == 0x3a ? 1.0f : (float)(i >> 15)};
                if (formats[f] == 0x3c) { rgb[1] = ((i >> 5) & 63) / 63.0f; rgb[2] = (i >> 11) / 31.0f; rgb[3] = 1.0f; }
                if (mode == 2) { float red = rgb[0]; rgb[0] = rgb[1]; rgb[1] = red; rgb[2] = 1; rgb[3] = 0; }
                if (mode == 3) memset(rgb, 0, sizeof rgb);
                for (unsigned c = 0; c < 4; c++) {
                    if (fabsf(pixels[i * 4 + c] - rgb[c]) > 0.001f) {
                        fprintf(stderr, "format=%#x mode=%u word=%#x channel=%u got=%g expected=%g\n",
                            formats[f], mode, i, c, pixels[i * 4 + c], rgb[c]); return 1;
                    }
                }
            }
        }
    }
    // Ordinary formats remain unchanged; selecting one mip/layer before swizzling keeps that view's range.
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
        width:16 height:16 mipmapped:YES];
    d.textureType = MTLTextureType2DArray; d.arrayLength = 3; d.storageMode = MTLStorageModeShared;
    id<MTLTexture> array = [device newTextureWithDescriptor:d]; assert(array);
    id<MTLTexture> selected = [array newTextureViewWithPixelFormat:array.pixelFormat textureType:MTLTextureType2D
        levels:NSMakeRange(1, 2) slices:NSMakeRange(2, 1)]; assert(selected);
    assert(zelda_texture_swizzle(selected, 0x25, 0) == selected);
    id<MTLTexture> nested = zelda_texture_swizzle(selected, 0x25, selectors[2]);
    assert(nested.width == 8 && nested.height == 8 && nested.mipmapLevelCount == 2 && nested.arrayLength == 1);
    assert(nested.swizzle.red == MTLTextureSwizzleGreen && nested.swizzle.green == MTLTextureSwizzleRed &&
        nested.swizzle.blue == MTLTextureSwizzleOne && nested.swizzle.alpha == MTLTextureSwizzleZero);
    id<MTLTexture> opaque = zelda_texture_swizzle(selected, 0x6d, 0);
    assert(opaque.swizzle.alpha == MTLTextureSwizzleOne);
    free(words);
    puts("Texture format and guest swizzles: 786432 packed-pixel GPU readbacks, opaque alpha and view ranges passed");
} }
