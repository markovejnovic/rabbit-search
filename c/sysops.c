#include "sysops.h"

#define _GNU_SOURCE
#include <pthread.h>
#include <sys/sysinfo.h>

int pinThreadToCore(int core_id) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(core_id, &cpuset);
    return pthread_setaffinity_np(pthread_self(), sizeof(cpu_set_t), &cpuset);
}

int getNumCpus(void) {
    return get_nprocs();
}
