#ifndef INTR_H
#define INTR_H

#include <immintrin.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

static inline __mmask64 _maskUntil(size_t n) {
    return _bzhi_u64(0xFFFFFFFFFFFFFFFF, (uint32_t)n);
}

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

/**
 *  @brief  Chooses the offsets of the most interesting characters in a search needle.
 *
 *  @note This has been mostly taken from stringzilla.h
 *
 *  Search throughput can significantly deteriorate if we are matching the wrong characters.
 *  Say the needle is "aXaYa", and we are comparing the first, mid, and last character.
 *  If we use SIMD and compare many offsets at a time, comparing against "a" in every register is a waste.
 *
 *  Similarly, dealing with UTF8 inputs, we know that the lower bits of each character code carry more information.
 *  Cyrillic alphabet, for example, falls into [0x0410, 0x042F] code range for uppercase [А, Я], and
 *  into [0x0430, 0x044F] for lowercase [а, я]. Scanning through a text written in Russian, half of the
 *  bytes will carry absolutely no value and will be equal to 0x04.
 */
inline static struct NeedleOffsets needleOffsets(const char* start, size_t length) {
    struct NeedleOffsets offsets = {0, length / 2, length - 1, length};

    const bool has_duplicates =
        start[offsets.first] == start[offsets.mid] ||
        start[offsets.first] == start[offsets.last] ||
        start[offsets.mid] == start[offsets.last];

    // Loop through letters to find non-colliding variants.
    if (length > 3 && has_duplicates) {
        // Pivot the middle point right, until we find a character different from the first one.
        for (; start[offsets.mid] == start[offsets.first] && offsets.mid + 1 < offsets.last; ++offsets.mid) {}

        // Pivot the last (last) point left, until we find a different character.
        for (; (start[offsets.last] == start[offsets.mid] || start[offsets.last] == start[offsets.first]) && offsets.last > (offsets.mid + 1);
             --offsets.last) {}
    }

    //// TODO: Investigate alternative strategies for long needles.
    //// On very long needles we have the luxury to choose!
    //// Often dealing with UTF8, we will likely benfit from shifting the first and mid characters
    //// further to the right, to achieve not only uniqness within the needle, but also avoid common
    //// rune prefixes of 2-, 3-, and 4-byte codes.
    //if (length > 8) {
    //    // Pivot the first and mid points right, until we find a character, that:
    //    // > is different from others.
    //    // > doesn't start with 0b'110x'xxxx - only 5 bits of relevant info.
    //    // > doesn't start with 0b'1110'xxxx - only 4 bits of relevant info.
    //    // > doesn't start with 0b'1111'0xxx - only 3 bits of relevant info.
    //    //
    //    // So we are practically searching for byte values that start with 0b0xxx'xxxx or 0b'10xx'xxxx.
    //    // Meaning they fall in the range [0, 127] and [128, 191], in other words any unsigned int up to 191.
    //    uint8_t const *start_u8 = (uint8_t const *)start;
    //    sz_size_t vibrant_first = *first, vibrant_mid = *mid, vibrant_last = *last;

    //    // Let's begin with the seccond character, as the termination criterea there is more obvious
    //    // and we may end up with more variants to check for the first candidate.
    //    for (; (start_u8[vibrant_mid] > 191 || start_u8[vibrant_mid] == start_u8[vibrant_last]) &&
    //           (vibrant_mid + 1 < vibrant_last);
    //         ++vibrant_mid) {}

    //    // Now check if we've indeed found a good candidate or should revert the `vibrant_mid` to `mid`.
    //    if (start_u8[vibrant_mid] < 191) { *mid = vibrant_mid; }
    //    else { vibrant_mid = *mid; }

    //    // Now check the first character.
    //    for (; (start_u8[vibrant_first] > 191 || start_u8[vibrant_first] == start_u8[vibrant_mid] ||
    //            start_u8[vibrant_first] == start_u8[vibrant_last]) &&
    //           (vibrant_first + 1 < vibrant_mid);
    //         ++vibrant_first) {}

    //    // Now check if we've indeed found a good candidate or should revert the `vibrant_first` to `first`.
    //    // We don't need to shift the last one when dealing with texts as the last byte of the text is
    //    // also the last byte of a rune and contains the most information.
    //    if (start_u8[vibrant_first] < 191) { *first = vibrant_first; }
    //}

    return offsets;
}

inline struct NeedleParameters compileNeedle(const char* n, size_t n_length) {
    const struct NeedleOffsets offsets = needleOffsets(n, n_length);
    const __m512i n_first = _mm512_set1_epi8(n[offsets.first]);
    const __m512i n_mid = _mm512_set1_epi8(n[offsets.mid]);
    const __m512i n_last = _mm512_set1_epi8(n[offsets.last]);

    return (struct NeedleParameters) {
        .needle = n,
        .offsets = offsets,
        .first = n_first,
        .mid = n_mid,
        .last = n_last,
    };
}

/**
 * @brief  Compares two strings of equal length using AVX512 instructions.
 * @note   The caller is responsible to ensure that the length of the strings
 *         is a leq 64.
 */
static inline bool avx512EqualUpTo64(const char* a, const char* b, size_t length) {
    // This mask is used to pick out the bytes that we are interested in
    // matching.
    // Note that the mask may be pointless if length == 64 (which is most
    // cases), but we want to minimize the amount of speculation the CPU does.
    // TODO(mvejnovic): Investigate if the mask should be conditionally
    // computed. (unlikely)
    const __mmask64 mask = _maskUntil(length);

    const __m512i a_vec = _mm512_maskz_loadu_epi8(mask, a);
    const __m512i b_vec = _mm512_maskz_loadu_epi8(mask, b);
    const __mmask64 neq = _mm512_mask_cmpneq_epi8_mask(mask, a_vec, b_vec);
    return neq == 0;
}

static inline bool avx512Equal(const char* a, const char* b, size_t length) {
    __mmask64 mask;
    __m512i a_vec = _mm512_maskz_loadu_epi8(mask, a);
    __m512i b_vec = _mm512_maskz_loadu_epi8(mask, b);

    while (length >= 64) {
        a_vec = _mm512_loadu_si512(a);
        b_vec = _mm512_loadu_si512(b);
        mask = _mm512_cmpneq_epi8_mask(a_vec, b_vec);
        if (mask != 0) return false;
        a += 64, b += 64, length -= 64;
    }

    if (length) {
        mask = _maskUntil(length);
        a_vec = _mm512_maskz_loadu_epi8(mask, a);
        b_vec = _mm512_maskz_loadu_epi8(mask, b);
        // Reuse the same `mask` variable to find the bit that doesn't match
        mask = _mm512_mask_cmpneq_epi8_mask(mask, a_vec, b_vec);
        return mask == 0;
    } else {
        return true;
    }
}

bool avx512SearchNeedle(const char* h, size_t h_length,
                        const struct NeedleParameters* needle);

#endif // INTR_H
