#include "sys.h"

#include <unistd.h>

size_t sys_get_avail_cores(void) {
    return sysconf(_SC_NPROCESSORS_ONLN);
}