#include "../host/performance.h"
#include "../host/nvn_present.h"
#include "../ios/performance_metrics.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <pthread.h>

static void *shader_worker(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < 1000; i++) {
        shader_status_note(SHADER_BUILD_BEGIN, 0);
        shader_status_note(SHADER_STEP, 0);
        shader_status_note(SHADER_BUILD_END, 0);
    }
    return NULL;
}

static int build_result(unsigned active, int *evaluations) {
    assert(shader_status_snapshot().active_builds == active);
    (*evaluations)++;
    return 42;
}

int main(void) {
    assert(shader_status_snapshot().phase == SHADER_IDLE);
    shader_status_note(SHADER_CHECKING, 0);
    assert(shader_status_snapshot().phase == SHADER_CHECKING);
    shader_status_note(SHADER_LIBRARIES, 4000);
    pthread_t workers[4];
    for (unsigned i = 0; i < 4; i++) assert(!pthread_create(&workers[i], NULL, shader_worker, NULL));
    for (unsigned i = 0; i < 4; i++) assert(!pthread_join(workers[i], NULL));
    ZeldaShaderStatus status = shader_status_snapshot();
    assert(status.phase == SHADER_LIBRARIES && status.completed == 4000 && status.total == 4000 && !status.active_builds);
    shader_status_note(SHADER_STEP, 0); assert(shader_status_snapshot().completed == 4000);
    shader_status_note(SHADER_PIPELINES, 0); shader_status_note(SHADER_STEP, 0);
    assert(shader_status_snapshot().phase == SHADER_PIPELINES && !shader_status_snapshot().completed);
    shader_status_note(SHADER_FINISHED, 0);
    int evaluations = 0;
    assert(ZELDA_SHADER_BUILD(build_result(1, &evaluations)) == 42);
    assert(ZELDA_SHADER_BUILD(ZELDA_SHADER_BUILD(build_result(2, &evaluations))) == 42);
    assert(evaluations == 2 && !shader_status_snapshot().active_builds);
    assert(ZELDA_SHADER_BUILD((void *)0) == NULL && !shader_status_snapshot().active_builds);
    shader_status_note(SHADER_BUILD_BEGIN, 0); shader_status_note(SHADER_FINISHED, 0);
    assert(shader_status_snapshot().phase == SHADER_IDLE && shader_status_snapshot().active_builds == 1);
    shader_status_note(SHADER_BUILD_END, 0); shader_status_note(SHADER_BUILD_END, 0);
    assert(!shader_status_snapshot().active_builds);
    ZeldaCPUUsage cpu = {0};
    assert(isnan(zelda_cpu_percent(&cpu, 10, 2, 8)));
    assert(zelda_cpu_percent(&cpu, 11, 3, 8) == 12.5);
    assert(zelda_cpu_percent(&cpu, 12, 7, 8) == 50);
    assert(zelda_cpu_percent(&cpu, 13, 15, 8) == 100);
    assert(isnan(zelda_cpu_percent(&cpu, 13, 15, 8)));
    assert(isnan(zelda_cpu_percent(&cpu, 12, 14, 8)));
    assert(isnan(zelda_cpu_percent(&cpu, 14, 1, 8)));
    assert(isnan(zelda_cpu_percent(&cpu, NAN, 1, 8)) && !cpu.valid);
    assert(isnan(zelda_cpu_percent(&cpu, 15, 1, 0)) && !cpu.valid);
    double deadline = 100;
    for (unsigned i = 1; i <= 60; i++) {
        deadline = zelda_present_deadline(deadline, 100 + i / 100.0, 1 / 60.0);
        assert(fabs(deadline - (100 + i / 60.0)) < 1e-8);
    }
    assert(zelda_present_deadline(deadline, 105, 1 / 60.0) == 105);
    ZeldaPerformance p;
    assert(!performance_snapshot(&p) && !p.samples);
    for (unsigned i = 0; i <= 120; i++)
        zelda_perf_present(i, 100 + i / 60.0, 7, i * 2000000ull, i * 100ull, i * 1048576ull, 100 + i / 60.0, 60, 1);
    assert(performance_snapshot(&p) && p.samples == 120 && p.frame == 120);
    assert(fabs(p.fps - 60) < 1e-6 && fabs(p.frame_p95_ms - 1000.0 / 60) < 1e-6);
    assert(p.gpu_ms == 7 && p.submit_cpu_ms == 2 && p.draws == 100 && p.upload_mb == 1);
    assert(p.pacing_fps == 60 && p.pacing_override);
    float interval[200], gpu[200];
    assert(performance_history(interval, gpu, 200) == 120 && fabsf(interval[0] - 1000.0f / 60) < 1e-3f && gpu[119] == 7);
    assert(!p.render_width); zelda_perf_render_size(1600, 896);
    assert(performance_snapshot(&p) && p.render_width == 1600 && p.render_height == 896);
    zelda_perf_present(121, -1, 8, 242000000, 12100, 121ull * 1048576, 102 + 1 / 60.0, 60, 1);
    zelda_perf_present(122, 102 + 2 / 60.0, 9, 244000000, 12200, 122ull * 1048576, 102 + 2 / 60.0, 60, 1);
    assert(performance_snapshot(&p) && p.dropped == 1 && p.fps < 60 && p.fps > 59);
    assert(performance_history(interval, gpu, 2) == 2 && gpu[0] == 8 && gpu[1] == 9); // oldest first
    assert(p.submit_cpu_ms == 2 && p.draws == 100 && p.upload_mb == 1 && fabs(p.render_fps - 60) < 1e-6);
    zelda_perf_present(123, NAN, 0, 0, 0, 0, NAN, 0, 0); zelda_perf_present(123, 100, 0, 0, 0, 0, 100, 0, 0);
    assert(performance_snapshot(&p) && p.frame == 122);
    for (unsigned i = 123; i <= 243; i++) zelda_perf_present(i, 103 + (i - 123) / 30.0, -1, 0, 0, 0, 103 + (i - 123) / 30.0, 30, 0);
    assert(performance_snapshot(&p) && p.samples == 120 && fabs(p.fps - 30) < 1e-6 && p.gpu_ms == -1);
    assert(p.pacing_fps == 30 && !p.pacing_override);
    for (unsigned i = 244; i <= 364; i++) zelda_perf_present(i, -1, 5, 0, 0, 0, 110 + (i - 244) / 60.0, 0, 1);
    assert(performance_snapshot(&p) && fabs(p.render_fps - 60) < 1e-6 && p.gpu_ms == 5 && fabs(p.fps - 30) < 1e-6);
    assert(!p.pacing_fps && p.pacing_override);
    uint64_t dropped = p.dropped;
    performance_reset_window();
    assert(!performance_snapshot(&p) && !p.samples && p.render_width == 1600 && p.dropped == dropped);
    assert(!performance_history(interval, gpu, 2));
    zelda_perf_present(400, 500, 7, 1000000000, 10000, 0, 500, 60, 0);
    zelda_perf_present(401, 500 + 1 / 60.0, 7, 1002000000, 10100, 1048576, 500 + 1 / 60.0, 60, 0);
    assert(performance_snapshot(&p) && p.samples == 1 && fabs(p.fps - 60) < 1e-6);
    assert(p.submit_cpu_ms == 2 && p.draws == 100 && p.upload_mb == 1);
    puts("Render/presentation timing and concurrent shader progress/build lifecycle checks passed");
}
