// The platform CJK substitute needs a 190,560-byte contiguous glyph allocation. The game's 512 KiB
// font heap can no longer provide it after menu/cache churn, even after the SDK evicts cached glyphs.
// Keep the SDK renderer and give it owned workspace; the game's original allocation still belongs to its caller.
#include "hle.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#define FONT_WATCH "Track SDK font state and recover supported text glyphs using the installed shared face"
#define FONT_WORKSPACE "Use host-owned font workspace while preserving the caller-owned buffer and SDK lifetime"
enum { ENGINES = 16, FONT_WORK_BYTES = 4 << 20 };
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static struct { void *engine, *original_work, *owned_work; char font[64], fallback[64]; int scale[4]; } engines[ENGINES];

static void *sdk(const char *name) {
    void *function = guest_sym(name);
    if (!function) die("fontll symbol missing: %s", name);
    return function;
}
static int slot(void *engine) {
    int free = -1;
    for (int i = 0; i < ENGINES; i++) {
        if (engines[i].engine == engine) return i;
        if (!engines[i].engine && free < 0) free = i;
    }
    if (free >= 0) engines[free].engine = engine;
    return free;
}

HLE_FORCE("_ZN2nn6fontll18ScalableFontEngine10InitializeEPvj", FONT_WORKSPACE,
          uint32_t, font_initialize, void *engine, void *work, uint32_t size) {
    static uint32_t (*initialize)(void *, void *, uint32_t);
    if (!initialize) initialize = sdk("_ZN2nn6fontll18ScalableFontEngine10InitializeEPvj");
    // Leave invalid/undersized inputs to the SDK. Its allocator header alone occupies 0x41d0 bytes.
    void *owned = work && size >= 0x4200 && size < FONT_WORK_BYTES ? calloc(1, FONT_WORK_BYTES) : NULL;
    if (work && size >= 0x4200 && size < FONT_WORK_BYTES && !owned) die("Font workspace allocation failed");
    pthread_mutex_lock(&lock);
    int i = slot(engine);
    if (i < 0 || engines[i].owned_work) die("Font workspace ownership limit or missing Finalize");
    engines[i] = (typeof(engines[i])){.engine = engine, .original_work = work, .owned_work = owned};
    pthread_mutex_unlock(&lock);
    uint32_t result = initialize(engine, owned ? owned : work, owned ? FONT_WORK_BYTES : size);
    if (result) {
        pthread_mutex_lock(&lock); engines[i].owned_work = NULL; pthread_mutex_unlock(&lock);
        free(owned);
    }
    if (owned) fprintf(stderr, "FONT workspace engine=%p original_bytes=%u host_bytes=%u result=%#x\n", engine, size, FONT_WORK_BYTES, result);
    return result;
}
HLE_FORCE("_ZN2nn6fontll18ScalableFontEngine22GetPointerToWorkBufferEv", FONT_WORKSPACE,
          void *, font_work, void *engine) {
    // v1.4.3's two callers save this pointer, Finalize, then free it through their own allocator.
    pthread_mutex_lock(&lock);
    for (int i = 0; i < ENGINES; i++) if (engines[i].engine == engine) {
        void *work = engines[i].original_work; pthread_mutex_unlock(&lock); return work;
    }
    pthread_mutex_unlock(&lock);
    static void *(*get)(void *);
    if (!get) get = sdk("_ZN2nn6fontll18ScalableFontEngine22GetPointerToWorkBufferEv");
    return get(engine);
}
HLE_FORCE("_ZN2nn6fontll18ScalableFontEngine8FinalizeEv", FONT_WORKSPACE,
          uint32_t, font_finalize, void *engine) {
    static uint32_t (*finalize)(void *);
    if (!finalize) finalize = sdk("_ZN2nn6fontll18ScalableFontEngine8FinalizeEv");
    uint32_t result = finalize(engine);
    if (!result) {
        void *owned = NULL;
        pthread_mutex_lock(&lock);
        for (int i = 0; i < ENGINES; i++) if (engines[i].engine == engine) {
            owned = engines[i].owned_work; engines[i] = (typeof(engines[i])){0}; break;
        }
        pthread_mutex_unlock(&lock);
        free(owned);
    }
    return result;
}

