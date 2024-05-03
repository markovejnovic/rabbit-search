cmake_minimum_required(VERSION 3.20)

set(CMAKE_C_CLANG_TIDY
    clang-tidy
)

project(
    rabbit-search
    VERSION 0.1.0
    LANGUAGES C
)
set(C_STANDARD C17)

add_executable(
    rbbs src/app.c src/job_q.c src/pathops.c src/cli.c src/sys.c
    src/string_search.c src/filters.c
)
target_include_directories(rbbs PRIVATE include)
