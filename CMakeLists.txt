cmake_minimum_required(VERSION 3.20)

project(
    rabbit-search
    VERSION 0.1.0
    LANGUAGES C
)
set(C_STANDARD C17)

add_executable(
    rbbs src/app.c src/job_q.c src/pathops.c src/cli.c src/sys.c
)
target_include_directories(rbbs PRIVATE include)