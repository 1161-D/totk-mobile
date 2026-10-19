#include <assert.h>
#include <unistd.h>
#include "../host/trace_writer.c"

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t changed;
    int blocked, entered, release, fail;
    size_t used;
    char bytes[2 * TRACE_CAPACITY];
} TestSink;
static int sink_write(void *opaque, const char *bytes, int count) {
    TestSink *s = opaque;
    pthread_mutex_lock(&s->lock); s->entered = 1; pthread_cond_broadcast(&s->changed);
    while (s->blocked && !s->release) pthread_cond_wait(&s->changed, &s->lock);
    int fail = s->fail;
    if (!fail) { assert(s->used + (size_t)count <= sizeof s->bytes); memcpy(s->bytes + s->used, bytes, (size_t)count); s->used += (size_t)count; }
    pthread_mutex_unlock(&s->lock);
    if (fail) { errno = ENOSPC; return -1; }
    return count;
}
static FILE *test_sink(TestSink *s) {
    assert(!pthread_mutex_init(&s->lock, NULL)); assert(!pthread_cond_init(&s->changed, NULL));
    FILE *sink = funopen(s, NULL, sink_write, NULL, NULL); assert(sink);
    FILE *front = trace_wrap(sink); assert(front); assert(!setvbuf(front, NULL, _IONBF, 0)); return front;
}
static void wait_entered(TestSink *s) {
    pthread_mutex_lock(&s->lock);
    while (!s->entered) pthread_cond_wait(&s->changed, &s->lock);
    pthread_mutex_unlock(&s->lock);
}
static void release_sink(TestSink *s) {
    pthread_mutex_lock(&s->lock); s->release = 1; pthread_cond_broadcast(&s->changed); pthread_mutex_unlock(&s->lock);
}
static void free_sink(TestSink *s) { pthread_cond_destroy(&s->changed); pthread_mutex_destroy(&s->lock); free(s); }
int main(void) {
    alarm(20);
    char bytes[TRACE_CHUNK]; for (unsigned i = 0; i < sizeof bytes; i++) bytes[i] = (char)(i * 17);
    TestSink *s = calloc(1, sizeof *s); assert(s); s->blocked = 1;
    FILE *front = test_sink(s);
    assert(fwrite(bytes, 1, sizeof bytes, front) == sizeof bytes); wait_entered(s);
    // The backend is blocked; these foreground writes must finish before it is released.
    for (int i = 0; i < 8; i++) assert(fwrite(bytes, 1, sizeof bytes, front) == sizeof bytes);
    release_sink(s); assert(zelda_trace_flush()); assert(!zelda_trace_close());
    assert(s->used == 9 * sizeof bytes);
    for (int i = 0; i < 9; i++) assert(!memcmp(s->bytes + i * sizeof bytes, bytes, sizeof bytes));
    free_sink(s);

    s = calloc(1, sizeof *s); assert(s); s->blocked = 1; front = test_sink(s);
    assert(fwrite(bytes, 1, sizeof bytes, front) == sizeof bytes); wait_entered(s);
    for (int i = 0; i < TRACE_CAPACITY / TRACE_CHUNK; i++) assert(fwrite(bytes, 1, sizeof bytes, front) == sizeof bytes);
    fwrite(bytes, 1, sizeof bytes, front); assert(ferror(front)); assert(!zelda_trace_flush());
    release_sink(s); assert(zelda_trace_close() != 0); free_sink(s);

    s = calloc(1, sizeof *s); assert(s); s->fail = 1; front = test_sink(s);
    fwrite(bytes, 1, sizeof bytes, front);
    assert(!zelda_trace_flush()); assert(zelda_trace_close() != 0); free_sink(s);

    const char *path = "work/tmp/trace-writer-test.tsv";
    for (int async = 0; async < 2; async++) {
        setenv("ZELDA_ASYNC_TRACE", async ? "1" : "0", 1);
        front = zelda_trace_open(path); assert(front); assert(!zelda_trace_open(path) && errno == EBUSY);
        for (unsigned i = 0; i < 60000; i++) {
            assert(fprintf(front, "%u\t@frame_ms\t16.667\n", i) > 0);
            if (!(i % 1000)) assert(zelda_trace_flush());
        }
        assert(zelda_trace_flush()); assert(!zelda_trace_close());
        FILE *readback = fopen(path, "r"); assert(readback); unsigned frame, expected = 0; double value;
        while (fscanf(readback, "%u\t@frame_ms\t%lf\n", &frame, &value) == 2) { assert(frame == expected++ && value == 16.667); }
        assert(expected == 60000 && feof(readback)); assert(!fclose(readback)); assert(!unlink(path));
    }
    assert(!zelda_trace_open("work/tmp/trace-writer-missing-parent/file"));
    assert(zelda_trace_flush() && !zelda_trace_close()); alarm(0);
    puts("Trace writer preserves order, keeps slow IO off the producer, bounds memory and reports overflow/write failures");
}
