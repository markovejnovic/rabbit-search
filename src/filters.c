#include "filters.h"
#include <string.h>

bool filter_directory(const char* dirname) {
  return strcmp(dirname, ".") != 0
    && strcmp(dirname, "..") != 0
    && strcmp(dirname, ".git") != 0;
}
