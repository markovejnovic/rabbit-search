#ifndef CLI_H
#define CLI_H

#include <stdlib.h>
#include <stdbool.h>

typedef struct {
    bool help;
    int jobs;
} cli_t;

cli_t cli_parse(size_t argc, const char** argv);

#endif // CLI_H