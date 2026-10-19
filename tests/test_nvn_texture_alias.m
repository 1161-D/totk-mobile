#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "nvn_obj.h"
#include <assert.h>
#include <stdio.h>
#include <pthread.h>
static id<MTLDevice> g_dev;
static id<MTLBuffer> memory;
static id<MTLResidencySet> residency;
static NSMutableDictionary *serials;
static unsigned removals;
static unsigned resolution_logs;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static struct { uint64_t lo, hi, base; id<MTLBuffer> buf; } g_pools[1];
static int g_npool = 1, g_cap = 1;
static unsigned pool_promotions;
#define MDIE(...) do { fprintf(stderr, __VA_ARGS__); abort(); } while (0)
#include "../host/nvn_pool_index.inc"
#define MLOG(...) (resolution_logs++)
static unsigned panel_width, panel_height;
void zelda_perf_render_size(unsigned width, unsigned height) { panel_width = width; panel_height = height; }
static void res_add(id<MTLResource> r) { [residency addAllocation:(id<MTLAllocation>)r]; }
static void res_remove(id<MTLResource> r) { if (r) { [residency removeAllocation:(id<MTLAllocation>)r]; removals++; } }
static void serial_put(uint64_t serial, id value) { serials[@(serial)] = value; }
static int mtl_addr(uint64_t address, uint64_t size, void **buffer, uint64_t *offset) {
    if (address < 0x100000 || size > memory.length || address - 0x100000 > memory.length - size) return 0;
    pool_promotions++; res_add(memory);
    *buffer = (__bridge void *)memory; *offset = address - 0x100000; return 1;
}
@interface NvPkg : NSObject { @public id<MTLTexture> tex; NSData *storage_key; id<MTLBuffer> storage_pool; } @end
@implementation NvPkg
- (void)dealloc { res_remove(tex); }
@end
#include "../host/nvn_texture_alias.inc"
static id<MTLTexture> tex_mtl(const tex_t *t) { NvPkg *holder=serials[@(t->serial)]; return holder ? holder->tex : nil; }

