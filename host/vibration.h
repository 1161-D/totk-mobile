#pragma once
#include <stdint.h>
#include <stdbool.h>
typedef struct { float low_amplitude, low_frequency, high_amplitude, high_frequency; } ZeldaVibrationValue;
typedef struct { float intensity, sharpness; } ZeldaRumble;
int vibration_handles(uint32_t *out, int count, uint32_t player, uint32_t style);
bool vibration_send(const uint32_t *handles, const ZeldaVibrationValue *values, int count, bool enqueue);
void vibration_flush(void);
void vibration_active(bool active);
void vibration_permit(bool permitted);
void vibration_read(ZeldaVibrationValue out[2]);
void vibration_take(ZeldaVibrationValue out[2]);
ZeldaRumble vibration_mix(ZeldaVibrationValue value);
// Xbox uses the physically calibrated amplitude curve; off always silences.
ZeldaRumble vibration_scale(ZeldaRumble rumble, int mode, bool xbox);
