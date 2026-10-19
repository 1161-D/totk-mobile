#include <assert.h>
#include <stdlib.h>
#include <stdint.h>
static void *tracked;
static unsigned allocations, releases;
static void *workspace_calloc(size_t n, size_t size) {
    assert(!tracked); tracked = calloc(n, size); assert(tracked); allocations++; return tracked;
}
static void workspace_free(void *p) {
    if (!p) return;
    assert(p == tracked); releases++; free(p); tracked = NULL;
}
#define calloc workspace_calloc
#define free workspace_free
#include "../host/font_watch.c"
#undef calloc
#undef free

static uint8_t engine[0xc0];
static void *sdk_work;
static uint32_t sdk_size, init_status, final_status;
static unsigned finalized;
static char selected[128];
static unsigned glyph_calls, glyph_format, shared_has_glyph = 1;
static int fallback_scale_error;
static int glyph_token;
static void set_error(uint32_t value) { memcpy(engine + 0x48, &value, 4); }
static uint32_t error_stub(void *e) { assert(e == engine); uint32_t value; memcpy(&value, engine + 0x48, 4); return value; }
static uint32_t load_stub(void *e, char *name, const void *data, uint32_t size, uint32_t index) {
    (void)name; (void)data; (void)size; (void)index; assert(e == engine); return 0;
}
static uint32_t set_stub(void *e, char *name) { assert(e == engine); snprintf(selected, sizeof selected, "%s", name); set_error(0); return 0; }
static uint32_t scale_stub(void *e, int a, int b, int c, int d) {
    (void)a; (void)b; (void)c; (void)d; assert(e == engine);
    uint32_t result = fallback_scale_error && !strcmp(selected, "AppleGothic Regular") ? 0x201 : 0;
    set_error(result); return result;
}
static uint32_t exists_stub(void *e, uint32_t code) { assert(e == engine && code == 0x84cb); return shared_has_glyph; }
static void *glyph_stub(void *e, uint32_t code, uint32_t format) {
    assert(e == engine && (code == 0x84cb || code == 0xe37f)); glyph_calls++; glyph_format = format;
    if (!strcmp(selected, "AppleGothic Regular") && shared_has_glyph) { set_error(0); return &glyph_token; }
    set_error(0x20c); return NULL;
}
static uint32_t initialize_stub(void *e, void *w, uint32_t n) {
    assert(e == engine); sdk_work = w; sdk_size = n;
    if (!init_status && w && n) ((uint8_t *)w)[0] = 0x5a;
    return init_status;
}
static void *work_stub(void *e) { assert(e == engine); return sdk_work; }
static uint32_t finalize_stub(void *e) {
    assert(e == engine);
    // The SDK still needs its storage while Finalize is running.
    if (sdk_work && !init_status) assert(((uint8_t *)sdk_work)[0] == 0x5a);
    finalized++; return final_status;
}
void *guest_sym(const char *name) {
    if (!strcmp(name, "_ZN2nn6fontll18ScalableFontEngine10InitializeEPvj")) return initialize_stub;
    if (!strcmp(name, "_ZN2nn6fontll18ScalableFontEngine22GetPointerToWorkBufferEv")) return work_stub;
    if (!strcmp(name, "_ZN2nn6fontll18ScalableFontEngine8FinalizeEv")) return finalize_stub;
    if (!strcmp(name, "_ZN2nn6fontll18ScalableFontEngine8LoadFontEPcPKvjj")) return load_stub;
    if (!strcmp(name, "_ZN2nn6fontll18ScalableFontEngine7SetFontEPc")) return set_stub;
    if (!strcmp(name, "_ZN2nn6fontll18ScalableFontEngine8SetScaleEiiii")) return scale_stub;
    if (!strcmp(name, "_ZN2nn6fontll18ScalableFontEngine15AcquireGlyphmapEjt")) return glyph_stub;
    if (!strcmp(name, "_ZN2nn6fontll18ScalableFontEngine15CheckGlyphExistEj")) return exists_stub;
    if (!strcmp(name, "_ZN2nn6fontll18ScalableFontEngine8GetErrorEv")) return error_stub;
    if (!strcmp(name, "FS_error")) { static uint32_t getter[] = {0xb9404800, 0xd65f03c0}; return getter; }
    assert(!"unexpected font symbol"); return NULL;
}
int main(void) {
    uint8_t *caller = malloc(FONT_WORK_BYTES + 64); assert(caller);
    memset(caller, 0xa5, FONT_WORK_BYTES + 64);
    assert(!font_initialize(engine, caller, 524288));
    assert(sdk_work == tracked && sdk_work != caller && sdk_size == FONT_WORK_BYTES);
    assert(font_work(engine) == caller && caller[0] == 0xa5 && caller[524288] == 0xa5);
    final_status = 0xc9;
    assert(font_finalize(engine) == final_status && tracked && !releases);
    final_status = 0;
    assert(!font_finalize(engine) && !tracked && releases == 1 && finalized == 2);
    assert(!font_initialize(engine, caller, 884736));
    assert(font_work(engine) == caller && allocations == 2);
    assert(!font_finalize(engine) && releases == 2);
    init_status = 0x20b;
    assert(font_initialize(engine, caller, 524288) == init_status && !tracked && releases == 3);
    assert(font_work(engine) == caller); // Failure must not make the caller free the host allocation.
    assert(!font_finalize(engine));
    init_status = 0;
    assert(!font_initialize(engine, caller, FONT_WORK_BYTES + 64));
    assert(sdk_work == caller && sdk_size == FONT_WORK_BYTES + 64 && allocations == 3);
    assert(!font_finalize(engine) && releases == 3);
    init_status = 0x20b;
    assert(font_initialize(engine, NULL, 0) == init_status && sdk_work == NULL && sdk_size == 0);
    assert(!font_finalize(engine));
    init_status = 0;
    assert(!font_initialize(engine, caller, 524288));
    char symbol[] = "Symbol", shared[] = "AppleGothic Regular", primary[] = "Broken";
    assert(!font_load(engine, symbol, NULL, 0, 50));
    assert(!font_load(engine, shared, NULL, 0, 50));
    assert(!font_load(engine, primary, NULL, 0, 50));
    assert(!font_set(engine, primary)); assert(!font_scale(engine, 30 << 16, 0, 0, 30 << 16));
    assert(font_glyph(engine, 0x84cb, 0x10008) == &glyph_token);
    assert(glyph_calls == 2 && glyph_format == 8 && !strcmp(selected, primary) && !error_stub(engine));
    shared_has_glyph = 0; glyph_calls = 0;
    assert(!font_glyph(engine, 0x84cb, 8));
    assert(glyph_calls == 1 && !strcmp(selected, primary) && error_stub(engine) == 0x20c);
    shared_has_glyph = 1; glyph_calls = 0;
    fallback_scale_error = 1;
    assert(!font_glyph(engine, 0x84cb, 8) && glyph_calls == 1 && error_stub(engine) == 0x20c && !strcmp(selected, primary));
    fallback_scale_error = 0; glyph_calls = 0;
    assert(!font_glyph(engine, 0xe37f, 8) && glyph_calls == 1); // Private-use symbols never cross font families.
    assert(!font_scale(engine, 0, 0, 0, 0)); glyph_calls = 0;
    assert(!font_glyph(engine, 0x84cb, 8) && glyph_calls == 1);
    assert(!font_scale(engine, 30 << 16, 0, 0, 30 << 16));
    char long_name[80]; memset(long_name, 'x', sizeof long_name - 1); long_name[79] = 0;
    assert(!font_set(engine, long_name)); glyph_calls = 0;
    assert(!font_glyph(engine, 0x84cb, 8) && glyph_calls == 1 && !strcmp(selected, long_name));
    assert(!font_finalize(engine));
    free(caller);
    puts("Font workspace and recovery: ownership, lifecycle, same-code fallback, original selection and failure error preserved");
}
