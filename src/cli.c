#include "cli.h"

#include <stdbool.h>
#include <string.h>

typedef size_t (*parser_f)(cli_t* const, const char**);

struct arg_entry {
    const char* help;
    const char* key_long;
    const char* key_short;
    parser_f parser;
};

static size_t help_parser(cli_t* out, const char**) {
    out->help = true;
    return 1;
}

static size_t job_parser(cli_t* out, const char** argv) {
    out->jobs = (int)strtol(argv[1], NULL, 10);
    return 2;
}

static const struct arg_entry args_table[] = {
    {
        .key_long = "--help",
        .key_short = "-h",
        .help = "Prints this message",
        .parser = &help_parser,
    },
    {
        .key_short = "-j",
        .key_long = "--jobs",
        .help = "Job count",
        .parser = &job_parser,
    },
};

cli_t cli_parse(size_t argc, const char** argv) {
    cli_t args = {
        .jobs = -1,
        .help = false,
    };

    for (size_t i = 0; i < argc;) {
        for (size_t j = 0; j < sizeof(args_table) / sizeof(args_table[0]); j++) {
            struct arg_entry const * const candidate_arg = &args_table[j];

            if (strcmp(argv[i], candidate_arg->key_short) == 0 ||
                    strcmp(argv[i], candidate_arg->key_long) == 0) {
                i += candidate_arg->parser(&args, &argv[i]);
                continue;
            }
        }

        i++;
    }

    return args;
}