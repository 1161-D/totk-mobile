// Native loading/startup probe; unsupported platform calls stop with exit 78.
#include "dm.h"
#include <signal.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include "relr.h"
#include "kernel.h"
#include "services.h"
#include "front.h"
#include "game_timing.h"
#include "settings.h"
#include "input_script.h"
#include <mach/mach.h>
#include "mach_memory.h"
#include <stdatomic.h>
#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include "hle.h"

HLE_FORCE("_ZN2nn2os14FlushDataCacheEPKvm", "macOS cache API replaces privileged CTR/DC instructions",
          void, host_flush_data_cache, const void *address, size_t size) {
    sys_dcache_flush((void *)address, size);
    atomic_thread_fence(memory_order_seq_cst);
}

struct dm_flags g_flag;
uint64_t g_t0_ns;
static _Atomic(const char *) phase = "load";
static const char *imports[4096];
static unsigned nimports;
extern uint64_t unimpl_stubs[];
extern void dm_gate(void);

uint64_t now_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}

void *hlecount_wrap(const char *kind, const char *name, void *fn) {
    (void)kind; (void)name;
    return fn;
}
void hlecount_seal(void) {}

uint64_t resolve_import(module_t *m, const char *name) {
    (void)m;
    for (unsigned i = 0; i < nimports; i++)
        if (!strcmp(imports[i], name)) return (uint64_t)&unimpl_stubs[i];
    if (nimports == 4096) die("too many unresolved imports");
    imports[nimports] = name;
    return (uint64_t)&unimpl_stubs[nimports++];
}

uint64_t unimpl_c(unsigned idx, uint64_t *regs) {
    (void)regs;
    fprintf(stderr, "BLOCKED phase=%s unresolved_import=%s\n", phase, imports[idx]);
    exit(78);
}
uint64_t guest_ns(void) { return now_ns(); }
int dm_detclock_enabled(void) { return 0; }
void dm_prof_add(int id, uint64_t ns, uint64_t bytes) { (void)id; (void)ns; (void)bytes; }

struct thread_environment { uint8_t tls[8192], tlr[0x200], thread[0x400], signal_stack[65536]; };
static pthread_key_t environment_key;
static pthread_once_t environment_once = PTHREAD_ONCE_INIT;
static void environment_free(void *p) {
    stack_t disable = {.ss_flags = SS_DISABLE}; sigaltstack(&disable, NULL); free(p);
}
static void environment_key_init(void) { if (pthread_key_create(&environment_key, environment_free)) abort(); }
static struct thread_environment *environment(void) {
    pthread_once(&environment_once, environment_key_init);
    struct thread_environment *env = pthread_getspecific(environment_key);
    if (!env) {
        env = calloc(1, sizeof *env);
        if (!env || pthread_setspecific(environment_key, env)) abort();
    }
    return env;
}
void crash_thread_init(void) {
    stack_t stack = {.ss_sp = environment()->signal_stack, .ss_size = 65536};
    if (sigaltstack(&stack, NULL)) abort();
}
void guest_thread_init(void) {
    struct thread_environment *env = environment();
    *(void **)(env->tlr + 0x1f8) = env->thread;
    pthread_setspecific(g_keygate, dm_gate); pthread_setspecific(g_key18, NULL);
    pthread_setspecific(g_keytls, env->tls); pthread_setspecific(g_keytlr, env->tlr);
}

