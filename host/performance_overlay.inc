#include "performance.h"
#include "game_timing.h"
#include "audio.h"
#include <mach/mach.h>
#include "thread_census.inc"

// Compact floating panel: on-screen FPS, a frame-time curve and the few numbers that explain it. Dragging anywhere moves
// it; it takes no clicks otherwise. Keys never reach it (the window monitor forwards them to the guest), so it cannot
// take input focus from the game. Visibility is a saved setting (control panel, menu or Command-P).
@interface ZeldaPerformancePanel : NSView { NSPoint drag_offset; }
@end
@implementation ZeldaPerformancePanel
- (NSView *)hitTest:(NSPoint)point { return [super hitTest:point] ? self : nil; }
- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self.superview convertPoint:event.locationInWindow fromView:nil];
    drag_offset = NSMakePoint(p.x - self.frame.origin.x, p.y - self.frame.origin.y);
}
- (void)mouseDragged:(NSEvent *)event {
    NSPoint p = [self.superview convertPoint:event.locationInWindow fromView:nil];
    NSRect area = self.superview.bounds;
    [self setFrameOrigin:NSMakePoint(MAX(0, MIN(p.x - drag_offset.x, area.size.width - self.frame.size.width)),
        MAX(0, MIN(p.y - drag_offset.y, area.size.height - self.frame.size.height)))];
}
@end

// Frame-time curve of the last 120 rendered frames: frame interval (white) and GPU time (cyan) against the
// target frame time (dashed). The scale is 0-40 ms; longer frames are clipped and marked red at the top.
enum { GRAPH_FRAMES = 120 };
static double graph_target_ms = 1000.0 / 60;
@interface ZeldaFrameGraph : NSView
@end
@implementation ZeldaFrameGraph
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    NSRect r = self.bounds;
    [[NSColor colorWithWhite:1 alpha:0.06] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:3 yRadius:3] fill];
    float interval[GRAPH_FRAMES], gpu[GRAPH_FRAMES];
    unsigned n = performance_history(interval, gpu, GRAPH_FRAMES);
    const double top = 40, inset = 2, h = r.size.height - 2 * inset, step = r.size.width / (GRAPH_FRAMES - 1);
    double (^y)(double) = ^double(double ms) { return inset + h * MIN(MAX(ms, 0), top) / top; };
    NSBezierPath *target = [NSBezierPath bezierPath];
    [target moveToPoint:NSMakePoint(0, y(graph_target_ms))]; [target lineToPoint:NSMakePoint(r.size.width, y(graph_target_ms))];
    CGFloat dash[] = {3, 3}; [target setLineDash:dash count:2 phase:0]; target.lineWidth = 1;
    [[NSColor.systemGreenColor colorWithAlphaComponent:0.7] setStroke]; [target stroke];
    NSDictionary *small = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8 weight:NSFontWeightMedium],
                            NSForegroundColorAttributeName: [NSColor colorWithWhite:1 alpha:0.55]};
    if (n >= 2) {
        double x0 = (GRAPH_FRAMES - n) * step;
        for (int series = 1; series >= 0; series--) {
            const float *values = series ? gpu : interval;
            NSBezierPath *line = [NSBezierPath bezierPath]; BOOL open = NO;
            for (unsigned i = 0; i < n; i++) {
                if (values[i] < 0) { open = NO; continue; }
                NSPoint point = NSMakePoint(x0 + i * step, y(values[i]));
                if (open) [line lineToPoint:point]; else [line moveToPoint:point];
                open = YES;
            }
            line.lineWidth = series ? 1.25 : 1.5; line.lineJoinStyle = NSLineJoinStyleRound;
            [(series ? [NSColor.systemTealColor colorWithAlphaComponent:0.9] : NSColor.whiteColor) setStroke]; [line stroke];
        }
        [NSColor.systemRedColor setFill];
        for (unsigned i = 0; i < n; i++) if (interval[i] > top) NSRectFill(NSMakeRect(x0 + i * step - 1, r.size.height - 3, 2, 3));
    }
    // The target label sits on a small backing plate so the curve never hides it; the 0-40 ms scale is in the tooltip.
    NSString *label = [NSString stringWithFormat:@"%.1f", graph_target_ms];
    NSSize size = [label sizeWithAttributes:small];
    double height = MIN(MAX(y(graph_target_ms) - size.height / 2, 1), r.size.height - size.height - 1);
    [[NSColor colorWithWhite:0.08 alpha:0.85] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(2, height - 0.5, size.width + 4, size.height + 1) xRadius:2 yRadius:2] fill];
    [label drawAtPoint:NSMakePoint(4, height) withAttributes:small];
}
@end

