#import <GameController/GameController.h>
#import <CoreHaptics/CoreHaptics.h>
#include "gamepad.h"
#include "input.h"
#include "vibration.h"
#include "dm_padmap.h"
#include <stdio.h>
#include <time.h>

static GCController *selected;
static id connect_observer, disconnect_observer;
static bool active;
static int vibration_mode = 1;   // ZELDA_VIBRATION_* from the settings
static CHHapticEngine *haptic_engines[2];
static id<CHHapticPatternPlayer> haptic_players[2];
static bool haptic_running[2];
static ZeldaRumble last_rumble[2];
static unsigned haptic_generation, haptic_failures, haptic_logged, haptic_pulses;
static uint64_t haptic_ticks, haptic_retry_at;
static int haptic_test_ticks;
static NSTimer *haptic_timer;
static bool haptic_trace;

static void haptics_close(void) {
    haptic_generation++;
    haptic_test_ticks = 0;
    for (unsigned i = 0; i < 2; i++) {
        // Stopping the engine also stops its players; a disconnected player's stop can throw.
        [haptic_engines[i] stopWithCompletionHandler:nil];
        haptic_players[i] = nil; haptic_engines[i] = nil; haptic_running[i] = false;
        last_rumble[i] = (ZeldaRumble){-1, -1};
    }
    vibration_active(active);
}
// A failed step (typically a player whose engine the system stopped or reset between pump ticks) closes the engines,
// and output resumes after a short back-off (1, 2, 4, then 8 s) instead of staying off until the window refocuses.
static bool haptics_fail(const char *step, NSError *error) {
    unsigned delay = 60u << (haptic_failures < 3 ? haptic_failures : 3);
    haptic_failures++;
    if (haptic_logged < 8) {
        haptic_logged++;
        fprintf(stderr, "HAPTIC %s failed domain=%s code=%ld; retry in %u s\n", step,
            error.domain.UTF8String ?: "none", (long)error.code, delay / 60);
    }
    haptics_close(); haptic_retry_at = haptic_ticks + delay;
    return false;
}
static bool haptic_player(unsigned channel, GCHapticsLocality locality) {
    if (haptic_players[channel]) return true;
    CHHapticEngine *engine = [selected.haptics createEngineWithLocality:locality];
    NSError *error = nil;
    if (!engine) return haptics_fail("engine creation", nil);
    engine.playsHapticsOnly = YES;
    if (![engine startAndReturnError:&error]) return haptics_fail("engine start", error);
    CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
        parameters:@[[[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
                     [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:.5]]
        relativeTime:0 duration:GCHapticDurationInfinite];
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
    // GameController engines support an infinite continuous event without an advanced looping player.
    id<CHHapticPatternPlayer> player = pattern ? [engine createPlayerWithPattern:pattern error:&error] : nil;
    if (!player) { [engine stopWithCompletionHandler:nil]; return haptics_fail("player creation", error); }
    haptic_engines[channel] = engine; haptic_players[channel] = player;
    unsigned generation = haptic_generation;
    // The system may stop or reset an engine at any time; the next tick recreates it.
    void (^invalidate)(long) = ^(long reason) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != haptic_generation) return;
            if (haptic_logged < 8) { haptic_logged++; fprintf(stderr, "HAPTIC engine stopped reason=%ld; recreating\n", reason); }
            haptics_close();
        });
    };
    engine.resetHandler = ^{ invalidate(-1); };
    engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { invalidate((long)reason); };
    return true;
}
static void haptics_tick(void) {
    haptic_ticks++;
    if (!active || !selected.haptics) return;
    ZeldaVibrationValue values[2]; vibration_take(values);
    bool xbox = [selected.extendedGamepad isKindOfClass:GCXboxGamepad.class];
    ZeldaRumble rumble[2] = {vibration_scale(vibration_mix(values[0]), vibration_mode, xbox), vibration_scale(vibration_mix(values[1]), vibration_mode, xbox)};
    bool testing = haptic_test_ticks > 0;
    if (testing) { haptic_test_ticks--; rumble[0] = rumble[1] = (ZeldaRumble){.8f, 0}; }
    if (haptic_trace) {
        static unsigned lines; static bool was_nonzero;
        bool nonzero = rumble[0].intensity > 0 || rumble[1].intensity > 0;
        if (lines < 600 && (nonzero || was_nonzero)) {
            lines++;
            fprintf(stderr,"HAPTIC_TRACE time=%.6f source=%s mode=%d xbox=%d left=%.6f/%.1f,%.6f/%.1f right=%.6f/%.1f,%.6f/%.1f output=%.6f,%.6f running=%d,%d retry=%d\n",
                clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e9,testing?"test":"game",vibration_mode,xbox,
                values[0].low_amplitude,values[0].low_frequency,values[0].high_amplitude,values[0].high_frequency,
                values[1].low_amplitude,values[1].low_frequency,values[1].high_amplitude,values[1].high_frequency,
                rumble[0].intensity,rumble[1].intensity,haptic_running[0],haptic_running[1],haptic_ticks<haptic_retry_at);
        }
        was_nonzero=nonzero;
    }
    if (haptic_ticks < haptic_retry_at) return;
    NSSet *localities = selected.haptics.supportedLocalities;
    bool split = [localities containsObject:GCHapticsLocalityLeftHandle] && [localities containsObject:GCHapticsLocalityRightHandle];
    if (!split && rumble[1].intensity > rumble[0].intensity) rumble[0] = rumble[1];
    for (unsigned i = 0; i < (split ? 2u : 1u); i++) {
        NSError *error = nil;
        if (!rumble[i].intensity) {
            if (haptic_running[i] && ![haptic_players[i] stopAtTime:CHHapticTimeImmediate error:&error]) { haptics_fail("player stop", error); return; }
            haptic_running[i] = false; last_rumble[i] = (ZeldaRumble){-1, -1};
        } else {
            GCHapticsLocality locality = split ? (i ? GCHapticsLocalityRightHandle : GCHapticsLocalityLeftHandle) : GCHapticsLocalityDefault;
            if (!haptic_player(i, locality)) return;
            if (rumble[i].intensity != last_rumble[i].intensity || rumble[i].sharpness != last_rumble[i].sharpness) {
                NSArray *parameters = @[
                    [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:rumble[i].intensity relativeTime:0],
                    [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:rumble[i].sharpness relativeTime:0]];
                if (![haptic_players[i] sendParameters:parameters atTime:CHHapticTimeImmediate error:&error]) { haptics_fail("parameter update", error); return; }
                last_rumble[i] = rumble[i];
            }
            if (!haptic_running[i]) {
                if (![haptic_players[i] startAtTime:CHHapticTimeImmediate error:&error]) { haptics_fail("player start", error); return; }
                haptic_running[i] = true; haptic_failures = 0;
                if (haptic_pulses < (haptic_trace ? 64u : 4u)) {
                    haptic_pulses++;
                    fprintf(stderr, "HAPTIC output started %s intensity=%.2f sharpness=%.2f\n", locality.UTF8String, rumble[i].intensity, rumble[i].sharpness);
                }
            }
        }
    }
}
void gamepad_vibration_mode(int mode) {
    if ((mode != 0) != vibration_mode) vibration_active(active);
    vibration_mode = mode != 0;
    if (!vibration_mode) haptics_close(); // Stop a running test as well as game pulses.
}
bool gamepad_test_vibration(void) {
    if (!vibration_mode || !selected.haptics) return false;
    haptic_test_ticks = 24; haptic_retry_at = haptic_ticks;   // 0.4 s on every motor, retrying a failed engine at once
    return true;
}
void gamepad_describe(char *name, unsigned size, bool *haptics) {
    snprintf(name, size, "%s", selected ? (selected.vendorName.UTF8String ?: "Controller") : "");
    *haptics = selected.haptics != nil;
}

