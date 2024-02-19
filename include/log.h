#ifndef LOG_H
#define LOG_H

#include <stdio.h>
#include <pthread.h>

#define LOG_SYSFAULT(msg) perror(msg)
#define LOG_ERROR_FMT(msg, ...) fprintf(stderr, msg "\n", __VA_ARGS__) 

#ifndef NDEBUG
#  define LOG_DEBUG(msg) fprintf(stderr, "[thread: %llx] " msg "\n", pthread_self())
#  define LOG_DEBUG_FMT(msg, ...) fprintf(stderr, "[thread: %llx] " msg "\n", pthread_self(), __VA_ARGS__)
#endif // NDEBUG

#endif // LOG_H