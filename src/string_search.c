// NOLINTBEGIN
#include "string_search.h"
#include <stdlib.h>
#include "stringzilla/stringzilla.h"

bool ssearch(
  const char *haystack, size_t haystack_sz,
  const char *needle, size_t needle_sz
) {
  return sz_find(haystack, haystack_sz, needle, needle_sz) != NULL;
}
// NOLINTEND
