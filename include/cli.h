#ifndef CLI_H
#define CLI_H

#include <stdbool.h>
#include <stdlib.h>

typedef struct {
  bool help;
  int jobs;
  const char *search_directory;
} cli_t;

cli_t cli_parse(size_t argc, const char **argv);

void cli_help(cli_t args);

#endif // CLI_H
