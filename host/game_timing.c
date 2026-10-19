#include "game_timing.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const uint8_t *movie_flag;
static const uint64_t *game_seconds_bits;
static float *ceiling;              // Read by the patched frame step on every frame.
static unsigned target_fps = 60;    // Atomic: changed from the menu while the game and present threads read it.
static float *render_scale;         // Read by the patched render-size computation (tools/render_scale.py).
bool zelda_timing_init(uint8_t *image, size_t size, uint64_t key_page, uint64_t patch) {
    const size_t state = 0x3ae4000;
    movie_flag = NULL; game_seconds_bits = NULL; ceiling = NULL; render_scale = NULL; __atomic_store_n(&target_fps, 60, __ATOMIC_RELAXED);
    if (!image || key_page != state - 0x4000 || patch < state + 32 || size < patch ||
        memcmp(image + state, "ZFPS143", 8)) return false;
    unsigned fps = 60;
    const char *value = getenv("ZELDA_TARGET_FPS");
    if (value) {
        if (!strcmp(value, "30")) fps = 30;
        else if (!strcmp(value, "60")) fps = 60;
        else if (!strcmp(value, "90")) fps = 90;
        else if (!strcmp(value, "120")) fps = 120;
        else { fputs("ZELDA_TARGET_FPS must be 30, 60, 90 or 120\n", stderr); return false; }
    }
    float day_rate = 1;
    const char *day = getenv("ZELDA_DAY_RATE");
    bool day_patch = patch >= state + 52 && !memcmp(image + state + 36, "ZDAY143", 8);
    if (day) {
        char *end;
        day_rate = strtof(day, &end);
        if (!day_patch || end == day || *end || !(day_rate >= 0 && day_rate <= 16)) {
            fputs("ZELDA_DAY_RATE requires the world-clock patch and a number from 0 to 16\n", stderr); return false;
        }
        fprintf(stderr, "DAY_CLOCK rate=%g (world time only)\n", day_rate);
    }
    if (day_patch) {
        memcpy(image + state + 44, &day_rate, sizeof day_rate);
        uint32_t enabled = day_rate != 1; memcpy(image + state + 48, &enabled, sizeof enabled);
    }
    ceiling = (float *)(image + state + 12);
    movie_flag = image + state + 8;
    game_seconds_bits = (const uint64_t *)(image + state + 16);
    float prepared; memcpy(&prepared, image + state + 32, sizeof prepared);
    if (patch >= state + 36 && prepared == 1.0f) render_scale = (float *)(image + state + 32);   // patched module only
    return zelda_set_target_fps(fps);
}
float zelda_render_scale_factor(int mode) {
    // Scene heights over the original 900 (1080 x 5/6) before the game's 8-pixel floor; +0.5 keeps float rounding
    // from landing just under a multiple of 8. Original stays exactly 1, including the game's dynamic size selection.
    const float heights[] = {0, 1080, 720, 640};   // ZELDA_RENDER_*
    if (mode < 0 || mode > 3) return 0;
    return mode ? (heights[mode] + 0.5f) / 900.0f : 1.0f;
}
bool zelda_set_render_scale(float scale) {
    if (!render_scale || !(scale >= 0.5f && scale <= 2.0f)) return false;
    uint32_t bits; memcpy(&bits, &scale, sizeof bits);
    __atomic_store_n((uint32_t *)render_scale, bits, __ATOMIC_RELAXED);
    return true;
}
float zelda_render_scale(void) {
    if (!render_scale) return 0;
    uint32_t bits = __atomic_load_n((uint32_t *)render_scale, __ATOMIC_RELAXED); float value; memcpy(&value, &bits, sizeof value);
    return value;
}
bool zelda_set_target_fps(unsigned fps) {
    if (!ceiling || (fps != 30 && fps != 60 && fps != 90 && fps != 120)) return false;
    float value = (float)fps; uint32_t bits; memcpy(&bits, &value, sizeof bits);
    __atomic_store_n((uint32_t *)ceiling, bits, __ATOMIC_RELAXED);
    __atomic_store_n(&target_fps, fps, __ATOMIC_RELAXED);
    return true;
}
unsigned zelda_target_fps(void) { return ceiling ? __atomic_load_n(&target_fps, __ATOMIC_RELAXED) : 0; }
unsigned zelda_game_frame_rate(void) {
    return movie_flag ? (__atomic_load_n(movie_flag, __ATOMIC_RELAXED) == 1 ? 30 : __atomic_load_n(&target_fps, __ATOMIC_RELAXED)) : 0;
}
double zelda_game_seconds(void) {
    if (!game_seconds_bits) return -1;
    uint64_t bits = __atomic_load_n(game_seconds_bits, __ATOMIC_RELAXED);
    double seconds; memcpy(&seconds, &bits, sizeof seconds); return seconds;
}
