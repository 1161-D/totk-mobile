#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

static id<MTLResidencySet> g_res;
static NSHashTable *g_res_objects;
static NSHashTable *g_res_ever;
static int g_res_census = -1;
static int g_res_dirty;
static pthread_mutex_t g_res_mu=PTHREAD_MUTEX_INITIALIZER;
static unsigned census_lines, alias_censuses;
#define MLOG(...) (census_lines++)
#include "../host/nvn_residency.inc"
static void zelda_texture_alias_census(void) { alias_censuses++; }
static void commit(void) { if(g_res_dirty){[g_res commit];g_res_dirty=0;} }
int main(void) { @autoreleasepool {
    setenv("DM_RES_CENSUS", "1", 1);
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); assert(device); NSError *error=nil;
    MTLResidencySetDescriptor *rd=[MTLResidencySetDescriptor new];g_res=[device newResidencySetWithDescriptor:rd error:&error];assert(g_res);
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.storageMode=MTLStorageModePrivate;td.usage=MTLTextureUsageShaderRead;
    id<MTLTexture> base=[device newTextureWithDescriptor:td];
    id<MTLTexture> view=[base newTextureViewWithPixelFormat:base.pixelFormat];
    id<MTLTexture> nested=[view newTextureViewWithPixelFormat:view.pixelFormat];assert(base&&view&&nested);
    id<MTLBuffer> input=[device newBufferWithLength:1024 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[device newBufferWithLength:1024 options:MTLResourceStorageModeShared];
    memset(input.contents,0x39,1024);memset(output.contents,0,1024);
    res_add(base);res_add(input);res_add(output);commit();assert(g_res.allocationCount==3);
    assert(zelda_resource_resident(nested) && zelda_resource_resident(input));
    res_add(base);res_add(view);res_add(nested);res_remove(view);res_remove(nested);
    assert(!g_res_dirty && g_res_objects.count==3);
    assert([g_res_objects containsObject:base] && ![g_res_objects containsObject:view]);
    assert(g_res_census == 1 && g_res_ever.count == 3 && ![g_res_ever containsObject:view]);
    id<MTL4CommandQueue> queue=[device newMTL4CommandQueue];[queue addResidencySet:g_res];
    id<MTL4CommandAllocator> allocator=[device newCommandAllocator];id<MTL4CommandBuffer> command=[device newCommandBuffer];
    [command beginCommandBufferWithAllocator:allocator];id<MTL4ComputeCommandEncoder> e=[command computeCommandEncoder];
    [e copyFromBuffer:input sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:1024 sourceSize:MTLSizeMake(4,4,1)
        toTexture:base destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [e barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:nested sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,4,1)
        toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
    [e endEncoding];[command endCommandBuffer];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);MTL4CommitOptions *options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> f){assert(!f.error);dispatch_semaphore_signal(done);}];
    id<MTL4CommandBuffer> commands[]={command};[queue commit:commands count:1 options:options];
    assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    for(unsigned row=0;row<4;row++)assert(!memcmp((uint8_t*)input.contents+row*256,(uint8_t*)output.contents+row*256,16));
    res_remove(base);res_remove(input);res_remove(output);commit();assert(!g_res.allocationCount);
    assert([g_res_ever containsObject:base] && ![g_res_objects containsObject:base]);
    assert(!zelda_resource_resident(nested) && !zelda_resource_resident(input));
    res_add(view);commit();assert([g_res_objects containsObject:view] && g_res.allocationCount==1);
    assert(zelda_resource_resident(view) && zelda_resource_resident(nested));
    // Access through a nested view with only its intermediate view registered (the game also registers swizzled views).
    res_add(input);res_add(output);commit();[allocator reset];memset(output.contents,0,1024);
    command=[device newCommandBuffer];[command beginCommandBufferWithAllocator:allocator];
    e=[command computeCommandEncoder];
    [e copyFromBuffer:input sourceOffset:0 sourceBytesPerRow:256 sourceBytesPerImage:1024 sourceSize:MTLSizeMake(4,4,1)
        toTexture:view destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [e barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromTexture:nested sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,4,1)
        toBuffer:output destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
    [e endEncoding];[command endCommandBuffer];commands[0]=command;
    options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> f){assert(!f.error);dispatch_semaphore_signal(done);}];
    [queue commit:commands count:1 options:options];
    assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    for(unsigned row=0;row<4;row++)assert(!memcmp((uint8_t*)input.contents+row*256,(uint8_t*)output.contents+row*256,16));
    res_remove(input);res_remove(output);
    res_remove(view);commit();assert(!g_res.allocationCount);
    res_remove(view);res_add(nil);assert(!g_res_dirty);
    zelda_texture_census(); assert(census_lines==1 && alias_censuses==1);   // format breakdown over the live set
    puts("Metal 4 residency: duplicate/view registrations, nested view GPU access, removal and unregistered-parent fallback passed");
} }
