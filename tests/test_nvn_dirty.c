// Zelda's dirty tracker: neighbouring pools that share a host page share its state.
#include "nvn_dirty.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static int (*fault_hook)(void *, int, void *);
static void (*write_hook)(void *, size_t);
void dm_fault_hook_register(int (*fn)(void *, int, void *)) { fault_hook = fn; }
void dm_guest_write_prep_register(void (*fn)(void *, size_t)) { write_hook = fn; }

int main(void) {
    size_t page = (size_t)getpagesize();
    uint8_t *memory = mmap(NULL, page * 4, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); assert(memory != MAP_FAILED);
    assert(!nvn_dirty_tracked(memory, 1) && nvn_dirty_since(memory, 1, 0));
    // Pool A ends 4 KiB into page 1 and pool B starts there, as Zelda's heap places small pools.
    uint8_t *a = memory + 0x1000, *b = memory + page + 0x1000;
    size_t a_size = page, b_size = page;
    nvn_dirty_add_range(a, a_size); nvn_dirty_add_range(b, b_size); assert(fault_hook && write_hook);
    assert(nvn_dirty_tracked(a, a_size) && nvn_dirty_tracked(b, b_size));
    assert(!nvn_dirty_tracked(memory + 3 * page, 1));
    nvn_dirty_protect(b, b_size); uint64_t stamp = nvn_dirty_now();
    assert(!nvn_dirty_since(b, b_size, stamp));
    // A write through pool A's part of the shared page is a write to B's texture data on that page.
    write_hook(a + a_size - 16, 16); a[a_size - 16] = 1;
    assert(nvn_dirty_since(b, b_size, stamp) && nvn_dirty_since(a, a_size, stamp));
    // A real fault on a protected page is claimed, marks it dirty and leaves it writable.
    nvn_dirty_protect(b, b_size); stamp = nvn_dirty_now();
    assert(fault_hook(b + b_size - 8, 1, NULL) && nvn_dirty_since(b, b_size, stamp));
    assert(!fault_hook(b + b_size - 8, 0, NULL) && !fault_hook(memory + 3 * page + 8, 1, NULL));
    b[b_size - 8] = 2;
    // Removing A keeps the shared page with B; removing B frees everything and leaves the memory writable.
    nvn_dirty_protect(b, b_size); nvn_dirty_remove_range(a);
    assert(!nvn_dirty_tracked(a, 1) && nvn_dirty_tracked(b, b_size));
    nvn_dirty_remove_range(b); assert(!nvn_dirty_tracked(b, 1));
    memset(memory, 3, page * 4);
    int live, peak, cap; nvn_dirty_stat(&live, &peak, &cap); assert(!live && peak == 2 && cap >= 2);
    assert(!munmap(memory, page * 4));
    puts("Dirty tracker: shared boundary pages, fault claims, neighbour removal and release passed");
}
