#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool zelda_timing_init(uint8_t *image, size_t size, uint64_t key_page, uint64_t patch);
// Changes the frame-step ceiling and presentation target while running (30, 60, 90; 120 stays exploratory).
bool zelda_set_target_fps(unsigned fps);
// The configured target, ignoring the 30 FPS movie override; 0 before a valid init.
unsigned zelda_target_fps(void);
unsigned zelda_game_frame_rate(void);
// Sum of the patched game's frame steps, for comparison with elapsed host time.
double zelda_game_seconds(void);
// Factor on every view's base size before clamp/alignment. 1 preserves original dynamic resolution; other factors
// disable the dynamic multiplier. Applies from the next size computation; 0.5..2, false without the patch.
bool zelda_set_render_scale(float scale);
float zelda_render_scale_factor(int mode);   // ZELDA_RENDER_* -> factor (ORIGINAL = 1); 0 for an unknown mode
float zelda_render_scale(void);
// Provided by the graphics backend: MetalFX spatial upscale of the presented image (0 off).
int zelda_present_metalfx_mode(void);
void zelda_present_metalfx(int mode);   // ZELDA_METALFX_*: off, to the window, to 3840x2160
