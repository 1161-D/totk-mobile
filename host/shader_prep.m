#include "shader_prep.h"
#import <QuartzCore/QuartzCore.h>
#include "nvn_shader_math.h"
#include "nvn_cube_source.h"
#include "dmsh_chain.h"
#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "shader_ir.inc"

static NSArray<NSString *> *library_names(NSString *directory) {
    NSArray *names = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]
        sortedArrayUsingSelector:@selector(compare:)];
    if (!names) return nil;
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *name in names) if ([name hasSuffix:@".metallib"]) [files addObject:name];
    return files;
}

static BOOL layered_library(NSString *name) {
    return [name isEqualToString:@"48e3901f9b4eb169_b.metallib"] || [name isEqualToString:@"c3960b272d349125_b.metallib"];
}

static NSArray<NSString *> *preparation_files(NSString *directory, NSArray<NSString *> *files) {
    const char *all = getenv("ZELDA_SHADER_PREP_ALL");
    if (ir_enabled() && !(all && atoi(all))) {
        NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:ir_directory(directory) error:nil];
        if (entries.count) {
            NSSet *cached = [NSSet setWithArray:entries];
            NSMutableArray *pending = [NSMutableArray array];
            for (NSString *name in files) {
                NSString *key = name.stringByDeletingPathExtension;
                BOOL present = [cached containsObject:name] && [cached containsObject:[key stringByAppendingString:@".json"]];
                if (present && layered_library(name))
                    present = [cached containsObject:[key stringByAppendingString:@"-cube.metallib"]] &&
                        [cached containsObject:[key stringByAppendingString:@"-cube.json"]];
                // File names only defer work; each actual load still verifies identity and contents.
                if (!present) [pending addObject:name];
            }
            return pending;
        }
    }
    return files;
}

