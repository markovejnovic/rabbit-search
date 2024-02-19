#ifndef STRING_SEARCH_H
#define STRING_SEARCH_H

#include <stdbool.h>
#include <stddef.h>

/**
 * @brief Search for whether haystack contains needle.
 * 
 * Both strings must be C-strings.
 */
bool ssearch(const char* haystack, size_t haystack_sz, const char* needle);

#endif // STRING_SEARCH_H