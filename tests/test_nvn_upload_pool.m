#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>
static id<MTLDevice> g_dev;
static id<MTLResidencySet> residency;
static void res_add(id<MTLResource> r) { [residency addAllocation:(id<MTLAllocation>)r]; }
#define MDIE(...) do { fprintf(stderr,__VA_ARGS__); abort(); } while(0)
#include "../host/nvn_upload_pool.h"
int main(void) { @autoreleasepool {
    g_dev=MTLCreateSystemDefaultDevice();assert(g_dev);NSError *error=nil;
    MTLResidencySetDescriptor *rd=[MTLResidencySetDescriptor new];residency=[g_dev newResidencySetWithDescriptor:rd error:&error];
    id<MTL4CommandQueue> queue=[g_dev newMTL4CommandQueue];[queue addResidencySet:residency];
    id<MTL4CommandAllocator> allocators[3];dispatch_semaphore_t done[3];
    id<MTLBuffer> source=[g_dev newBufferWithLength:3*256 options:MTLResourceStorageModeShared];
    id<MTLBuffer> output=[g_dev newBufferWithLength:3*256 options:MTLResourceStorageModeShared];res_add(source);res_add(output);
    for(unsigned i=0;i<3;i++){allocators[i]=[g_dev newCommandAllocator];done[i]=dispatch_semaphore_create(0);zelda_upload_buffer(i,256);}
    assert(z_upload_buffers_created==3 && !zelda_upload_buffer(0,(4u<<20)+1));
    [residency commit];
    for(unsigned round=0;round<4;round++) {
        for(unsigned slot=0;slot<3;slot++) {
            if(round) { assert(!dispatch_semaphore_wait(done[slot],dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));[allocators[slot] reset]; }
            id<MTLBuffer> buffer=zelda_upload_buffer(slot,256);assert(zelda_upload_is_pooled(buffer));
            assert(buffer!=z_upload_buffers[(slot+1)%3]);
            memset((uint8_t*)source.contents+slot*256,0x10+round*3+slot,256);
            id<MTL4CommandBuffer> cb=[g_dev newCommandBuffer];[cb beginCommandBufferWithAllocator:allocators[slot]];
            id<MTL4ComputeCommandEncoder> e=[cb computeCommandEncoder];
            [e copyFromBuffer:source sourceOffset:slot*256 toBuffer:buffer destinationOffset:0 size:256];
            [e barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
            [e copyFromBuffer:buffer sourceOffset:0 toBuffer:output destinationOffset:slot*256 size:256];[e endEncoding];[cb endCommandBuffer];
            dispatch_semaphore_t complete=done[slot];MTL4CommitOptions *options=[MTL4CommitOptions new];
            [options addFeedbackHandler:^(id<MTL4CommitFeedback> f){assert(!f.error);dispatch_semaphore_signal(complete);}];
            id<MTL4CommandBuffer> batch[]={cb};[queue commit:batch count:1 options:options];
        }
    }
    for(unsigned slot=0;slot<3;slot++)assert(!dispatch_semaphore_wait(done[slot],dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    for(unsigned slot=0;slot<3;slot++)for(unsigned i=0;i<256;i++)assert(((uint8_t*)output.contents)[slot*256+i]==0x19+slot);
    assert(z_upload_buffers_created==3 && !zelda_upload_is_pooled(output));
    puts("Metal 4 upload buffers: three independent slots, completion-gated reuse, readback and large-allocation fallback passed");
} }