static unsigned prep_files(id<MTLDevice> device, NSString *directory, NSArray<NSString *> *files, long slots_count,
                           qos_class_t qos, void (^progress)(unsigned, unsigned)) {
    unsigned total = (unsigned)files.count;
    shader_status_note(SHADER_LIBRARIES, total);
    __block _Atomic unsigned complete = 0, failed = 0;
    dispatch_semaphore_t slots = dispatch_semaphore_create(slots_count);
    dispatch_group_t group = dispatch_group_create();
    progress(0, total);
    for (NSString *name in files) {
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        dispatch_group_async(group, dispatch_get_global_queue(qos, 0), ^{ @autoreleasepool {
            NSString *path = [directory stringByAppendingPathComponent:name];
            NSData *data = [NSData dataWithContentsOfFile:path];
            BOOL ok = data.length >= 4;
            if (ok && memcmp(data.bytes, "MTLB", 4)) {
                NSString *source = nil; NSError *issue = nil;
                id<MTLLibrary> library = shader_ir_load(device, path, data.bytes, data.length, false);
                if (!library) {
                    source = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    MTLCompileOptions *options = nil;
                    NSString *prepared = source ? zelda_shader_math(source, &options) : nil;
                    library = prepared ? [device newLibraryWithSource:prepared options:options error:&issue] : nil;
                }
                ok = library != nil;
                // These two generated vertex libraries use the same transformation at first draw.
                if (ok && layered_library(name)) {
                    library = shader_ir_load(device, path, data.bytes, data.length, true);
                    if (!library) {
                        source = source ?: [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                        NSString *layered = zelda_cube_source(source); MTLCompileOptions *options = nil;
                        NSString *prepared = layered ? zelda_shader_math(layered, &options) : nil;
                        library = prepared ? [device newLibraryWithSource:prepared options:options error:&issue] : nil;
                    }
                    ok = library != nil;
                }
                if (!ok && atomic_load(&failed) < 8)
                    fprintf(stderr, "SHADER_PREP failed %s: %s\n", name.UTF8String, issue.localizedDescription.UTF8String ?: "invalid source");
            }
            if (!ok) atomic_fetch_add(&failed, 1);
            shader_status_note(SHADER_STEP, 0);
            unsigned count = atomic_fetch_add(&complete, 1) + 1;
            if (count % 100 == 0 || count == total) progress(count, total);
            dispatch_semaphore_signal(slots);
        } });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    shader_status_note(SHADER_FINISHED, 0);
    return atomic_load(&failed);
}

unsigned shader_prep_run(id<MTLDevice> device, NSString *directory, void (^progress)(unsigned, unsigned)) {
    shader_status_note(SHADER_CHECKING, 0);
    NSArray<NSString *> *files = library_names(directory);
    if (!files) { fprintf(stderr, "SHADER_PREP cannot read shader directory\n"); shader_status_note(SHADER_FINISHED, 0); return 1; }
    if (!files.count) { fprintf(stderr, "SHADER_PREP no prepared libraries\n"); shader_status_note(SHADER_FINISHED, 0); return 1; }
    NSArray<NSString *> *pending = preparation_files(directory, files);
    fprintf(stderr, "SHADER_PREP plan available=%lu pending=%lu deferred_ir=%lu\n",
        (unsigned long)files.count, (unsigned long)pending.count, (unsigned long)(files.count - pending.count));
    unsigned failed = prep_files(device, directory, pending, 4, QOS_CLASS_USER_INITIATED, progress);
    shader_ir_report("prep");
    return failed;
}

ShaderScreenState shader_screen_state(bool prep_done, bool warm, unsigned runs_at_boot, ZeldaShaderStatus status) {
    ShaderScreenState state = {SCREEN_CHECKING, status.completed, status.total};
    if (!prep_done) {
        if (status.phase == SHADER_LIBRARIES && status.total) state.stage = SCREEN_COMPILING;
    } else if (!warm || status.runs > runs_at_boot) state.stage = SCREEN_READY;
    else if (status.phase == SHADER_CHECKING) state.stage = SCREEN_READING;
    else if (status.phase == SHADER_LIBRARIES) state.stage = SCREEN_LOADING;
    else if (status.phase == SHADER_PIPELINES) state.stage = status.total ? SCREEN_BUILDING : SCREEN_DESCRIBING;
    else state.stage = SCREEN_STARTING;   // the game boots until its first submission
    return state;
}

double shader_screen_advance(ShaderScreenBar *bar, ShaderScreenState state, double now) {
    // Each stage owns a share of what is left of the bar. Counted stages fill it by their counters; stages of unknown
    // length creep toward its end and slow down as they approach it, so the bar keeps moving and never goes back.
    static const double share[] = {0.25, 1.0, 0.35, 0.1, 0.45, 0.15, 1.0, 1.0};
    if ((int)state.stage != bar->stage) {
        bar->stage = (int)state.stage; bar->base = bar->fraction; bar->since = now;
        bar->span = (1.0 - bar->base) * (state.stage == SCREEN_COMPILING && bar->warm ? 0.85 : share[state.stage]);
    }
    double part;
    switch (state.stage) {
        case SCREEN_COMPILING: case SCREEN_LOADING: case SCREEN_BUILDING:
            part = state.total ? (double)state.completed / state.total : 0.0; break;
        case SCREEN_READY: part = 1.0; break;
        default: part = 1.0 - exp(-(now - bar->since) / 2.0);
    }
    bar->fraction = fmax(bar->fraction, bar->base + bar->span * part);
    return bar->fraction;
}

#if !TARGET_OS_IPHONE
// Same inputs as zelda_shader_warm: an enabled warm-up with a non-empty record of earlier shaders and pipelines.
static bool warm_expected(void) {
    const char *setting = getenv("ZELDA_SHADER_WARM"), *record = getenv("DM_PSO_USER"), *save = getenv("DM_SAVE");
    if (setting && !atoi(setting)) return false;
    NSString *path = record && *record ? @(record) : save && *save ?
        [@(save).stringByDeletingLastPathComponent stringByAppendingPathComponent:@"pso_user.tsv"] : nil;
    NSNumber *size = path ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileSize] : nil;
    return size.unsignedLongLongValue > 0;
}

@interface ZeldaShaderScreen : NSObject
- (instancetype)initInView:(NSView *)view;
- (void)prepFinished;
@end

@implementation ZeldaShaderScreen {
    NSView *_panel; NSTextField *_status; NSProgressIndicator *_bar, *_spinner; NSTimer *_timer;
    NSNumberFormatter *_digits; ZeldaShaderStatus _last; ShaderScreenBar _progress;
    bool _warm, _prep_done, _closing; unsigned _runs_at_boot; int _stage;
    double _shown; CFAbsoluteTime _opened, _tick, _changed;
}

- (instancetype)initInView:(NSView *)view {
    if (!(self = [super init])) return nil;
    _panel = [[NSView alloc] initWithFrame:view.bounds];
    _panel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _panel.wantsLayer = YES; _panel.layer.backgroundColor = NSColor.blackColor.CGColor;
    NSTextField *title = [NSTextField labelWithString:@"Preparing shaders"];
    title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold]; title.textColor = NSColor.whiteColor;
    _bar = [NSProgressIndicator new]; _bar.indeterminate = NO; _bar.minValue = 0; _bar.maxValue = 1000;
    _spinner = [NSProgressIndicator new]; _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeSmall; _spinner.usesThreadedAnimation = YES; [_spinner startAnimation:nil];
    // Fixed-width digits keep the counter from shifting while it changes.
    _status = [NSTextField labelWithString:@"Checking shader libraries…"];
    _status.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    _status.textColor = [NSColor colorWithWhite:0.9 alpha:1];
    NSStackView *row = [NSStackView stackViewWithViews:@[_spinner, _status]]; row.spacing = 8;
    NSTextField *notice = [NSTextField wrappingLabelWithString:
        @"First-time shader compilation can take a long time.\nPlease keep the app open. Later launches are usually faster."];
    notice.textColor = NSColor.lightGrayColor; notice.alignment = NSTextAlignmentCenter;
    for (NSView *child in @[title, _bar, row, notice]) { child.translatesAutoresizingMaskIntoConstraints = NO; [_panel addSubview:child]; }
    [NSLayoutConstraint activateConstraints:@[
        [_bar.centerXAnchor constraintEqualToAnchor:_panel.centerXAnchor], [_bar.centerYAnchor constraintEqualToAnchor:_panel.centerYAnchor],
        [_bar.widthAnchor constraintEqualToAnchor:_panel.widthAnchor multiplier:.6],
        [title.centerXAnchor constraintEqualToAnchor:_panel.centerXAnchor], [title.bottomAnchor constraintEqualToAnchor:_bar.topAnchor constant:-24],
        [row.centerXAnchor constraintEqualToAnchor:_panel.centerXAnchor], [row.topAnchor constraintEqualToAnchor:_bar.bottomAnchor constant:16],
        [notice.widthAnchor constraintEqualToAnchor:_panel.widthAnchor multiplier:.8],
        [notice.centerXAnchor constraintEqualToAnchor:_panel.centerXAnchor], [notice.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:20]]];
    [view addSubview:_panel];
    _digits = [NSNumberFormatter new]; _digits.numberStyle = NSNumberFormatterDecimalStyle;
    _warm = warm_expected(); _stage = -1; _opened = _tick = _changed = CFAbsoluteTimeGetCurrent();
    _progress = (ShaderScreenBar){.warm = _warm, .stage = -1};
    // Display-rate refresh in the common modes, so the bar keeps moving while the window is dragged or resized.
    // The timer holds the screen until the fade-out invalidates it.
    _timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *timer) { (void)timer; [self tick]; }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    return self;
}

