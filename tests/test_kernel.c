#include "../host/kernel.h"
#include "dm.h"
#include <assert.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <unistd.h>
#include <sys/mman.h>

module_t g_mod[MAX_MOD];
int g_nmod;
struct info { uint64_t base, size; uint32_t state, attr, perm, ipc, device, padding; };
static size_t prepared;
static int graphics_fault(void *address, int write, void *context) { return write && address == &prepared && context == &prepared; }
static void graphics_write(void *address, size_t length) { assert(address == &prepared); prepared += length; }
static void check_graphics_hooks(void) {
    assert(!kernel_graphics_fault(&prepared, 1, &prepared));
    dm_guest_write_prepare(&prepared, 1); assert(!prepared);
    dm_fault_hook_register(graphics_fault); dm_fault_hook_register(graphics_fault);
    dm_guest_write_prep_register(graphics_write);
    assert(!kernel_graphics_fault(&prepared, 0, &prepared));
    assert(!kernel_graphics_fault(NULL, 1, &prepared));
    assert(kernel_graphics_fault(&prepared, 1, &prepared));
    dm_guest_write_prepare(&prepared, 0); assert(!prepared);
    dm_guest_write_prepare(&prepared, 16); assert(prepared == 16);
}

static uint64_t get_info(unsigned type) {
    uint64_t r[31] = {0, type, 0xffff8001u, 0};
    assert(kernel_svc(0x29, r) && !r[0]);
    return r[1];
}
static struct info query(uint64_t address) {
    struct { struct info info; uint64_t canary; } out = {.canary = 0x12345678};
    uint64_t r[31] = {(uint64_t)&out, 0, address};
    assert(kernel_svc(6, r) && !r[0] && !r[1]);
    assert(out.canary == 0x12345678);
    assert(!(out.info.attr & ~17u) && !out.info.ipc && !out.info.device && !out.info.padding);
    return out.info;
}
static uint64_t map(unsigned number, uint64_t address, uint64_t size) {
    uint64_t r[31] = {address, size};
    assert(kernel_svc(number, r));
    return r[0];
}
static void *other_thread(void *unused) {
    (void)unused;
    uint64_t r[31] = {0, 0xffff8000u};
    assert(kernel_svc(0x25, r) && r[0] == 0xe401);
    return NULL;
}
static void *signal_event(void *arg) {
    uint64_t r[31] = {(uintptr_t)arg};
    assert(kernel_svc(0x11, r) && !r[0]);
    return NULL;
}
static void check_events(void) {
    uint32_t w, rd;
    assert(kernel_event_create(&w, &rd) && w != rd);
    uint32_t copy = kernel_event_copy(rd); assert(copy && copy != rd);
    uint64_t r[31] = {rd};
    assert(kernel_svc(0x11, r) && r[0] == 0xe401);
    r[0] = rd; assert(kernel_svc(0x17, r) && r[0] == 0xfa01);
    r[1] = (uint64_t)&rd; r[2] = 1; r[3] = 0;
    assert(kernel_svc(0x18, r) && r[0] == 0xea01);
    pthread_t writer; assert(!pthread_create(&writer, NULL, signal_event, (void *)(uintptr_t)w));
    r[1] = (uint64_t)&copy; r[2] = 1; r[3] = 1000000000;
    assert(kernel_svc(0x18, r) && !r[0] && !r[1]);
    assert(!pthread_join(writer, NULL));
    r[0] = rd; assert(kernel_svc(0x16, r) && !r[0]);
    r[0] = copy; assert(kernel_svc(0x17, r) && !r[0]);
    r[0] = copy; assert(kernel_svc(0x17, r) && r[0] == 0xfa01);
    r[1] = 1; r[2] = 1; r[3] = 0; assert(kernel_svc(0x18, r) && r[0] == 0xe601);
    r[2] = 65; assert(kernel_svc(0x18, r) && r[0] == 0xca01);
    r[0] = w; assert(kernel_svc(0x16, r) && !r[0]);
    r[0] = copy; assert(kernel_svc(0x16, r) && !r[0]);
    assert(!kernel_event_copy(copy));
}
static void check_readonly(void) {
    uint8_t large[0x5000] = {17}; large[sizeof large - 1] = 91;
    uint32_t multi = kernel_readonly_memory(large, sizeof large); assert(multi);
    assert(!kernel_readonly_memory(large, sizeof large - 1));
    uint64_t mapped = get_info(12) + 0x10000;
    uint64_t map_regs[31] = {multi, mapped, sizeof large, 1};
    assert(kernel_svc(0x13, map_regs) && !map_regs[0]);
    assert(*(uint8_t *)mapped == 17 && *(uint8_t *)(mapped + sizeof large - 1) == 91);
    assert(query(mapped + sizeof large - 1).state == 6);
    map_regs[0] = multi; assert(kernel_svc(0x14, map_regs) && !map_regs[0]);
    assert(query(mapped).state == 0 && query(mapped + sizeof large - 1).state == 0);
    map_regs[0] = multi; assert(kernel_svc(0x16, map_regs) && !map_regs[0]);
    uint8_t data[0x1000] = {42}; uint32_t h = kernel_readonly_page(data); assert(h);
    uint64_t base = get_info(12) + 0x4000, a = base + 0x1000, b = base + 0x2000;
    uint64_t r[31] = {h, a, 0x1000, 3}; assert(kernel_svc(0x13, r) && r[0] == 0xd801);
    r[0] = h; r[3] = 1; assert(kernel_svc(0x13, r) && !r[0]);
    assert(*(uint8_t *)a == 42 && query(a).state == 6 && query(a).perm == 1);
    uint8_t bad = 7; assert(mach_vm_write(mach_task_self(), a, (vm_offset_t)&bad, 1) != KERN_SUCCESS);
    r[0] = h; assert(kernel_svc(0x13, r) && r[0] == 0xd401);
    r[0] = h; r[1] = b; assert(kernel_svc(0x13, r) && !r[0]);
    r[0] = h; r[1] = a; assert(kernel_svc(0x14, r) && !r[0]);
    assert(*(uint8_t *)b == 42 && !query(a).state && query(b).perm == 1);
    r[0] = h; r[1] = b; assert(kernel_svc(0x14, r) && !r[0]);
    mach_vm_size_t got = 0; assert(mach_vm_read_overwrite(mach_task_self(), b, 1, (mach_vm_address_t)&bad, &got) != KERN_SUCCESS);
    uint64_t alias = get_info(2);
    assert(!map(0x2c, alias, 0x1000));
    r[0] = h; r[1] = alias + 0x1000; assert(kernel_svc(0x13, r) && r[0] == 0xd401);
    assert(!map(0x2d, alias, 0x1000));
    r[0] = h; r[1] = alias; assert(kernel_svc(0x13, r) && !r[0]);
    assert(map(0x2c, alias + 0x1000, 0x1000) == 0xd401);
    r[0] = h; r[1] = alias; assert(kernel_svc(0x14, r) && !r[0]);
    r[0] = h; assert(kernel_svc(0x16, r) && !r[0]);
    r[0] = h; r[1] = a; assert(kernel_svc(0x13, r) && r[0] == 0xe401);
}
static void check_heap(void) {
    uint64_t alias = get_info(2), alias_size = get_info(3), stack_base = get_info(14);
    // Zelda's SDK keeps the first ~1 GiB for VAMM metadata before allocating user regions.
    assert(alias_size > 0x40000000 && alias + alias_size <= stack_base);
    assert(stack_base + get_info(15) <= get_info(4));
    assert(!map(0x2c, alias + 0x40000000, 0x1000));
    *(uint64_t *)(alias + 0x40000000) = 7;
    assert(query(alias + 0x40000000).state == 5);
    assert(!map(0x2d, alias + 0x40000000, 0x1000));
    uint64_t initial = get_info(22), base = get_info(4), r[31] = {0, 1};
    assert(kernel_svc(1, r) && r[0] == 0xca01);
    r[1] = get_info(5) + 0x200000; assert(kernel_svc(1, r) && r[0] == 0xca01);
    r[1] = get_info(5); assert(kernel_svc(1, r) && r[0] == 0x10801);
    r[1] = 0x400000; assert(kernel_svc(1, r) && !r[0] && r[1] == base);
    assert(query(base).state == 5 && query(base).perm == 3 && query(base).size == 0x400000);
    assert(get_info(22) == initial + 0x400000);
    r[1] = base + 0x300000; r[2] = 0x1000; r[3] = 0;
    assert(kernel_svc(0x15, r) && !r[0]); uint32_t transfer = (uint32_t)r[1];
    uint64_t ta, ts; assert(kernel_transfer_memory(transfer, &ta, &ts) && ta == base + 0x300000 && ts == 0x1000);
    assert(query(ta).attr == 1 && !kernel_access(ta, ts, 1));
    assert(!kernel_access(ta - 0x1000, 0x2000, 1));
    r[1] = 0x200000; assert(kernel_svc(1, r) && r[0] == 0xd401);
    r[0] = transfer; assert(kernel_svc(0x16, r) && !r[0]);
    assert(!kernel_transfer_memory(transfer, &ta, &ts) && query(base + 0x300000).perm == 3);
    *(uint64_t *)base = 42; *(uint64_t *)(base + 0x200000) = 99;
    r[1] = 0x400000; assert(kernel_svc(1, r) && !r[0] && *(uint64_t *)base == 42);
    uint64_t stack = get_info(14);
    r[0] = stack; r[1] = base + 0x200000; r[2] = 0x1000; assert(kernel_svc(4, r) && !r[0]);
    r[1] = 0x200000; assert(kernel_svc(1, r) && r[0] == 0xd401);
    r[0] = stack; r[1] = base + 0x200000; r[2] = 0x1000; assert(kernel_svc(5, r) && !r[0]);
    r[1] = 0x200000; assert(kernel_svc(1, r) && !r[0] && !query(base + 0x200000).state);
    r[1] = 0x400000; assert(kernel_svc(1, r) && !r[0] && *(uint64_t *)(base + 0x200000) == 0);
    assert(*(uint64_t *)base == 42);
    r[1] = 0; assert(kernel_svc(1, r) && !r[0] && get_info(22) == initial && !query(base).state);
}
static void check_module_permissions(void) {
    uint8_t *base = mmap(NULL, 0x20000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(base != MAP_FAILED);
    g_mod[g_nmod++] = (module_t){.base = base, .size = 0x20000, .text_end = 0x4000,
        .key_page_off = 0x18000, .key_page_size = 0x4000, .patch_off = 0x1c000};
    uint64_t address = (uint64_t)base + 0x5000, r[31] = {address, 0x12000, 1};
    assert(kernel_svc(2, r) && !r[0]);
    assert(query(address).perm == 1 && query(address - 1).perm == 3);
    uint8_t byte = 42;
    assert(mach_vm_write(mach_task_self(), (uint64_t)base + 0x8000, (vm_offset_t)&byte, 1) != KERN_SUCCESS);
    assert(mach_vm_write(mach_task_self(), (uint64_t)base + 0x4000, (vm_offset_t)&byte, 1) == KERN_SUCCESS);
    r[0] = address + 0x4000; r[1] = 0x1000; r[2] = 3; assert(kernel_svc(2, r) && !r[0]);
    assert(query(address + 0x4000).perm == 3 && query(address + 0x5000).perm == 1);
    r[0] = address; r[1] = 0x12000; r[2] = 1; assert(kernel_svc(2, r) && !r[0]);
    assert(query(address + 0x4000).perm == 1);
    r[0] = address; r[2] = 2; assert(kernel_svc(2, r) && r[0] == 0xd801);
    r[0] = address + 1; r[2] = 1; assert(kernel_svc(2, r) && r[0] == 0xcc01);
    r[0] = address; r[2] = 16; r[3] = 0; assert(kernel_svc(3, r) && r[0] == 0xe801);
    r[0] = address; r[3] = 16; assert(kernel_svc(3, r) && !r[0]);
    assert(query(address).perm == 1 && query(address).attr == 16);
    r[0] = address; assert(kernel_svc(3, r) && !r[0]);
    r[0] = address; r[2] = 3; assert(kernel_svc(2, r) && r[0] == 0xd401);
    g_nmod--; assert(!munmap(base, 0x20000));
}
int main(void) {
    // Unsorted module fixtures check that free-range bounds do not depend on load order.
    g_nmod = 2;
    for (int i = 0; i < g_nmod; i++) {
        g_mod[i] = (module_t){.base = (uint8_t *)(0x200000000ull - i * 0x100000000ull),
            .size = 0x10000, .text_end = 0x4000, .key_page_off = 0x8000,
            .key_page_size = 0x4000, .patch_off = 0xc000};
    }
    uint32_t main_handle = kernel_init(0x20000);
    uint64_t exception_context = get_info(20);
    assert(!(exception_context & 0xfff) && query(exception_context).state == 12 && query(exception_context).perm == 3);
    assert(!*(uint64_t *)exception_context); *(uint64_t *)exception_context = 123;
    assert(get_info(20) == exception_context && *(uint64_t *)get_info(20) == 123);
    uint64_t r[31] = {0};
    assert(kernel_svc(0x08, r) && r[0] == 0xcc01); // Invalid code/stack pointers cannot create a thread.
    r[1] = 999; assert(!kernel_svc(0x29, r));
    for (unsigned index = 0; index < 4; index++) {
        r[1] = 11; r[2] = 0; r[3] = index;
        assert(kernel_svc(0x29, r) && !r[0]);
        uint64_t entropy = r[1];
        r[1] = 11;
        assert(kernel_svc(0x29, r) && !r[0] && r[1] == entropy);
    }
    r[1] = 11; r[2] = 0; r[3] = 4;
    assert(kernel_svc(0x29, r) && r[0] == 0xe801);
    r[1] = 11; r[2] = main_handle; r[3] = 0;
    assert(kernel_svc(0x29, r) && r[0] == 0xe401);
    r[1] = 4; r[2] = 0xffff8001u; r[3] = 1;
    assert(kernel_svc(0x29, r) && r[0] == 0xe801);
    r[1] = 4; r[2] = main_handle; r[3] = 0;
    assert(kernel_svc(0x29, r) && r[0] == 0xe401);
    r[1] = main_handle; assert(kernel_svc(0x0c, r) && !r[0] && r[1] == 44);
    r[1] = main_handle; assert(kernel_svc(0x25, r) && !r[0]);
    uint64_t thread_id; assert(!pthread_threadid_np(pthread_self(), &thread_id) && thread_id == r[1]);
    r[2] = main_handle; assert(kernel_svc(0x0e, r) && !r[0] && !r[1] && r[2] == 7);
    // DontCare (-1) preserves the mask; it does not mean virtual CPU zero.
    for (unsigned cpu = 0; cpu < 3; cpu++) {
        r[0] = main_handle; r[1] = (uint32_t)-1; r[2] = 1u << cpu;
        assert(kernel_svc(0x0f, r) && !r[0]);
        assert(kernel_svc(0x10, r) && r[0] == cpu);
        r[2] = main_handle; assert(kernel_svc(0x0e, r) && !r[0] && r[1] == UINT32_MAX && r[2] == (1u << cpu));
    }
    const struct { int core; uint64_t mask; uint32_t error; } bad_cores[] = {
        {3, 7, 0xe201}, {-4, 7, 0xe201}, {-1, 8, 0xe201}, {-1, 0, 0xe801}, {0, 2, 0xe801}, {-3, 4, 0xe801},
    };
    for (unsigned i = 0; i < sizeof bad_cores / sizeof *bad_cores; i++) {
        r[0] = main_handle; r[1] = (uint32_t)bad_cores[i].core; r[2] = bad_cores[i].mask;
        assert(kernel_svc(0x0f, r) && r[0] == bad_cores[i].error);
        assert(kernel_svc(0x10, r) && r[0] == 2);
    }
    r[0] = main_handle; r[1] = 1; r[2] = 6; assert(kernel_svc(0x0f, r) && !r[0]);
    r[0] = main_handle; r[1] = (uint32_t)-3; r[2] = 2; assert(kernel_svc(0x0f, r) && !r[0]);
    assert(kernel_svc(0x10, r) && r[0] == 1);
    r[0] = main_handle; r[1] = (uint32_t)-2; r[2] = 8; assert(kernel_svc(0x0f, r) && !r[0]);
    r[2] = main_handle; assert(kernel_svc(0x0e, r) && !r[0] && !r[1] && r[2] == 1);
    r[0] = main_handle; r[1] = 0; r[2] = 7; assert(kernel_svc(0x0f, r) && !r[0]);
    pthread_t other; assert(!pthread_create(&other, NULL, other_thread, NULL));
    assert(!pthread_join(other, NULL));
    check_events();
    check_readonly();
    check_heap();
    struct info m = query((uint64_t)&r);
    assert(m.state == 11 && m.perm == 3 && m.size == pthread_get_stacksize_np(pthread_self()));
    m = query(0); assert(m.state == 0 && m.base == 0 && m.size == 0x100000000);
    m = query(0x100000004); assert(m.state == 3 && m.perm == 5 && m.size == 0x4000);
    m = query(0x100004000); assert(m.state == 4 && m.perm == 3 && m.size == 0x4000);
    m = query(0x100008000); assert(m.state == 4 && m.perm == 1);
    m = query(0x10000c000); assert(m.state == 3 && m.perm == 5);
    m = query(1ull << 39); assert(m.state == 16 && m.base == 1ull << 39);
    r[0] = 0; r[2] = (uint64_t)&r; assert(kernel_svc(6, r) && r[0] == 0xe601);
    uint64_t alias = get_info(2), initial = get_info(22);
    assert(get_info(7) == initial + get_info(16));
    assert(get_info(6) == get_info(21) + get_info(16));
    assert(get_info(28) == 0 && get_info(0) == 7);
    assert(get_info(1) == (1ull << 60) - (1ull << 28));
    uint64_t a = alias + 0x1000, b = alias + 0x2000;
    assert(!map(0x2c, a, 0x1000)); *(uint64_t *)a = 0xaabbccdd;
    assert(!map(0x2c, b, 0x1000)); *(uint64_t *)b = 0x11223344;
    assert(!map(0x2c, a, 0x2000)); // Repeated maps preserve both data and the memory charge.
    assert(*(uint64_t *)a == 0xaabbccdd && *(uint64_t *)b == 0x11223344);
    assert(get_info(22) == initial + 0x2000);
    m = query(a); assert(m.base == a && m.size == 0x2000 && m.state == 5 && m.perm == 3);
    assert(!map(0x2d, a, 0x1000));
    assert(query(a).state == 0 && query(b).state == 5 && *(uint64_t *)b == 0x11223344);
    uint64_t c = b + 0x4000;
    assert(!map(0x2c, c, 0x1000));
    m = query(b + 0x1000);
    assert(m.state == 0 && m.base == b + 0x1000 && m.size == 0x3000);
    assert(kernel_access(b, 0x1000, 3) && !kernel_access(b, 0x1001, 3));
    assert(kernel_access(c, 0x1000, 3) && !kernel_access(c - 4, 8, 3));
    assert(!map(0x2d, c, 0x1000));
    assert(!map(0x2c, a, 0x1000) && *(uint64_t *)a == 0);
    assert(*(uint64_t *)b == 0x11223344);
    uint64_t stack = get_info(14) + 0x1000;
    r[0] = stack; r[1] = a; r[2] = 0x1000;
    assert(kernel_svc(4, r) && !r[0] && *(uint64_t *)stack == 0);
    assert(query(stack).state == 11 && query(a).perm == 0 && query(a).attr == 1);
    *(uint64_t *)stack = 42;
    assert(map(0x2d, a, 0x1000) == 0xd401);
    r[0] = stack; r[1] = a; r[2] = 0x1000; assert(kernel_svc(4, r) && r[0] == 0xd401);
    r[0] = stack; r[1] = b; r[2] = 0x1000; assert(kernel_svc(5, r) && r[0] == 0xd401);
    r[0] = stack; r[1] = a; r[2] = 0x1000; assert(kernel_svc(5, r) && !r[0]);
    assert(*(uint64_t *)a == 42 && query(a).perm == 3 && !query(a).attr && !query(stack).state);
    assert(map(0x2c, a + 1, 0x1000) == 0xcc01);
    assert(map(0x2c, a, 0) == 0xca01);
    assert(map(0x2c, alias + get_info(3), 0x1000) == 0xdc01);
    assert(map(0x2c, UINT64_MAX - 0xfff, 0x1000) == 0xdc01);
    assert(map(0x2c, alias, UINT64_MAX - 0xfff) == 0xdc01);
    assert(!map(0x2d, alias, getpagesize()));
    assert(!map(0x2d, alias, getpagesize()));
    assert(get_info(22) == initial);
    uint64_t data; mach_vm_size_t read = 0;
    assert(mach_vm_read_overwrite(mach_task_self(), a, sizeof data, (mach_vm_address_t)&data, &read) != KERN_SUCCESS);
    check_module_permissions();
    kernel_destroy();
    kernel_init(0xcd500000ull - 0x1800000 - pthread_get_stacksize_np(pthread_self()));
    assert(map(0x2c, get_info(2), 0x1000) == 0x10801);
    kernel_destroy();
    check_graphics_hooks();
    puts("kernel checks passed");
}
