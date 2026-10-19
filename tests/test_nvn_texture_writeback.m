#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvn_tex.h"
#include "nvn_deswizzle.h"
#define ZELDA_WRITEBACK_ANALYSIS_ONLY 1
#include "../host/nvn_texture_writeback.inc"

// The write-back kernel must place every texel exactly where the CPU swizzle (the inverse of the upload path) does.
static int check(id<MTLDevice> device, id<MTLCommandQueue> queue, id<MTLComputePipelineState> pipeline, nvn_texdesc d, const char *name) {
    nvn_texlayout L; nvn_tex_layout(&d, &L);
    unsigned levels = d.levels ? d.levels : 1, layers = L.layers ? L.layers : 1;
    uint8_t *expected = malloc(L.size + 65536);
    id<MTLBuffer> storage = [device newBufferWithLength:L.size + 65536 options:MTLResourceStorageModeShared];
    memset(expected, 0xcd, L.size + 65536); memset(storage.contents, 0xcd, L.size + 65536);
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:pipeline];
    [e useResource:storage usage:MTLResourceUsageWrite];
    NSMutableArray *keep = [NSMutableArray array];
    unsigned seed = 1;
    for (unsigned level = 0; level < levels; level++) for (unsigned layer = 0; layer < layers; layer++) {
        uint32_t row_bytes, rows, slices, bpb; uint64_t base; unsigned th, td;
        assert(!nvn_deswizzle_geom(&d, level, layer, &row_bytes, &rows, &slices, &base, &th, &td, &bpb));
        size_t n = (size_t)row_bytes * rows * slices;
        id<MTLBuffer> linear = [device newBufferWithLength:n options:MTLResourceStorageModeShared];
        uint8_t *bytes = linear.contents;
        for (size_t i = 0; i < n; i++) { seed = seed * 1103515245u + 12345u; bytes[i] = (uint8_t)(seed >> 16); }
        assert(!nvn_swizzle(&d, level, layer, bytes, row_bytes, expected));
        zwb_params_t p = {storage.gpuAddress + base, row_bytes, rows, slices, th, td, row_bytes};
        id<MTLBuffer> params = [device newBufferWithBytes:&p length:sizeof p options:MTLResourceStorageModeShared];
        [keep addObject:linear]; [keep addObject:params];
        [e setBuffer:linear offset:0 atIndex:0];
        [e setBuffer:params offset:0 atIndex:1];
        [e dispatchThreads:MTLSizeMake((row_bytes + 15) / 16, rows, slices) threadsPerThreadgroup:MTLSizeMake(32, 4, 1)];
    }
    [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
    assert(cb.status == MTLCommandBufferStatusCompleted);
    size_t wrong = 0;
    for (size_t i = 0; i < L.size + 65536; i++) wrong += ((const uint8_t *)storage.contents)[i] != expected[i];
    printf("%-34s %8llu bytes, %u levels x %u layers, tileH %u: %zu wrong\n", name, (unsigned long long)L.size, levels, layers, L.tileH, wrong);
    free(expected);
    return wrong == 0;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device);
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:@(zelda_writeback_msl) options:nil error:&error];
        assert(library);
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"zwb_scatter"] error:&error];
        assert(pipeline);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        int ok = 1;
        ok &= check(device, queue, pipeline, (nvn_texdesc){.target = 1, .format = 0x3b, .flags = 0x200, .width = 320, .height = 320, .depth = 1, .levels = 1}, "Cave 320x320 minimal + guard");
        // Terrain normal map: RG8, 260x260, 9 levels, MINIMAL_LAYOUT (the case found in v1.4.3).
        ok &= check(device, queue, pipeline, (nvn_texdesc){.target = 1, .format = 0xd, .flags = 0x200, .width = 260, .height = 260, .depth = 1, .levels = 9}, "RG8 260x260 9 levels");
        ok &= check(device, queue, pipeline, (nvn_texdesc){.target = 1, .format = 0x25, .width = 800, .height = 448, .depth = 1, .levels = 1}, "RGBA8 800x448");
        ok &= check(device, queue, pipeline, (nvn_texdesc){.target = 1, .format = 0x1, .width = 37, .height = 23, .depth = 1, .levels = 4}, "R8 37x23 4 levels");
        ok &= check(device, queue, pipeline, (nvn_texdesc){.target = 4, .format = 0x2c, .width = 64, .height = 48, .depth = 3, .levels = 4}, "RGBA16F 64x48 array 3 x 4 levels");
        ok &= check(device, queue, pipeline, (nvn_texdesc){.target = 8, .format = 0x3f, .width = 16, .height = 16, .depth = 1, .levels = 2}, "R11G11B10F cube 16 2 levels");
        ok &= check(device, queue, pipeline, (nvn_texdesc){.target = 1, .format = 0x2e, .width = 130, .height = 700, .depth = 1, .levels = 3}, "RGBA32F 130x700 3 levels");
        assert(ok);
        printf("nvn texture write-back: ok\n");
    }
    return 0;
}
