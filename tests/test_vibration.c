#include "../host/vibration.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    uint32_t handles[3] = {0, 0, 0xabcdef};
    assert(vibration_handles(handles, 3, 0, 1) == 2 && handles[0] == 3 && handles[1] == 0x10003 && handles[2] == 0xabcdef);
    assert(!vibration_handles(NULL, 2, 0, 1) && !vibration_handles(handles, -1, 0, 1));
    assert(!vibration_handles(handles, 2, 1, 1) && !vibration_handles(handles, 2, 0, 2));
    ZeldaVibrationValue values[2] = {{.2f, 160, .3f, 320}, {.8f, 160, .1f, 320}}, out[2];
    vibration_active(true); assert(vibration_send(handles, values, 2, true));
    vibration_read(out); assert(!out[0].low_amplitude && !out[1].high_amplitude);
    vibration_flush(); vibration_read(out); assert(!memcmp(out, values, sizeof values));
    uint32_t invalid[2] = {handles[0], 999};
    assert(!vibration_send(invalid, values, 2, false));
    vibration_read(out); assert(!memcmp(out, values, sizeof values));
    assert(!vibration_send(handles, values, 17, false) && !vibration_send(NULL, values, 1, false));
    ZeldaRumble mixed = vibration_mix(values[0]); assert(fabsf(mixed.intensity - .5f) < 1e-6f && fabsf(mixed.sharpness - .1f) < 1e-6f);
    ZeldaVibrationValue zero = {0, 160, 0, 320};
    // A pulse shorter than the host pump interval must still be delivered once, then stop.
    vibration_active(true); assert(vibration_send(handles, values, 1, false));
    assert(vibration_send(handles, &zero, 1, false)); vibration_take(out); assert(out[0].high_amplitude == .3f);
    vibration_take(out); assert(!out[0].high_amplitude && !out[0].low_amplitude);
    ZeldaVibrationValue malformed = {NAN, 160, 1, 320};
    assert(vibration_send(handles, &malformed, 1, false)); vibration_read(out); assert(!vibration_mix(out[0]).intensity);
    malformed = (ZeldaVibrationValue){-2, 160, 9, 320};
    mixed = vibration_mix(malformed); assert(mixed.intensity == 1 && mixed.sharpness == .5f);
    malformed.low_frequency = INFINITY; assert(!vibration_mix(malformed).intensity);
    // Other controllers retain their original strength mapping.
    ZeldaRumble faint = {.04f, .25f};
    assert(!vibration_scale(faint, 0, false).intensity && vibration_scale(faint, 1, false).intensity == .04f);
    assert(vibration_scale(faint, 1, false).sharpness == .25f);
    // Calibrated landing peak, with a smooth falloff to silence instead of a minimum motor level.
    ZeldaRumble landing = vibration_mix((ZeldaVibrationValue){.1f,198.7f,0,299.9f});
    assert(fabsf(vibration_scale(landing, 1, true).intensity - .9205746f) < 1e-6f);
    assert(vibration_scale(landing, 1, true).sharpness == 0);
    assert(vibration_scale((ZeldaRumble){1e-8f,0},1,true).intensity < .001f);
    const float captured[] = {.071373f,.1f,.1f,.1f,.1f,.099216f,.041176f,.059608f,.045882f,.015686f,.011373f,.009020f,.002353f,.002745f,.000392f,0};
    for (unsigned i=0;i<sizeof captured/sizeof captured[0];i++) {
        ZeldaVibrationValue pulse[2]={{captured[i],160,0,320},{captured[i],160,0,320}};
        assert(vibration_send(handles,pulse,2,false)); vibration_take(out);
        float intensity=vibration_scale(vibration_mix(out[0]),1,true).intensity;
        assert((intensity>0)==(captured[i]>0)); // No tail after the captured 250 ms pulse.
        assert(intensity < 1);                // Preserve strength differences without clipping.
    }
    for (int xbox=0;xbox<2;xbox++) for (int mode=0;mode<2;mode++) {
        assert(!vibration_scale((ZeldaRumble){0,0},mode,xbox).intensity);
        assert(vibration_scale((ZeldaRumble){1,0},mode,xbox).intensity == (mode ? 1 : 0));
        float previous=0;
        for (int i=0;i<=1000;i++) {
            ZeldaRumble r=vibration_scale((ZeldaRumble){i/1000.f,-.5f},mode,xbox);
            assert(r.intensity>=previous && r.intensity<=1 && r.sharpness==(xbox ? 0 : -.5f));
            previous=r.intensity;
        }
    }
    vibration_send(handles, values, 2, true); vibration_active(false); vibration_flush();
    vibration_send(handles, values, 2, false); vibration_take(out);
    assert(!out[0].low_amplitude && !out[1].high_amplitude);
    vibration_active(true); vibration_send(handles, values, 2, false);
    vibration_permit(false); vibration_send(handles, values, 2, true); vibration_flush(); vibration_take(out);
    assert(!out[0].low_amplitude && !out[1].high_amplitude);
    vibration_permit(true); vibration_take(out); assert(!out[0].low_amplitude && !out[1].high_amplitude);
    puts("Vibration: FullKey handles, atomic batches, queued flush, short pulses, bounds and lifecycle reset passed");
}
