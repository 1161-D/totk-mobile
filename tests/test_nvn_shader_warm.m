// Exercise the production record reader/prewarmer and consume its derived pipelines in real GPU draws.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
#include "nvn_hmap.h"
@interface NvShader : NSObject { @public char key[24]; int stage; id<MTLFunction> fn; }
@end
@implementation NvShader @end
#include "nvn_pso_skey.h"
#include "../host/nvn_pso_key.h"
#include "../host/performance.h"

static id<MTLDevice> g_dev;
static NSString *g_msl_dir, *record_path;
static NSMutableDictionary<NSString *, NvShader *> *g_shcache;
static NSDictionary<NSString *, NvShader *> *fixture_shaders;
static _Atomic unsigned g_shcache_n;
static nvn_hmap g_pso = {.klen = sizeof(pso_key)}, g_cps = {.klen = sizeof(void *)};
static int z_warming;
#define MLOG(...) do { fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } while (0)
static id hm_get_id(nvn_hmap *map, const void *key) { return (__bridge id)nvn_hm_get(map, key); }
static void hm_put_id(nvn_hmap *map, const void *key, id object) {
    void *old = nvn_hm_put(map, key, (__bridge_retained void *)object); if (old) CFRelease(old);
}
static void release_object(void *object) { CFRelease(object); }
static uint64_t bp_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
static NSString *pso_user_path(void) { return record_path; }
static void shmap_load(void) {}
static void shader_ir_report(const char *phase) { (void)phase; }
static NSString *warm_key(const char *key, size_t size) { return [[NSString alloc] initWithBytes:key length:strnlen(key, size) encoding:NSUTF8StringEncoding]; }
static NvShader *shader_load(NSString *key, int stage) {
    assert(shader_status_snapshot().phase == SHADER_LIBRARIES && shader_status_snapshot().total);
    NvShader *shader = fixture_shaders[key]; assert(shader->stage == stage); return shader;
}
static NvShader *zelda_fetch_shader(NvShader *s, NSDictionary *m, NSString *i) { (void)s; (void)m; (void)i; return nil; }
static NSDictionary *zelda_fetch_reads(NvShader *s) { (void)s; return @{}; }
static NSSet *zelda_fetch_screen_outputs(NvShader *s) { (void)s; return [NSSet set]; }
static MTLRenderPipelineDescriptor *pso_desc(const pso_key *k, NvShader *vs, NvShader *fs, id<MTLFunction> fn, int merged) {
    assert(shader_status_snapshot().phase == SHADER_PIPELINES);
    assert(!merged && !fn);
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs->fn; d.fragmentFunction = fs->fn;
    for (unsigned i = 0; i < 8; i++) {
        d.colorAttachments[i].pixelFormat = k->cfmt[i];
        d.colorAttachments[i].writeMask = k->chmask >> (4 * i) & 15;
    }
    return d;
}
#include "../host/nvn_shader_warm.inc"

int main(void) { @autoreleasepool {
    g_dev = MTLCreateSystemDefaultDevice(); assert(g_dev);
    g_msl_dir = [@"work/tmp/shader-warm-" stringByAppendingString:NSUUID.UUID.UUIDString];
    assert([NSFileManager.defaultManager createDirectoryAtPath:g_msl_dir withIntermediateDirectories:NO attributes:nil error:nil]);
    record_path = [g_msl_dir stringByAppendingPathComponent:@"records.tsv"];
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vs(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
        "struct Output { float4 color [[color(1)]]; }; fragment Output fs() { return {float4(1,0,0,1)}; }\n";
    NSError *error = nil;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:source options:nil error:&error]; assert(library && !error);
    NvShader *vs = [NvShader new], *fs = [NvShader new];
    strcpy(vs->key, "1111111111111111_b"); strcpy(fs->key, "2222222222222222_b");
    vs->stage = 0; fs->stage = 1; vs->fn = [library newFunctionWithName:@"vs"]; fs->fn = [library newFunctionWithName:@"fs"];
    fixture_shaders = @{@(vs->key):vs, @(fs->key):fs};
    for (NSString *key in fixture_shaders)
        assert([[@"fixture" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[g_msl_dir stringByAppendingPathComponent:[key stringByAppendingString:@".metallib"]] atomically:YES]);
    pso_key base = {0}; base.cfmt[0] = base.cfmt[1] = base.cfmt[5] = MTLPixelFormatRGBA8Unorm; base.chmask = 15u << 4;
    pso_skey record; pso_skey_from(&base, vs, fs, 0, NULL, &record);
    char hex[sizeof record * 2 + 1]; pso_skey_hex(&record, hex);
    NSString *records = [NSString stringWithFormat:@"R\t%s\nR\t%s\nR\tmalformed\n", hex, hex];
    assert([records writeToFile:record_path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    zelda_shader_warm();
    assert(shader_status_snapshot().phase == SHADER_IDLE && !shader_status_snapshot().active_builds);
    bool expanded = !getenv("ZELDA_WARM_ATTACHMENT_VARIANTS") || atoi(getenv("ZELDA_WARM_ATTACHMENT_VARIANTS")) >= 2;
    assert(g_pso.n == (expanded ? 4u : 1u) && g_shcache_n == 2); // One observation yields three unseen layouts, no duplicates.
    zelda_shader_warm(); assert(g_pso.n == (expanded ? 4u : 1u));
    base.vs = (__bridge void *)vs; base.fs = (__bridge void *)fs;
    id<MTLCommandQueue> queue = [g_dev newCommandQueue];
    for (unsigned removed = 0; removed < (expanded ? 4u : 1u); removed++) {
        pso_key k = base;
        if (removed & 1) k.cfmt[0] = 0;
        if (removed & 2) k.cfmt[5] = 0;
        zelda_pso_normalize(&k, 0);
        id<MTLRenderPipelineState> pipeline = hm_get_id(&g_pso, &k); assert(pipeline);
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        for (unsigned i = 0; i < 8; i++) if (k.cfmt[i]) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:k.cfmt[i] width:4 height:4 mipmapped:NO];
            d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModeShared;
            pass.colorAttachments[i].texture = [g_dev newTextureWithDescriptor:d];
            pass.colorAttachments[i].loadAction = MTLLoadActionClear; pass.colorAttachments[i].storeAction = MTLStoreActionStore;
        }
        id<MTLCommandBuffer> command = [queue commandBuffer]; id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline]; [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted]; assert(!command.error);
        uint8_t pixels[64]; [pass.colorAttachments[1].texture getBytes:pixels bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
        for (unsigned i = 0; i < 64; i += 4) assert(pixels[i] == 255 && !pixels[i+1] && !pixels[i+2] && pixels[i+3] == 255);
    }
    nvn_hm_clear(&g_pso, release_object); free(g_pso.keys); free(g_pso.vals);
    assert([NSFileManager.defaultManager removeItemAtPath:g_msl_dir error:nil]);
    puts("Pipeline prewarm: observed/derived cache hits, duplicate records, malformed input and GPU pixels passed");
} }
