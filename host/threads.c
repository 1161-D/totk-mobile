// Reuse the reference's pthread, mutex, condition-variable and address-arbiter implementation.
// Keeping it in this translation unit also lets event copies share its wait queues and refcounts.
#include "kernel.h"
#include "threads.h"
#include "timeline.h"
#define dm_thread_enter zelda_thread_enter
#include "hle_thread.c"
#undef dm_thread_enter
#include "mach_memory.h"
#include <setjmp.h>

static _Thread_local jmp_buf host_exit_context;
static _Thread_local bool has_host_exit_context;
extern void dm_thread_enter(uint64_t entry, uint64_t argument, uint64_t stack);
void zelda_thread_enter(uint64_t entry, uint64_t argument, uint64_t stack) {
    has_host_exit_context = true;
    if (!setjmp(host_exit_context)) {
        dm_thread_enter(entry, argument, stack);
        die("guest thread entry returned");
    }
    has_host_exit_context = false;
    // Publishing exit lets the game unmap its stack; pthread cleanup must already be on the host stack.
    thread_exit(cur());
}

uint32_t threads_init(void) {
    uint32_t handle = svc_thread_main_init();
    if (pthread_threadid_np(pthread_self(), &cur()->id)) abort();
    return handle;
}

bool threads_destroy(void) {
    pthread_mutex_lock(&G);
    for (thr_t *t = g_all; t; t = t->all) if (!t->exited && !pthread_equal(t->pt, pthread_self())) {
        // Process exit reclaims live guest threads and their address space together.
        pthread_mutex_unlock(&G); return false;
    }
    for (unsigned i = 1; i < MAX_H; i++) if (g_h[i].type == O_EVENT_R || g_h[i].type == O_EVENT_W) {
        event_t *e = g_h[i].obj; if (!--e->refs) free(e);
    }
    while (g_all) thr_free(g_all);
    memset(g_h, 0, sizeof g_h); g_wait = NULL;
    pthread_setspecific(g_keythr, NULL); pthread_key_delete(g_keythr);
    pthread_mutex_unlock(&G);
    return true;
}

bool kernel_event_create(uint32_t *write_handle, uint32_t *read_handle) {
    event_t *e = calloc(1, sizeof *e);
    if (!e) return false;
    pthread_mutex_lock(&G);
    unsigned free_handles = 0;
    for (unsigned i = 1; i < MAX_H; i++) free_handles += g_h[i].type == O_FREE;
    if (free_handles < 2) { pthread_mutex_unlock(&G); free(e); return false; }
    e->refs = 2; *write_handle = h_new(O_EVENT_W, e); *read_handle = h_new(O_EVENT_R, e);
    pthread_mutex_unlock(&G);
    return true;
}

uint32_t kernel_event_copy(uint32_t handle) {
    pthread_mutex_lock(&G);
    event_t *e = h_peek(handle, O_EVENT_R);
    uint32_t copy = 0;
    for (unsigned i = 1; e && i < MAX_H; i++) if (!g_h[i].type) {
        e->refs++; copy = h_new(O_EVENT_R, e); break;
    }
    pthread_mutex_unlock(&G);
    return copy;
}

