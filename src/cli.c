#include "cli.h"
#include "pp.h"
#include "sys.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

typedef size_t (*parser_f)(cli_t *const, const char **);

struct arg_entry {
  const char *help;
  const char *key_long;
  const char *key_short;
  parser_f parser;
};

static size_t help_parser(cli_t *out, const char **argv) {
  out->help = true;
  return 1;
}

static size_t job_parser(cli_t *out, const char **argv) {
  const int TARGET_BASE = 10;

  out->jobs = (int)strtol(argv[1], NULL, TARGET_BASE);
  return 2;
}

static const struct arg_entry args_table[] = {
    {
        .key_long = "--help",
        .key_short = "-h",
        .help = "-h, --help      Print this message.",
        .parser = &help_parser,
    },
    {
        .key_short = "-j",
        .key_long = "--jobs",
        .help = "-j, --jobs [N]  Use N threads in parallel.",
        .parser = &job_parser,
    },
};

cli_t cli_parse(size_t argc, const char **argv) {
  cli_t args = {
      .jobs = -1,
      .help = false,
      .search_directory = NULL,
  };

  for (size_t i = 1; i < argc;) {
    size_t arguments_parsed = 1;
    bool arg_is_opt = false;

    for (size_t j = 0; j < arr_sz(args_table); j++) {
      struct arg_entry const *const candidate_arg = &args_table[j];

      if (strcmp(argv[i], candidate_arg->key_short) == 0 ||
          strcmp(argv[i], candidate_arg->key_long) == 0) {
        arguments_parsed = candidate_arg->parser(&args, &argv[i]);
        arg_is_opt = true;
        break;
      }
    }

    if (!arg_is_opt) {
      if (args.search_directory != NULL) {
        // TODO(mvejnovic): Propagate error up.
        sys_panic(1,
          "Invalid arguments. Cannot search multiple directories.\n");
      }

      args.search_directory = argv[i];
    }

    i += arguments_parsed;
  }

  return args;
}

void cli_help(cli_t args) {
  (void)args;

  // Nobody can help.
  printf("Usage: rbbs [OPTION]... NEEDLE\nSearch for NEEDLE in cwd.\n\n");

  for (size_t i = 0; i < arr_sz(args_table); i++) {
    struct arg_entry const *const opt = &args_table[i];
    printf("    %s\n", opt->help);
  }
}
