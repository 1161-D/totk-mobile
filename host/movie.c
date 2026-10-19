// Pre-rendered cutscenes (Event/Movie/*.webm, VP9 1920x1080 30 fps, video only). The SDK's movie::Decoder decodes
// through NVDEC (NvMMLite -> NvRmChannelOpen on /dev/nvhost-nvdec), which this host does not provide: its worker
// aborted the game (2162-0001) as the first movie started. The decoder is taken over at construction with a host
// implementation of the SDK's MediaCodec-style contract on top of movie_video (libvpx, portable to iOS/Android);
// movie::Extractor, Buffer and MediaData stay the SDK's (software WebM parsing and plain containers).
//
// Game protocol, v1.4.3 main 0x2b44300-0x2b45e60 (read from code; slots index the object's vtable):
//   setup: Extractor slot 5 GetTrackConfiguration -> "mime" video/avc|vp8|vp9 -> Decoder(type 1|2|3, output 4 = NV12,
//     mode 1, movie::GetThreadPriority()) -> slot 3 RegisterClientEvents({input, output, format, error} EventType*)
//     -> slot 2 Configure(track MediaData: width/height) -> slot 14 GetOutputBufferSize (unused) -> Extractor SelectTrack.
//   slot 5 Start. Worker: input event -> slot 9 AcquireInputBufferIndex(&i, &more) until non-zero; read thread ->
//     slot 10 GetInputBuffer -> Extractor Read/GetSampleTime/Advance -> slot 11 SendInputBufferForDecode(i, off, size,
//     pts, flags 4 at end); output event -> slot 12 AcquireOutputBufferIndex(&i, &pts, &flags, &more): flags 4 ends
//     playback with slot 15 Release, other frames wait for their time; format event -> slot 4 GetOutputFormat
//     (width/height/stride/crop). Each displayed frame: Buffer over the game's NV12 texture memory (Y w*h, then
//     interleaved UV) -> slot 13 GetOutputBuffer(i, &buffer) -> slot 15 ReleaseOutputBufferIndex(i).
//   end/skip: slot 8 Flush + slot 6 Stop; destroy: slot 8 Flush + slot 1 (deleting destructor).
// Unused slots abort with their name instead of returning a guessed success.
#include "hle.h"
#include "movie_video.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { ST_OK = 0, ST_FAILED = 0x1001, ST_TRY_AGAIN = 0x1008 }; // movie::Status: the game tests only for non-zero.
enum { FLAG_EOS = 4, TYPE_VP8 = 2, TYPE_VP9 = 3, OUTPUT_NV12 = 4 };
enum { INPUTS = 4, OUTPUTS = 8, INPUT_CAPACITY = 4 << 20, STACK = 512 << 10 };
enum { FREE, ACQUIRED, QUEUED, READY };

typedef struct {
    pthread_mutex_t lock; pthread_cond_t wake, idle;
    void *events[4]; // input available, output available, output format changed, error
    int type, priority, width, height, announced_width, announced_height;
    zelda_video *video;
    uint8_t *input[INPUTS]; int input_state[INPUTS];
    struct { int index, offset, size; int64_t pts; uint32_t flags; } queue[INPUTS]; int queue_head, queue_count;
    uint8_t *output[OUTPUTS]; size_t output_capacity, output_size[OUTPUTS]; int output_state[OUTPUTS];
    int64_t output_pts[OUTPUTS]; uint32_t output_flags[OUTPUTS]; int ready[OUTPUTS], ready_head, ready_count;
    int started, busy, quit, thread_created, last_error, ended;
    _Alignas(16) uint8_t thread[0x400]; void *stack;
    uint64_t frames, decode_ns;
} movie_decoder;

static struct {
    void (*signal)(void *);
    uint32_t (*create_thread)(void *, void (*)(void *), void *, void *, size_t, int);
    void (*start_thread)(void *), (*wait_thread)(void *), (*destroy_thread)(void *), (*release)(void *);
    void (*set_data)(void *, void *, size_t), (*set_range)(void *, int, int);
    void *(*base)(const void *); size_t (*capacity)(const void *); int (*offset)(const void *);
    unsigned (*find_int32)(const void *, const char *, int *); // bool: only bit 0 is defined
    void (*set_int32)(void *, const char *, int), (*set_rect)(void *, const char *, int, int, int, int);
    void (*set_string)(void *, const char *, const char *);
} sdk;

