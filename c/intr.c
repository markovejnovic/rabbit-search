#include "intr.h"
#include <pthread.h>
/**
 * @note The caller is responsible to ensure that the haystack is >= needle.
 * @note The caller is responsbile to ensure that the needle is at least 2
 *       bytes long.
 *
 * @note This function has been modified from the original version in
 * stringzila.h. See sz_find_avx512 for the original version.
 */
bool avx512SearchNeedle(const char* h, size_t h_length, const struct NeedleParameters* needle) {
    // Pick the parts of the needle that are worth comparing.

    // The string is guaranteed to be at most 64 bytes long. We can load it in
    // one go.
    const __mmask64 mask = _maskUntil(h_length - needle->offsets.length + 1);
    const __m512i h_first = _mm512_maskz_loadu_epi8(mask, h + needle->offsets.first);
    const __m512i h_mid = _mm512_maskz_loadu_epi8(mask, h + needle->offsets.mid);
    const __m512i h_last = _mm512_maskz_loadu_epi8(mask, h + needle->offsets.last);
    __mmask64 matches = _kand_mask64(
        _kand_mask64(_mm512_cmpeq_epi8_mask(h_first, needle->first),
                     _mm512_cmpeq_epi8_mask(h_mid, needle->mid)),
        _mm512_cmpeq_epi8_mask(h_last, needle->last)
    );

    while (matches) {
        unsigned long long potential_offset = _tzcnt_u64(matches);
        if (needle->offsets.length <= 3 || avx512EqualUpTo64(h + potential_offset, needle->needle, needle->offsets.length))
            return h + potential_offset;
        matches &= matches - 1;
    }

    return false;
}