int main(void) { @autoreleasepool {
    setenv("ZELDA_ALIAS_RESIDENCY", "0", 1);
    g_dev = MTLCreateSystemDefaultDevice(); assert(g_dev);
    memory = [g_dev newBufferWithLength:16384 options:MTLResourceStorageModeShared];
    g_pools[0] = (typeof(g_pools[0])){0x100000, 0x104000, 0x100000, memory};
    residency = [g_dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:NULL];
    serials = [NSMutableDictionary dictionary];
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:1 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    tex_t a = {.serial=1,.mem=(void *)0x100000,.L={.size=512,.layer_size=512,.bpb=4}};
    tex_t b = a; b.serial = 2; b.swizzle = 0x831a;
    id<MTLTexture> writer, reader;
    @autoreleasepool {
        writer = zelda_device_texture(&a,d); reader = zelda_device_texture(&b,d);
        assert(writer == reader && serials[@1] == serials[@2] && z_texture_alias_hits == 1);
        [residency commit]; assert(residency.allocationCount == 1 && !pool_promotions);
        assert(((NvPkg *)serials[@1])->storage_pool == memory);
        uint64_t offset = 0;
        assert(!zelda_texture_pool(UINT64_MAX, 2, &offset));
        assert(!zelda_texture_pool(0x104000, 1, &offset));
    }
    @autoreleasepool { assert([z_texture_storage objectForKey:((NvPkg *)serials[@2])->storage_key] == serials[@2]); }
    assert(zelda_texture_same_storage(&a,&b)); b.mem=(void *)0x100100; assert(!zelda_texture_same_storage(&a,&b));
    b.mem=(void *)0x100200; assert(!zelda_texture_same_storage(&a,&b)); b.mem=a.mem;
    const char *upscale="cf0fd3303967d34b_b";
    zelda_note_render_input("another-shader",0,writer); zelda_note_render_input(upscale,1,writer);
    zelda_note_render_input(upscale,0,nil); assert(!resolution_logs);
    zelda_note_render_input(upscale,0,writer); zelda_note_render_input(upscale,0,reader); assert(resolution_logs==1);
    assert(panel_width==writer.width && panel_height==writer.height);
    // Same address does not merge incompatible extents, formats, layout or a replacement pool allocation.
    @autoreleasepool {
        b.serial=3; d.width=8; id<MTLTexture> smaller=zelda_device_texture(&b,d);
        assert(smaller!=writer); assert(!zelda_texture_same_storage(&a,&b));
        zelda_note_render_input(upscale,0,smaller); assert(resolution_logs==2 && panel_width==8); d.width=16;
        b.serial=4; d.pixelFormat=MTLPixelFormatR32Float; assert(zelda_device_texture(&b,d)!=writer); d.pixelFormat=MTLPixelFormatRGBA8Unorm;
        b.serial=5; b.L.tileH=1; assert(zelda_device_texture(&b,d)!=writer); b.L.tileH=0;
        id<MTLBuffer> original=memory; memory=[g_dev newBufferWithLength:16384 options:MTLResourceStorageModeShared];
        g_pools[0].buf=memory;
        b.serial=6; assert(zelda_device_texture(&b,d)!=writer); memory=original; g_pools[0].buf=memory;
        for (int n=3;n<=6;n++) [serials removeObjectForKey:@(n)];
    }
    unsigned before=removals;
    @autoreleasepool { [serials removeObjectForKey:@1]; }
    assert(removals==before); // One alias retiring must not remove the live alias from residency.
    id<MTLBuffer> upload=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    for (unsigned i=0;i<64;i++) ((uint8_t *)upload.contents)[i]=(uint8_t)(3*i+7);
    res_add(upload); res_add(output); [residency commit];
    id<MTL4CommandQueue> queue=[g_dev newMTL4CommandQueue]; [queue addResidencySet:residency];
    id<MTL4CommandAllocator> allocator=[g_dev newCommandAllocator]; id<MTL4CommandBuffer> command=[g_dev newCommandBuffer];
    [command beginCommandBufferWithAllocator:allocator]; id<MTL4ComputeCommandEncoder> e=[command computeCommandEncoder];
    [e copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:256 sourceSize:MTLSizeMake(16,1,1)
        toTexture:writer destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [e barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:reader sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,1,1)
        toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
    [e endEncoding]; [command endCommandBuffer];
    dispatch_semaphore_t done=dispatch_semaphore_create(0); MTL4CommitOptions *options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { assert(!feedback.error); dispatch_semaphore_signal(done); }];
    id<MTL4CommandBuffer> batch[]={command}; [queue commit:batch count:1 options:options];
    assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    assert(!memcmp(output.contents,upload.contents,64));
    assert(!pool_promotions);
    @autoreleasepool { [serials removeObjectForKey:@2]; }
    assert(removals==before+1);
    @autoreleasepool { assert(!z_texture_storage.objectEnumerator.allObjects.count); }
    // Render-target heap: targets of a CPU-inaccessible virtual pool sit at their guest offsets x the heap scale.
    id<MTLBuffer> targets = [g_dev newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
    g_pools[0] = (typeof(g_pools[0])){0x200000, 0x300000, 0x200000, targets};
    pool_t virtual_pool = {.flags = 0x2a1, .size = 1 << 20}, plain_pool = {.flags = 0xa1, .size = 1 << 20};
    MTLTextureDescriptor *rt = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
    rt.storageMode = MTLStorageModePrivate; rt.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    tex_t first = {.serial = 20, .mem = (void *)0x200000, .pool = &virtual_pool, .L = {.size = 256 * 1024, .layer_size = 256 * 1024, .bpb = 4}};
    tex_t second = first; second.serial = 21; second.mem = (void *)(0x200000 + 512 * 1024);
    tex_t overlap = first; overlap.serial = 22;
    id<MTLTexture> t1 = zelda_device_texture(&first, rt), t2 = zelda_device_texture(&second, rt);
    rt.pixelFormat = MTLPixelFormatR32Float;
    id<MTLTexture> t3 = zelda_device_texture(&overlap, rt);   // same guest range, another format: shares memory
    rt.pixelFormat = MTLPixelFormatRGBA8Unorm;
    assert(t1.heap && t1.heap == t2.heap && t3.heap == t1.heap && t1 != t3);
    assert(t3.heapOffset == t1.heapOffset && t1.heap.size >= (uint64_t)((1 << 20) * z_rt_heap_scale));
    assert(t1.heapOffset + t1.allocatedSize <= t2.heapOffset && t2.heapOffset >= (uint64_t)(512 * 1024 * z_rt_heap_scale));
    tex_t display = first; display.serial = 23; display.d.flags = NVN_TEXTURE_FLAGS_DISPLAY; display.mem = (void *)(0x200000 + 256 * 1024);
    tex_t plain = display; plain.serial = 24; plain.d.flags = 0; plain.pool = &plain_pool;
    tex_t tiny = display; tiny.serial = 25; tiny.d.flags = 0; tiny.L.size = 4096;   // Metal needs more than 4 KiB x scale
    assert(!zelda_device_texture(&display, rt).heap && !zelda_device_texture(&plain, rt).heap && !zelda_device_texture(&tiny, rt).heap);
    // Separate guest ranges keep separate contents on the GPU.
    id<MTLBuffer> source = [g_dev newBufferWithLength:2 * 256 * 1024 options:MTLResourceStorageModeShared];
    id<MTLBuffer> back = [g_dev newBufferWithLength:2 * 256 * 1024 options:MTLResourceStorageModeShared];
    for (unsigned i = 0; i < 2 * 256 * 1024; i++) ((uint8_t *)source.contents)[i] = (uint8_t)(i * 7 + (i >> 18) * 101);
    res_add(source); res_add(back); [residency commit];
    command = [g_dev newCommandBuffer]; [command beginCommandBufferWithAllocator:allocator]; e = [command computeCommandEncoder];
    for (unsigned k = 0; k < 2; k++)
        [e copyFromBuffer:source sourceOffset:k * 256 * 1024 sourceBytesPerRow:1024 sourceBytesPerImage:256 * 1024 sourceSize:MTLSizeMake(256, 256, 1)
            toTexture:k ? t2 : t1 destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    [e barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    for (unsigned k = 0; k < 2; k++)
        [e copyFromTexture:k ? t2 : t1 sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(256, 256, 1)
            toBuffer:back destinationOffset:k * 256 * 1024 destinationBytesPerRow:1024 destinationBytesPerImage:256 * 1024];
    [e endEncoding]; [command endCommandBuffer];
    dispatch_semaphore_t copied = dispatch_semaphore_create(0); options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { assert(!feedback.error); dispatch_semaphore_signal(copied); }];
    id<MTL4CommandBuffer> heap_batch[] = {command}; [queue commit:heap_batch count:1 options:options];
    assert(!dispatch_semaphore_wait(copied, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    assert(!memcmp(back.contents, source.contents, 2 * 256 * 1024));
    zelda_texture_alias_census();   // diagnostic walk over live storage, including heap-placed targets
    puts("Texture aliases: shared GPU contents, incompatible storage separation and final-owner residency passed");
    puts("Render-target heap: guest-offset placement, aliasing only where guest ranges overlap, exclusions and separate GPU contents passed");
} }
