#include "../host/kernel.h"
#include "dm.h"
#include <assert.h>
#include <stdatomic.h>
#include <sched.h>
#include <unistd.h>

module_t g_mod[MAX_MOD];
int g_nmod;
uint32_t thr_cur_handle(void);
struct shared { _Atomic uint32_t mutex, key; atomic_int ran, cleaned; uint32_t event, core; bool cancel; uint64_t stack; };
static pthread_key_t cleanup_key;
static uintptr_t stack_pointer(void) { uintptr_t sp; __asm__("mov %0, sp" : "=r"(sp)); return sp; }
static void cleanup(void *p) {
    struct shared *s = p;
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    assert(stack_pointer() < top && stack_pointer() >= top - pthread_get_stacksize_np(pthread_self()));
    assert(stack_pointer() < s->stack || stack_pointer() >= s->stack + 0x10000);
    atomic_store(&s->cleaned, 1);
}

static void worker(uint64_t argument) {
    struct shared *s = (void *)argument;
    assert(stack_pointer() >= s->stack && stack_pointer() < s->stack + 0x10000);
    assert(!pthread_setspecific(cleanup_key, s));
    uint32_t me = thr_cur_handle(); assert(me);
    uint64_t r[31] = {0, 0xffff8000u};
    assert(kernel_svc(0x25, r) && !r[0]);
    uint64_t actual; assert(!pthread_threadid_np(pthread_self(), &actual) && r[1] == actual);
    assert(kernel_svc(0x10, r) && r[0] == s->core);
    atomic_store(&s->ran, 1);
    if (s->cancel) {
        r[1] = (uint64_t)&s->event; r[2] = 1; r[3] = UINT64_MAX;
        assert(kernel_svc(0x18, r) && r[0] == 0xec01);
    } else {
        r[0] = (uint64_t)&s->mutex; r[1] = (uint64_t)&s->key; r[2] = me; r[3] = 2000000000;
        assert(kernel_svc(0x1c, r) && !r[0]);
        assert(atomic_load(&s->mutex) == me && !atomic_load(&s->key));
        r[0] = (uint64_t)&s->mutex; assert(kernel_svc(0x1b, r) && !r[0]);
    }
    kernel_svc(0x0a, r); abort();
}

static uint64_t info(unsigned type) {
    uint64_t r[31] = {0, type, 0xffff8001u};
    assert(kernel_svc(0x29, r) && !r[0]); return r[1];
}

int main(void) {
    alarm(10);
    assert(!pthread_key_create(&cleanup_key, cleanup));
    uintptr_t code = (uintptr_t)worker & ~(uintptr_t)0xffff;
    g_nmod = 1; g_mod[0] = (module_t){.base = (void *)code, .size = 0x10000,
        .text_end = 0x10000, .key_page_off = 0x10000, .patch_off = 0x10000};
    uint32_t main_handle = kernel_init(0x10000);
    uint64_t source = info(2), stack = info(14), r[31] = {source, 0x10000};
    assert(kernel_svc(0x2c, r) && !r[0]);
    uint32_t w, rd; assert(kernel_event_create(&w, &rd));
    for (unsigned iteration = 0; iteration < 24; iteration++) {
        r[0] = stack; r[1] = source; r[2] = 0x10000; assert(kernel_svc(4, r) && !r[0]);
        struct shared s = {.event = rd, .core = iteration % 3, .cancel = iteration % 2 != 0, .stack = stack};
        r[1] = (uint64_t)worker; r[2] = (uint64_t)&s; r[3] = stack + 0x10000; r[4] = 44; r[5] = 0;
        assert(kernel_svc(8, r) && !r[0]); uint32_t child = r[1];
        r[0] = child; r[1] = (uint32_t)-1; r[2] = 1u << s.core;
        assert(kernel_svc(0x0f, r) && !r[0]);
        assert(!atomic_load(&s.ran));
        atomic_store(&s.mutex, child);
        r[0] = child; assert(kernel_svc(9, r) && !r[0]);
        if (s.cancel) {
            // Cancellation before or during the wait must be consumed by that wait.
            r[0] = child; assert(kernel_svc(0x19, r) && !r[0]);
        } else {
            while (!atomic_load(&s.key)) sched_yield();
            uint32_t expected = 0;
            while (!atomic_compare_exchange_weak(&s.mutex, &expected, main_handle)) { expected = 0; sched_yield(); }
            r[0] = (uint64_t)&s.key; r[1] = 1; assert(kernel_svc(0x1d, r) && !r[0]);
            r[0] = (uint64_t)&s.mutex; assert(kernel_svc(0x1b, r) && !r[0]);
        }
        r[1] = (uint64_t)&child; r[2] = 1; r[3] = 2000000000;
        assert(kernel_svc(0x18, r) && !r[0] && !r[1] && atomic_load(&s.ran));
        r[0] = stack; r[1] = source; r[2] = 0x10000; assert(kernel_svc(5, r) && !r[0]);
        while (!atomic_load(&s.cleaned)) sched_yield();
        r[0] = child; assert(kernel_svc(0x16, r) && !r[0]);
    }
    r[0] = rd; assert(kernel_svc(0x16, r) && !r[0]);
    r[0] = w; assert(kernel_svc(0x16, r) && !r[0]);
    kernel_destroy();
    assert(!pthread_key_delete(cleanup_key));
    puts("thread exit after guest stack unmap, cancellation and condition-variable handoff checks passed");
}