// The game's movie allocator (guest heap). nn::os::CreateThread maps a thread stack with svcMapMemory, which only
// accepts guest heap memory, so the worker stack must come from here rather than the host heap.
static struct { void *(*alloc)(size_t, size_t, void *); void (*free)(void *, void *); void *user; } allocator;

static void *symbol(const char *name) {
    void *function = guest_sym(name);
    if (!function) die("movie: SDK symbol missing: %s", name);
    return function;
}
static void resolve(void) { // First decoder construction, on the game's movie thread.
    if (sdk.signal) return;
    sdk.signal = symbol("_ZN2nn2os11SignalEventEPNS0_9EventTypeE");
    sdk.create_thread = symbol("_ZN2nn2os12CreateThreadEPNS0_10ThreadTypeEPFvPvES3_S3_mi");
    sdk.start_thread = symbol("_ZN2nn2os11StartThreadEPNS0_10ThreadTypeE");
    sdk.wait_thread = symbol("_ZN2nn2os10WaitThreadEPNS0_10ThreadTypeE");
    sdk.destroy_thread = symbol("_ZN2nn2os13DestroyThreadEPNS0_10ThreadTypeE");
    sdk.release = symbol("_ZdlPv");
    sdk.set_data = symbol("_ZN5movie6Buffer18SetDataAndCapacityEPvm");
    sdk.set_range = symbol("_ZN5movie6Buffer8SetRangeEii");
    sdk.base = symbol("_ZNK5movie6Buffer4BaseEv");
    sdk.capacity = symbol("_ZNK5movie6Buffer8CapacityEv");
    sdk.offset = symbol("_ZNK5movie6Buffer6OffsetEv");
    sdk.find_int32 = symbol("_ZNK5movie9MediaData9FindInt32EPKcPi");
    sdk.set_int32 = symbol("_ZN5movie9MediaData8SetInt32EPKci");
    sdk.set_rect = symbol("_ZN5movie9MediaData7SetRectEPKciiii");
    sdk.set_string = symbol("_ZN5movie9MediaData9SetStringEPKcS2_");
}

static movie_decoder *M(void *self) { return ((movie_decoder **)self)[1]; }
static uint64_t monotonic_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
static void signal_event(movie_decoder *m, int which) { if (m->events[which]) sdk.signal(m->events[which]); }

static int free_output(movie_decoder *m) {
    for (int i = 0; i < OUTPUTS; i++) if (m->output_state[i] == FREE) return i;
    return -1;
}
// Worker side, lock held: wait for a free output slot unless the stream is being flushed or torn down.
static int claim_output(movie_decoder *m, uint64_t generation, const _Atomic uint64_t *current) {
    int slot;
    while ((slot = free_output(m)) < 0 && !m->quit && atomic_load(current) == generation) pthread_cond_wait(&m->wake, &m->lock);
    return m->quit || atomic_load(current) != generation ? -1 : slot;
}
static _Atomic uint64_t flushes;

static void publish(movie_decoder *m, int slot, size_t size, int64_t pts, uint32_t flags) {
    m->output_size[slot] = size; m->output_pts[slot] = pts; m->output_flags[slot] = flags; m->output_state[slot] = READY;
    m->ready[(m->ready_head + m->ready_count++) % OUTPUTS] = slot;
}

