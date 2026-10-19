#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include "shader_ir_identity.h"

static _Atomic uint64_t ir_hits, ir_missing, ir_rejected, ir_failed;
static _Atomic uint64_t ir_metadata_ns, ir_verify_ns, ir_library_ns;

static BOOL ir_enabled(void) {
    const char *setting = getenv("ZELDA_SHADER_IR");
    return !setting || atoi(setting);
}

static NSString *ir_directory(NSString *source_dir) {
    // Keep the existing cache identity; unified Metal libraries also load on our iOS 26 minimum.
    return [[[source_dir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"ir-macos"]
        stringByAppendingPathComponent:source_dir.lastPathComponent] stringByAppendingPathComponent:@ZELDA_SHADER_IR_CONTRACT];
}

static NSString *ir_hash(const void *bytes, size_t length) {
    if (length > UINT32_MAX) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH]; char text[65];
    CC_SHA256(bytes, (CC_LONG)length, hash);
    for (unsigned i = 0; i < sizeof hash; i++) snprintf(text + i * 2, 3, "%02x", hash[i]);
    return @(text);
}

id<MTLLibrary> shader_ir_load(id<MTLDevice> device, NSString *source_path, const void *source, size_t length, bool layered) {
    if (!ir_enabled() || !device || !source || !length) return nil;
    uint64_t begin = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    NSString *directory = ir_directory(source_path.stringByDeletingLastPathComponent);
    NSString *name = [source_path.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:layered ? @"-cube" : @""];
    NSString *base = [directory stringByAppendingPathComponent:name];
    int fd = open([base stringByAppendingString:@".json"].fileSystemRepresentation, O_RDONLY);
    if (fd < 0) { atomic_fetch_add(&ir_missing, 1); return nil; }
    char metadata[4096]; ssize_t count = read(fd, metadata, sizeof metadata); close(fd);
    id record = count > 0 && (size_t)count < sizeof metadata ? [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithBytes:metadata length:(NSUInteger)count] options:0 error:nil] : nil;
    uint64_t parsed = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    BOOL valid = [record isKindOfClass:NSDictionary.class] && [record[@"format"] isEqual:@1] &&
        [record[@"contract"] isEqual:@ZELDA_SHADER_IR_CONTRACT] && [record[@"target"] isEqual:@"air64-apple-macosx26.0"] &&
        [record[@"language"] isEqual:@"metal3.2"] &&
        [record[@"layered"] isEqual:@(layered)] && [record[@"source_sha256"] isEqual:ir_hash(source, length)];
    if (!valid) { atomic_fetch_add(&ir_rejected, 1); return nil; }
    fd = open([base stringByAppendingString:@".metallib"].fileSystemRepresentation, O_RDONLY);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size < 4 || info.st_size > (64 << 20)) {
        if (fd >= 0) close(fd);
        atomic_fetch_add(&ir_rejected, 1); return nil;
    }
    size_t size = (size_t)info.st_size;
    void *bytes = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0); close(fd);
    if (bytes == MAP_FAILED) { atomic_fetch_add(&ir_rejected, 1); return nil; }
    if (memcmp(bytes, "MTLB", 4) || ![record[@"binary_sha256"] isEqual:ir_hash(bytes, size)]) {
        munmap(bytes, size); atomic_fetch_add(&ir_rejected, 1); return nil;
    }
    dispatch_data_t data = dispatch_data_create(bytes, size, nil, ^{ munmap(bytes, size); });
    uint64_t verified = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    id<MTLLibrary> library = [device newLibraryWithData:data error:nil];
    atomic_fetch_add(&ir_metadata_ns, parsed - begin);
    atomic_fetch_add(&ir_verify_ns, verified - parsed);
    atomic_fetch_add(&ir_library_ns, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - verified);
    atomic_fetch_add(library ? &ir_hits : &ir_failed, 1);
    return library;
}

void shader_ir_report(const char *phase) {
    fprintf(stderr, "SHADER_IR phase=%s hits=%llu missing=%llu rejected=%llu load_failed=%llu metadata_worker_ms=%.1f verify_worker_ms=%.1f library_worker_ms=%.1f\n", phase,
        (unsigned long long)atomic_load(&ir_hits), (unsigned long long)atomic_load(&ir_missing),
        (unsigned long long)atomic_load(&ir_rejected), (unsigned long long)atomic_load(&ir_failed),
        atomic_load(&ir_metadata_ns) / 1e6, atomic_load(&ir_verify_ns) / 1e6, atomic_load(&ir_library_ns) / 1e6);
}
