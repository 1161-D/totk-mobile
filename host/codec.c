#include "hle.h"

// D2R uses the SDK's software Opus decoder too; this SDK exposes the C API instead of constructors.
// The checked Zelda SDK software state uses 0x28 bytes inside the hardware state's 0x30 bytes.
static void *codec_symbol(const char *name) {
    void *function = guest_sym(name);
    if (!function) die("SDK software Opus entry missing: %s", name);
    return function;
}

#define CODEC_REASON "Use the SDK software Opus decoder in the hardware decoder's opaque state"
HLE_FORCE("_ZN2nn5codec36GetHardwareOpusDecoderWorkBufferSizeEiii", CODEC_REASON,
          size_t, h_codec_size, int rate, int channels, int option) {
    (void)option;
    size_t (*function)(int, int) = codec_symbol("_ZN2nn5codec28GetOpusDecoderWorkBufferSizeEii");
    return function(rate, channels);
}
HLE_FORCE("_ZN2nn5codec29InitializeHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeEiiPvmi", CODEC_REASON,
          Result, h_codec_initialize, void *state, int rate, int channels, void *work, size_t size, int option) {
    (void)option;
    Result (*function)(void *, int, int, void *, size_t) = codec_symbol("_ZN2nn5codec21InitializeOpusDecoderEPNS0_15OpusDecoderTypeEiiPvm");
    return function(state, rate, channels, work, size);
}
HLE_FORCE("_ZN2nn5codec27FinalizeHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeE", CODEC_REASON,
          void, h_codec_finalize, void *state) {
    void (*function)(void *) = codec_symbol("_ZN2nn5codec19FinalizeOpusDecoderEPNS0_15OpusDecoderTypeE");
    function(state);
}
HLE_FORCE("_ZN2nn5codec32GetHardwareOpusDecoderSampleRateEPKNS0_23HardwareOpusDecoderTypeE", CODEC_REASON,
          int, h_codec_rate, const void *state) {
    int (*function)(const void *) = codec_symbol("_ZN2nn5codec24GetOpusDecoderSampleRateEPKNS0_15OpusDecoderTypeE");
    return function(state);
}
HLE_FORCE("_ZN2nn5codec34GetHardwareOpusDecoderChannelCountEPKNS0_23HardwareOpusDecoderTypeE", CODEC_REASON,
          int, h_codec_channels, const void *state) {
    int (*function)(const void *) = codec_symbol("_ZN2nn5codec26GetOpusDecoderChannelCountEPKNS0_15OpusDecoderTypeE");
    return function(state);
}
HLE_FORCE("_ZN2nn5codec24ResetHardwareOpusDecoderEPNS0_23HardwareOpusDecoderTypeE", CODEC_REASON,
          void, h_codec_reset, void *state) {
    void (*function)(void *) = codec_symbol("_ZN2nn5codec16ResetOpusDecoderEPNS0_15OpusDecoderTypeE");
    function(state);
}
HLE_FORCE("_ZN2nn5codec33DecodeOpusInterleavedWithHardwareEPNS0_23HardwareOpusDecoderTypeEPmPiPsmPKvm", CODEC_REASON,
          Result, h_codec_decode, void *state, size_t *consumed, int *samples, int16_t *pcm, size_t capacity, const void *packet, size_t bytes) {
    Result (*function)(void *, size_t *, int *, int16_t *, size_t, const void *, size_t) =
        codec_symbol("_ZN2nn5codec21DecodeOpusInterleavedEPNS0_15OpusDecoderTypeEPmPiPsmPKvm");
    return function(state, consumed, samples, pcm, capacity, packet, bytes);
}