static bool threads_svc_inner(unsigned number, uint64_t *r) {
    if (number == 0x0a && has_host_exit_context) longjmp(host_exit_context, 1);
    if (number == 0x0f || number == 0x10) {
        pthread_mutex_lock(&G);
        thr_t *t = number == 0x10 ? cur() : h_peek((uint32_t)r[0], O_THREAD);
        if (number == 0x10) {
            // The guest indexes per-core allocators by this value, so it must satisfy the affinity mask.
            r[0] = t->core >= 0 ? (unsigned)t->core : (unsigned)__builtin_ctzll(t->mask);
        } else if (!t) r[0] = R_BAD_HANDLE;
        else {
            int core = (int)r[1]; uint64_t mask = r[2];
            uint32_t result = 0;
            if (core == -2) { core = 0; mask = 1; } // Process default.
            else if (mask & ~7ull) result = 0xe201;
            else if (!mask) result = 0xe801;
            else if (core == -3) {
                core = t->core;
                if (core < 0 || !(mask & (1ull << core))) result = 0xe801;
            } else if (core < -1 || core > 2) result = 0xe201;
            else if (core >= 0 && !(mask & (1ull << core))) result = 0xe801;
            if (!result) { t->core = core; t->mask = mask; }
            r[0] = result;
        }
        pthread_mutex_unlock(&G);
        return true;
    }
    if (number == 0x08) {
        if ((r[1] & 3) || !kernel_access(r[1], 4, 5) || (r[3] & 15) || r[3] < 16 || !kernel_access(r[3] - 16, 16, 3)) {
            r[0] = 0xcc01; return true;
        }
        if ((int)r[4] < 28 || (int)r[4] > 59) { r[0] = 0xe001; return true; }
        int core = (int)r[5];
        if (core == -2) r[5] = 0;
        else if (core < 0 || core > 2) { r[0] = 0xe201; return true; }
    }
    if (number == 0x18) {
        int count = (int)r[2]; uint32_t handles[64]; mach_vm_size_t got = 0;
        if (count < 0 || count > 64) { r[0] = 0xca01; return true; }
        if (count && (mach_vm_read_overwrite(mach_task_self(), r[1], count * 4,
                (mach_vm_address_t)handles, &got) || got != (unsigned)count * 4)) {
            r[0] = 0xe601; return true;
        }
        pthread_mutex_lock(&G);
        int bad = 0;
        for (int i = 0; i < count; i++) sig_obj(handles[i], &bad);
        pthread_mutex_unlock(&G);
        if (bad || !pthread_getspecific(g_keythr)) { r[0] = R_BAD_HANDLE; return true; }
        // The reference consumes the array synchronously, including across its wait.
        r[1] = (uint64_t)handles;
        return svc_thread(number, r);
    }
    if (number == 0x16) {
        unsigned index = (uint32_t)r[0] - 0x1000;
        pthread_mutex_lock(&G);
        bool known = index > 0 && index < MAX_H && g_h[index].type != O_FREE;
        pthread_mutex_unlock(&G);
        if (!known) return false; // Service sessions use a separate handle range.
    }
    if (number == 0x25 || number == 0x0c || number == 0x0e || number == 0x0d) {
        pthread_mutex_lock(&G);
        uint32_t handle = (uint32_t)r[number == 0x0e ? 2 : number == 0x0d ? 0 : 1];
        thr_t *t = h_peek(handle, O_THREAD);
        if (t && number == 0x25 && !t->exited) pthread_threadid_np(t->pt, &t->id);
        bool handled = svc_thread(number, r);
        pthread_mutex_unlock(&G);
        return handled;
    }
    unsigned pointer_reg = number == 0x1a ? 1 : 0;
    if (number == 0x1a || number == 0x1b || number == 0x1c || number == 0x1d || number == 0x34 || number == 0x35) {
        if ((r[pointer_reg] & 3) || !kernel_access(r[pointer_reg], 4, 3) ||
            (number == 0x1c && ((r[1] & 3) || !kernel_access(r[1], 4, 3)))) {
            r[0] = 0xcc01; return true;
        }
        if ((number == 0x34 || number == 0x35) && r[1] > 2) { r[0] = 0xf001; return true; }
    }
    return svc_thread(number, r);
}

bool threads_svc(unsigned number, uint64_t *r) {
    // Blocking waits show which guest dependency holds a frame; owner handles identify lock holders.
    bool blocking = number == 0x0b || number == 0x18 || number == 0x1a || number == 0x1c || number == 0x34;
    uint64_t begin = blocking ? zelda_timeline_now() : 0;
    uint64_t kind = number | (number == 0x1a ? (uint64_t)(uint32_t)r[0] << 32 : 0), target = r[number == 0x1a || number == 0x1c ? 1 : 0];
    bool handled = threads_svc_inner(number, r);
    if (begin) {
        uint64_t end = zelda_timeline_now();
        if (end > begin + 50000) zelda_timeline_span(TL_SVC_WAIT, begin, end, kind, target);
    }
    return handled;
}
