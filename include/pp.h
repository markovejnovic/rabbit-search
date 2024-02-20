#ifndef PP_H
#define PP_H

#define likely(x) __builtin_expect(!!(x), 1)
#define unlikely(x) __builtin_expect(!!(x), 0)

#define arr_sz(xs) (sizeof(xs) / sizeof((xs)[0]))

#endif // PP_H
