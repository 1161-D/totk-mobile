#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include "nvn_obj.h"
#include "nvn_refl.h"
static id<MTLDevice> g_dev;
static id<MTL4CommandBuffer> command;
static id<MTL4ComputeCommandEncoder> g_blit;
static id<MTLBuffer> memory, arena, output;
static id<MTLBuffer> pointer_uniform, pointer_geometry;
static uint64_t g_sub_serial = 1, z_queue_submit = 1;
static _Atomic uint64_t z_pool_generation = 1;
static size_t arena_used;
#define PEND_MAX 64
static int g_npend, g_pend_over;
static uint64_t g_pend_lo[PEND_MAX], g_pend_hi[PEND_MAX];
static unsigned z_uniform_pending_count, dirty_calls, copies;
static id g_enc;
static pthread_mutex_t g_rmu = PTHREAD_MUTEX_INITIALIZER;
static struct { tex_t t; } g_treg[2];
static int g_ntreg = 2;
static struct { p_bind_buf ubo[6][16], ssbo[6][16]; NVNbufferRange vbuf[16]; uint64_t tex[6][128]; } S;
static struct { p_set_rt rt; } R;
@interface NvShader : NSObject { @public int stage; nvn_refl rf; char key[20]; } @end
@implementation NvShader @end
@interface NvProg : NSObject { @public NvShader *sh[6]; } @end
@implementation NvProg @end
uint64_t nvn_canonical_address(uint64_t a, uint64_t n) {
    if (!a || n > UINT64_MAX-a) return 0;
    if (a >= 0x300000 && a+n <= 0x310000) return (uintptr_t)pointer_geometry.contents+a-0x300000;
    return a >= 0x200000 && a+n <= 0x210000 ? a-0x100000 : a; // A second mapping aliases the same pool.
}
static int mtl_addr(uint64_t address, uint64_t length, void **buffer, uint64_t *offset) {
    address=nvn_canonical_address(address,length);
    id<MTLBuffer> pools[]={pointer_uniform,pointer_geometry};
    for(unsigned i=0;i<2;i++) {
        uint64_t base=(uintptr_t)pools[i].contents;
        if(base && address>=base && address-base<=pools[i].length && length<=pools[i].length-(address-base)) {
            *buffer=(__bridge void *)pools[i];*offset=address-base;return 1;
        }
    }
    return 0;
}
static int mtl_gpu_addr(uint64_t address,uint64_t length,void **buffer,uint64_t *offset,uint64_t *gpu) {
    if(!mtl_addr(address,length,buffer,offset)) return 0;
    *gpu=((__bridge id<MTLBuffer>)*buffer).gpuAddress+*offset;return 1;
}
static uint64_t mtl_last_fence(void) { return 1; }
static int mtl_wait(uint64_t fence,uint64_t timeout) { (void)timeout;return fence<=1; }
static int pend_hits(uint64_t address,uint64_t length) { (void)address;(void)length;return 0; }
static void use_rec(const char *kind,uint64_t address,uint64_t length,int tid,const tex_t *texture) {
    (void)kind;(void)address;(void)length;(void)tid;(void)texture;
}
#define MLOG(...) ((void)0)
#define RED_ONCE(...) ((void)0)
#define MDIE(...) do { fprintf(stderr,__VA_ARGS__); abort(); } while(0)
#define ZELDA_POINTER_STORAGE_BIND 1
#include "../host/nvn_pointer_storage.inc"
static size_t arena_alloc(size_t n, id<MTLBuffer> *buffer) {
    size_t offset=arena_used;arena_used+=(n+255)&~255u;assert(arena_used<=arena.length);*buffer=arena;return offset;
}
static void args_dirty_all(void) { dirty_calls++; }
static int tbdr_on(void) { return 0; }
static id<MTL4ComputeCommandEncoder> blit(void) {
    g_enc=nil; // The real blit() ends the open render pass first.
    if(!g_blit){g_blit=[command computeCommandEncoder];[g_blit barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];}
    return g_blit;
}
static void finish_blit(void) {
    if(g_blit){[g_blit barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];[g_blit endEncoding];g_blit=nil;}
}
#include "../host/nvn_buffer_copy.inc"
static void mtl_sub_copy(uint64_t source, uint64_t destination, uint64_t n) {
    // The inline record lives in host command memory; stage it so the GPU copy keeps stream order.
    id<MTLBuffer> staging; size_t at=arena_alloc(n,&staging); memcpy((uint8_t *)staging.contents+at,(const void *)(uintptr_t)source,n);
    uint64_t target=nvn_canonical_address(destination,n),offset; void *buffer;
    if(target>=0x100000 && target+n<=0x110000) { buffer=(__bridge void *)memory;offset=target-0x100000; }
    else assert(mtl_addr(destination,n,&buffer,&offset));
    enc_b_copy_buffer(blit(),staging,at,(__bridge id<MTLBuffer>)buffer,offset,n); copies++;
}
static void defer_obj_release(id buffer) { assert(!buffer); } // This fixture never populates index results.
#include "../host/nvn_buffer_cache.inc"
// Write-backs here always copy at once; waiting for the next pass is covered by test_nvn_pass_writes.m.
static int zelda_write_defer(uint64_t source, uint64_t destination, uint64_t bytes) { (void)source; (void)destination; (void)bytes; return 0; }
#include "../host/nvn_inline_uniform.inc"
typedef struct { uint64_t address, length; uint8_t bytes[128]; } Update;
static int update(Update *u, size_t n) { // Mirrors the command loop: drop identical bytes, else defer or copy now.
    u->length=n; zelda_update_log_op(OP_UPDATE_UB,u); if (zelda_buffer_write_op(OP_UPDATE_UB,u)) return 1;
    if (zelda_inline_defer(u)) return 2;
    zelda_inline_flush(); mtl_sub_copy((uint64_t)(uintptr_t)u->bytes,u->address,n); return 0;
}
static NvProg *program_with(nvn_rbind *bindings, int count) {
    NvProg *program=[NvProg new]; program->sh[0]=[NvShader new]; program->sh[0]->stage=0;
    program->sh[0]->rf.nb=count; memcpy(program->sh[0]->rf.b,bindings,count*sizeof *bindings); return program;
}
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
    id<MTLLibrary> library=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; kernel void sum(constant uint *p [[buffer(0)]],device uint *out [[buffer(1)]]){uint s=0;for(uint i=0;i<24;i++)s=s*31+p[i];*out=s;} kernel void sum12(constant uint *p [[buffer(0)]],device uint *out [[buffer(1)]]){uint s=0;for(uint i=0;i<12;i++)s=s*31+p[i];*out=s;}" options:nil error:&error];
    assert(library);id<MTLComputePipelineState> pipeline=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"sum"] error:&error];assert(pipeline);
    id<MTLComputePipelineState> short_pipeline=[g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"sum12"] error:&error];assert(short_pipeline);
    MTL4ArgumentTableDescriptor *ad=[MTL4ArgumentTableDescriptor new];ad.maxBufferBindCount=3;
    id<MTL4ArgumentTable> table=[g_dev newArgumentTableWithDescriptor:ad error:&error];
    memory=[g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];memset(memory.contents,0x5a,65536);
    arena=[g_dev newBufferWithLength:4<<20 options:MTLResourceStorageModeShared];output=[g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLResidencySet> residency=[g_dev newResidencySetWithDescriptor:[MTLResidencySetDescriptor new] error:&error];
    for(id<MTLAllocation> r in @[memory,arena,output])[residency addAllocation:r];[residency commit];
    id<MTL4CommandQueue> queue=[g_dev newMTL4CommandQueue];[queue addResidencySet:residency];
    id<MTL4CommandAllocator> allocator=[g_dev newCommandAllocator];command=[g_dev newCommandBuffer];[command beginCommandBufferWithAllocator:allocator];

    // A shadow-style pass: two view constants updated between draws, each bound with exactly its updated size.
    Update first={.address=0x100200}, second={.address=0x200200}, view={.address=0x100100};
    for(unsigned i=0;i<96;i++){first.bytes[i]=(uint8_t)i;second.bytes[i]=(uint8_t)(200-i);} memset(view.bytes,7,48);
    nvn_rbind bindings[]={{.kind=NVN_RB_CBUF,.reg=3},{.kind=NVN_RB_CBUF,.reg=12},{.kind=NVN_RB_CBUF,.reg=1},{.kind=NVN_RB_SAMP,.reg=0}};
    NvProg *program=program_with(bindings,4);
    S.ubo[0][3]=(p_bind_buf){.addr=0x100200,.size=96};S.ubo[0][12]=(p_bind_buf){.addr=0x100100,.size=48};S.ubo[0][1]=(p_bind_buf){.addr=0x100800,.size=64};
    assert(update(&first,96)==0 && copies==1); // No pass is open: the ordinary copy is already free of a pass break.
    g_enc=@YES; assert(update(&view,48)==2 && update(&first,96)==1); // Identical bytes are still dropped.
    assert(update(&second,96)==2 && z_inline_count==2 && g_npend==2 && g_enc);
    unsigned dirty=dirty_calls; zelda_inline_prepare_draw(program,NULL);
    uint64_t snapshot_second=z_inline_override[0][3], snapshot_view=z_inline_override[0][12];
    assert(snapshot_second && snapshot_view && !z_inline_override[0][1] && g_enc && copies==1 && dirty_calls==dirty+1);
    assert(!memcmp((uint8_t *)arena.contents+(snapshot_second-arena.gpuAddress),second.bytes,96));
    assert(!memcmp((uint8_t *)arena.contents+(snapshot_view-arena.gpuAddress),view.bytes,48));
    uint8_t second_at_draw[96]; memcpy(second_at_draw,second.bytes,96);
    assert(update(&first,96)==2 && z_inline_count==3);
    zelda_inline_prepare_draw(program,NULL); uint64_t snapshot_first=z_inline_override[0][3];
    assert(snapshot_first && snapshot_first!=snapshot_second && z_inline_override[0][12]);
    // Only checked commands keep the updates pending.
    uint64_t report[]={NVN_COUNTER_TYPE_TIMESTAMP,0x108000}; assert(zelda_inline_passthrough(OP_REPORT_COUNTER,report));
    report[1]=0x200110; assert(!zelda_inline_passthrough(OP_REPORT_COUNTER,report));
    assert(zelda_inline_passthrough(OP_DRAW,NULL) && zelda_inline_passthrough(OP_BARRIER,NULL) && !zelda_inline_passthrough(OP_DISPATCH,NULL));
    assert(!zelda_inline_passthrough(OP_COPY_B2B,NULL) && !zelda_inline_passthrough(OP_COPY_T2B,NULL));
    tex_t target={.mem=(void *)0x100000,.L={.size=0x1000}}; p_set_rt targets={.n=1,.color={&target}};
    assert(!zelda_inline_passthrough(OP_SET_RT,&targets)); target.mem=(void *)0x104000; assert(zelda_inline_passthrough(OP_SET_RT,&targets));
    p_render_enable condition={.address=0x1001f0}; assert(!zelda_inline_passthrough(OP_RENDER_ENABLE,&condition));
    consume(pipeline,table,snapshot_second,0); consume(pipeline,table,snapshot_first,1); consume(short_pipeline,table,snapshot_view,2);
    // Writing them out keeps stream order, so memory ends with the last bytes for each range.
    g_enc=@YES; zelda_inline_flush(); assert(copies==4 && !z_inline_count && !z_inline_overridden && !g_enc);
    finish_blit(); consume(pipeline,table,memory.gpuAddress+0x200,3); consume(short_pipeline,table,memory.gpuAddress+0x100,4);

    // Every other kind of reader writes pending updates before the draw, including a constant range only partly known.
    nvn_rbind wide[]={{.kind=NVN_RB_CBUF,.reg=3}}; NvProg *wide_program=program_with(wide,1);
    g_enc=@YES; second.bytes[0]^=1; assert(update(&second,96)==2); S.ubo[0][3].size=128;
    zelda_inline_prepare_draw(wide_program,NULL); assert(copies==5 && !z_inline_count && !z_inline_overridden);
    S.ubo[0][3].size=96;
    nvn_rbind other[]={{.kind=NVN_RB_CBUF,.reg=1}}; NvProg *plain=program_with(other,1);
    g_enc=@YES; second.bytes[0]^=1; assert(update(&second,96)==2); S.vbuf[2]=(NVNbufferRange){.address=0x2001f0,.size=32};
    zelda_inline_prepare_draw(plain,NULL); assert(copies==6 && !z_inline_count); S.vbuf[2]=(NVNbufferRange){0};
    g_enc=@YES; second.bytes[0]^=1; assert(update(&second,96)==2);
    p_draw_idx indices={.ibuf=0x100240,.count=4,.itype=1}; zelda_inline_prepare_draw(plain,&indices); assert(copies==7 && !z_inline_count);
    nvn_rbind sampled[]={{.kind=NVN_RB_TEX,.reg=5}}; NvProg *textured=program_with(sampled,1);
    g_treg[1].t=(tex_t){.mem=(void *)0x100000,.L={.size=0x300}}; S.tex[0][5]=1;
    g_enc=@YES; second.bytes[0]^=1; assert(update(&second,96)==2); zelda_inline_prepare_draw(textured,NULL); assert(copies==8 && !z_inline_count);
    nvn_rbind storage[]={{.kind=NVN_RB_SBUFP,.reg=2}}; NvProg *stored=program_with(storage,1); S.ssbo[0][2]=(p_bind_buf){.addr=0x200200,.size=4};
    g_enc=@YES; second.bytes[0]^=1; assert(update(&second,96)==2); zelda_inline_prepare_draw(stored,NULL); assert(copies==9 && !z_inline_count);
    nvn_rbind image[]={{.kind=NVN_RB_IMG,.reg=0}}; NvProg *imaged=program_with(image,1);
    g_enc=@YES; second.bytes[0]^=1; assert(update(&second,96)==2); zelda_inline_prepare_draw(imaged,NULL); assert(copies==10 && !z_inline_count);
    R.rt=(p_set_rt){.n=1,.color={&target}}; target.mem=(void *)0x100200;
    g_enc=@YES; second.bytes[0]^=1; assert(update(&second,96)==2); zelda_inline_prepare_draw(plain,NULL); assert(copies==11 && !z_inline_count);
    R.rt=(p_set_rt){0};
    // A draw that reads none of the pending ranges leaves them deferred and binds no snapshot.
    g_enc=@YES; second.bytes[0]^=1; assert(update(&second,96)==2); zelda_inline_prepare_draw(plain,NULL);
    assert(copies==11 && z_inline_count==1 && !z_inline_overridden);
    // Deferral needs an open pass, no cube words in flight and a free slot.
    zelda_inline_flush(); assert(copies==12);
    g_enc=nil; second.bytes[0]^=1; assert(update(&second,96)==0 && copies==13);
    g_enc=@YES; z_uniform_pending_count=1; second.bytes[0]^=1; assert(update(&second,96)==0 && copies==14); z_uniform_pending_count=0;
    for(unsigned i=0;i<Z_INLINE_MAX;i++){second.bytes[1]=(uint8_t)i; g_enc=@YES; assert(update(&second,96)==2);}
    // A full queue writes the pending updates in order, then copies the new one.
    second.bytes[1]^=0xff; assert(update(&second,96)==0 && copies==15+Z_INLINE_MAX && !z_inline_count);
    assert(z_inline_deferred==3+8+Z_INLINE_MAX && z_inline_snapshots==2);
    zelda_inline_flush(); finish_blit();

    // Cave draws: the pointer itself changes in deferred uniforms, while the pointed-at mesh is untouched.
    pointer_uniform=[g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    pointer_geometry=[g_dev newBufferWithLength:65536 options:MTLResourceStorageModeShared];
    [residency addAllocation:pointer_uniform];[residency addAllocation:pointer_geometry];[residency commit];
    uint64_t geometry=(uintptr_t)pointer_geometry.contents;
    ((uint32_t *)pointer_geometry.contents)[16]=7;((uint32_t *)pointer_geometry.contents)[32]=13;
    *(uint64_t *)pointer_uniform.contents=geometry+192; // Deliberately stale CPU pointer; the update log must win.
    nvn_rbind pointed[]={{.kind=NVN_RB_CBUF,.reg=3},{.kind=ZELDA_RB_SBUF_CB,.reg=3}};
    NvProg *cave=program_with(pointed,2);S.ubo[0][3]=(p_bind_buf){.addr=(uintptr_t)pointer_uniform.contents,.size=16};
    Update pointer={.address=(uintptr_t)pointer_uniform.contents};
    id<MTLLibrary> pointer_library=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal; kernel void read_pointer(constant uint *u [[buffer(0)]],device uint *out [[buffer(1)]],const device uint *mesh [[buffer(2)]]){*out=u[2]+mesh[0];}" options:nil error:&error];
    assert(pointer_library);
    id<MTLComputePipelineState> pointer_pipeline=[g_dev newComputePipelineStateWithFunction:[pointer_library newFunctionWithName:@"read_pointer"] error:&error];assert(pointer_pipeline);
    for(unsigned i=0;i<2;i++) {
        uint64_t address=geometry+64+64*i;uint32_t value=5+i;
        memcpy(pointer.bytes,&address,8);memcpy(pointer.bytes+8,&value,4);
        g_enc=@YES;assert(update(&pointer,16)==2);unsigned before=copies;
        zelda_inline_prepare_draw(cave,NULL);
        assert(g_enc && copies==before && z_inline_count==i+1 && z_inline_override[0][3]);
        void *buffer;uint64_t gpu=zelda_pointer_storage(0,&pointed[1],"test",&buffer);
        assert(gpu==pointer_geometry.gpuAddress+64+64*i);
        [table setAddress:gpu atIndex:2];consume(pointer_pipeline,table,z_inline_override[0][3],5+i);
    }
    zelda_inline_flush();finish_blit();
    // A write through another mapping of the mesh must flush before the next draw reads it.
    Update mesh={.address=0x300080};uint32_t changed=31;memcpy(mesh.bytes,&changed,4);
    g_enc=@YES;assert(update(&mesh,4)==2);unsigned before=copies;
    zelda_inline_prepare_draw(cave,NULL);assert(!g_enc && !z_inline_count && copies==before+1);
    [table setAddress:pointer_geometry.gpuAddress+128 atIndex:2];consume(pointer_pipeline,table,pointer_uniform.gpuAddress,7);
    // Unknown pointer bounds retain the original write-first path.
    g_enc=@YES;pointer.bytes[8]^=1;assert(update(&pointer,16)==2);S.ubo[0][3].size=4;before=copies;
    zelda_inline_prepare_draw(cave,NULL);assert(!g_enc && !z_inline_count && copies==before+1);
    finish_blit();

    // Repeated large write -> overlapping small write -> readback in one encoder must preserve stream order.
    id<MTLBuffer> stress=[g_dev newBufferWithLength:65536 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> history=[g_dev newBufferWithLength:128 options:MTLResourceStorageModeShared];
    [residency addAllocation:stress]; [residency addAllocation:history]; [residency commit];
    id<MTLBuffer> staging; size_t large_offset=arena_alloc(65536,&staging), words=arena_alloc(128,&staging);
    memset((uint8_t *)staging.contents+large_offset,0xa5,65536);
    for(unsigned i=0;i<32;i++) ((uint32_t *)((uint8_t *)staging.contents+words))[i]=0x12340000+i;
    id<MTL4ComputeCommandEncoder> ordered=[command computeCommandEncoder];
    [ordered barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    for(unsigned i=0;i<32;i++) {
        enc_b_copy_buffer(ordered,staging,large_offset,stress,0,65536);
        enc_b_copy_buffer(ordered,staging,words+4*i,stress,0,4);
        enc_b_copy_buffer(ordered,stress,0,history,4*i,4);
    }
    [ordered barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [ordered endEncoding];

    id<MTLBuffer> readback=[g_dev newBufferWithLength:96 options:MTLResourceStorageModeShared];
    [residency addAllocation:readback];[residency commit];
    id<MTL4ComputeCommandEncoder> copy=[command computeCommandEncoder];
    [copy barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:MTL4VisibilityOptionDevice];
    [copy copyFromBuffer:memory sourceOffset:0x200 toBuffer:readback destinationOffset:0 size:96];[copy endEncoding];
    [command endCommandBuffer]; id<MTL4CommandBuffer> commands[]={command};
    dispatch_semaphore_t done=dispatch_semaphore_create(0); MTL4CommitOptions *options=[MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) { assert(!feedback.error); dispatch_semaphore_signal(done); }];
    [queue commit:commands count:1 options:options];
    assert(!dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC)));
    uint32_t expected[5]; const uint8_t *sources[]={second_at_draw,first.bytes,view.bytes,first.bytes,view.bytes};
    for(unsigned k=0;k<5;k++){
        unsigned words=k==2||k==4?12:24; uint32_t s=0;
        for(unsigned i=0;i<words;i++){uint32_t w; memcpy(&w,sources[k]+4*i,4); s=s*31+w;} expected[k]=s;
    }
    const uint32_t *results=output.contents;
    for(unsigned k=0;k<5;k++) {
        if(results[k]!=expected[k]) fprintf(stderr,"readback %u: got %08x expected %08x\n",k,results[k],expected[k]);
        assert(results[k]==expected[k]);
    }
    assert(results[5]==12 && results[6]==19 && results[7]==37);
    assert(!memcmp(readback.contents,second.bytes,96));
    for(unsigned i=0;i<32;i++) assert(((uint32_t *)history.contents)[i]==0x12340000+i);
    puts("Inline uniform deferral: snapshots, uniform-held pointers, alias conflicts, ordered write-back and limits passed");
} }
