#pragma once
#include <stdint.h>
typedef struct {
    int64_t sampling;
    uint64_t buttons;
    int32_t lx, ly, rx, ry;
    uint32_t attributes, reserved;
} ZeldaPadState;
void input_key(unsigned code, int pressed);
void input_clear(void);
void input_controller(uint64_t buttons, float lx, float ly, float rx, float ry);
void input_controller_clear(void);
int input_states(ZeldaPadState *out, int count, uint32_t id, uint32_t style);
