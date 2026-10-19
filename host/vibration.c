#include "vibration.h"
#include "hle.h"
#include <math.h>
#include <pthread.h>
#include <string.h>
#include <stdio.h>
#include <stdatomic.h>

_Static_assert(sizeof(ZeldaVibrationValue) == 16, "SDK vibration ABI");
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static bool active, permitted = true, received, reported;
static unsigned pending_mask;
static ZeldaVibrationValue current[2], pending[2], peak[2];
static const ZeldaVibrationValue silent = {0, 160, 0, 320};
static int index_of(uint32_t handle) { return handle == 3 ? 0 : handle == 0x10003 ? 1 : -1; }
int vibration_handles(uint32_t *out, int count, uint32_t player, uint32_t style) {
    if (!out || count <= 0 || player || !(style & 1)) return 0;
    count = count < 2 ? count : 2;
    for (int i = 0; i < count; i++) out[i] = 3u | ((uint32_t)i << 16);
    static atomic_flag noted = ATOMIC_FLAG_INIT;
    if (!atomic_flag_test_and_set(&noted)) fprintf(stderr, "HAPTIC virtual FullKey devices requested\n");
    return count;
}
static ZeldaVibrationValue sanitize(ZeldaVibrationValue value) {
    if (!isfinite(value.low_amplitude) || !isfinite(value.high_amplitude) ||
        !isfinite(value.low_frequency) || !isfinite(value.high_frequency) ||
        value.low_frequency <= 0 || value.high_frequency <= 0) return silent;
    value.low_amplitude = fminf(1, fmaxf(0, value.low_amplitude));
    value.high_amplitude = fminf(1, fmaxf(0, value.high_amplitude));
    return value;
}
static void clear_locked(void) { current[0] = current[1] = pending[0] = pending[1] = peak[0] = peak[1] = silent; pending_mask = 0; }
static void commit_locked(unsigned channel, ZeldaVibrationValue value) {
    current[channel] = value;
    if (value.low_amplitude > peak[channel].low_amplitude) {
        peak[channel].low_amplitude = value.low_amplitude; peak[channel].low_frequency = value.low_frequency;
    }
    if (value.high_amplitude > peak[channel].high_amplitude) {
        peak[channel].high_amplitude = value.high_amplitude; peak[channel].high_frequency = value.high_frequency;
    }
}
void vibration_active(bool value) {
    pthread_mutex_lock(&lock); active = value; clear_locked(); pthread_mutex_unlock(&lock);
}
void vibration_permit(bool value) {
    pthread_mutex_lock(&lock); permitted = value; if (!value) clear_locked(); pthread_mutex_unlock(&lock);
}
bool vibration_send(const uint32_t *handles, const ZeldaVibrationValue *values, int count, bool enqueue) {
    if (count < 0 || count > 16 || (count && (!handles || !values))) return false;
    for (int i = 0; i < count; i++) if (index_of(handles[i]) < 0) return false;
    pthread_mutex_lock(&lock);
    for (int i = 0; i < count; i++) {
        int channel = index_of(handles[i]); ZeldaVibrationValue value = sanitize(values[i]);
        if (!received) { received = true; fprintf(stderr, "HAPTIC guest values received; physical output is not confirmed\n"); }
        if (!reported && (value.low_amplitude || value.high_amplitude)) {
            reported = true; fprintf(stderr, "HAPTIC guest vibration observed; physical output depends on controller capability\n");
        }
        if (!active || !permitted) value = silent;
        if (enqueue) { pending[channel] = value; pending_mask |= 1u << channel; }
        else commit_locked((unsigned)channel, value);
    }
    pthread_mutex_unlock(&lock); return true;
}
void vibration_flush(void) {
    pthread_mutex_lock(&lock);
    for (unsigned i = 0; i < 2; i++) if (pending_mask & (1u << i)) commit_locked(i, pending[i]);
    pending_mask = 0; pthread_mutex_unlock(&lock);
}
void vibration_read(ZeldaVibrationValue out[2]) {
    pthread_mutex_lock(&lock); memcpy(out, current, sizeof current); pthread_mutex_unlock(&lock);
}
void vibration_take(ZeldaVibrationValue out[2]) {
    pthread_mutex_lock(&lock);
    for (unsigned i = 0; i < 2; i++) {
        out[i] = current[i];
        // Preserve a brief pulse that starts and stops between host timer ticks.
        if (peak[i].low_amplitude > out[i].low_amplitude) {
            out[i].low_amplitude = peak[i].low_amplitude; out[i].low_frequency = peak[i].low_frequency;
        }
        if (peak[i].high_amplitude > out[i].high_amplitude) {
            out[i].high_amplitude = peak[i].high_amplitude; out[i].high_frequency = peak[i].high_frequency;
        }
        peak[i] = silent;
    }
    pthread_mutex_unlock(&lock);
}
ZeldaRumble vibration_mix(ZeldaVibrationValue value) {
    value = sanitize(value); float sum = value.low_amplitude + value.high_amplitude;
    // shortcut: CoreHaptics approximates HD bands; calibrate the feel on physical Xbox controllers.
    return (ZeldaRumble){fminf(1, sum), sum > 0 ? value.high_amplitude / sum - .5f : 0};
}
ZeldaRumble vibration_scale(ZeldaRumble rumble, int mode, bool xbox) {
    // HD band balance is not a pitch control for the individual Xbox handle motors.
    if (xbox) rumble.sharpness = 0;
    if (mode <= 0 || !(rumble.intensity > 0)) return (ZeldaRumble){0, rumble.sharpness};
    rumble.intensity = fminf(1, rumble.intensity);
    // Short-pulse A/B matched the native player; Xbox needs more gain below full strength.
    if (xbox) rumble.intensity = sqrtf(rumble.intensity / (.02f + .98f * rumble.intensity));
    return rumble;
}

