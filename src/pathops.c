#include "pathops.h"
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

char* path_mkcat(const char* l, const char* r) {
    // TODO(markovejnovic): Hankey implementation, obviously barely supports
    //                      *nix.
    const size_t strlen_l = strlen(l);
    const size_t total_sz = strlen_l + strlen(r) + 1;
    char* new = malloc(total_sz);
    strcpy(&new[0], l);
    new[strlen_l] = '/';
    strcpy(&new[strlen_l + 1], r);

    return new;
}