#include "performance.h"
#include <pthread.h>
#include <stdlib.h>
#include <math.h>

enum { WINDOW = 120 };
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct { double interval, gpu, cpu, draws, upload; } samples[WINDOW];
static double present_intervals[WINDOW];
static unsigned count, cursor, present_count, present_cursor;
static uint64_t last_frame, last_cpu, last_draws, last_upload, presented, dropped;
static double last_timestamp, last_rendered;
static double pacing_fps;
static int pacing_override;
static unsigned render_width, render_height;
static ZeldaShaderStatus shader_status;

void shader_status_note(unsigned event, unsigned total) {
    pthread_mutex_lock(&lock);
    switch (event) {
        case SHADER_CHECKING: case SHADER_LIBRARIES: case SHADER_PIPELINES:
            shader_status.phase = event; shader_status.completed = 0; shader_status.total = total; break;
        case SHADER_STEP:
            if (shader_status.completed < shader_status.total) shader_status.completed++; break;
        case SHADER_FINISHED:
            shader_status.phase = SHADER_IDLE; shader_status.completed = shader_status.total = 0; break;
        case SHADER_BUILD_BEGIN: shader_status.active_builds++; break;
        case SHADER_BUILD_END: if (shader_status.active_builds) shader_status.active_builds--; break;
    }
    pthread_mutex_unlock(&lock);
}

ZeldaShaderStatus shader_status_snapshot(void) {
    pthread_mutex_lock(&lock); ZeldaShaderStatus result = shader_status; pthread_mutex_unlock(&lock);
    return result;
}

void performance_reset_window(void) {
    pthread_mutex_lock(&lock);
    count = cursor = present_count = present_cursor = 0;
    last_timestamp = last_rendered = 0;
    pthread_mutex_unlock(&lock);
}

void zelda_perf_present(uint64_t frame, double timestamp, double gpu_ms, uint64_t cpu_ns, uint64_t draws, uint64_t uploaded, double rendered_at, double target, int forced) {
    pthread_mutex_lock(&lock);
    if (isfinite(timestamp) && timestamp < 0) dropped++;
    if (isfinite(timestamp) && timestamp > last_timestamp) {
        if (last_timestamp) {
            present_intervals[present_cursor] = (timestamp - last_timestamp) * 1000;
            present_cursor = (present_cursor + 1) % WINDOW; if (present_count < WINDOW) present_count++;
        }
        last_timestamp = timestamp; presented++;
    }
    if (isfinite(rendered_at) && rendered_at > last_rendered && (!last_rendered || frame > last_frame)) {
        pacing_fps = target; pacing_override = forced;
        if (last_rendered) {
            uint64_t elapsed = frame - last_frame;
            samples[cursor].interval = (rendered_at - last_rendered) * 1000 / elapsed;
            samples[cursor].gpu = gpu_ms >= 0 && isfinite(gpu_ms) ? gpu_ms : -1;
            samples[cursor].cpu = cpu_ns >= last_cpu ? (cpu_ns - last_cpu) / 1e6 / elapsed : 0;
            samples[cursor].draws = draws >= last_draws ? (double)(draws - last_draws) / elapsed : 0;
            samples[cursor].upload = uploaded >= last_upload ? (uploaded - last_upload) / 1048576.0 / elapsed : 0;
            cursor = (cursor + 1) % WINDOW; if (count < WINDOW) count++;
        }
        last_rendered = rendered_at; last_frame = frame; last_cpu = cpu_ns; last_draws = draws; last_upload = uploaded;
    }
    pthread_mutex_unlock(&lock);
}
static int compare(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return (x > y) - (x < y); }
bool performance_snapshot(ZeldaPerformance *out) {
    double intervals[WINDOW], actual[WINDOW], total = 0, present_total = 0, gpu = 0; unsigned gpu_count = 0;
    pthread_mutex_lock(&lock);
    *out = (ZeldaPerformance){.frame=last_frame,.presented=presented,.dropped=dropped,.samples=count,
        .last_presented=last_timestamp,.last_rendered=last_rendered,.fps=-1,.gpu_ms=-1,
        .pacing_fps=pacing_fps,.pacing_override=pacing_override,.render_width=render_width,.render_height=render_height};
    unsigned np = present_count;
    for (unsigned i = 0; i < np; i++) { actual[i] = present_intervals[i]; present_total += actual[i]; }
    for (unsigned i = 0; i < count; i++) {
        intervals[i] = samples[i].interval; total += intervals[i];
        if (samples[i].gpu >= 0) { gpu += samples[i].gpu; gpu_count++; }
        out->submit_cpu_ms += samples[i].cpu; out->draws += samples[i].draws; out->upload_mb += samples[i].upload;
    }
    pthread_mutex_unlock(&lock);
    if (!out->samples || total <= 0) return false;
    qsort(intervals, out->samples, sizeof(double), compare);
    out->render_fps = 1000 * out->samples / total; out->render_p95_ms = intervals[(out->samples - 1) * 95 / 100];
    if (np && present_total > 0) {
        qsort(actual, np, sizeof(double), compare);
        out->fps = 1000 * np / present_total; out->frame_p95_ms = actual[(np - 1) * 95 / 100];
    }
    out->gpu_ms = gpu_count ? gpu / gpu_count : -1;
    out->submit_cpu_ms /= out->samples; out->draws /= out->samples; out->upload_mb /= out->samples;
    return true;
}
void zelda_perf_render_size(unsigned width, unsigned height) {
    pthread_mutex_lock(&lock); render_width = width; render_height = height; pthread_mutex_unlock(&lock);
}
unsigned performance_history(float *interval_ms, float *gpu_ms, unsigned capacity) {
    pthread_mutex_lock(&lock);
    unsigned n = count < capacity ? count : capacity;
    for (unsigned i = 0; i < n; i++) {
        unsigned slot = (cursor + WINDOW - n + i) % WINDOW;
        interval_ms[i] = (float)samples[slot].interval; gpu_ms[i] = (float)samples[slot].gpu;
    }
    pthread_mutex_unlock(&lock);
    return n;
}