#define WHY "Virtual FullKey vibration feeds the host GameController haptics bridge"
#define BAD 0x1c01u
HLE_FORCE("_ZN2nn3hid6detail20IsVibrationPermittedEPb", WHY, uint32_t, h_vib_permitted, bool *out) {
    if (!out) return BAD; pthread_mutex_lock(&lock); *out = permitted; pthread_mutex_unlock(&lock); return 0;
}
// Switch callers do not extend bool arguments as required by the Apple ABI.
HLE_FORCE("_ZN2nn3hid6detail15PermitVibrationEb", WHY, uint32_t, h_vib_permit, unsigned value) { vibration_permit((value & 1) != 0); return 0; }
HLE_FORCE("_ZN2nn3hid6detail25InitializeVibrationDeviceERKNS0_21VibrationDeviceHandleE", WHY, uint32_t, h_vib_init, const uint32_t *handle) {
    return handle && index_of(*handle) >= 0 ? 0 : BAD;
}
HLE_FORCE("_ZN2nn3hid6detail22GetVibrationDeviceInfoEPNS0_19VibrationDeviceInfoERKNS0_21VibrationDeviceHandleE", WHY, uint32_t, h_vib_info, uint32_t *out, const uint32_t *handle) {
    if (!out || !handle || index_of(*handle) < 0) return BAD;
    out[0] = 1; out[1] = (uint32_t)index_of(*handle) + 1; return 0;
}
HLE_FORCE("_ZN2nn3hid6detail18SendVibrationValueERKNS0_21VibrationDeviceHandleERKNS0_14VibrationValueE", WHY, uint32_t, h_vib_send, const uint32_t *handle, const ZeldaVibrationValue *value) {
    return vibration_send(handle, value, 1, false) ? 0 : BAD;
}
HLE_FORCE("_ZN2nn3hid6detail19SendVibrationValuesEPKNS0_21VibrationDeviceHandleEPKNS0_14VibrationValueEi", WHY, uint32_t, h_vib_send_many, const uint32_t *handles, const ZeldaVibrationValue *values, int count) {
    return vibration_send(handles, values, count, false) ? 0 : BAD;
}
HLE_FORCE("_ZN2nn3hid6detail21EnqueueVibrationValueERKNS0_21VibrationDeviceHandleERKNS0_14VibrationValueE", WHY, uint32_t, h_vib_enqueue, const uint32_t *handle, const ZeldaVibrationValue *value) {
    return vibration_send(handle, value, 1, true) ? 0 : BAD;
}
HLE_FORCE("_ZN2nn3hid6detail28FlushEnqueuedVibrationValuesEv", WHY, uint32_t, h_vib_flush, void) { vibration_flush(); return 0; }
HLE_FORCE("_ZN2nn3hid6detail23GetActualVibrationValueEPNS0_14VibrationValueERKNS0_21VibrationDeviceHandleE", WHY, uint32_t, h_vib_get, ZeldaVibrationValue *out, const uint32_t *handle) {
    if (!out || !handle || index_of(*handle) < 0) return BAD;
    ZeldaVibrationValue values[2]; vibration_read(values); *out = values[index_of(*handle)]; return 0;
}
HLE_FORCE("_ZN2nn3hid6detail24IsVibrationDeviceMountedEPbRKNS0_21VibrationDeviceHandleE", WHY, uint32_t, h_vib_mounted, bool *out, const uint32_t *handle) {
    if (!out || !handle || index_of(*handle) < 0) return BAD;
    *out = true; return 0; // The emulated FullKey devices exist even when the physical sink is absent.
}
// Cover referenced public entry points too: the SDK can inline its own detail wrappers.
HLE_FORCE("_ZN2nn3hid25InitializeVibrationDeviceERKNS0_21VibrationDeviceHandleE", WHY, void, h_vib_public_init, const uint32_t *handle) { (void)h_vib_init(handle); }
HLE_FORCE("_ZN2nn3hid22GetVibrationDeviceInfoEPNS0_19VibrationDeviceInfoERKNS0_21VibrationDeviceHandleE", WHY, void, h_vib_public_info, uint32_t *out, const uint32_t *handle) { (void)h_vib_info(out, handle); }
HLE_FORCE("_ZN2nn3hid18SendVibrationValueERKNS0_21VibrationDeviceHandleERKNS0_14VibrationValueE", WHY, void, h_vib_public_send, const uint32_t *handle, const ZeldaVibrationValue *value) { (void)h_vib_send(handle, value); }
HLE_FORCE("_ZN2nn3hid23GetActualVibrationValueEPNS0_14VibrationValueERKNS0_21VibrationDeviceHandleE", WHY, void, h_vib_public_get, ZeldaVibrationValue *out, const uint32_t *handle) { (void)h_vib_get(out, handle); }
