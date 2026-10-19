#import <Metal/Metal.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include "nvn_obj.h"
#include "nvn_refl.h"

static id<MTLDevice> g_dev;
static id<MTL4CommandBuffer> command;
static id<MTL4ComputeCommandEncoder> g_blit;
static id<MTLBuffer> source, arena;
static id<MTLResidencySet> residency;
static NSMutableArray *retired;
static struct { p_bind_buf ssbo[6][16]; } S;
static void defer_obj_release(id buffer) { if (buffer) [retired addObject:buffer]; }
static void res_add(id<MTLResource> buffer) { [residency addAllocation:(id<MTLAllocation>)buffer]; [residency commit]; }
static uint64_t g_sub_serial = 1, z_queue_submit = 1;
static _Atomic uint64_t z_pool_generation = 1;
static size_t used;
static unsigned conversions, pass_ends, compute_encoders;
uint64_t nvn_canonical_address(uint64_t a, uint64_t n) {
    if (!a || n > UINT64_MAX-a) return 0;
    return a >= 0x2000 && a+n <= 0x2200 ? a-0x1000 : a;
}
static int mtl_gpu_addr(uint64_t a, uint64_t n, void **b, uint64_t *off, uint64_t *gpu) {
    a=nvn_canonical_address(a,n); if (a<0x1000 || a+n>0x1000+source.length) return 0;
    *b=(__bridge void *)source; *off=a-0x1000; *gpu=source.gpuAddress+*off; return 1;
}
static size_t arena_alloc(size_t n, id<MTLBuffer> *b) {
    size_t at=used; used+=(n+255)&~255u; assert(used<=arena.length); *b=arena; return at;
}
static void rp_end(void) { pass_ends++; }
static void args_dirty_all(void) {}
static id<MTL4ComputeCommandEncoder> enc_c_begin(MTLComputePassDescriptor *d) {
    (void)d; compute_encoders++; id<MTL4ComputeCommandEncoder> e=[command computeCommandEncoder];
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; return e;
}
#define enc_c_pso(e,p) [(e) setComputePipelineState:(p)]
#define enc_c_dispatch(e,n,s) do { conversions++; [(e) dispatchThreadgroups:(n) threadsPerThreadgroup:(s)]; } while(0)
static void enc_c_end(id<MTL4ComputeCommandEncoder> e) {
    [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice]; [e endEncoding];
}
static id<MTL4ComputeCommandEncoder> blit(void) {
    rp_end(); if (!g_blit) g_blit=enc_c_begin(NULL); return g_blit;
}
static void finish_blit(void) { if (g_blit) { enc_c_end(g_blit); g_blit=nil; } }
#define MDIE(...) do { fprintf(stderr,__VA_ARGS__); abort(); } while (0)
#define PD(...) ((void)0)
#include "../host/nvn_buffer_cache.inc"
#include "../host/nvn_buffer_writes.inc"
// The in-pass conversion path needs an open render pass; this fixture checks the copy-encoder path (the in-pass
// path is covered by test_nvn_pass_writes.m), so the pass state below is never used.
static struct { uint32_t cfmt[8], dfmt, sfmt, samples; } g_pass;
static id g_vt, g_enc_pso, g_enc; static int g_pso_dirty;
static int tbdr_on(void) { return 0; }
static void enc_r_pso(id encoder, id pipeline) { (void)encoder; (void)pipeline; abort(); }
#include "../host/nvn_index.inc"

static unsigned uniform_copies;
static void update_uniform(const uint64_t *record) {
    if (zelda_buffer_write_op(OP_UPDATE_UB, record)) return;
    finish_blit();
    id<MTLBuffer> upload; size_t start=arena_alloc(record[1], &upload);
    memcpy((uint8_t *)arena.contents+start, record+2, record[1]);
    id<MTL4ComputeCommandEncoder> e=[command computeCommandEncoder];
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [e copyFromBuffer:arena sourceOffset:start toBuffer:source
        destinationOffset:nvn_canonical_address(record[0],record[1])-0x1000 size:record[1]];
    enc_c_end(e); uniform_copies++;
}

