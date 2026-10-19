// Resource-dependent integration check: ./script/build_and_run.sh --codec-test
#define main probe_main
#include "../host/probe.c"
#undef main
#include "../host/codec.c"
#include <assert.h>
#include <math.h>
#include <opus.h>

int main(int argc, char **argv) {
    assert(argc == 2);
    char *load[] = {argv[0], argv[1], "--load-only"};
    assert(!probe_main(3, load));
    initialize_guest();
    _Alignas(16) uint8_t state[0x40] = {0};
    memset(state + 0x30, 0xa5, 16);
    size_t size = h_codec_size(48000, 1, 1);
    assert(size && size < (1u << 20));
    uint8_t *work = calloc(1, size + 16); assert(work);
    memset(work + size, 0xa5, 16);
    assert(!h_codec_initialize(state, 48000, 1, work, size, 1));
    assert(h_codec_rate(state) == 48000 && h_codec_channels(state) == 1);
    int error; OpusEncoder *encoder = opus_encoder_create(48000, 1, OPUS_APPLICATION_AUDIO, &error);
    assert(encoder && !error);
    int16_t tone[960], pcm[968], first[960];
    for (unsigned i = 0; i < 960; i++) tone[i] = (int16_t)(12000 * sin(i * 0.0575958653158));
    for (unsigned i = 0; i < 968; i++) pcm[i] = 0x5555;
    uint8_t packet[4096]; int length = opus_encode(encoder, tone, 960, packet + 8, sizeof packet - 8);
    assert(length > 0);
    uint32_t range; assert(!opus_encoder_ctl(encoder, OPUS_GET_FINAL_RANGE(&range)));
    for (unsigned i = 0; i < 4; i++) { packet[i] = (uint32_t)length >> (24 - i * 8); packet[4 + i] = range >> (24 - i * 8); }
    size_t consumed = 0; int samples = 0;
    assert(!h_codec_decode(state, &consumed, &samples, pcm, sizeof first, packet, length + 8));
    assert(consumed == (size_t)length + 8 && samples == 960);
    unsigned audible = 0; for (unsigned i = 0; i < 960; i++) audible += abs(pcm[i]) > 100;
    assert(audible > 400); memcpy(first, pcm, sizeof first);
    h_codec_reset(state);
    assert(!h_codec_decode(state, &consumed, &samples, pcm, sizeof first, packet, length + 8));
    assert(!memcmp(first, pcm, sizeof first));
    assert(h_codec_decode(state, &consumed, &samples, pcm, sizeof first, packet, 7));
    h_codec_finalize(state);
    for (unsigned i = 0; i < 16; i++) assert(state[0x30 + i] == 0xa5 && work[size + i] == 0xa5);
    for (unsigned i = 960; i < 968; i++) assert(pcm[i] == 0x5555);
    opus_encoder_destroy(encoder); free(work);
    puts("SDK software Opus decode, reset, bounds and opaque-state canaries passed");
    return 0;
}
