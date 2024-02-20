#include "sys.h"

#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// NOLINTNEXTLINE(cppcoreguidelines-avoid-non-const-global-variables)
static pthread_mutex_t exit_mutex;

void sys_global_init(void) {
  pthread_mutex_init(&exit_mutex, NULL);
}

size_t sys_get_avail_cores(void) { return sysconf(_SC_NPROCESSORS_ONLN); }

void sys_panic(int errno, const char* msgfmt, ...) {
  pthread_mutex_lock(&exit_mutex);

  va_list args;
  va_start(args, msgfmt);
  (void)vfprintf(stderr, msgfmt, args);
  va_end(args);

  // NOLINTNEXTLINE(concurrency-mt-unsafe)
  exit(errno);
}