HLE_FORCE("_ZN2nn6fontll18ScalableFontEngine8LoadFontEPcPKvjj", FONT_WATCH,
          uint32_t, font_load, void *engine, char *name, const void *data, uint32_t size, uint32_t index) {
    static uint32_t (*load)(void *, char *, const void *, uint32_t, uint32_t);
    if (!load) load = sdk("_ZN2nn6fontll18ScalableFontEngine8LoadFontEPcPKvjj");
    uint32_t result = load(engine, name, data, size, index);
    if (!result && name && *name && strlen(name) < sizeof engines[0].fallback) {
        pthread_mutex_lock(&lock);
        int i = slot(engine);
        // The game's Symbol face loads first; only the installed shared substitute is a text fallback.
        if (i >= 0 && !strcmp(name, "AppleGothic Regular")) strcpy(engines[i].fallback, name);
        pthread_mutex_unlock(&lock);
    }
    fprintf(stderr, "FONT load engine=%p name=%.63s bytes=%u index=%u result=%#x\n", engine, name ? name : "", size, index, result);
    return result;
}
HLE_FORCE("_ZN2nn6fontll18ScalableFontEngine7SetFontEPc", FONT_WATCH, uint32_t, font_set, void *engine, char *name) {
    static uint32_t (*set)(void *, char *);
    if (!set) set = sdk("_ZN2nn6fontll18ScalableFontEngine7SetFontEPc");
    uint32_t result = set(engine, name);
    if (result) return result;
    pthread_mutex_lock(&lock);
    int i = slot(engine);
    if (i >= 0) {
        // An unrecordable name must not be truncated and later used to restore the SDK selection.
        engines[i].font[0] = 0;
        if (name && strlen(name) < sizeof engines[i].font) strcpy(engines[i].font, name);
    }
    pthread_mutex_unlock(&lock);
    return result;
}
HLE_FORCE("_ZN2nn6fontll18ScalableFontEngine8SetScaleEiiii", FONT_WATCH,
          uint32_t, font_scale, void *engine, int a, int b, int c, int d) {
    static uint32_t (*scale)(void *, int, int, int, int);
    if (!scale) scale = sdk("_ZN2nn6fontll18ScalableFontEngine8SetScaleEiiii");
    uint32_t result = scale(engine, a, b, c, d);
    if (result) return result;
    pthread_mutex_lock(&lock);
    int i = slot(engine);
    if (i >= 0) { engines[i].scale[0] = a; engines[i].scale[1] = b; engines[i].scale[2] = c; engines[i].scale[3] = d; }
    pthread_mutex_unlock(&lock);
    return result;
}
HLE_FORCE("_ZN2nn6fontll18ScalableFontEngine15AcquireGlyphmapEjt", FONT_WATCH,
          void *, font_glyph, void *engine, uint32_t code, uint32_t format) {
    static void *(*acquire)(void *, uint32_t, uint32_t);
    static uint32_t (*error)(void *);
    if (!acquire) { acquire = sdk("_ZN2nn6fontll18ScalableFontEngine15AcquireGlyphmapEjt"); error = sdk("_ZN2nn6fontll18ScalableFontEngine8GetErrorEv"); }
    format &= 0xffff; // uint16_t from Switch code: upper bits are not defined
    void *glyph = acquire(engine, code, format);
    if (!glyph) {
        static int reported;
        uint32_t original_error = error(engine);
        char original[64] = {0}, fallback[64] = {0}; int saved_scale[4] = {0};
        pthread_mutex_lock(&lock);
        int i = slot(engine);
        if (i >= 0) {
            memcpy(original, engines[i].font, sizeof original);
            memcpy(fallback, engines[i].fallback, sizeof fallback);
            memcpy(saved_scale, engines[i].scale, sizeof saved_scale);
        }
        if (reported++ < 32)
            fprintf(stderr, "FONT glyph failed engine=%p font=%s code=U+%04X format=%u scale=%d,%d,%d,%d error=%#x\n", engine,
                    i >= 0 ? engines[i].font : "?", code, format, i >= 0 ? engines[i].scale[0] : 0, i >= 0 ? engines[i].scale[1] : 0,
                    i >= 0 ? engines[i].scale[2] : 0, i >= 0 ? engines[i].scale[3] : 0, original_error);
        pthread_mutex_unlock(&lock);
        // Keep the same Unicode character, engine/cache and release protocol. Never return a missing-glyph box.
        int private_code = (code >= 0xe000 && code <= 0xf8ff) || (code >= 0xf0000 && code <= 0x10fffd);
        if (original[0] && fallback[0] && strcmp(original, fallback) && !private_code &&
            (original_error == 0xc9 || original_error == 0x20c) &&
            (saved_scale[0] || saved_scale[1] || saved_scale[2] || saved_scale[3])) {
            const uint32_t *getter = sdk("FS_error");
            // Exact v1.4.3 getter (ldr w0,[x0,#0x48]; ret) proves where to preserve the error after a failed retry.
            if (getter[0] == 0xb9404800 && getter[1] == 0xd65f03c0) {
                uint32_t (*exists)(void *, uint32_t) = sdk("_ZN2nn6fontll18ScalableFontEngine15CheckGlyphExistEj");
                if (!font_set(engine, fallback)) {
                    if (!font_scale(engine, saved_scale[0], saved_scale[1], saved_scale[2], saved_scale[3]) && exists(engine, code))
                        glyph = acquire(engine, code, format);
                }
                if (font_set(engine, original) || font_scale(engine, saved_scale[0], saved_scale[1], saved_scale[2], saved_scale[3]))
                    die("Font selection could not be restored after glyph recovery");
                uint32_t result = glyph ? 0 : original_error;
                memcpy((uint8_t *)engine + 0x48, &result, sizeof result);
                if (glyph) fprintf(stderr, "FONT glyph recovered engine=%p code=U+%04X font=%s fallback=%s\n", engine, code, original, fallback);
            }
        }
    }
    return glyph;
}
