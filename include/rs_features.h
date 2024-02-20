#ifndef RS_FEATURES_H
#define RS_FEATURES_H

#include <stdbool.h>

#ifndef NDEBUG
#  ifndef RABBITSEARCH_LOGS
#    define RABBITSEARCH_LOGS true
#  endif
#  ifndef RABBITSEARCH_METRICS
#    define RABBITSEARCH_METRICS_ENABLE true
#  endif
#else
#  define RABBITSEARCH_METRICS false
#  define RABBITSEARCH_LOGS false
#endif

#endif // RS_FEATURES_H
