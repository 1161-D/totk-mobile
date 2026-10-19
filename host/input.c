#include "hle.h"
#include "input.h"
#include "vibration.h"
#include <pthread.h>
#include <string.h>
#include <math.h>

_Static_assert(sizeof(ZeldaPadState) == 0x28, "SDK Npad state ABI");
static pthread_mutex_t input_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t sampling, latched_buttons;
static uint64_t controller_buttons, controller_latched;
static int32_t controller_axes[4];
static unsigned char keys[128];
static uint32_t styles = 1, player_enabled = 1;
static const struct { unsigned key; uint64_t button; } mapping[] = {
    {7, 1u << 0}, {6, 1u << 1}, {15, 1u << 2}, {3, 1u << 3}, // X/Z/R/F: A/B/X/Y
    {12, 1u << 6}, {14, 1u << 7}, {56, 1u << 8}, {49, 1u << 9},
    {36, 1u << 10}, {48, 1u << 11}, {123, 1u << 12}, {126, 1u << 13},
    {124, 1u << 14}, {125, 1u << 15}, {8, 1u << 4}, {9, 1u << 5},
};
void input_key(unsigned code, int pressed) {
    if (code >= sizeof keys) return;
    pthread_mutex_lock(&input_lock);
    if (pressed && !keys[code]) for (unsigned i = 0; i < sizeof mapping / sizeof *mapping; i++)
        if (mapping[i].key == code) latched_buttons |= mapping[i].button;
    keys[code] = !!pressed;
    pthread_mutex_unlock(&input_lock);
}
void input_clear(void) {
    pthread_mutex_lock(&input_lock); memset(keys, 0, sizeof keys); latched_buttons = 0;
    controller_buttons = controller_latched = 0; memset(controller_axes, 0, sizeof controller_axes);
    pthread_mutex_unlock(&input_lock);
}
void input_controller_clear(void) {
    pthread_mutex_lock(&input_lock);
    controller_buttons = controller_latched = 0; memset(controller_axes, 0, sizeof controller_axes);
    pthread_mutex_unlock(&input_lock);
}
void input_controller(uint64_t buttons, float lx, float ly, float rx, float ry) {
    float axes[4] = {lx, ly, rx, ry};
    pthread_mutex_lock(&input_lock);
    buttons &= 0xffff;
    controller_latched |= buttons & ~controller_buttons; controller_buttons = buttons;
    for (unsigned s = 0; s < 2; s++) {
        float x = axes[s * 2], y = axes[s * 2 + 1];
        if (!isfinite(x) || !isfinite(y) || hypotf(x, y) < .12f) x = y = 0;
        controller_axes[s * 2] = (int32_t)lroundf(fmaxf(-1, fminf(1, x)) * 32767);
        controller_axes[s * 2 + 1] = (int32_t)lroundf(fmaxf(-1, fminf(1, y)) * 32767);
    }
    pthread_mutex_unlock(&input_lock);
}
int input_states(ZeldaPadState *out, int count, uint32_t id, uint32_t style) {
    if (!out || count <= 0) return 0;
    pthread_mutex_lock(&input_lock);
    *out = (ZeldaPadState){.sampling = ++sampling};
    if (id == 0 && player_enabled && (styles & style & 1)) {
        out->buttons = latched_buttons | controller_buttons | controller_latched;
        latched_buttons = controller_latched = 0;
        for (unsigned i = 0; i < sizeof mapping / sizeof *mapping; i++) if (keys[mapping[i].key]) out->buttons |= mapping[i].button;
        // WASD move; IJKL control the camera, leaving face buttons separate. A deflected stick wins over held keys for
        // its side, so keys held by an input script (or by someone else at the keyboard) never take it from the player.
        out->lx = (keys[2] - keys[0]) * 32767; out->ly = (keys[13] - keys[1]) * 32767;
        out->rx = (keys[37] - keys[38]) * 32767; out->ry = (keys[34] - keys[40]) * 32767;
        if (controller_axes[0] || controller_axes[1]) { out->lx = controller_axes[0]; out->ly = controller_axes[1]; }
        if (controller_axes[2] || controller_axes[3]) { out->rx = controller_axes[2]; out->ry = controller_axes[3]; }
        out->attributes = 3; // Connected and wired.
    }
    pthread_mutex_unlock(&input_lock);
    return 1;
}

