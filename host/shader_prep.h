#pragma once
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#if !TARGET_OS_IPHONE
#import <AppKit/AppKit.h>
#endif
#import <Metal/Metal.h>
#include <stdbool.h>
#include "shader_status.h"
// A verified macOS IR library, or nil so the caller can compile the original source.
id<MTLLibrary> shader_ir_load(id<MTLDevice> device, NSString *source_path, const void *source, size_t length, bool layered);
void shader_ir_report(const char *phase);
// Compile source libraries before the guest starts, using the runtime's exact transforms/options.
unsigned shader_prep_run(id<MTLDevice> device, NSString *directory, void (^progress)(unsigned, unsigned));
#if !TARGET_OS_IPHONE
void shader_prep_begin(NSView *view, id<MTLDevice> device, dispatch_block_t done);
#endif
