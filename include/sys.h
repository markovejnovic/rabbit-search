#ifndef SYS_H
#define SYS_H

#include <stddef.h>

void sys_global_init(void);

size_t sys_get_avail_cores(void);

void sys_panic(int errno, const char* msgfmt, ...);

#endif // SYS_H
