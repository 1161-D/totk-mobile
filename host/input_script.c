// ZELDA_INPUT_SCRIPT=path replays host keyboard keys for repeatable scene checks; a FIFO keeps accepting lines.
#include "dm.h"
#include "input.h"
#include "input_script.h"
#include "game_timing.h"
#include "timeline.h"
#include "trace_writer.h"
#include <pthread.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// Verbs: wait ms, down/up key, tap key [ms], shot path, mark text, trace seconds path, trace-flush, dump frames, fps target,
// render percent (internal render scale, 50..200), conditional mode (0 CPU, 1 simple GPU, 2 batched GPU).
// Names are the documented host keys, so a script reads like the keyboard mapping in the README.
static const struct { const char *name; unsigned code; } names[] = {
    {"a", 0}, {"s", 1}, {"d", 2}, {"f", 3}, {"z", 6}, {"x", 7}, {"c", 8}, {"v", 9}, {"q", 12}, {"w", 13},
    {"e", 14}, {"r", 15}, {"i", 34}, {"l", 37}, {"j", 38}, {"k", 40}, {"return", 36}, {"tab", 48},
    {"space", 49}, {"shift", 56}, {"left", 123}, {"right", 124}, {"down", 125}, {"up", 126},
};
static bool key_code(const char *name, unsigned *code) {
    for (unsigned i = 0; i < sizeof names / sizeof *names; i++)
        if (!strcmp(names[i].name, name)) { *code = names[i].code; return true; }
    return false;
}
static bool number(const char *text, unsigned long limit, unsigned *value) {
    char *end; unsigned long parsed = strtoul(text, &end, 10);
    if (*text < '0' || *text > '9' || *end || parsed > limit) return false;
    *value = (unsigned)parsed; return true;
}
bool input_script_parse(const char *line, ZeldaScriptStep *step) {
    char verb[16] = "", first[1024] = "", second[16] = "", extra[2] = "";
    *step = (ZeldaScriptStep){.kind = SCRIPT_NONE};
    if (strlen(line) > 1100) return false;
    int fields = sscanf(line, " %15s %1023s %15s %1s", verb, first, second, extra);
    if (fields <= 0 || verb[0] == '#') return true;
    if (!strcmp(verb, "shot") || !strcmp(verb, "mark")) {
        const char *text = strstr(line, verb) + 4; text += strspn(text, " \t");
        size_t length = strcspn(text, "\r\n");
        if (!length || length >= sizeof step->text) return false;
        memcpy(step->text, text, length); step->kind = verb[0] == 's' ? SCRIPT_SHOT : SCRIPT_MARK;
        return true;
    }
    if (!strcmp(verb, "trace-flush")) { step->kind = SCRIPT_TRACE_FLUSH; return fields == 1; }
    if (!strcmp(verb, "trace")) {
        step->kind = SCRIPT_TRACE; unsigned seconds;
        if (sscanf(line, " trace %15s %1023s %1s", second, step->text, extra) != 2 || !number(second, 600, &seconds) || !seconds) return false;
        step->ms = seconds * 1000; return true;
    }
    if (!strcmp(verb, "wait")) { step->kind = SCRIPT_WAIT; return fields == 2 && number(first, 600000, &step->ms); }
    if (!strcmp(verb, "dump")) { step->kind = SCRIPT_DUMP; return fields == 2 && number(first, 600, &step->ms) && step->ms; }
    if (!strcmp(verb, "fps")) {
        step->kind = SCRIPT_FPS;
        return fields == 2 && number(first, 120, &step->ms) && (step->ms == 30 || step->ms == 60 || step->ms == 90 || step->ms == 120);
    }
    if (!strcmp(verb, "render")) { step->kind = SCRIPT_RENDER; return fields == 2 && number(first, 200, &step->ms) && step->ms >= 50; }
    if (!strcmp(verb, "conditional")) { step->kind = SCRIPT_CONDITIONAL; return fields == 2 && number(first, 2, &step->ms); }
    if (!strcmp(verb, "down") || !strcmp(verb, "up")) {
        step->kind = verb[0] == 'd' ? SCRIPT_DOWN : SCRIPT_UP; return fields == 2 && key_code(first, &step->key);
    }
    if (!strcmp(verb, "tap")) {
        step->kind = SCRIPT_TAP; step->ms = 100;
        return (fields == 2 || (fields == 3 && number(second, 10000, &step->ms) && step->ms)) && key_code(first, &step->key);
    }
    return false;
}