enum { PERF_VALUES = 6 };
static NSView *perf_panel, *perf_graph;
static NSTextField *perf_fps, *perf_state, *perf_values[PERF_VALUES];
static NSString *perf_normal_state;
static NSColor *perf_normal_state_color;
static NSTimer *perf_timer, *perf_graph_timer;
static FILE *perf_log;

static NSColor *perf_secondary(void) { return [NSColor colorWithWhite:1 alpha:0.62]; }
static NSTextField *perf_text(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont monospacedDigitSystemFontOfSize:size weight:weight];
    field.textColor = color; field.lineBreakMode = NSLineBreakByClipping;
    return field;
}
static NSString *perf_ms(double ms) { return ms >= 0 ? [NSString stringWithFormat:@"%.1f ms", ms] : @"—"; }

static void performance_update_shader_status(void) {
    ZeldaShaderStatus status = shader_status_snapshot();
    NSString *text = nil, *detail = nil;
    if (status.phase == SHADER_CHECKING) text = @"Checking shaders";
    else if (status.phase == SHADER_LIBRARIES || status.phase == SHADER_PIPELINES) {
        NSString *kind = status.phase == SHADER_LIBRARIES ? @"Shaders" : @"Pipelines";
        text = status.total ? [NSString stringWithFormat:@"%@ %u%%", kind, (unsigned)(100ull * status.completed / status.total)] : @"Warming up";
        if (status.total) detail = [NSString stringWithFormat:@"%@ warmup: %u / %u", kind, status.completed, status.total];
    } else if (status.active_builds) text = @"Compiling shaders";
    NSString *shown = text ?: perf_normal_state ?: @"Waiting";
    if (![perf_state.stringValue isEqualToString:shown]) perf_state.stringValue = shown;
    perf_state.toolTip = detail ?: text;
    perf_state.accessibilityValue = detail ?: perf_state.stringValue;
    perf_state.textColor = text ? NSColor.systemTealColor : perf_normal_state_color ?: perf_secondary();
}

