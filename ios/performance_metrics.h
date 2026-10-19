#pragma once
#include <math.h>
#include <stdbool.h>

typedef struct { double wall, cpu; bool valid; } ZeldaCPUUsage;

// Whole-device CPU capacity: one fully busy core on an eight-core device is 12.5%.
static inline double zelda_cpu_percent(ZeldaCPUUsage *previous, double wall, double cpu, unsigned cores) {
    double result = NAN;
    if (!isfinite(wall) || !isfinite(cpu) || wall < 0 || cpu < 0 || !cores) {
        *previous = (ZeldaCPUUsage){0}; return result;
    }
    if (previous->valid && wall > previous->wall && cpu >= previous->cpu)
        result = fmin(100, 100 * (cpu - previous->cpu) / (wall - previous->wall) / cores);
    *previous = (ZeldaCPUUsage){wall, cpu, true};
    return result;
}
