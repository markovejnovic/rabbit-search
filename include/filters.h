#ifndef FILTERS_H
#define FILTERS_H

#include <stdbool.h>

/**
 * @brief Determine whether a directory is interesting and should be traversed.
 *        
 * This always returns false for "." and "..". It might also return false for
 * other interesting filters based on the filter configuration.
 */
bool filter_directory(const char* dirname);

#endif // FILTERS_H