static void performance_update(void) {
    thread_census_tick();
    NSWindow *window = perf_panel.window;
    unsigned state_flags = NSApp.active | (window.keyWindow << 1) | (window.visible << 2) |
        (!!(window.occlusionState & NSWindowOcclusionStateVisible) << 3);
    static unsigned previous_flags = UINT_MAX;
    if (state_flags != previous_flags) {
        LOG("PRESENTATION active=%u key=%u visible=%u unoccluded=%u display_hz=%ld", state_flags & 1,
            (state_flags >> 1) & 1, (state_flags >> 2) & 1, (state_flags >> 3) & 1, (long)window.screen.maximumFramesPerSecond);
        previous_flags = state_flags;
    }
    ZeldaPerformance p;
    BOOL ready = performance_snapshot(&p);
    double age = p.last_rendered ? MAX(0, now_ns() / 1e9 - p.last_rendered) : 0;
    double fps = ready && age < 1 ? p.render_fps : 0;
    struct task_vm_info info = {0}; mach_msg_type_number_t size = TASK_VM_INFO_COUNT;
    double memory = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &size) == KERN_SUCCESS ? info.phys_footprint / 1073741824.0 : 0;
    double gpu_memory = metal_layer.device.currentAllocatedSize / 1073741824.0;
    NSString *thermal[] = {@"", @"Warm", @"Hot", @"Critical"};
    NSInteger heat = MIN(MAX(NSProcessInfo.processInfo.thermalState, 0), 3);
    BOOL has_present = p.last_presented && CACurrentMediaTime() - p.last_presented < 1 && p.fps >= 0;
    NSString *policy = p.pacing_fps <= 0 ? @"Uncapped" : [NSString stringWithFormat:@"%@ %.0f", p.pacing_override ? @"Forced" : @"Target", p.pacing_fps];
    NSString *state = !ready ? @"Waiting" : age >= 1 ? [NSString stringWithFormat:@"Stalled %.1f s", age] : policy;
    if (heat) state = [state stringByAppendingFormat:@" · %@", thermal[heat]];
    double target = p.pacing_fps > 0 ? p.pacing_fps : 60;
    graph_target_ms = 1000 / target;
    // The headline is what reaches the screen; without presentation receipts it falls back to the render rate.
    double shown = has_present && fps > 0 ? p.fps : fps;
    perf_fps.stringValue = shown > 0 ? [NSString stringWithFormat:@"%.1f", shown] : @"—";
    perf_fps.textColor = shown <= 0 ? perf_secondary() : shown >= target - 2 ? NSColor.systemGreenColor :
        shown >= target * 0.75 ? NSColor.systemYellowColor : NSColor.systemOrangeColor;
    perf_normal_state = state;
    perf_normal_state_color = heat >= 2 ? NSColor.systemOrangeColor : perf_secondary();
    performance_update_shader_status();
    double average = shown > 0 ? 1000 / shown : -1, p95 = has_present ? p.frame_p95_ms : p.render_p95_ms;
    NSString *values[PERF_VALUES] = {
        perf_ms(ready ? average : -1), perf_ms(ready ? p95 : -1),
        perf_ms(ready ? p.gpu_ms : -1), perf_ms(ready ? p.submit_cpu_ms : -1),
        p.render_width ? [NSString stringWithFormat:@"%u×%u", p.render_width, p.render_height] : @"—",
        [NSString stringWithFormat:@"%.1f GiB", memory],
    };
    for (int i = 0; i < PERF_VALUES; i++) perf_values[i].stringValue = values[i];
    if (perf_log) {
        fprintf(perf_log, "%.3f\t%llu\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.3f\t%.1f\t%.3f\t%llu\t%ld\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%.6f\n",
            CACurrentMediaTime(), (unsigned long long)p.frame, has_present ? p.fps : -1, p.frame_p95_ms, p.gpu_ms, p.submit_cpu_ms,
            memory, gpu_memory, p.draws, p.upload_mb, (unsigned long long)p.dropped, (long)heat, age, fps, p.render_p95_ms, p.pacing_fps, p.pacing_override, zelda_game_seconds());
        fflush(perf_log);
    }
}
static void performance_start(NSWindow *window, bool visible) {
    const CGFloat width = 216, margin = 10, inner = width - 20;
    ZeldaPerformancePanel *panel = [[ZeldaPerformancePanel alloc] initWithFrame:NSMakeRect(0, 0, width, 100)];
    perf_panel = panel;
    perf_panel.wantsLayer = YES; perf_panel.layer.backgroundColor = [NSColor colorWithWhite:0.03 alpha:0.78].CGColor;
    perf_panel.layer.cornerRadius = 8;
    perf_panel.accessibilityLabel = @"Performance overlay";
    perf_panel.toolTip = @"Drag to move · ⌘P to hide";

    perf_fps = perf_text(@"—", 20, NSFontWeightSemibold, perf_secondary());
    NSTextField *unit = perf_text(@"FPS", 10, NSFontWeightMedium, perf_secondary());
    perf_state = perf_text(@"Waiting", 10, NSFontWeightMedium, perf_secondary());
    perf_state.alignment = NSTextAlignmentRight;
    NSStackView *header = [NSStackView stackViewWithViews:@[perf_fps, unit, perf_state]];
    header.alignment = NSLayoutAttributeFirstBaseline; header.spacing = 3; header.distribution = NSStackViewDistributionFill;
    [header setCustomSpacing:6 afterView:unit];
    // The status absorbs the free width and stays right-aligned.
    for (NSView *view in @[perf_fps, unit]) [view setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [perf_state setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    perf_graph = [[ZeldaFrameGraph alloc] initWithFrame:NSMakeRect(0, 0, inner, 36)];
    perf_graph.accessibilityLabel = @"Frame-time graph";
    perf_graph.toolTip = @"Last 120 frames, 0–40 ms: white is frame interval, cyan is GPU time, and the dashed green line is the target. Frames over 40 ms are marked red at the top.";
    [perf_graph.heightAnchor constraintEqualToConstant:36].active = YES;

    // Two label/value pairs per row; the frame and GPU labels take the colors of their curves and double as the legend.
    NSString *labels[PERF_VALUES] = {@"Time", @"p95", @"GPU", @"CPU", @"Res", @"RAM"};
    NSColor *label_colors[PERF_VALUES] = {NSColor.whiteColor, perf_secondary(), NSColor.systemTealColor, perf_secondary(), perf_secondary(), perf_secondary()};
    NSMutableArray<NSArray<NSView *> *> *rows = [NSMutableArray array];
    for (int row = 0; row < PERF_VALUES / 2; row++) {
        NSMutableArray<NSView *> *cells = [NSMutableArray array];
        for (int i = 2 * row; i < 2 * row + 2; i++) {
            perf_values[i] = perf_text(@"—", 11, NSFontWeightMedium, NSColor.whiteColor);
            perf_values[i].alignment = NSTextAlignmentRight;
            [cells addObject:perf_text(labels[i], 10, NSFontWeightRegular, label_colors[i])]; [cells addObject:perf_values[i]];
        }
        [rows addObject:cells];
    }
    perf_values[0].toolTip = @"Average interval between presented frames; uses render intervals when presentation receipts are unavailable.";
    perf_values[3].toolTip = @"CPU time spent translating and submitting game graphics commands to Metal.";
    perf_values[4].toolTip = @"Internal render size; the game may lower it under load.";
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.rowSpacing = 2; grid.columnSpacing = 4;
    // Fixed columns: values change every second and must not move the layout.
    const CGFloat columns[] = {24, 70, 28, 56};
    for (int i = 0; i < 4; i++) {
        [grid columnAtIndex:i].width = columns[i];
        [grid columnAtIndex:i].xPlacement = i & 1 ? NSGridCellPlacementTrailing : NSGridCellPlacementLeading;
    }
    [grid columnAtIndex:1].trailingPadding = 6;

    NSStackView *stack = [NSStackView stackViewWithViews:@[header, perf_graph, grid]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical; stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 5; stack.edgeInsets = NSEdgeInsetsMake(6, 10, 8, 10);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [perf_panel addSubview:stack];
    for (NSView *view in @[header, perf_graph]) [view.widthAnchor constraintEqualToConstant:inner].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:perf_panel.leadingAnchor], [stack.trailingAnchor constraintEqualToAnchor:perf_panel.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:perf_panel.topAnchor], [stack.widthAnchor constraintEqualToConstant:width]]];
    // The panel itself is frame-placed (draggable); its height follows the content once.
    NSSize content = stack.fittingSize;
    NSSize area = window.contentView.bounds.size;
    perf_panel.frame = NSMakeRect(area.width - width - margin, area.height - content.height - margin, width, content.height);
    perf_panel.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    perf_panel.hidden = !visible;
    [window.contentView addSubview:perf_panel];

    perf_log = fopen("work/logs/performance.tsv", "w");
    if (perf_log) fputs("time_s\tframe\tfps\tp95_ms\tgpu_ms\tsubmit_cpu_ms\tphysical_gb\tgpu_gb\tdraws\tupload_mb\tdropped\tthermal\tstale_s\trender_fps\trender_p95_ms\tpacing_fps\tpacing_override\tgame_seconds\n", perf_log);
    else LOG("cannot open performance.tsv");
    performance_update();
    perf_timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { (void)timer; performance_update(); }];
    // The curve redraws at 10 Hz; numbers stay at 1 Hz so they remain readable.
    perf_graph_timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        (void)timer; if (!perf_panel.hidden) { perf_graph.needsDisplay = YES; performance_update_shader_status(); } }];
    [NSRunLoop.mainRunLoop addTimer:perf_timer forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:perf_graph_timer forMode:NSRunLoopCommonModes];
}
static void performance_set_visible(bool visible) { perf_panel.hidden = !visible; }
static bool performance_visible(void) { return perf_panel && !perf_panel.hidden; }
static void performance_stop(void) {
    [perf_timer invalidate]; perf_timer = nil;
    [perf_graph_timer invalidate]; perf_graph_timer = nil;
    if (perf_log) fclose(perf_log); perf_log = NULL;
}