int main(void) { @autoreleasepool {
    setenv("ZELDA_INDEX_IN_PASS", "0", 1);
    zelda_index_encode(nil);   // Nothing pending: no work.
    g_dev=MTLCreateSystemDefaultDevice(); assert(g_dev); NSError *error=nil;
    uint8_t data[8192]; for (unsigned i=0;i<sizeof data;i++) data[i]=(uint8_t)(i^17);
    id<MTLBuffer> staging=[g_dev newBufferWithBytes:data length:sizeof data options:MTLResourceStorageModeShared];
    source=[g_dev newBufferWithLength:sizeof data options:MTLResourceStorageModePrivate];
    arena=[g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared]; memset(arena.contents,0xa5,arena.length);
    retired=[NSMutableArray array];
    id<MTL4CommandQueue> queue=[g_dev newMTL4CommandQueue];
    id<MTL4CommandAllocator> allocator=[g_dev newCommandAllocator]; command=[g_dev newCommandBuffer];
    MTLResidencySetDescriptor *rd=[MTLResidencySetDescriptor new];
    residency=[g_dev newResidencySetWithDescriptor:rd error:&error];
    for (id<MTLAllocation> r in @[staging,source,arena]) [residency addAllocation:r];
    [residency commit]; [queue addResidencySet:residency];
    [command beginCommandBufferWithAllocator:allocator];
    id<MTL4ComputeCommandEncoder> copy=g_blit=enc_c_begin(NULL);
    [copy copyFromBuffer:staging sourceOffset:0 toBuffer:source destinationOffset:0 size:sizeof data];
    p_draw_idx draw={.count=16,.ibuf=0x1000}; uint64_t first=zelda_expand_indices(&draw);
    id<MTLBuffer> first_buffer=z_index_cache[0].buffer;
    assert(first_buffer && first_buffer != arena);
    memset((uint8_t *)first_buffer.contents+256+32,0xa5,224);
    assert(zelda_expand_indices(&draw)==first && conversions==1 && pass_ends==1);
    draw.ibuf=0x2000; assert(zelda_expand_indices(&draw)==first && conversions==1);
    uint64_t update[]={0x1080,8,0x9988776655443322}; zelda_buffer_write_op(OP_UPDATE_UB,update);
    assert(zelda_expand_indices(&draw)==first && conversions==1);
    draw.count=6; uint64_t short_result=zelda_expand_indices(&draw); assert(short_result!=first && conversions==2 && compute_encoders==1);
    uint64_t mutation[]={0,0x2000,16}; zelda_buffer_write_op(OP_COPY_B2B,mutation);
    finish_blit();
    copy=[command computeCommandEncoder];
    [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [copy fillBuffer:source range:NSMakeRange(0,16) value:0x22]; enc_c_end(copy);
    draw.count=16; uint64_t changed=zelda_expand_indices(&draw); assert(changed!=first && conversions==3);
    assert(zelda_expand_indices(&draw)==changed && conversions==3);
    id<MTLBuffer> changed_buffer=z_index_cache[0].buffer;
    memset((uint8_t *)changed_buffer.contents+256+32,0xa5,224);
    uint64_t counter[]={0,0x2008}; zelda_buffer_write_op(OP_REPORT_COUNTER,counter);
    assert(!z_index_count); uint64_t refreshed=zelda_expand_indices(&draw); assert(refreshed!=changed);
    uint64_t event=0x1000; zelda_buffer_write_op(OP_SIGNAL_EVENT,&event); assert(!z_index_count);
    uint64_t persistent=zelda_expand_indices(&draw);
    zelda_buffer_write_op(OP_DISPATCH,NULL); assert(z_index_count);
    nvn_refl writes={.nb=1}; writes.b[0]=(nvn_rbind){.kind=NVN_RB_SBUFP,.rw=1,.reg=2};
    S.ssbo[5][2]=(p_bind_buf){.addr=0x1100,.size=16};
    zelda_buffer_shader_written(&writes,5); assert(zelda_expand_indices(&draw)==persistent);
    // A new command buffer can reset arena storage without invalidating the owned index result.
    g_sub_serial++; zelda_buffer_cache_sync(); assert(zelda_expand_indices(&draw)==persistent);
    assert(!memcmp(first_buffer.contents,&(uint32_t){16},4));
    S.ssbo[5][2]=(p_bind_buf){.addr=0x2008,.size=1};
    zelda_buffer_shader_written(&writes,5); assert(!z_index_count);
    zelda_expand_indices(&draw); S.ssbo[5][2].size=0;
    zelda_buffer_shader_written(&writes,5); assert(!z_index_count);
    zelda_expand_indices(&draw); writes.b[0].kind=NVN_RB_IMG;
    zelda_buffer_shader_written(&writes,0); assert(!z_index_count);
    zelda_expand_indices(&draw); writes.b[0].kind=0x40;
    zelda_buffer_shader_written(&writes,0); assert(!z_index_count);
    zelda_expand_indices(&draw); z_queue_submit++; zelda_buffer_cache_sync(); assert(!z_index_count);
    zelda_expand_indices(&draw); z_pool_generation++; zelda_buffer_cache_sync(); assert(!z_index_count);
    uint64_t u[]={0x1080,8,0x1122334455667788}, alias[]={0x2080,8,0x1122334455667788};
    update_uniform(u); update_uniform(alias); assert(uniform_copies==1);
    uint64_t same_subset[]={0x2084,4,0x11223344};
    update_uniform(same_subset); assert(uniform_copies==1);
    uint64_t overlap[]={0x2084,4,0xaabbccdd}; update_uniform(overlap);
    update_uniform(u); assert(uniform_copies==3);
    uint64_t unrelated[]={0,0x1100,4}; zelda_buffer_write_op(OP_COPY_B2B,unrelated);
    update_uniform(u); assert(uniform_copies==3);
    uint64_t modified[]={0,0x2080,8}; zelda_buffer_write_op(OP_COPY_B2B,modified);
    copy=[command computeCommandEncoder];
    [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [copy fillBuffer:source range:NSMakeRange(128,8) value:0xff]; enc_c_end(copy);
    update_uniform(u); assert(uniform_copies==4);
    zelda_buffer_write_op(OP_DISPATCH,NULL); update_uniform(u); assert(uniform_copies==5);
    // A slice keeps known uniform bytes; a new guest submit may contain CPU writes and expires both caches.
    g_sub_serial++; update_uniform(u); assert(uniform_copies==5);
    z_queue_submit++; update_uniform(u); assert(uniform_copies==6);
    z_pool_generation++; update_uniform(u); assert(uniform_copies==7);
    tex_t texture={.mem=(void *)0x1100, .L={.size=16}};
    p_copy_b2t to_texture={.tex=&texture}; zelda_buffer_write_op(OP_COPY_B2T,&to_texture);
    update_uniform(u); assert(uniform_copies==7);
    texture.mem=(void *)0x2080;
    p_copy_t2t texture_copy={.dst=&texture}; zelda_buffer_write_op(OP_COPY_T2T,&texture_copy);
    update_uniform(u); assert(uniform_copies==8);
    p_clear_tex texture_clear={.tex=&texture}; zelda_buffer_write_op(OP_CLEAR_TEX,&texture_clear);
    update_uniform(u); assert(uniform_copies==9);
    zelda_buffer_forget(); assert(!z_uniform_count && !z_index_count);
    id<MTLBuffer> readback=[g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    [residency addAllocation:readback]; [residency commit];
    copy=[command computeCommandEncoder];
    [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [copy copyFromBuffer:source sourceOffset:128 toBuffer:readback destinationOffset:0 size:16]; enc_c_end(copy);
    [command endCommandBuffer]; id<MTL4CommandBuffer> commands[]={command};
    dispatch_semaphore_t done=dispatch_semaphore_create(0); MTL4CommitOptions *options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { assert(!feedback.error); dispatch_semaphore_signal(done); }];
    [queue commit:commands count:1 options:options];
    assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    const uint16_t *original=(const void *)((uint8_t *)first_buffer.contents+256);
    const uint16_t *updated=(const void *)((uint8_t *)changed_buffer.contents+256);
    for (unsigned i=0;i<16;i++) { assert(original[i]==data[i]); assert(updated[i]==0x22); }
    assert(original[16]==0xa5a5 && updated[16]==0xa5a5);
    assert(!memcmp(readback.contents,u+2,8));
    assert(!memcmp((uint8_t *)readback.contents+8,data+136,8));
    assert(retired.count && [retired containsObject:first_buffer] && [retired containsObject:changed_buffer]);

    // Two real queue submissions: the second reuses a result, then replaces it after an aliased GPU write.
    g_sub_serial++; z_queue_submit++; used=0;
    id<MTL4CommandAllocator> second_allocator=[g_dev newCommandAllocator];
    id<MTL4CommandBuffer> first_command=[g_dev newCommandBuffer]; command=first_command;
    [command beginCommandBufferWithAllocator:allocator];
    draw=(p_draw_idx){.count=16,.ibuf=0x1000}; uint64_t across=zelda_expand_indices(&draw);
    id<MTLBuffer> across_buffer=z_index_cache[0].buffer;
    finish_blit(); [command endCommandBuffer];
    id<MTL4CommandBuffer> one[]={first_command}; [queue commit:one count:1 options:[MTL4CommitOptions new]];

    command=[g_dev newCommandBuffer]; [command beginCommandBufferWithAllocator:second_allocator];
    g_sub_serial++; used=0; memset(arena.contents,0xcc,arena.length);
    unsigned before=conversions;
    assert(zelda_expand_indices(&draw)==across && conversions==before);
    id<MTLBuffer> results=[g_dev newBufferWithLength:96 options:MTLResourceStorageModeShared]; res_add(results);
    copy=g_blit=enc_c_begin(NULL);
    [copy copyFromBuffer:across_buffer sourceOffset:256 toBuffer:results destinationOffset:0 size:32];
    zelda_buffer_write_op(OP_COPY_B2B,mutation);
    [copy fillBuffer:source range:NSMakeRange(0,16) value:0x33];
    uint64_t newer=zelda_expand_indices(&draw); assert(newer!=across);
    id<MTLBuffer> newer_buffer=z_index_cache[0].buffer;
    finish_blit(); copy=enc_c_begin(NULL);
    [copy copyFromBuffer:across_buffer sourceOffset:256 toBuffer:results destinationOffset:32 size:32];
    [copy copyFromBuffer:newer_buffer sourceOffset:256 toBuffer:results destinationOffset:64 size:32]; enc_c_end(copy);

    draw=(p_draw_idx){.count=4097,.ibuf=0x1000};
    uint64_t large=zelda_expand_indices(&draw);
    assert(z_index_count==2 && !z_index_cache[1].buffer);
    assert(large>=arena.gpuAddress && large<arena.gpuAddress+arena.length);
    g_sub_serial++; zelda_buffer_cache_sync(); assert(z_index_count==1 && z_index_cache[0].buffer==newer_buffer);
    finish_blit(); [command endCommandBuffer];
    MTL4CommitOptions *second_options=[MTL4CommitOptions new];
    [second_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { assert(!feedback.error); dispatch_semaphore_signal(done); }];
    id<MTL4CommandBuffer> two[]={command}; [queue commit:two count:1 options:second_options];
    assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    for (unsigned i=0;i<16;i++) {
        const uint16_t *r=results.contents; assert(r[i]==0x22 && r[16+i]==0x22 && r[32+i]==0x33);
    }
    const uint16_t *fallback=(const void *)((uint8_t *)arena.contents+large-arena.gpuAddress);
    assert(fallback[4096]==data[4096]);
    zelda_buffer_invalidate(UINT64_MAX,2); assert(!z_index_count);
    puts("Metal 4 owned index results: real queue/slice reuse, aliased GPU writes, shader ranges, guest-submit expiry, arena fallback and retired-reader output passed");
} }
