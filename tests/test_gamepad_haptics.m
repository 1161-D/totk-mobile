// Reproduce a stopped engine with a still-retained player, without a physical controller.
#include "../host/gamepad.m"
#include <assert.h>

void input_clear(void) {}
void input_controller(uint64_t b,float x,float y,float rx,float ry) {(void)b;(void)x;(void)y;(void)rx;(void)ry;}
void input_controller_clear(void) {}

@interface StoppedPlayer : NSObject
@property unsigned stop_calls;
@end
@implementation StoppedPlayer
- (BOOL)stopAtTime:(NSTimeInterval)time error:(NSError **)error {
    (void)time; self.stop_calls++;
    if (!error) @throw [NSException exceptionWithName:@"com.apple.CoreHaptics" reason:@"self.running" userInfo:nil];
    *error=[NSError errorWithDomain:CoreHapticsErrorDomain code:CHHapticErrorCodeEngineNotRunning userInfo:nil];
    return NO;
}
- (BOOL)sendParameters:(NSArray *)parameters atTime:(NSTimeInterval)time error:(NSError **)error {
    (void)parameters; (void)time; assert(error);
    *error=[NSError errorWithDomain:CoreHapticsErrorDomain code:CHHapticErrorCodeEngineNotRunning userInfo:nil];
    return NO;
}
@end

@interface StoppedEngine : NSObject
@property unsigned stop_calls;
@end
@implementation StoppedEngine
- (void)stopWithCompletionHandler:(CHHapticCompletionHandler)completion {
    self.stop_calls++; if (completion) completion(nil);
}
@end

@interface TestHaptics : NSObject
@property NSSet *supportedLocalities;
@end
@implementation TestHaptics @end
@interface TestController : NSObject
@property TestHaptics *haptics;
@property GCExtendedGamepad *extendedGamepad;
@end
@implementation TestController @end

int main(void) { @autoreleasepool {
    TestController *controller=[TestController new]; controller.haptics=[TestHaptics new];
    controller.haptics.supportedLocalities=[NSSet setWithObjects:GCHapticsLocalityLeftHandle,GCHapticsLocalityRightHandle,nil];
    selected=(GCController *)(id)controller;
    uint32_t handles[]={3,0x10003};
    ZeldaVibrationValue values[2]={{.1f,160,0,320},{.1f,160,0,320}}, out[2];
    for (int scenario=0;scenario<3;scenario++) {
        StoppedEngine *engines[2]={[StoppedEngine new],[StoppedEngine new]};
        StoppedPlayer *players[2]={[StoppedPlayer new],[StoppedPlayer new]};
        active=true; vibration_active(true); vibration_permit(true);
        haptic_ticks=100; haptic_retry_at=0; haptic_failures=0;
        haptic_test_ticks=scenario==0 ? 7 : 0;
        unsigned generation=haptic_generation;
        for (unsigned i=0;i<2;i++) {
            haptic_engines[i]=(CHHapticEngine *)(id)engines[i];
            haptic_players[i]=(id<CHHapticPatternPlayer>)players[i];
            haptic_running[i]=true; last_rumble[i]=(ZeldaRumble){.5f,0};
        }
        if (scenario!=1) assert(vibration_send(handles,values,2,false));
        if (scenario==0) haptics_close(); // stopped/reset callback, before disconnect notification
        else haptics_tick();             // stop or parameter update races the stopped callback
        assert(haptic_generation==generation+1 && !haptic_test_ticks);
        if (scenario) assert(haptic_failures==1 && haptic_retry_at==haptic_ticks+60);
        for (unsigned i=0;i<2;i++) {
            assert(!haptic_engines[i] && !haptic_players[i] && !haptic_running[i]);
            assert(engines[i].stop_calls==1);
            assert(players[i].stop_calls==(scenario==1 && i==0 ? 1u : 0u));
        }
        vibration_take(out); assert(out[0].low_amplitude==0 && out[1].low_amplitude==0);
        haptics_close(); // duplicate disconnect/focus cleanup must remain harmless
        assert(engines[0].stop_calls==1 && engines[1].stop_calls==1);
    }
    assert(gamepad_test_vibration() && haptic_test_ticks);
    assert(vibration_send(handles,values,2,false));
    gamepad_vibration_mode(0);
    assert(!haptic_test_ticks && !gamepad_test_vibration());
    assert(vibration_send(handles,values,2,false)); // No replay of a pulse sent while rumble was off.
    gamepad_vibration_mode(1); vibration_take(out);
    assert(!out[0].low_amplitude && !out[1].low_amplitude);
    selected=nil;
    puts("Gamepad haptics: stopped-engine cleanup, racing stop/update failures and duplicate cleanup passed");
} }