static void worker(void *argument) {
    movie_decoder *m = argument;
    pthread_mutex_lock(&m->lock);
    while (!m->quit) {
        if (!m->started || !m->queue_count || free_output(m) < 0) { pthread_cond_wait(&m->wake, &m->lock); continue; }
        typeof(m->queue[0]) job = m->queue[m->queue_head];
        m->queue_head = (m->queue_head + 1) % INPUTS; m->queue_count--;
        uint64_t generation = atomic_load(&flushes);
        m->busy = 1;
        pthread_mutex_unlock(&m->lock);
        uint64_t start = monotonic_ns();
        int status = zelda_video_decode(m->video, job.size ? m->input[job.index] + job.offset : NULL, (size_t)job.size);
        uint64_t spent = monotonic_ns() - start; // decode and conversion only, not the wait for a free output slot
        pthread_mutex_lock(&m->lock);
        if (status) { m->last_error = ST_FAILED; fprintf(stderr, "MOVIE decode error pts=%lld size=%d\n", (long long)job.pts, job.size); }
        int changed = 0, produced = 0;
        for (;;) {
            int slot = claim_output(m, generation, &flushes);
            if (slot < 0) break;
            int width = 0, height = 0;
            pthread_mutex_unlock(&m->lock);
            uint64_t convert = monotonic_ns();
            int frame = zelda_video_frame(m->video, m->output[slot], m->output_capacity, &width, &height);
            spent += monotonic_ns() - convert;
            pthread_mutex_lock(&m->lock);
            if (frame < 0) die("movie: decoded frame %dx%d does not fit the configured %dx%d NV12 output", width, height, m->width, m->height);
            if (!frame) break;
            if (width != m->announced_width || height != m->announced_height) { m->announced_width = width; m->announced_height = height; changed = 1; }
            publish(m, slot, zelda_video_nv12_size(width, height), job.pts, 0);
            produced++; m->frames++;
        }
        m->decode_ns += spent;
        if (job.flags & FLAG_EOS) {
            int slot = claim_output(m, generation, &flushes);
            if (slot >= 0) { publish(m, slot, 0, job.pts, FLAG_EOS); produced++; }
            if (!m->ended++) fprintf(stderr, "MOVIE end frames=%llu decode_ms_per_frame=%.2f\n", (unsigned long long)m->frames, m->frames ? m->decode_ns / 1e6 / m->frames : 0.0);
        }
        if (atomic_load(&flushes) == generation) m->input_state[job.index] = FREE;
        m->busy = 0;
        pthread_cond_broadcast(&m->idle);
        pthread_mutex_unlock(&m->lock);
        // Format first, as MediaCodec does, so the game re-reads the size before taking the frame.
        if (changed) signal_event(m, 2);
        if (produced) signal_event(m, 1);
        signal_event(m, 0);
        pthread_mutex_lock(&m->lock);
    }
    pthread_mutex_unlock(&m->lock);
}

static void fill_format(movie_decoder *m, void *media) {
    int width = m->announced_width ? m->announced_width : m->width, height = m->announced_height ? m->announced_height : m->height;
    sdk.set_string(media, "mime", m->type == TYPE_VP9 ? "video/x-vnd.on2.vp9" : "video/x-vnd.on2.vp8");
    sdk.set_int32(media, "width", width); sdk.set_int32(media, "height", height);
    sdk.set_int32(media, "stride", width); sdk.set_int32(media, "slice-height", height);
    sdk.set_rect(media, "crop", 0, 0, width - 1, height - 1);
}

// Drops queued input and undelivered frames; the decoder restarts from the next key frame the game sends.
static void flush_locked(movie_decoder *m) {
    atomic_fetch_add(&flushes, 1);
    pthread_cond_broadcast(&m->wake);
    while (m->busy) pthread_cond_wait(&m->idle, &m->lock);
    for (int i = 0; i < INPUTS; i++) m->input_state[i] = FREE;
    for (int i = 0; i < OUTPUTS; i++) m->output_state[i] = FREE;
    m->queue_head = m->queue_count = m->ready_head = m->ready_count = 0; m->ended = 0;
    if (m->video) {
        zelda_video_close(m->video);
        if (!(m->video = zelda_video_open(m->type, 4))) die("movie: decoder restart failed");
    }
}

static void destroy(void *self) {
    movie_decoder *m = M(self);
    if (!m) return;
    pthread_mutex_lock(&m->lock);
    m->quit = 1; pthread_cond_broadcast(&m->wake);
    pthread_mutex_unlock(&m->lock);
    if (m->thread_created) { sdk.wait_thread(m->thread); sdk.destroy_thread(m->thread); }
    zelda_video_close(m->video);
    for (int i = 0; i < INPUTS; i++) free(m->input[i]);
    for (int i = 0; i < OUTPUTS; i++) free(m->output[i]);
    if (m->stack) allocator.free(m->stack, allocator.user);
    fprintf(stderr, "MOVIE decoder destroyed frames=%llu\n", (unsigned long long)m->frames);
    free(m);
    ((movie_decoder **)self)[1] = NULL;
}
static void decoder_delete(void *self) { destroy(self); sdk.release(self); }

