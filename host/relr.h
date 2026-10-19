#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// ELF DT_RELR: even entries set the cursor, odd entries cover the next 63 words.
static bool zelda_relr(uint8_t *base, size_t begin, size_t end,
                       const uint64_t *entries, size_t count, size_t *applied) {
    uint64_t cursor = 0;
    bool anchored = false;
    *applied = 0;
    for (size_t i = 0; i < count; i++) {
        uint64_t entry = entries[i];
        if (!(entry & 1)) {
            cursor = entry;
            anchored = true;
        } else if (!anchored) return false;
        unsigned words = entry & 1 ? 63 : 1;
        for (unsigned bit = 0; bit < words; bit++) {
            if (!(entry & 1) || (entry & (1ull << (bit + 1)))) {
                if (cursor > UINT64_MAX - bit * 8) return false;
                uint64_t offset = cursor + bit * 8;
                if (end < 8 || offset < begin || offset > end - 8 || offset % 8) return false;
                *(uint64_t *)(base + offset) += (uintptr_t)base;
                (*applied)++;
            }
        }
        if (cursor > UINT64_MAX - words * 8) return false;
        cursor += words * 8;
    }
    return true;
}
