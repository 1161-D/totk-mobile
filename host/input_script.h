#pragma once
#include <stdbool.h>
enum { SCRIPT_NONE, SCRIPT_WAIT, SCRIPT_DOWN, SCRIPT_UP, SCRIPT_TAP, SCRIPT_SHOT, SCRIPT_MARK, SCRIPT_TRACE, SCRIPT_DUMP, SCRIPT_FPS, SCRIPT_RENDER, SCRIPT_CONDITIONAL, SCRIPT_TRACE_FLUSH };
typedef struct { int kind; unsigned key, ms; char text[1024]; } ZeldaScriptStep;
bool input_script_parse(const char *line, ZeldaScriptStep *step);
void input_script_start(void (*shot)(long frames, const char *path));
