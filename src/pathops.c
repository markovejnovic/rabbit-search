#include "pathops.h"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

char *path_mkcat(const char *base, const char *tip) {
  // TODO(markovejnovic): Hankey implementation, obviously barely supports
  //                      *nix.
  const size_t base_len = strlen(base);
  const size_t tip_len = strlen(tip);

  // Add one for the '/' separator
  const size_t total_sz = base_len + tip_len + 1;

  // Add one for the trailing \0
  const size_t buf_size = total_sz + 1;
  char *new = malloc(buf_size);

  // TODO(markovejnovic): strlcpy is a tad slower than strncpy
  strlcpy(&new[0], base, buf_size);
  new[base_len] = '/'; new[base_len + 1] = 0;
  // TODO(markovejnovic): strlcat is a little slow
  strlcat(new, tip, buf_size);

  return new;
}