#define WHY "Host keyboard and GameController supply one FullKey controller"
HLE_FORCE("_ZN2nn3hid14InitializeNpadEv", WHY, void, h_pad_init, void) { input_clear(); }
HLE_FORCE("_ZN2nn3hid22SetSupportedNpadIdTypeEPKjm", WHY, void, h_pad_ids, const uint32_t *ids, uint64_t n) {
    if (n > 10 || (!ids && n)) die("invalid supported controller IDs");
    pthread_mutex_lock(&input_lock); player_enabled = 0;
    for (uint64_t i = 0; i < n; i++) if (ids[i] == 0) player_enabled = 1;
    pthread_mutex_unlock(&input_lock);
}
HLE_FORCE("_ZN2nn3hid24SetSupportedNpadStyleSetENS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", WHY, void, h_pad_styles, uint32_t value) {
    pthread_mutex_lock(&input_lock); styles = value; pthread_mutex_unlock(&input_lock);
}
HLE_FORCE("_ZN2nn3hid15GetNpadStyleSetERKj", WHY, uint32_t, h_pad_style, const uint32_t *id) {
    pthread_mutex_lock(&input_lock); uint32_t result = *id == 0 && player_enabled ? styles & 1 : 0; pthread_mutex_unlock(&input_lock); return result;
}
#define STATES(symbol, name, style) HLE_FORCE(symbol, WHY, int, name, ZeldaPadState *out, int n, const uint32_t *id) { return input_states(out, n, *id, style); }
STATES("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadFullKeyStateEiRKj", h_pad_full, 1)
STATES("_ZN2nn3hid13GetNpadStatesEPNS0_17NpadHandheldStateEiRKj", h_pad_handheld, 2)
STATES("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadJoyDualStateEiRKj", h_pad_dual, 4)
STATES("_ZN2nn3hid13GetNpadStatesEPNS0_16NpadJoyLeftStateEiRKj", h_pad_left, 8)
STATES("_ZN2nn3hid13GetNpadStatesEPNS0_17NpadJoyRightStateEiRKj", h_pad_right, 16)
HLE_FORCE("_ZN2nn3hid18SetNpadJoyHoldTypeENS0_15NpadJoyHoldTypeE", WHY, void, h_pad_hold, int type) { (void)type; }
HLE_FORCE("_ZN2nn3hid14DisconnectNpadERKj", WHY, void, h_pad_disconnect, const uint32_t *id) {
    pthread_mutex_lock(&input_lock); if (*id == 0) player_enabled = 0; pthread_mutex_unlock(&input_lock);
}
HLE_FORCE("_ZN2nn3hid23GetSixAxisSensorHandlesEPNS0_19SixAxisSensorHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", WHY,
          int, h_pad_sensors, void *out, int n, const uint32_t *id, uint32_t style) { (void)out; (void)n; (void)id; (void)style; return 0; }
HLE_FORCE("_ZN2nn3hid25GetVibrationDeviceHandlesEPNS0_21VibrationDeviceHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", WHY,
          int, h_pad_vibration, uint32_t *out, int n, const uint32_t *id, uint32_t style) {
    pthread_mutex_lock(&input_lock);
    int count = id && player_enabled ? vibration_handles(out, n, *id, styles & style) : 0;
    pthread_mutex_unlock(&input_lock); return count;
}
// These are separate console HID devices; the host keyboard is already mapped to the controller.
HLE_FORCE("_ZN2nn3hid15InitializeMouseEv", WHY, void, h_mouse_init, void) {}
HLE_FORCE("_ZN2nn3hid18InitializeKeyboardEv", WHY, void, h_keyboard_init, void) {}
HLE_FORCE("_ZN2nn3hid14GetMouseStatesEPNS0_10MouseStateEi", WHY, int, h_mouse_states, void *out, int n) {
    if (n <= 0) return 0; memset(out, 0, 0x28); return 1;
}
HLE_FORCE("_ZN2nn3hid16GetKeyboardStateEPNS0_13KeyboardStateE", WHY, void, h_keyboard_state, void *out) { memset(out, 0, 0x30); }