static void (*take_shot)(long, const char *);
static void pause_ms(unsigned ms) {
    struct timespec rest = {ms / 1000, (long)(ms % 1000) * 1000000};
    while (nanosleep(&rest, &rest)) {}
}
static void *run(void *argument) {
    const char *path = argument; struct stat info; unsigned line_number = 0;
    do {
        FILE *file = fopen(path, "r"); char line[1200];
        if (!file) die("cannot open input script %s", path);
        while (fgets(line, sizeof line, file)) {
            ZeldaScriptStep step; line_number++;
            if (!input_script_parse(line, &step)) die("invalid input script line %u", line_number);
            double now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; // Same clock as performance.tsv.
            switch (step.kind) {
                case SCRIPT_WAIT: pause_ms(step.ms); break;
                case SCRIPT_DOWN: input_key(step.key, 1); break;
                case SCRIPT_UP: input_key(step.key, 0); break;
                case SCRIPT_TAP: input_key(step.key, 1); pause_ms(step.ms); input_key(step.key, 0); break;
                case SCRIPT_SHOT: if (take_shot) take_shot(0, step.text); LOG("INPUT_SCRIPT shot time=%.3f %s", now, step.text); break;
                case SCRIPT_MARK: LOG("INPUT_SCRIPT mark time=%.3f %s", now, step.text); break;
                case SCRIPT_TRACE_FLUSH:
                    if (!zelda_trace_flush()) die("TRACE_ERROR flush failed; measurement invalid");
                    LOG("INPUT_SCRIPT trace flushed time=%.3f", now); break;
                // Pass/command dump of the next frames (DM_NVN_PASSDUMP format; DM_NVN_PASSDUMP_ALL adds every draw).
                case SCRIPT_DUMP: zelda_passdump_request(step.ms); LOG("INPUT_SCRIPT dump time=%.3f frames=%u", now, step.ms); break;
                // Same runtime switch as the menu, without saving it (measurement scripts compare targets in one run).
                case SCRIPT_FPS:
                    if (!zelda_set_target_fps(step.ms)) die("target FPS %u rejected", step.ms);
                    LOG("INPUT_SCRIPT fps time=%.3f target=%u", now, step.ms); break;
                case SCRIPT_RENDER:
                    if (!zelda_set_render_scale(step.ms / 100.0f)) die("render scale %u%% rejected", step.ms);
                    LOG("INPUT_SCRIPT render time=%.3f scale=%u%%", now, step.ms); break;
                case SCRIPT_CONDITIONAL:
                    if (!zelda_conditional_mode_request(step.ms)) die("conditional mode %u rejected", step.ms);
                    LOG("INPUT_SCRIPT conditional requested time=%.3f mode=%u", now, step.ms); break;
                case SCRIPT_TRACE:
                    if (!zelda_timeline_start()) die("timeline already recording or unavailable");
                    LOG("INPUT_SCRIPT trace start time=%.3f seconds=%u", now, step.ms / 1000);
                    pause_ms(step.ms);
                    LOG("INPUT_SCRIPT trace %s %s", zelda_timeline_stop(step.text) ? "written" : "incomplete", step.text);
                    break;
            }
        }
        fclose(file);
    } while (!stat(path, &info) && S_ISFIFO(info.st_mode));
    LOG("INPUT_SCRIPT finished lines=%u", line_number);
    return NULL;
}
void input_script_start(void (*shot)(long, const char *)) {
    const char *path = getenv("ZELDA_INPUT_SCRIPT");
    if (!path || !*path) return;
    take_shot = shot; pthread_t thread;
    if (pthread_create(&thread, NULL, run, (void *)path)) die("input script thread unavailable");
    pthread_detach(thread);
    LOG("INPUT_SCRIPT started %s", path);
}