static void publish(GCController *controller, GCExtendedGamepad *pad) {
    if (!active || controller != selected) return;
    uint64_t buttons = dm_padmap_face(dm_padmap_kind(controller.productCategory.UTF8String, controller.vendorName.UTF8String),
        pad.buttonA.pressed, pad.buttonB.pressed, pad.buttonX.pressed, pad.buttonY.pressed);
    if (pad.leftShoulder.pressed) buttons |= DM_BTN_L;
    if (pad.rightShoulder.pressed) buttons |= DM_BTN_R;
    if (pad.leftTrigger.pressed) buttons |= DM_BTN_ZL;
    if (pad.rightTrigger.pressed) buttons |= DM_BTN_ZR;
    if (pad.leftThumbstickButton.pressed) buttons |= DM_BTN_LS;
    if (pad.rightThumbstickButton.pressed) buttons |= DM_BTN_RS;
    if (pad.buttonMenu.pressed) buttons |= DM_BTN_PLUS;
    if (pad.buttonOptions.pressed) buttons |= DM_BTN_MINUS;
    if (pad.dpad.left.pressed) buttons |= DM_BTN_LEFT;
    if (pad.dpad.right.pressed) buttons |= DM_BTN_RIGHT;
    if (pad.dpad.up.pressed) buttons |= DM_BTN_UP;
    if (pad.dpad.down.pressed) buttons |= DM_BTN_DOWN;
    input_controller(buttons, pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value,
        pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value);
}
static void select_controller(void) {
    if (selected) return;
    for (GCController *controller in GCController.controllers) if (controller.extendedGamepad) {
        selected = controller; controller.handlerQueue = dispatch_get_main_queue();
        haptics_close(); haptic_failures = 0; haptic_retry_at = 0;
        __weak GCController *weak_controller = controller;
        controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad *pad, GCControllerElement *element) {
            (void)element; GCController *current = weak_controller;
            if (current) publish(current, pad);
        };
        fprintf(stderr, "GAMEPAD connected vendor=%s category=%s; face buttons follow printed letters\n",
            controller.vendorName.UTF8String ?: "unknown", controller.productCategory.UTF8String ?: "unknown");
        fprintf(stderr, "HAPTIC controller capability=%s\n", controller.haptics ? "available" : "unavailable");
        publish(controller, controller.extendedGamepad); break;
    }
}
void gamepad_active(bool value) {
    active = value;
    haptics_close(); haptic_failures = 0; haptic_retry_at = 0;
    if (!value) input_clear();
    else if (selected) publish(selected, selected.extendedGamepad);
}
void gamepad_start(void) {
    const char *trace = getenv("ZELDA_HAPTIC_TRACE"); haptic_trace = trace && atoi(trace);
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    connect_observer = [center addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *notification) { (void)notification; select_controller(); }];
    disconnect_observer = [center addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *notification) {
            if (notification.object == selected) {
                selected.extendedGamepad.valueChangedHandler = nil; selected = nil;
                haptics_close();
                input_controller_clear(); fprintf(stderr, "GAMEPAD disconnected\n"); select_controller();
            }
        }];
    active = true; select_controller();
    vibration_active(active);
    haptic_timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) { (void)timer; haptics_tick(); }];
    [NSRunLoop.mainRunLoop addTimer:haptic_timer forMode:NSRunLoopCommonModes];
    if (!selected) fprintf(stderr, "GAMEPAD waiting for a connected extended controller\n");
}
void gamepad_stop(void) {
    [haptic_timer invalidate]; haptic_timer = nil;
    selected.extendedGamepad.valueChangedHandler = nil; selected = nil;
    if (connect_observer) [NSNotificationCenter.defaultCenter removeObserver:connect_observer];
    if (disconnect_observer) [NSNotificationCenter.defaultCenter removeObserver:disconnect_observer];
    connect_observer = disconnect_observer = nil; gamepad_active(false);
}
