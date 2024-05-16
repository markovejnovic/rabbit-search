#ifndef STRING_SEARCH_H
#define STRING_SEARCH_H

#include <stdbool.h>
#include <stddef.h>

/**
 * @brief Search for whether haystack contains needle.
 * Neither strings need be C strings.
 */
bool ssearch(
  const char *haystack,
  size_t haystack_sz,
  const char *needle,
  size_t needle_sz
);

#endif // STRING_SEARCH_H
