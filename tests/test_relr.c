#include "../host/relr.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    uint64_t image[128] = {0};
    uint64_t entries[] = {16, 1 | (1ull << 1) | (1ull << 3), 640};
    image[2] = 100; image[3] = 200; image[5] = 300; image[80] = 400;
    size_t applied;
    assert(zelda_relr((uint8_t *)image, 16, sizeof image, entries, 3, &applied));
    assert(applied == 4);
    assert(image[2] == (uintptr_t)image + 100);
    assert(image[3] == (uintptr_t)image + 200);
    assert(image[4] == 0);
    assert(image[5] == (uintptr_t)image + 300);
    assert(image[80] == (uintptr_t)image + 400);
    uint64_t trailing_bitmap[] = {16, 3};
    assert(zelda_relr((uint8_t *)image, 16, 32, trailing_bitmap, 2, &applied));
    assert(applied == 2);
    uint64_t bad[] = {3};
    assert(!zelda_relr((uint8_t *)image, 16, sizeof image, bad, 1, &applied));
    bad[0] = 8;
    assert(!zelda_relr((uint8_t *)image, 16, sizeof image, bad, 1, &applied));
    bad[0] = sizeof image;
    assert(!zelda_relr((uint8_t *)image, 16, sizeof image, bad, 1, &applied));
    bad[0] = UINT64_MAX - 1;
    assert(!zelda_relr((uint8_t *)image, 16, sizeof image, bad, 1, &applied));
    puts("RELR address, bitmap and bounds checks passed");
}
