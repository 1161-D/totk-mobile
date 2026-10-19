// Sorted pool index: same answers as a scan of every pool, through additions, swap-removals and misses.
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#define MDIE(...) abort()
typedef struct { uint64_t lo, hi; } pool_ent;
static pool_ent *g_pools; static int g_npool, g_cap;
#include "../host/nvn_pool_index.inc"
static int scan(uint64_t addr, uint64_t len) {
    if (len > UINT64_MAX - addr) return -1;
    for (int i = 0; i < g_npool; i++) if (addr >= g_pools[i].lo && addr + len <= g_pools[i].hi) return i;
    return -1;
}
int main(void) {
    g_cap = 4096; g_pools = calloc((size_t)g_cap, sizeof *g_pools); assert(g_pools);
    srand(7);
    uint64_t next = 0x100000;
    for (int i = 0; i < 3000; i++) {  // adjacent 4 KiB-aligned pools in shuffled registration order, as on the guest heap
        uint64_t size = (uint64_t)(1 + rand() % 64) << 12;
        g_pools[g_npool++] = (pool_ent){next, next + size}; next += size + ((rand() % 3) << 12);
    }
    for (int i = g_npool - 1; i > 0; i--) { int j = rand() % (i + 1); pool_ent t = g_pools[i]; g_pools[i] = g_pools[j]; g_pools[j] = t; }
    z_pool_sorted_dirty = 1;
    for (int k = 0; k < 200000; k++) {
        uint64_t addr = 0xff000 + (uint64_t)rand() % (next - 0xf0000), len = (uint64_t)(rand() % 0x3000);
        assert(zelda_pool_find(addr, len) == scan(addr, len));
        if (k % 5000 == 0 && g_npool > 1) { int r = rand() % g_npool; g_pools[r] = g_pools[--g_npool]; z_pool_sorted_dirty = 1; }
    }
    // A pool nested inside another is still found (the scan fallback).
    g_pools[g_npool++] = (pool_ent){0x100, 0x10000}; g_pools[g_npool++] = (pool_ent){0x2000, 0x3000}; z_pool_sorted_dirty = 1;
    assert(zelda_pool_find(0x1000, 16) == g_npool - 2 && zelda_pool_find(0x2100, 16) >= 0 && zelda_pool_find(0x20000000000, 1) == -1);
    // The same cache bucket must not keep an enclosing pool across a nested pool's start.
    g_npool = 2; g_pools[0] = (pool_ent){0x100, 0x900}; g_pools[1] = (pool_ent){0x200, 0x300}; z_pool_sorted_dirty = 1;
    for (int k = 0; k < 100; k++) {
        assert(zelda_pool_find(0x180, 16) == 0);
        assert(zelda_pool_find(0x210, 16) == 1);
        assert(zelda_pool_find(0x210, 0x200) == 0); // Nested candidate too short: preserve scan fallback.
        assert(zelda_pool_find(0x500, 16) == 0);
        assert(zelda_pool_find(0x210, 16) == 1);
    }
    assert(zelda_pool_find(UINT64_MAX - 7, 16) == -1);
    assert(zelda_pool_find(0x900, 0) == 0 && zelda_pool_find(0x900, 1) == -1);
    // Pool removal swaps indices; additions/reallocations must invalidate every cached hint.
    g_pools[0] = g_pools[1]; g_npool = 1; z_pool_sorted_dirty = 1;
    assert(zelda_pool_find(0x210, 16) == 0 && zelda_pool_find(0x180, 16) == -1);
    g_pools = realloc(g_pools, 8192 * sizeof *g_pools); assert(g_pools); g_cap = 8192;
    g_pools[g_npool++] = (pool_ent){0x200, 0x900}; z_pool_sorted_dirty = 1;
    assert(zelda_pool_find(0x500, 16) == 1);
    g_npool = 0; z_pool_sorted_dirty = 1; assert(zelda_pool_find(0x210, 16) == -1);
    free(g_pools); free(z_pool_order);
    puts("Pool index: matches a full scan through additions, swap-removals, misses and nested ranges");
}