static struct { uint64_t ret, orig; char kind[16]; int arg; } gates[1024];
static unsigned ngates;
static atomic_uint trace_index;
static atomic_uint_fast64_t trace[32];
static void caller_trace(uint64_t frame) {
    for (unsigned depth = 0; depth < 16 && frame && !(frame & 15); depth++) {
        uint64_t pair[2]; mach_vm_size_t count = 0;
        if (mach_vm_read_overwrite(mach_task_self(), frame, sizeof pair, (mach_vm_address_t)pair, &count) || count != sizeof pair) break;
        module_t *caller = module_of((void *)pair[1]);
        if (caller) dprintf(STDERR_FILENO, "CALLER module=%s offset=0x%llx\n", caller->name, pair[1] - (uint64_t)caller->base);
        else {
            // Saved return addresses in Apple system libraries may carry pointer authentication bits.
            uint64_t address = pair[1] & 0x0000ffffffffffffull; Dl_info host;
            if (dladdr((void *)address, &host)) dprintf(STDERR_FILENO, "CALLER host=%s offset=%llu\n",
                    host.dli_sname ?: "unknown", address - (uint64_t)host.dli_saddr);
        }
        if (pair[0] <= frame || pair[0] - frame > 0x100000) break;
        frame = pair[0];
    }
}
uint32_t thr_cur_handle(void);
void gate_register(uint64_t ret, const char *kind, int arg, uint64_t orig) {
    if (ngates == 1024) die("gate overflow");
    gates[ngates].ret = ret;
    gates[ngates].orig = orig;
    gates[ngates].arg = arg;
    strlcpy(gates[ngates++].kind, kind, 16);
}
uint64_t gate_dispatch(uint64_t ret, uint64_t *regs) {
    for (unsigned i = 0; i < ngates; i++) if (gates[i].ret == ret) {
        if (!strcmp(gates[i].kind, "svc")) {
            unsigned index = atomic_fetch_add(&trace_index, 1);
            atomic_store(&trace[index % 32], ((uint64_t)thr_cur_handle() << 32) | (unsigned)gates[i].arg);
        }
        if (!strcmp(gates[i].kind, "cntpct") || !strcmp(gates[i].kind, "cntvct")) {
            uint64_t ns = now_ns();
            return regs[gates[i].arg] = ns / 625 * 12 + ns % 625 * 12 / 625;
        }
        if (!strcmp(gates[i].kind, "svc") && kernel_svc(gates[i].arg, regs))
            return regs[0];
        if (!strcmp(gates[i].kind, "svc") && gates[i].arg == 0x16)
            return regs[0] = service_close((uint32_t)regs[0]) ? 0 : 0xe401;
        if (!strcmp(gates[i].kind, "svc") && gates[i].arg == 0x1f) {
            char name[12] = {0}; mach_vm_size_t count = 0; uint32_t handle;
            for (size_t p = 0; p < sizeof name; p++) {
                if (regs[1] > UINT64_MAX - p || mach_vm_read_overwrite(mach_task_self(), regs[1] + p, 1,
                        (mach_vm_address_t)&name[p], &count) || count != 1) return regs[0] = 0xe601;
                if (!name[p]) break;
            }
            if (!memchr(name, 0, sizeof name)) return regs[0] = 0xe601;
            if (service_connect(name, &handle)) {
                regs[1] = handle; return regs[0] = 0;
            }
            fprintf(stderr, "SERVICE BLOCKED: %s\n", service_blocker());
        }
        if (!strcmp(gates[i].kind, "svc") && gates[i].arg == 0x21) {
            uint32_t result;
            if (service_request((uint32_t)regs[0], pthread_getspecific(g_keytlr), 0x100, &result))
                return regs[0] = result;
            fprintf(stderr, "SERVICE BLOCKED: %s\n", service_blocker());
        }
        module_t *m = module_of((void *)ret);
        fprintf(stderr, "BLOCKED phase=%s module=%s offset=0x%llx %s=0x%x\n",
                phase, m ? m->name : "?", gates[i].orig, gates[i].kind, gates[i].arg);
        if (!strcmp(gates[i].kind, "svc") && gates[i].arg == 0x29)
            fprintf(stderr, "GetInfo type=%llu handle=0x%llx subtype=%llu\n", regs[1], regs[2], regs[3]);
        if (!strcmp(gates[i].kind, "svc") && (gates[i].arg == 2 || gates[i].arg == 3))
            fprintf(stderr, "Memory address=0x%llx size=0x%llx argument=0x%llx attribute=0x%llx\n", regs[0], regs[1], regs[2], regs[3]);
        caller_trace(regs[29]);
        exit(78);
    }
    die("unknown gate");
}

static void relocate_relr(module_t *m) {
    uint64_t table = 0, size = 0, stride = 0;
    for (const Elf64_Dyn *d = m->dyn; d->d_tag; d++) {
        if (d->d_tag == 36) table = d->d_un.d_ptr;
        if (d->d_tag == 35) size = d->d_un.d_val;
        if (d->d_tag == 37) stride = d->d_un.d_val;
    }
    if (!table && !size) return;
    if (stride != 8 || size % 8 || table > m->size || size > m->size - table)
        die("invalid DT_RELR in %s", m->name);
    size_t applied;
    if (!zelda_relr(m->base, m->data_off, m->key_page_off,
                    (const uint64_t *)(m->base + table), size / 8, &applied))
        die("invalid RELR target in %s", m->name);
    fprintf(stderr, "RELR %s relocations=%zu\n", m->name, applied);
}

static void fault(int signal, siginfo_t *info, void *context) {
    ucontext_t *uc = context;
    if ((signal == SIGBUS || signal == SIGSEGV) && kernel_graphics_fault(info->si_addr,
            (uc->uc_mcontext->__es.__esr >> 6) & 1, context)) return;
    uint64_t pc = uc->uc_mcontext->__ss.__pc;
    module_t *m = module_of((void *)pc);
    // This diagnostic path exits immediately; it never attempts to resume a guest fault.
    dprintf(STDERR_FILENO, "BLOCKED phase=%s signal=%d module=%s offset=0x%llx\n",
            phase, signal, m ? m->name : "host", m ? pc - (uint64_t)m->base : 0);
    dprintf(STDERR_FILENO, "FAULT address=%p write=%u host_pc=%p\n", info->si_addr, (uc->uc_mcontext->__es.__esr >> 6) & 1, (void *)pc);
    dprintf(STDERR_FILENO, "CONTEXT sp=0x%llx fp=0x%llx lr=0x%llx esr=0x%x\n",
            uc->uc_mcontext->__ss.__sp, uc->uc_mcontext->__ss.__fp, uc->uc_mcontext->__ss.__lr, uc->uc_mcontext->__es.__esr);
    for (unsigned i = 0; i < 29; i++) dprintf(STDERR_FILENO, "REGISTER x%u=0x%llx\n", i, uc->uc_mcontext->__ss.__x[i]);
    if (!m) {
        Dl_info host;
        if (dladdr((void *)pc, &host)) dprintf(STDERR_FILENO, "HOST symbol=%s offset=%llu\n", host.dli_sname ?: "unknown", pc - (uint64_t)host.dli_saddr);
    }
    caller_trace(uc->uc_mcontext->__ss.__fp);
    unsigned end = atomic_load(&trace_index), start = end > 16 ? end - 16 : 0;
    for (unsigned i = start; i < end; i++) {
        uint64_t step = atomic_load(&trace[i % 32]);
        dprintf(STDERR_FILENO, "RECENT thread=0x%x svc=0x%x\n", (uint32_t)(step >> 32), (uint32_t)step);
    }
    _exit(128 + signal);
}

