#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_done, g_fence;
static NSMutableArray *retired;
static void defer_obj_release(id object) { if (object) [retired addObject:object]; }
#include "../host/nvn_texture_reuse.inc"

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
    id<MTL4CommandQueue> queue = [device newMTL4CommandQueue];
    id<MTL4CommandAllocator> allocator = [device newCommandAllocator];
    id<MTLResidencySet> residency = [device newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:NULL];
    [queue addResidencySet:residency]; retired = [NSMutableArray array];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:16 height:1 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> first = [device newTextureWithDescriptor:d], second = [device newTextureWithDescriptor:d];
    id<MTLBuffer> source = [device newBufferWithLength:768 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [device newBufferWithLength:768 options:MTLResourceStorageModeShared];
    for (unsigned i = 0; i < 3; i++) memset((uint8_t *)source.contents + 256 * i, 0x11 * (i + 1), 256);
    for (id<MTLAllocation> r in @[first, second, source, output]) [residency addAllocation:r];
    [residency commit];
    for (unsigned round = 0; round < 2; round++) {
        [allocator reset]; id<MTL4CommandBuffer> cb = [device newCommandBuffer];
        [cb beginCommandBufferWithAllocator:allocator];
        id<MTL4ComputeCommandEncoder> e = [cb computeCommandEncoder];
        if (!round) {
            zelda_texture_retire(first); assert(!zelda_texture_reuse(d));
            assert(z_texture_reuse_bytes == first.allocatedSize);
            for (unsigned i = 0; i < 2; i++) {
                id<MTLTexture> t = i ? second : first;
                [e copyFromBuffer:source sourceOffset:256*i sourceBytesPerRow:256 sourceBytesPerImage:256 sourceSize:MTLSizeMake(16,1,1)
                    toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
            }
        } else {
            d.width = 17; assert(!zelda_texture_reuse(d)); d.width = 16;
            d.usage |= MTLTextureUsageShaderWrite; assert(!zelda_texture_reuse(d)); d.usage = MTLTextureUsageShaderRead;
            id<MTLTexture> reused = zelda_texture_reuse(d); assert(reused == first && !z_texture_reuse_bytes);
            assert(!zelda_texture_reuse(d));
            [e copyFromBuffer:source sourceOffset:512 sourceBytesPerRow:256 sourceBytesPerImage:256 sourceSize:MTLSizeMake(16,1,1)
                toTexture:reused destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        }
        [e barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
        [e copyFromTexture:first sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,1,1)
            toBuffer:output destinationOffset:round ? 512 : 0 destinationBytesPerRow:256 destinationBytesPerImage:256];
        [e copyFromTexture:second sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,1,1)
            toBuffer:output destinationOffset:256 destinationBytesPerRow:256 destinationBytesPerImage:256];
        [e endEncoding]; [cb endCommandBuffer];
        dispatch_semaphore_t done = dispatch_semaphore_create(0); MTL4CommitOptions *options = [MTL4CommitOptions new];
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> f) { assert(!f.error); dispatch_semaphore_signal(done); }];
        id<MTL4CommandBuffer> batch[] = {cb}; [queue commit:batch count:1 options:options];
        assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC))); g_done = ++g_fence;
    }
    for (unsigned i = 0; i < 3; i++) for (unsigned j = 0; j < 16; j++)
        assert(((uint8_t *)output.contents)[i*256+j] == 0x11*(i+1));
    for (unsigned i = 0; i < Z_TEXTURE_REUSE_COUNT + 1; i++) zelda_texture_retire([device newTextureWithDescriptor:d]);
    assert(retired.count == 1 && z_texture_reuse_bytes <= Z_TEXTURE_REUSE_BYTES);
    for (unsigned i = 0; i < Z_TEXTURE_REUSE_COUNT; i++) zelda_texture_evict(i);
    assert(!z_texture_reuse_bytes && retired.count == Z_TEXTURE_REUSE_COUNT + 1);
    [retired removeAllObjects]; d.width = d.height = 2048;
    for (unsigned i = 0; i < 5; i++) zelda_texture_retire([device newTextureWithDescriptor:d]);
    assert(retired.count && z_texture_reuse_bytes <= Z_TEXTURE_REUSE_BYTES);
    for (unsigned i = 0; i < Z_TEXTURE_REUSE_COUNT; i++) zelda_texture_evict(i);
    assert(!z_texture_reuse_bytes);
    puts("Metal 4 texture reuse: completion gate, descriptor mismatch, exact readback and bounded retirement passed");
} }
