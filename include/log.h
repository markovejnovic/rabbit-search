#ifndef LOG_H
#define LOG_H

#include "features.h"

#include <pthread.h>
#include <stdio.h>

#define LOG_SYSFAULT(msg) perror(msg)
#define LOG_ERROR_FMT(msg, ...) (void)fprintf(stderr, msg "\n", __VA_ARGS__)

#if RABBITSEARCH_LOGS
#  define LOG_DEBUG(msg)                                                       \
    (void)fprintf(stderr, "[t:%llx] (f:%s) " msg "\n",                         \
            (unsigned long long)pthread_self(), __func__)

#  define LOG_DEBUG_FMT(msg, ...)                                              \
    (void)fprintf(stderr, "[t:%llx] (f:%s) " msg "\n",                         \
            (unsigned long long)pthread_self(), __func__, __VA_ARGS__)
#else
#define LOG_DEBUG(msg)
#define LOG_DEBUG_FMT(msg, ...)
#endif

#endif // LOG_H
