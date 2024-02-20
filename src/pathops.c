#include "pathops.h"
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

char *path_mkcat(const char *base, const char *tip) {
  // TODO(markovejnovic): Hankey implementation, obviously barely supports
  //                      *nix.
  const size_t strlen_l = strlen(base);
  const size_t total_sz = strlen_l + strlen(tip) + 1;
  char *new = malloc(total_sz);
  strlcpy(&new[0], base, total_sz - 1);
  new[strlen_l] = '/';
  strlcpy(&new[strlen_l + 1], tip, total_sz - 1);

  return new;
}
