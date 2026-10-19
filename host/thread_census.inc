// ZELDA_THREAD_CPU=1: once a second, work/logs/threads.tsv gets the process's CPU and runnable-but-not-running time
// (cores' worth over the interval) and the busiest threads by name. It answers "is the CPU oversubscribed" from inside
// the process, where sample / ps cannot look at the game's threads.
#include <libproc.h>
#include <mach/mach_time.h>
#include <mach/mach.h>
static FILE *census_log;
static struct { uint64_t id, cpu_ns; } census_prev[512];
static unsigned census_prev_n;
static uint64_t census_runnable, census_cpu;
static double census_at;
static void thread_census_tick(void) {
    static int enabled = -1;
    if (enabled < 0) { const char *e = getenv("ZELDA_THREAD_CPU"); enabled = e && atoi(e); }
    if (!enabled) return;
    if (!census_log && !(census_log = fopen("work/logs/threads.tsv", "w"))) { enabled = 0; return; }
    double now = CACurrentMediaTime(), wall = census_at ? now - census_at : 0;
    struct rusage_info_v4 ru;
    uint64_t runnable = 0, cpu = 0;
    if (!proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&ru)) {
        mach_timebase_info_data_t tb; mach_timebase_info(&tb);
        runnable = ru.ri_runnable_time * tb.numer / tb.denom; cpu = (ru.ri_user_time + ru.ri_system_time) * tb.numer / tb.denom;
    }
    thread_act_array_t threads; mach_msg_type_number_t n = 0;
    if (task_threads(mach_task_self(), &threads, &n) != KERN_SUCCESS) return;
    struct { double share; char name[64]; int pri; } top[10] = {0};
    typeof(census_prev) next; unsigned next_n = 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_extended_info_data_t xi; mach_msg_type_number_t xc = THREAD_EXTENDED_INFO_COUNT;
        thread_identifier_info_data_t ii; mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT;
        if (thread_info(threads[i], THREAD_EXTENDED_INFO, (thread_info_t)&xi, &xc) == KERN_SUCCESS &&
            thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &ic) == KERN_SUCCESS) {
            uint64_t total = xi.pth_user_time + xi.pth_system_time, before = total;
            for (unsigned k = 0; k < census_prev_n; k++) if (census_prev[k].id == ii.thread_id) { before = census_prev[k].cpu_ns; break; }
            if (next_n < sizeof next / sizeof *next) next[next_n++] = (typeof(*next)){ii.thread_id, total};
            double share = wall > 0 ? (total - before) / 1e9 / wall : 0;
            for (int k = 0; k < 10; k++) if (share > top[k].share) {
                memmove(&top[k + 1], &top[k], (9 - k) * sizeof *top);
                top[k].share = share; top[k].pri = xi.pth_curpri;
                snprintf(top[k].name, sizeof top[k].name, "%s#%llu", xi.pth_name[0] ? xi.pth_name : "?", (unsigned long long)ii.thread_id % 100000);
                break;
            }
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, n * sizeof *threads);
    if (wall > 0) {
        fprintf(census_log, "%.3f\tcpu=%.2f\trunnable=%.2f\tthreads=%u", now, (cpu - census_cpu) / 1e9 / wall, (runnable - census_runnable) / 1e9 / wall, n);
        for (int k = 0; k < 10 && top[k].share > 0.02; k++) fprintf(census_log, "\t%s:%.2f@%d", top[k].name, top[k].share, top[k].pri);
        fputc('\n', census_log); fflush(census_log);
    }
    memcpy(census_prev, next, next_n * sizeof *next); census_prev_n = next_n;
    census_runnable = runnable; census_cpu = cpu; census_at = now;
}
