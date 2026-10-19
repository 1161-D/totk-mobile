// Resource-dependent corpus check: font_audit.py, then build_and_run.sh --font-test.
#define main probe_main
#include "../host/probe.c"
#undef main
#include "../host/codec.c"
#include <assert.h>
#include <mach-o/getsect.h>

extern const struct mach_header_64 _mh_execute_header;
static void *font_hook(const char *name) {
    unsigned long size = 0;
    const hle_force_ent *table = (const void *)getsectiondata(&_mh_execute_header, "__DATA", "swforce", &size);
    for (size_t i = 0; i < size / sizeof *table; i++) if (!strcmp(table[i].name, name)) return table[i].fn;
    fprintf(stderr, "Missing font hook: %s\n", name); abort();
}
static uint8_t *font_bytes(const char *path, size_t *size) {
    FILE *file = fopen(path, "rb"); assert(file);
    assert(!fseek(file, 0, SEEK_END)); long length = ftell(file);
    assert(length > 0 && length <= (64 << 20)); rewind(file);
    uint8_t *data = calloc(1, (size_t)length + 16); assert(data);
    assert(fread(data, 1, (size_t)length, file) == (size_t)length); fclose(file);
    *size = (size_t)length; return data;
}
int main(int argc, char **argv) {
    assert(argc == 3);
    char *load[] = {argv[0], argv[1], "--load-only"};
    assert(!probe_main(3, load)); initialize_guest(); alarm(1800);
    void (*ctor)(void *) = guest_sym("_ZN2nn6fontll18ScalableFontEngineC1Ev");
    void *(*decode)(void *, uint32_t, void *, const void *) = guest_sym("_ZN2nn6fontll24ScalableFontEngineHelper6DecodeEPKvjPFmPvmS3_mS3_mS3_mEPKh");
    uint32_t (*init)(void *, void *, uint32_t) = font_hook("_ZN2nn6fontll18ScalableFontEngine10InitializeEPvj");
    uint32_t (*load_font)(void *, char *, const void *, uint32_t, uint32_t) = font_hook("_ZN2nn6fontll18ScalableFontEngine8LoadFontEPcPKvjj");
    uint32_t (*set)(void *, char *) = font_hook("_ZN2nn6fontll18ScalableFontEngine7SetFontEPc");
    uint32_t (*scale)(void *, int, int, int, int) = font_hook("_ZN2nn6fontll18ScalableFontEngine8SetScaleEiiii");
    uint32_t (*exists)(void *, uint32_t) = guest_sym("_ZN2nn6fontll18ScalableFontEngine15CheckGlyphExistEj");
    void *(*acquire)(void *, uint32_t, uint32_t) = font_hook("_ZN2nn6fontll18ScalableFontEngine15AcquireGlyphmapEjt");
    uint32_t (*error)(void *) = guest_sym("_ZN2nn6fontll18ScalableFontEngine8GetErrorEv");
    void (*release)(void *, void *) = guest_sym("_ZN2nn6fontll18ScalableFontEngine13ReleasesGlyphEPv");
    uint32_t (*used)(void *) = guest_sym("FS_get_heap_used");
    void *(*work_pointer)(void *) = font_hook("_ZN2nn6fontll18ScalableFontEngine22GetPointerToWorkBufferEv");
    uint32_t (*finish)(void *) = font_hook("_ZN2nn6fontll18ScalableFontEngine8FinalizeEv");
    assert(ctor && decode && exists && error && release && used);
    FILE *manifest = fopen(argv[2], "r"); assert(manifest);
    size_t shared_size;
    uint8_t *shared = font_bytes("/System/Library/Fonts/Supplemental/AppleGothic.ttf", &shared_size);
    uint32_t *codes = malloc(0x110000 * sizeof *codes); assert(codes);
    char line[4096]; unsigned fonts = 0, failures = 0; uint64_t total = 0;
    while (fgets(line, sizeof line, manifest)) {
        assert(strchr(line, '\n')); line[strcspn(line, "\r\n")] = 0;
        char *next, *kind = strtok_r(line, "\t", &next), *path = strtok_r(NULL, "\t", &next), *label = strtok_r(NULL, "\t", &next);
        char *scope_path = strtok_r(NULL, "\t", &next);
        assert(kind && path && label && !strtok_r(NULL, "\t", &next));
        uint8_t *scope = NULL;
        if (scope_path) {
            scope = calloc(0x110000, 1); assert(scope);
            FILE *list = fopen(scope_path, "r"); assert(list); unsigned code, items = 0;
            int scan;
            while ((scan = fscanf(list, "%x", &code)) == 1) { assert(code <= 0x10ffff); scope[code] = 1; items++; }
            assert(scan == EOF && items); fclose(list);
        }
        size_t length; uint8_t *data = font_bytes(path, &length); void *font = data;
        if (!strcmp(kind, "bfont")) { font = decode(data, (uint32_t)length, NULL, NULL); assert(font == data + 8); }
        else assert(!strcmp(kind, "plain"));
        _Alignas(16) uint8_t engine[0xc0] = {0}; ctor(engine);
        uint8_t *caller = malloc(524288 + 16); assert(caller); memset(caller, 0xa5, 524288 + 16);
        assert(!init(engine, caller, 524288));
        if (strcmp(kind, "plain")) {
            char shared_name[256] = {0}; assert(!load_font(engine, shared_name, shared, 0, 50));
        }
        char name[256] = {0}; assert(!load_font(engine, name, font, 0, 50)); assert(!set(engine, name));
        unsigned count = 0, peak = used(engine), failed = 0;
        for (uint32_t c = 0; c <= 0x10ffff; c++) {
            if (c >= 0xd800 && c <= 0xdfff) continue;
            if (scope && !scope[c]) continue;
            if (exists(engine, c)) codes[count++] = c;
        }
        assert(count && count < 0x110000);
        const int pixels[] = {18, 30, 48, 96, 30};
        for (unsigned p = 0; p < sizeof pixels / sizeof *pixels; p++) {
            assert(!scale(engine, pixels[p] << 16, 0, 0, pixels[p] << 16));
            for (unsigned j = 0; j < count; j++) {
                uint32_t c = codes[p & 1 ? count - 1 - j : j];
                void *glyph = acquire(engine, c, 8);
                if (!glyph) { fprintf(stderr, "FONT_AUDIT FAILED asset=%s font=%s code=U+%X px=%d error=%#x heap_used=%u\n", label, name, c, pixels[p], error(engine), used(engine)); failed = 1; failures++; break; }
                assert(!error(engine));
                unsigned now = used(engine); if (now > peak) peak = now;
                release(engine, glyph); total++;
            }
            if (failed) break;
            fprintf(stderr, "FONT_AUDIT scale asset=%s px=%d glyphs=%u heap_peak=%u\n", label, pixels[p], count, peak);
        }
        assert(work_pointer(engine) == caller); assert(!finish(engine));
        if (failed) { free(caller); free(data); free(scope); fonts++; continue; }
        assert(!init(engine, caller, 524288)); memset(name, 0, sizeof name);
        if (strcmp(kind, "plain")) {
            char shared_name[256] = {0}; assert(!load_font(engine, shared_name, shared, 0, 50));
        }
        assert(!load_font(engine, name, font, 0, 50)); assert(!set(engine, name));
        assert(!scale(engine, 30 << 16, 0, 0, 30 << 16));
        void *glyph = acquire(engine, codes[count / 2], 8); assert(glyph); release(engine, glyph);
        assert(work_pointer(engine) == caller); assert(!finish(engine));
        for (unsigned i = 0; i < 524288 + 16; i++) assert(caller[i] == 0xa5);
        fprintf(stderr, "FONT_AUDIT passed asset=%s glyphs=%u heap_peak=%u lifecycle=2 scope=%s\n", label, count, peak, scope ? "message-literals" : "full-font");
        free(caller); free(data); free(scope); fonts++;
    }
    assert(fonts); fclose(manifest); free(codes); free(shared); alarm(0);
    printf("FONT_AUDIT COMPLETE fonts=%u glyph_checks=%llu failures=%u\n", fonts, (unsigned long long)total, failures);
    return failures ? 2 : 0;
}
