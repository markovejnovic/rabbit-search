// NOLINTBEGIN
#include "string_search.h"
#include <string.h>

// TODO(mvejnovic): Random implementation from the interwebs.
#ifndef MAX
#define MAX(a, b) ((a > b) ? (a) : (b))
#endif

void fillBadCharIndexTable(
    /*----------------------------------------------------------------
    function:
       the table fits for 8 bit character only (including utf-8)
    parameters: */
    size_t aBadCharIndexTable[], char const *const pPattern,
    size_t const patternLength)
/*----------------------------------------------------------------*/
{
  size_t i;
  size_t remainingPatternLength = patternLength - 1;

  for (i = 0; i < 256; ++i) {
    aBadCharIndexTable[i] = patternLength;
  }
  for (i = 0; i < patternLength; ++i) {
    aBadCharIndexTable[pPattern[i]] = remainingPatternLength--;
  }
}

void fillGoodSuffixRuleTable(
    /*----------------------------------------------------------------
    function:
       the table fits for patterns of length < 256; for longer patterns ... (1
    of)
       - increase the static size
       - use variable length arrays and >= C99 compilers
       - allocate (and finally release) heap according to demand
    parameters: */
    size_t aGoodSuffixIndexTable[],
    char const *const pPattern, size_t const patternLength)
/*----------------------------------------------------------------*/
{
  size_t const highestPatternIndex = patternLength - 1;
  size_t prefixLength = 1;

  /* complementary prefix length, i.e. difference from highest possible pattern
   * index and prefix length */
  size_t cplPrefixLength = highestPatternIndex;

  /* complementary length of recently inspected pattern substring which is
   * simultaneously pattern prefix and suffix */
  size_t cplPrefixSuffixLength = patternLength;

  /* too hard to explain in a C source ;-) */
  size_t iRepeatedSuffixMax;

  aGoodSuffixIndexTable[cplPrefixLength] = patternLength;

  while (cplPrefixLength > 0) {
    if (!strncmp(pPattern, pPattern + cplPrefixLength, prefixLength)) {
      cplPrefixSuffixLength = cplPrefixLength;
    }

    aGoodSuffixIndexTable[--cplPrefixLength] =
        cplPrefixSuffixLength + prefixLength++;
  }

  if (pPattern[0] != pPattern[highestPatternIndex]) {
    aGoodSuffixIndexTable[highestPatternIndex] = highestPatternIndex;
  }

  for (iRepeatedSuffixMax = 1; iRepeatedSuffixMax < highestPatternIndex;
       ++iRepeatedSuffixMax) {
    size_t iSuffix = highestPatternIndex;
    size_t iRepeatedSuffix = iRepeatedSuffixMax;

    do {
      if (pPattern[iRepeatedSuffix] != pPattern[iSuffix]) {
        aGoodSuffixIndexTable[iSuffix] = highestPatternIndex - iRepeatedSuffix;
        break;
      }

      --iSuffix;
    } while (--iRepeatedSuffix > 0);
  }
}

char const *boyerMoore(
    /*----------------------------------------------------------------
    function:
       find a pattern (needle) inside a text (haystack)
    parameters: */
    char const *const pHaystack, size_t const haystackLength,
    char const *const pPattern)
/*----------------------------------------------------------------*/
{
  size_t const patternLength = strlen(pPattern);
  size_t const highestPatternIndex = patternLength - 1;
  size_t aBadCharIndexTable[256];
  size_t aGoodSuffixIndexTable[256];

  if (*pPattern == '\0') {
    return pHaystack;
  }

  if (patternLength <= 1) {
    return strchr(pHaystack, *pPattern);
  }

  if (patternLength >= sizeof aGoodSuffixIndexTable) {
    /* exit for too long patterns */
    return 0;
  }

  {
    char const *pInHaystack = pHaystack + highestPatternIndex;

    /* search preparation */
    fillBadCharIndexTable(aBadCharIndexTable, pPattern, patternLength);
    fillGoodSuffixRuleTable(aGoodSuffixIndexTable, pPattern, patternLength);

    /* search execution */
    while (pInHaystack++ < pHaystack + haystackLength) {
      int iPattern = (int)highestPatternIndex;

      while (*--pInHaystack == pPattern[iPattern]) {
        if (--iPattern < 0) {
          return pInHaystack;
        }
      }

      pInHaystack += MAX(aBadCharIndexTable[*pInHaystack],
                         aGoodSuffixIndexTable[iPattern]);
    }
  }

  return 0;
}

bool ssearch(const char *haystack, size_t haystack_sz, const char *needle) {
  const char *result = boyerMoore(haystack, haystack_sz, needle);

  return result != NULL;
}
// NOLINTEND
