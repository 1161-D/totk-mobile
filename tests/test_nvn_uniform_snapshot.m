#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include "nvn_obj.h"
#include "nvn_refl.h"
#define MDIE(...) do { fprintf(stderr,__VA_ARGS__); abort(); } while(0)
static id<MTLDevice> g_dev;
static id<MTL4CommandBuffer> command;
static id<MTL4ComputeCommandEncoder> g_blit;
static id<MTLBuffer> original, arena, output;
static uint64_t g_sub_serial = 1, z_queue_submit = 1;
static _Atomic uint64_t z_pool_generation = 1;
static size_t arena_used;
#define PEND_MAX 64
static unsigned g_npend, g_pend_over, dirty_calls;
static uint64_t g_pend_lo[PEND_MAX], g_pend_hi[PEND_MAX];
static pthread_mutex_t g_rmu = PTHREAD_MUTEX_INITIALIZER;
static struct { tex_t t; } g_treg[2];
static int g_ntreg = 2;
static struct { const prog_t *prog; p_bind_buf ubo[6][16]; NVNbufferRange vbuf[16]; uint64_t tex[6][128]; va_st attr[16]; } S;
static struct { p_set_rt rt; } R;
@interface NvShader : NSObject { @public char key[32]; int z_cube_uniform; nvn_refl rf; } @end
@implementation NvShader @end
@interface NvProg : NSObject { @public NvShader *sh[6]; } @end
@implementation NvProg @end
uint64_t nvn_canonical_address(uint64_t a, uint64_t n) {
    if (!a || n > UINT64_MAX-a) return 0;
    return a >= 0x200000 && a+n <= 0x210000 ? a-0x100000 : a;
}
static int mtl_addr(uint64_t a, uint64_t n, void **buffer, uint64_t *offset) {
    a=nvn_canonical_address(a,n); if(a<0x100000 || a+n>0x110000)return 0;
    *buffer=(__bridge void*)original;*offset=a-0x100000;return 1;
}
static size_t arena_alloc(size_t n, id<MTLBuffer> *buffer) {
    size_t offset=arena_used;arena_used+=(n+255)&~255u;assert(arena_used<=arena.length);*buffer=arena;return offset;
}
static void args_dirty_all(void) { dirty_calls++; }
static int tbdr_on(void) { return 0; }
static int zelda_uniform_linked_source(int layout) { return layout == 1 || layout == 2; }
static unsigned zelda_vertex_input_class(unsigned f) { return f; }
static id<MTL4ComputeCommandEncoder> blit(void) {
    if(!g_blit){g_blit=[command computeCommandEncoder];[g_blit barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];}
    return g_blit;
}
static void finish_blit(void) {
    if(g_blit){[g_blit barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];[g_blit endEncoding];g_blit=nil;}
}
static void enc_b_copy_buffer(id e,id<MTLBuffer> s,NSUInteger so,id<MTLBuffer> d,NSUInteger off,NSUInteger n) {
    [e copyFromBuffer:s sourceOffset:so toBuffer:d destinationOffset:off size:n];
}
static void defer_obj_release(id buffer) { assert(!buffer); } // This fixture never populates index results.
#include "../host/nvn_buffer_cache.inc"
#include "../host/nvn_uniform_snapshot.inc"
#include "../host/nvn_uniform_layout.h"
static void consume(id<MTLComputePipelineState> pipeline,id<MTL4ArgumentTable> table,uint64_t source,unsigned index) {
    finish_blit();id<MTL4ComputeCommandEncoder> e=[command computeCommandEncoder];
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [table setAddress:source atIndex:0];[table setAddress:output.gpuAddress+4*index atIndex:1];
    [e setArgumentTable:table];[e setComputePipelineState:pipeline];
    [e dispatchThreadgroups:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
    [e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];[e endEncoding];
}
int main(void) { @autoreleasepool {
    g_dev=MTLCreateSystemDefaultDevice();assert(g_dev);NSError *error=nil;
    id<MTLLibrary> library=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; kernel void read_words(constant uint *p [[buffer(0)]],device uint *out [[buffer(1)]]){*out=p[1]+p[3]+p[4]+p[5]+p[10]+p[11];} kernel void read_mip(constant uint *p [[buffer(0)]],device uint *out [[buffer(1)]]){uint sum=p[64];for(uint i=8;i<=24;i++)sum+=p[i];*out=sum;}" options:nil error:&error];
    assert(library);id<MTLComputePipelineState> pipeline=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"read_words"] error:&error];assert(pipeline);
    MTL4ArgumentTableDescriptor *ad=[MTL4ArgumentTableDescriptor new];ad.maxBufferBindCount=2;
    id<MTL4ArgumentTable> table=[g_dev newArgumentTableWithDescriptor:ad error:&error];
    original=[g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];memset(original.contents,0x5a,65536);
    arena=[g_dev newBufferWithLength:4<<20 options:MTLResourceStorageModeShared];output=[g_dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    id<MTLResidencySet> residency=[g_dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    for(id<MTLAllocation> r in @[original,arena,output])[residency addAllocation:r];[residency commit];
    id<MTL4CommandQueue> queue=[g_dev newMTL4CommandQueue];[queue addResidencySet:residency];
    id<MTL4CommandAllocator> allocator=[g_dev newCommandAllocator];command=[g_dev newCommandBuffer];[command beginCommandBufferWithAllocator:allocator];
    prog_t guest={.serial=1};S.prog=&guest;S.ubo[0][0]=(p_bind_buf){.addr=0x100000,.size=65536};S.ubo[1][0]=S.ubo[0][0];
    NvProg *program=[NvProg new];program->sh[0]=[NvShader new];program->sh[1]=[NvShader new];
    strcpy(program->sh[0]->key,"ec4f05739b0fbc91_b");strcpy(program->sh[1]->key,"4e370f8adcd93698_b");
    program->sh[0]->z_cube_uniform=program->sh[1]->z_cube_uniform=1;
    for(unsigned i=0;i<6;i++){uint64_t record[]={0x100000+4*z_cube_words[i],4,i+1};assert(!zelda_buffer_write_op(OP_UPDATE_UB,record));((uint32_t*)original.contents)[z_cube_words[i]]=i+1;}
    zelda_uniform_prepare_draw(program,NULL);assert(z_uniform_gpu);consume(pipeline,table,z_uniform_gpu,0);
    for(unsigned i=0;i<2;i++) {
        uint64_t record[]={0x200004,4,i?19:11};assert(!zelda_buffer_write_op(OP_UPDATE_UB,record));
        assert(zelda_uniform_defer(record,32)&&z_uniform_pending_count==1);
        assert(zelda_uniform_passthrough(OP_UPDATE_UB,record));
        uint64_t query[]={NVN_COUNTER_TYPE_TIMESTAMP_TOP,0x108000};assert(zelda_uniform_passthrough(OP_REPORT_COUNTER,query));
        query[1]=0x100004;assert(!zelda_uniform_passthrough(OP_REPORT_COUNTER,query));
        assert(!zelda_uniform_passthrough(OP_DISPATCH,NULL));
        zelda_uniform_prepare_draw(program,NULL);assert(z_uniform_gpu);consume(pipeline,table,z_uniform_gpu,i+1);
    }
    program->sh[1]->rf.nb=1;program->sh[1]->rf.b[0]=(nvn_rbind){.kind=NVN_RB_TEX,.reg=0};
    S.tex[1][0]=1;g_treg[1].t=(tex_t){.mem=(void*)0x200000,.L={.size=64}};
    zelda_uniform_prepare_draw(program,NULL);assert(!z_uniform_gpu&&!z_uniform_pending_count);
    consume(pipeline,table,original.gpuAddress,3);
    S.tex[1][0]=0;program->sh[0]->z_cube_uniform=0;zelda_uniform_prepare_draw(program,NULL);assert(!z_uniform_gpu);
    // A later slice snapshots from bytes already known in this queue submission; a new submission must reread them.
    program->sh[0]->z_cube_uniform=1;g_sub_serial++;zelda_uniform_prepare_draw(program,NULL);assert(z_uniform_gpu);
    z_queue_submit++;g_sub_serial++;zelda_uniform_prepare_draw(program,NULL);assert(!z_uniform_gpu);
    assert(z_uniform_snapshots==4 && z_uniform_deferred==2 && g_npend==1 && !g_pend_over && dirty_calls);
    pipeline=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"read_mip"] error:&error];assert(pipeline);
    strcpy(program->sh[0]->key,"caf33ef1b3566666_b");strcpy(program->sh[1]->key,"704413ad2261cb23_b");
    program->sh[0]->z_cube_uniform=program->sh[1]->z_cube_uniform=2;
    for(unsigned i=0;i<18;i++){
        uint64_t record[]={0x100000+4*z_mip_words[i],4,i+1};assert(!zelda_buffer_write_op(OP_UPDATE_UB,record));
        id<MTLBuffer> source;size_t offset=arena_alloc(4,&source);uint32_t value=i+1;memcpy((uint8_t*)source.contents+offset,&value,4);
        enc_b_copy_buffer(blit(),source,offset,original,4*z_mip_words[i],4);
    }
    zelda_uniform_prepare_draw(program,NULL);assert(z_uniform_gpu);consume(pipeline,table,z_uniform_gpu,4);
    for(unsigned i=0;i<2;i++){
        uint64_t face[]={0x200060,4,100+10*i},level[]={0x200100,4,200+20*i};
        assert(!zelda_buffer_write_op(OP_UPDATE_UB,face));assert(zelda_uniform_defer(face,32));
        assert(!zelda_buffer_write_op(OP_UPDATE_UB,level));assert(zelda_uniform_defer(level,32));
        assert(z_uniform_pending_count==2);
        zelda_uniform_prepare_draw(program,NULL);assert(z_uniform_gpu);consume(pipeline,table,z_uniform_gpu,5+i);
    }
    program->sh[1]->z_cube_uniform=1;zelda_uniform_prepare_draw(program,NULL);assert(!z_uniform_gpu&&!z_uniform_pending_count);
    consume(pipeline,table,original.gpuAddress,7);
    assert(!zelda_cube_uniform_layout(@"tests/fixtures/invariant_math.metal",@"caf33ef1b3566666_b"));
    assert(!zelda_cube_uniform_layout(@"missing",@"ec4f05739b0fbc91_b"));
    assert(!zelda_cube_uniform_layout(@"tests/fixtures/invariant_math.metal",@"unknown"));
    finish_blit();[command endCommandBuffer];dispatch_semaphore_t done=dispatch_semaphore_create(0);MTL4CommitOptions *options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> f){assert(!f.error);dispatch_semaphore_signal(done);}];
    id<MTL4CommandBuffer> batch[]={command};[queue commit:batch count:1 options:options];
    assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    const uint32_t expected[]={21,31,39,39,171,436,466,466};assert(!memcmp(output.contents,expected,sizeof expected));
    assert(((uint32_t*)original.contents)[1]==19 && ((uint32_t*)original.contents)[0]==0x5a5a5a5a);
    puts("Uniform snapshots: distinct GPU consumers, deferred last write, aliases, hazards, source guard and submission lifetime passed");
} }