static int configure(void *self, void *media) {
    movie_decoder *m = M(self);
    int width = 0, height = 0;
    if (!(sdk.find_int32(media, "width", &width) & 1) || !(sdk.find_int32(media, "height", &height) & 1) || width <= 0 || height <= 0 || width > 8192 || height > 8192)
        die("movie: track format has no usable width/height");
    pthread_mutex_lock(&m->lock);
    m->width = width; m->height = height;
    m->output_capacity = zelda_video_nv12_size(width, height);
    if (!(m->video = zelda_video_open(m->type, 4))) die("movie: libvpx decoder unavailable for type %d", m->type);
    for (int i = 0; i < INPUTS; i++) if (!(m->input[i] = malloc(INPUT_CAPACITY))) die("movie: input buffer allocation failed");
    for (int i = 0; i < OUTPUTS; i++) if (!(m->output[i] = malloc(m->output_capacity))) die("movie: output buffer allocation failed");
    pthread_mutex_unlock(&m->lock);
    fprintf(stderr, "MOVIE configure codec=%s %dx%d inputs=%d outputs=%d\n", m->type == TYPE_VP9 ? "vp9" : "vp8", width, height, INPUTS, OUTPUTS);
    return ST_OK;
}
static int register_events(void *self, void **events) { memcpy(M(self)->events, events, sizeof M(self)->events); return ST_OK; }
static int output_format(void *self, void *media) {
    movie_decoder *m = M(self);
    pthread_mutex_lock(&m->lock); fill_format(m, media); pthread_mutex_unlock(&m->lock);
    return ST_OK;
}
static int start(void *self) {
    movie_decoder *m = M(self);
    pthread_mutex_lock(&m->lock);
    if (!m->video) { pthread_mutex_unlock(&m->lock); return ST_FAILED; }
    m->started = 1;
    if (!m->thread_created) {
        // A guest thread, so the worker can signal the game's nn::os events.
        if (!allocator.alloc || !(m->stack = allocator.alloc(STACK, 0x1000, allocator.user))) die("movie: worker stack allocation failed");
        uint32_t result = sdk.create_thread(m->thread, worker, m, m->stack, STACK, m->priority);
        if (result) die("movie: worker thread creation failed %#x", result);
        sdk.start_thread(m->thread); m->thread_created = 1;
    }
    pthread_cond_broadcast(&m->wake);
    pthread_mutex_unlock(&m->lock);
    fprintf(stderr, "MOVIE start\n");
    signal_event(m, 0);
    return ST_OK;
}
static int stop(void *self) {
    movie_decoder *m = M(self);
    pthread_mutex_lock(&m->lock); m->started = 0; pthread_mutex_unlock(&m->lock);
    fprintf(stderr, "MOVIE stop frames=%llu\n", (unsigned long long)m->frames);
    return ST_OK;
}
static int flush(void *self) {
    movie_decoder *m = M(self);
    pthread_mutex_lock(&m->lock); flush_locked(m); int started = m->started; pthread_mutex_unlock(&m->lock);
    if (started) signal_event(m, 0);
    return ST_OK;
}
static int acquire_input(void *self, int *index, int *more) {
    movie_decoder *m = M(self); int found = -1, others = 0;
    pthread_mutex_lock(&m->lock);
    for (int i = 0; i < INPUTS; i++) if (m->input_state[i] == FREE) { if (found < 0) found = i; else others++; }
    if (found >= 0) m->input_state[found] = ACQUIRED;
    pthread_mutex_unlock(&m->lock);
    *index = found; *more = found >= 0 ? others : 0;
    return found >= 0 ? ST_OK : ST_TRY_AGAIN;
}
static int input_buffer(void *self, int index, void *buffer) {
    movie_decoder *m = M(self);
    if (index < 0 || index >= INPUTS || m->input_state[index] != ACQUIRED) return ST_FAILED;
    sdk.set_data(buffer, m->input[index], INPUT_CAPACITY); sdk.set_range(buffer, 0, 0);
    return ST_OK;
}
static int send_input(void *self, int index, int offset, int size, int64_t pts, uint32_t flags) {
    movie_decoder *m = M(self);
    pthread_mutex_lock(&m->lock);
    if (index < 0 || index >= INPUTS || m->input_state[index] != ACQUIRED || offset < 0 || size < 0 || (int64_t)offset + size > INPUT_CAPACITY) {
        pthread_mutex_unlock(&m->lock); return ST_FAILED;
    }
    m->input_state[index] = QUEUED;
    m->queue[(m->queue_head + m->queue_count++) % INPUTS] = (typeof(m->queue[0])){index, offset, size, pts, flags};
    pthread_cond_broadcast(&m->wake);
    pthread_mutex_unlock(&m->lock);
    return ST_OK;
}
static int acquire_output(void *self, int *index, int64_t *pts, uint32_t *flags, int *more) {
    movie_decoder *m = M(self); int slot = -1;
    pthread_mutex_lock(&m->lock);
    if (m->ready_count) {
        slot = m->ready[m->ready_head]; m->ready_head = (m->ready_head + 1) % OUTPUTS; m->ready_count--;
        m->output_state[slot] = ACQUIRED; *pts = m->output_pts[slot]; *flags = m->output_flags[slot];
    }
    *more = m->ready_count;
    pthread_mutex_unlock(&m->lock);
    *index = slot;
    return slot >= 0 ? ST_OK : ST_TRY_AGAIN;
}
static int acquired(movie_decoder *m, int index) {
    pthread_mutex_lock(&m->lock);
    int held = index >= 0 && index < OUTPUTS && m->output_state[index] == ACQUIRED;
    pthread_mutex_unlock(&m->lock);
    return held;
}
static int output_buffer(void *self, int index, void *buffer) {
    movie_decoder *m = M(self);
    // An acquired slot is only touched by the game until it is released.
    if (!acquired(m, index)) return ST_FAILED;
    size_t size = m->output_size[index], offset = (size_t)sdk.offset(buffer);
    uint8_t *destination = (uint8_t *)sdk.base(buffer) + offset;
    if (size > sdk.capacity(buffer) - offset) die("movie: game frame buffer %zu bytes is smaller than the %zu-byte NV12 frame", sdk.capacity(buffer) - offset, size);
    // The destination is the game's texture memory; let the dirty-page tracker see the host write.
    if (size) { dm_guest_write_prepare(destination, size); memcpy(destination, m->output[index], size); }
    sdk.set_range(buffer, (int)offset, (int)size);
    return ST_OK;
}
static int output_buffer_size(void *self, int *count, int *size) {
    movie_decoder *m = M(self); *count = OUTPUTS; *size = (int)m->output_capacity;
    return ST_OK;
}
static int release_output(void *self, int index) {
    movie_decoder *m = M(self);
    pthread_mutex_lock(&m->lock);
    int valid = index >= 0 && index < OUTPUTS && m->output_state[index] == ACQUIRED;
    if (valid) { m->output_state[index] = FREE; pthread_cond_broadcast(&m->wake); }
    pthread_mutex_unlock(&m->lock);
    return valid ? ST_OK : ST_FAILED;
}
static int last_error(void *self) { return M(self)->last_error; }
static int output_buffer_media(void *self, int index, void *buffer, void *media) {
    int status = output_buffer(self, index, buffer);
    if (!status) output_format(self, media);
    return status;
}
static int output_buffer_format(void *self, int index, void *media) {
    if (!acquired(M(self), index)) return ST_FAILED;
    return output_format(self, media);
}
static void reset_trap(void) { die("movie: Decoder slot 7 Reset is outside the game's protocol"); }

