#include "../host/kernel.h"
#include "dm.h"
#include <assert.h>
#include "../host/input.h"
#include "../host/input_script.h"
#include "../host/timeline.h"
#include <stdio.h>
#include "dm_padmap.h"
#include <math.h>

module_t g_mod[MAX_MOD];
int g_nmod;
uint32_t front_vsync_handle(void);
// The performance panel's sound switch lives in audio.c, which this host-only test does not link.
static bool test_muted;
void audio_mute(bool muted) { test_muted = muted; }
bool audio_muted(void) { return test_muted; }

int main(void) {
    ZeldaPadState pad;
    input_key(7, 1); input_key(7, 0); // A short tap must reach one guest sample.
    assert(input_states(&pad, 1, 0, 1) == 1 && pad.buttons == 1 && pad.attributes == 3);
    assert(input_states(&pad, 1, 0, 1) == 1 && !pad.buttons);
    const struct { unsigned key; int32_t lx, ly, rx, ry; } directions[] = {
        {13, 0, 32767, 0, 0}, {0, -32767, 0, 0, 0}, {1, 0, -32767, 0, 0}, {2, 32767, 0, 0, 0},
        {34, 0, 0, 0, 32767}, {38, 0, 0, -32767, 0}, {40, 0, 0, 0, -32767}, {37, 0, 0, 32767, 0},
    };
    for (unsigned i = 0; i < sizeof directions / sizeof *directions; i++) {
        input_clear(); input_key(directions[i].key, 1);
        assert(input_states(&pad, 1, 0, 1) == 1 && !pad.buttons);
        assert(pad.lx == directions[i].lx && pad.ly == directions[i].ly && pad.rx == directions[i].rx && pad.ry == directions[i].ry);
    }
    input_clear(); input_key(13, 1); input_key(2, 1); input_key(34, 1); input_key(37, 1);
    assert(input_states(&pad, 1, 0, 1) == 1 && !pad.buttons && pad.lx == 32767 && pad.ly == 32767 && pad.rx == 32767 && pad.ry == 32767);
    input_key(0, 1); input_key(1, 1); input_key(38, 1); input_key(40, 1);
    assert(input_states(&pad, 1, 0, 1) == 1 && !pad.buttons && !pad.lx && !pad.ly && !pad.rx && !pad.ry);
    input_clear(); input_key(15, 1); input_key(15, 0); input_key(3, 1); input_key(3, 0);
    assert(input_states(&pad, 1, 0, 1) == 1 && pad.buttons == 12 && !pad.lx && !pad.ly && !pad.rx && !pad.ry);
    assert(input_states(&pad, 1, 0, 1) == 1 && !pad.buttons);
    assert(input_states(&pad, 1, 1, 1) == 1 && !pad.attributes && !pad.buttons && !pad.lx);
    input_key(13, 1); input_key(34, 1);
    input_clear(); assert(input_states(&pad, 1, 0, 1) == 1 && !pad.buttons && !pad.lx && !pad.ly && !pad.rx && !pad.ry);
    assert(!input_states(&pad, 0, 0, 1));
    assert(dm_padmap_face(dm_padmap_kind("Xbox One", "Microsoft"), 1, 0, 0, 0) == 1);
    assert(dm_padmap_face(dm_padmap_kind("Switch Pro Controller", "Nintendo"), 0, 1, 0, 0) == 1);
    input_controller(1, .5f, -.5f, .01f, .01f); input_controller(0, .5f, -.5f, .01f, .01f);
    assert(input_states(&pad, 1, 0, 1) == 1 && pad.buttons == 1 && pad.lx == 16384 && pad.ly == -16384 && !pad.rx && !pad.ry);
    assert(input_states(&pad, 1, 0, 1) == 1 && !pad.buttons);
    input_key(13, 1); input_key(37, 1); input_controller(2, 2, -2, NAN, 1);   // a deflected stick wins over held keys
    assert(input_states(&pad, 1, 0, 1) == 1 && pad.buttons == 2 && pad.lx == 32767 && pad.ly == -32767 && pad.rx == 32767 && !pad.ry);
    input_key(37, 0);
    input_key(13, 0);
    assert(input_states(&pad, 1, 0, 1) == 1 && pad.lx == 32767 && pad.ly == -32767);
    input_controller(4, 1, 1, 1, 1); input_key(13, 1); input_controller_clear();
    assert(input_states(&pad, 1, 0, 1) == 1 && !pad.buttons && !pad.lx && pad.ly == 32767 && !pad.rx && !pad.ry);
    input_controller(8, 1, 1, 1, 1); input_clear();
    assert(input_states(&pad, 1, 0, 1) == 1 && !pad.buttons && !pad.lx && !pad.ly && !pad.rx && !pad.ry);
    ZeldaScriptStep step;
    assert(input_script_parse("tap x\n", &step) && step.kind == SCRIPT_TAP && step.key == 7 && step.ms == 100);
    assert(input_script_parse("  tap return 250", &step) && step.key == 36 && step.ms == 250);
    assert(input_script_parse("down w", &step) && step.kind == SCRIPT_DOWN && step.key == 13);
    assert(input_script_parse("up shift", &step) && step.kind == SCRIPT_UP && step.key == 56);
    assert(input_script_parse("wait 600000", &step) && step.kind == SCRIPT_WAIT && step.ms == 600000);
    assert(input_script_parse("shot work/logs/a b.png\n", &step) && step.kind == SCRIPT_SHOT && !strcmp(step.text, "work/logs/a b.png"));
    assert(input_script_parse("mark scene ready", &step) && step.kind == SCRIPT_MARK && !strcmp(step.text, "scene ready"));
    assert(input_script_parse("trace 20 work/logs/scene.tsv", &step) && step.kind == SCRIPT_TRACE && step.ms == 20000 && !strcmp(step.text, "work/logs/scene.tsv"));
    assert(input_script_parse("trace-flush\n", &step) && step.kind == SCRIPT_TRACE_FLUSH);
    assert(!input_script_parse("trace-flush extra", &step));
    assert(!input_script_parse("trace 0 a", &step) && !input_script_parse("trace 601 a", &step) && !input_script_parse("trace 5", &step) && !input_script_parse("trace 5 a b", &step));
    assert(input_script_parse("# comment", &step) && step.kind == SCRIPT_NONE);
    assert(input_script_parse("fps 90", &step) && step.kind == SCRIPT_FPS && step.ms == 90);
    assert(input_script_parse("fps 30", &step) && step.ms == 30 && input_script_parse("fps 120", &step) && step.ms == 120);
    assert(!input_script_parse("fps 45", &step) && !input_script_parse("fps", &step) && !input_script_parse("fps 90 x", &step) && !input_script_parse("fps 900", &step));
    assert(input_script_parse("render 120", &step) && step.kind == SCRIPT_RENDER && step.ms == 120);
    assert(!input_script_parse("render 49", &step) && !input_script_parse("render 201", &step) && !input_script_parse("render", &step));
    assert(input_script_parse("conditional 0", &step) && step.kind == SCRIPT_CONDITIONAL && step.ms == 0);
    assert(input_script_parse("conditional 1", &step) && step.ms == 1 && input_script_parse("conditional 2", &step) && step.ms == 2);
    assert(!input_script_parse("conditional 3", &step) && !input_script_parse("conditional -1", &step) && !input_script_parse("conditional 2 x", &step));
    assert(zelda_conditional_mode_take() == -1 && !zelda_conditional_mode_request(3));
    assert(zelda_conditional_mode_request(0) && zelda_conditional_mode_take() == 0 && zelda_conditional_mode_take() == -1);
    assert(zelda_conditional_mode_request(2) && zelda_conditional_mode_take() == 2);
    assert(input_script_parse("\n", &step) && step.kind == SCRIPT_NONE);
    // Malformed lines stop the run instead of silently changing the measured scene.
    assert(!input_script_parse("tap", &step) && !input_script_parse("tap g", &step) && !input_script_parse("tap x 0", &step));
    assert(!input_script_parse("tap x 10001", &step) && !input_script_parse("tap x 10 z", &step) && !input_script_parse("down w 5", &step));
    assert(!input_script_parse("wait", &step) && !input_script_parse("wait -1", &step) && !input_script_parse("wait 600001", &step));
    assert(!input_script_parse("wait 1x", &step) && !input_script_parse("shot", &step) && !input_script_parse("press x", &step));
    assert(!zelda_timeline_now() && !zelda_timeline_stop("work/tmp/test_timeline.tsv"));
    assert(zelda_timeline_start() && !zelda_timeline_start());
    uint64_t begin = zelda_timeline_now(); assert(begin);
    zelda_timeline(TL_SUBMIT, begin, 3, 4); zelda_timeline(TL_SUBMIT, 0, 5, 6); // A hook that began before recording is skipped.
    zelda_timeline_span(TL_GPU, 10, 20, 7, 8);
    assert(zelda_timeline_stop("work/tmp/test_timeline.tsv") && !zelda_timeline_now());
    zelda_timeline(TL_SUBMIT, begin, 9, 9);
    FILE *trace = fopen("work/tmp/test_timeline.tsv", "r"); char row[256]; unsigned long long b0, e0, a0, b1; unsigned k0, thread0;
    assert(trace && fgets(row, sizeof row, trace) && !strcmp(row, "begin_ns\tend_ns\tkind\tthread\ta\tb\n"));
    assert(fscanf(trace, "%llu %llu %u %u %llu %llu", &b0, &e0, &k0, &thread0, &a0, &b1) == 6 && b0 == begin && e0 >= b0 && k0 == TL_SUBMIT && a0 == 3 && b1 == 4);
    assert(fscanf(trace, "%llu %llu %u %u %llu %llu", &b0, &e0, &k0, &thread0, &a0, &b1) == 6 && b0 == 10 && e0 == 20 && k0 == TL_GPU && a0 == 7 && b1 == 8);
    assert(fscanf(trace, "%llu", &b0) == EOF); fclose(trace); remove("work/tmp/test_timeline.tsv");
    kernel_init(0);
    atexit(kernel_destroy);
    uint32_t read = front_vsync_handle(), copy = front_vsync_handle();
    assert(read && copy && read != copy);
    uint64_t start = now_ns();
    for (unsigned i = 0; i < 6; i++) {
        uint64_t regs[31] = {0, (uint64_t)&read, 1, 1000000000};
        assert(kernel_svc(0x18, regs) && !regs[0]);
        regs[0] = copy; assert(kernel_svc(0x17, regs) && !regs[0]);
        regs[1] = (uint64_t)&read; regs[2] = 1; regs[3] = 0;
        assert(kernel_svc(0x18, regs) && regs[0] == 0xea01);
    }
    assert(now_ns() - start >= 50000000); // A permanently signaled event must not pass.
    uint64_t regs[31] = {read}; assert(kernel_svc(0x16, regs) && !regs[0]);
    regs[0] = copy; assert(kernel_svc(0x16, regs) && !regs[0]);
    puts("host display refresh checks passed");
}
