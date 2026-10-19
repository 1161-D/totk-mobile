#include "shader_prep.h"
#import <QuartzCore/QuartzCore.h>
#include "nvn_shader_math.h"
#include "nvn_cube_source.h"
#include "dmsh_chain.h"
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

#if !TARGET_OS_IPHONE
void shader_prep_begin(NSView *view, id<MTLDevice> device, dispatch_block_t done) {
    NSView *panel = [[NSView alloc] initWithFrame:view.bounds];
    panel.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    panel.wantsLayer = YES; panel.layer.backgroundColor = NSColor.blackColor.CGColor;
    NSTextField *title = [NSTextField labelWithString:@"Preparing shaders"];
    NSString *notice = @"First-time shader compilation can take a long time.\nPlease keep the app open. Later launches are usually faster.";
    NSTextField *detail = [NSTextField wrappingLabelWithString:notice];
    NSProgressIndicator *bar = [NSProgressIndicator new]; bar.indeterminate = NO;
    for (NSView *child in @[title, detail, bar]) { child.translatesAutoresizingMaskIntoConstraints = NO; [panel addSubview:child]; }
    title.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold]; title.textColor = NSColor.whiteColor;
    detail.textColor = NSColor.lightGrayColor; detail.alignment = NSTextAlignmentCenter;
    [NSLayoutConstraint activateConstraints:@[
        [bar.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor], [bar.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],
        [bar.widthAnchor constraintEqualToAnchor:panel.widthAnchor multiplier:.6],
        [title.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor], [title.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-24],
        [detail.widthAnchor constraintEqualToAnchor:panel.widthAnchor multiplier:.8],
        [detail.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor], [detail.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:20]]];
    [view addSubview:panel];
    NSString *root = @(getenv("DM_MSL_DIR") ?: "work/shaders");
    NSString *directory = [root stringByAppendingPathComponent:@"b-" DMSH_CHAIN];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool {
        CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        fprintf(stderr, "SHADER_PREP begin chain=%s scope=needed\n", DMSH_CHAIN);
        unsigned failed = shader_prep_run(device, directory, ^(unsigned count, unsigned total) {
            if (count % 500 == 0 || count == total) fprintf(stderr, "SHADER_PREP progress=%u/%u\n", count, total);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (count < bar.doubleValue) return;
                bar.maxValue = total ?: 1; bar.doubleValue = total ? count : 1;
                detail.stringValue = total ? [NSString stringWithFormat:@"%u / %u · The game will start when preparation finishes\n\n%@", count, total, notice] : @"Loading prepared shader libraries";
            });
        });
        fprintf(stderr, "SHADER_PREP end failed=%u seconds=%.3f\n", failed, CFAbsoluteTimeGetCurrent() - start);
        // Unused unsupported libraries must not block existing scenes; runtime requests still fail explicitly.
        dispatch_async(dispatch_get_main_queue(), ^{ [panel removeFromSuperview]; done(); });
    } });
}
#endif
