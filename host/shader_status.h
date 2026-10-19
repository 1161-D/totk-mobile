#pragma once

enum {
    SHADER_IDLE, SHADER_CHECKING, SHADER_LIBRARIES, SHADER_PIPELINES,
    SHADER_STEP, SHADER_FINISHED, SHADER_BUILD_BEGIN, SHADER_BUILD_END
};
typedef struct { unsigned phase, completed, total, active_builds; } ZeldaShaderStatus;

void shader_status_note(unsigned event, unsigned total);
ZeldaShaderStatus shader_status_snapshot(void);

#define ZELDA_SHADER_BUILD(...) ({ \
    shader_status_note(SHADER_BUILD_BEGIN, 0); \
    __auto_type zelda_build_result = (__VA_ARGS__); \
    shader_status_note(SHADER_BUILD_END, 0); \
    zelda_build_result; \
})