static void *const decoder_vtable[19] = {
    destroy, decoder_delete, configure, register_events, output_format, start, stop, reset_trap, flush,
    acquire_input, input_buffer, send_input, acquire_output, output_buffer, output_buffer_size, release_output,
    last_error, output_buffer_media, output_buffer_format,
};

HLE_FORCE("_ZN5movie12SetAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_",
          "Pre-rendered movies: keep the game's movie allocator for the decoder worker stack, then pass it to the SDK",
          void, movie_set_allocator, void *(*alloc)(size_t, size_t, void *), void (*release)(void *, void *),
          void *(*resize)(void *, size_t, void *), void *user) {
    allocator.alloc = alloc; allocator.free = release; allocator.user = user;
    void (*set)(void *, void *, void *, void *) = symbol("_ZN5movie12SetAllocatorEPFPvmmS0_EPFvS0_S0_EPFS0_S0_mS0_ES0_");
    set((void *)alloc, (void *)release, (void *)resize, user);
}

HLE_FORCE("_ZN5movie7DecoderC1ENS_11DecoderTypeENS_19DecoderOutputFormatENS_11DecoderModeEi",
          "Pre-rendered movies: the SDK decoder needs NVDEC; decode VP9/VP8 to NV12 on the host (libvpx)",
          void, movie_decoder_construct, void **self, int type, int output, int mode, int priority) {
    resolve();
    if ((type != TYPE_VP9 && type != TYPE_VP8) || output != OUTPUT_NV12 || mode != 1)
        die("movie: unsupported decoder request type=%d output=%d mode=%d", type, output, mode);
    movie_decoder *m = calloc(1, sizeof *m);
    if (!m) die("movie: decoder allocation failed");
    pthread_mutex_init(&m->lock, NULL); pthread_cond_init(&m->wake, NULL); pthread_cond_init(&m->idle, NULL);
    m->type = type; m->priority = priority;
    self[0] = (void *)decoder_vtable; self[1] = m;
}
