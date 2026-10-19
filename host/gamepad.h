#pragma once
#include <stdbool.h>
void gamepad_start(void);
void gamepad_active(bool active);
void gamepad_stop(void);
void gamepad_vibration_mode(int mode);   // ZELDA_VIBRATION_*
bool gamepad_test_vibration(void);       // short pulse on every motor; false without a controller reporting haptics
void gamepad_describe(char *name, unsigned size, bool *haptics);   // empty name when no controller is connected
