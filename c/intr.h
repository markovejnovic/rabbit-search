#ifndef INTR_H
#define INTR_H

#include <immintrin.h>
#include <stdint.h>
#include <stdbool.h>

struct NeedleOffsets {
    uint8_t first;
    uint8_t mid;
    uint8_t last;
    uint8_t length;
};

/**
 * The needle is split up into three different pointers we search for.
 *
 * The first pointer is going to point at the first character in the needle,
 * the middle at some middle character and the last at the last character.
 *
 * These are computed 
 */
struct NeedleParameters {
    const char* needle;
    struct NeedleOffsets offsets;
    __m512i first;
    __m512i mid;
    __m512i last;
};

struct NeedleParameters compileNeedle(const char* n, size_t n_length);

bool avx512EqualUpTo64(const char* a, const char* b, size_t length);

bool avx512SearchNeedle(const char* h, size_t h_length,
                        const struct NeedleParameters* needle);

#endif // INTR_H