- (void)prepFinished { _prep_done = true; _runs_at_boot = shader_status_snapshot().runs; }

- (NSString *)text:(ShaderScreenState)state {
    NSString *count = state.total ? [NSString stringWithFormat:@"  %@ / %@", [_digits stringFromNumber:@(state.completed)],
                                     [_digits stringFromNumber:@(state.total)]] : @"";
    switch (state.stage) {
        case SCREEN_CHECKING: return @"Checking shader libraries…";
        case SCREEN_COMPILING: return [@"Compiling shader libraries" stringByAppendingString:count];
        case SCREEN_STARTING: return @"Starting the game…";
        case SCREEN_READING: return @"Reading the pipeline record…";
        case SCREEN_LOADING: return [@"Loading shaders" stringByAppendingString:count];
        case SCREEN_DESCRIBING: return @"Preparing pipeline descriptions…";
        case SCREEN_BUILDING: return [@"Building pipelines" stringByAppendingString:count];
        case SCREEN_READY: return @"Ready";
    }
    return @"";
}

- (void)tick {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent(); double dt = fmin(now - _tick, 0.1); _tick = now;
    ZeldaShaderStatus status = shader_status_snapshot();
    ShaderScreenState state = shader_screen_state(_prep_done, _warm, _runs_at_boot, status);
    if (memcmp(&status, &_last, sizeof status)) { _last = status; _changed = now; }
    // A warm-up that never starts or stops reporting must not hide the game for good.
    if (_prep_done && state.stage != SCREEN_READY && now - _changed > (state.stage == SCREEN_STARTING ? 90 : 180)) {
        fprintf(stderr, "SHADER_SCREEN no warm-up progress for %.0f s; showing the game\n", now - _changed);
        state.stage = SCREEN_READY; _warm = false;
    }
    // The drawn bar eases toward the model so counter bursts and stage changes glide instead of jumping.
    double target = shader_screen_advance(&_progress, state, now - _opened);
    _shown += (target - _shown) * fmin(1.0, dt * (state.stage == SCREEN_READY ? 14 : 5));
    if (target - _shown < 0.0005) _shown = target;
    _bar.doubleValue = _shown * 1000;
    if ((int)state.stage != _stage) {
        static const char *names[] = {"checking", "compiling", "starting", "reading", "loading", "describing", "building", "ready"};
        fprintf(stderr, "SHADER_SCREEN stage=%s at=%.2f bar=%.3f\n", names[state.stage], now - _opened, _shown);
        _stage = (int)state.stage;
    }
    NSString *text = [self text:state];
    if (![text isEqualToString:_status.stringValue]) _status.stringValue = text;
    if (state.stage == SCREEN_READY && _shown >= 1.0 && !_closing) {
        _closing = true;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.35; self->_panel.animator.alphaValue = 0;
        } completionHandler:^{
            [self->_timer invalidate]; [self->_spinner stopAnimation:nil]; [self->_panel removeFromSuperview];
        }];
    }
}
@end

void shader_prep_begin(NSView *view, id<MTLDevice> device, dispatch_block_t done) {
    ZeldaShaderScreen *screen = [[ZeldaShaderScreen alloc] initInView:view];
    NSString *root = @(getenv("DM_MSL_DIR") ?: "work/shaders");
    NSString *directory = [root stringByAppendingPathComponent:@"b-" DMSH_CHAIN];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        fprintf(stderr, "SHADER_PREP begin chain=%s scope=needed\n", DMSH_CHAIN);
        unsigned failed = shader_prep_run(device, directory, ^(unsigned count, unsigned total) {
            if (count % 500 == 0 || count == total) fprintf(stderr, "SHADER_PREP progress=%u/%u\n", count, total);
        });
        fprintf(stderr, "SHADER_PREP end failed=%u seconds=%.3f\n", failed, CFAbsoluteTimeGetCurrent() - start);
        // Unused unsupported libraries must not block existing scenes; runtime requests still fail explicitly.
        dispatch_async(dispatch_get_main_queue(), ^{ [screen prepFinished]; done(); });
    } });
}
#endif