static void call(const char *name) {
    void (*fn)(void) = guest_sym(name);
    if (!fn) { fprintf(stderr, "BLOCKED missing SDK entry: %s\n", name); exit(78); }
    phase = name;
    fprintf(stderr, "ENTER %s\n", name);
    fn();
    fprintf(stderr, "RETURN %s\n", name);
}

static void initialize_guest(void) {
    size_t image_bytes = 0;
    for (int i = 0; i < g_nmod; i++) image_bytes += g_mod[i].key_page_off;
    uint32_t main_handle = kernel_init(image_bytes);
    atexit(kernel_destroy);
    crash_thread_init();
    guest_thread_init();
    call("_init_libc0");
    void (*os_init)(uint64_t, uint64_t) = guest_sym("nnosInitialize");
    if (!os_init) { fprintf(stderr, "BLOCKED missing SDK entry: nnosInitialize\n"); exit(78); }
    phase = "nnosInitialize";
    fprintf(stderr, "ENTER nnosInitialize\n");
    os_init(main_handle, 0);
    fprintf(stderr, "RETURN nnosInitialize\n");
    call("_init_libc1");
    call("nninitInitializeSdkModule");
    call("nninitStartup");
    call("_init_libc2");
    phase = "module constructors";
    run_module_inits();
}

static unsigned run_timeout;
static void run_game(void) {
    alarm(run_timeout);
    void dm_gfx_shot_at(long frames, const char *path);
    input_script_start(dm_gfx_shot_at);
    initialize_guest();
    call("nnMain");
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3 || (argc == 3 && strcmp(argv[2], "--load-only"))) {
        fprintf(stderr, "usage: zelda_probe PATCHED_DIR [--load-only]\n");
        return 2;
    }
    struct rlimit core = {0, 0};
    setrlimit(RLIMIT_CORE, &core);
    struct sigaction sa = {.sa_sigaction = fault, .sa_flags = SA_SIGINFO | SA_ONSTACK};
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL); sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGALRM, &sa, NULL);
    crash_thread_init();
    const char *limit = getenv("ZELDA_TIMEOUT_SECONDS");
    unsigned seconds = 120;
    if (limit) {
        char *end; unsigned long value = strtoul(limit, &end, 10);
        if (!*limit || *end || value > 3600) { fprintf(stderr, "ZELDA_TIMEOUT_SECONDS must be 0..3600\n"); return 2; }
        seconds = (unsigned)value;
    }
    alarm(seconds);
    const char *names[] = {"main", "subsdk0", "sdk"};
    load_modules(argv[1], names, 3);
    for (int i = 0; i < g_nmod; i++) relocate_relr(&g_mod[i]);
    if (!zelda_timing_init(g_mod[0].base, g_mod[0].size, g_mod[0].key_page_off, g_mod[0].patch_off))
        die("invalid version-bound FPS timing; check ZELDA_TARGET_FPS and rebuild patched modules");
    // ZELDA_TARGET_FPS (tests and 120 FPS exploration) wins over the saved menu choice.
    if (!getenv("ZELDA_TARGET_FPS") && !zelda_set_target_fps(zelda_settings().target_fps)) die("invalid saved target FPS");
    zelda_present_metalfx(getenv("ZELDA_METALFX") ? atoi(getenv("ZELDA_METALFX")) : zelda_settings().metalfx);
    const char *render_scale = getenv("ZELDA_RENDER_SCALE");   // experiments: any factor 0.5..2
    if (render_scale && !zelda_set_render_scale((float)atof(render_scale))) die("ZELDA_RENDER_SCALE must be 0.5..2 with the patched module");
    if (!render_scale && !zelda_set_render_scale(zelda_render_scale_factor(zelda_settings().render))) LOG("RENDER scale unavailable without the patched module");
    fprintf(stderr, "TIMING target=%u movie=30 original_graphics=1\n", zelda_game_frame_rate());
    fprintf(stderr, "LOADED modules=%d unresolved_imports=%u gates=%u\n", g_nmod, nimports, ngates);
    for (unsigned i = 0; i < nimports; i++) fprintf(stderr, "UNRESOLVED %s\n", imports[i]);
    if (argc == 3) return 0;
    run_timeout = seconds;
    alarm(0); // The gameplay timeout and scripted keys begin after shader preparation.
    front_run(run_game);
    return 0;
}
