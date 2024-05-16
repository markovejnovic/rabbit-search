cmake_minimum_required(VERSION 3.20)

include(FetchContent)

set(CMAKE_C_CLANG_TIDY
    clang-tidy
)

project(
    rabbit-search
    VERSION 0.1.0
    LANGUAGES C
)

option(OPTIMIZE_FOR_NATIVE "Build with -march=native" ON)

set(C_STANDARD C17)

FetchContent_Declare(stringzilla
  GIT_REPOSITORY https://github.com/ashvardanian/stringzilla.git
  GIT_TAG v3.8.4
)
FetchContent_MakeAvailable(stringzilla)

include(CheckCCompilerFlag)
CHECK_C_COMPILER_FLAG("-march=native" COMPILER_SUPPORTS_MARCH_NATIVE)
if(COMPILER_SUPPORTS_MARCH_NATIVE AND OPTIMIZE_FOR_NATIVE)
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -march=native")
endif()
set(CMAKE_CXX_FLAGS_RELEASE "-Ofast")

add_executable(
  rbbs src/app.c src/job_q.c src/pathops.c src/cli.c src/sys.c
  src/string_search.c src/filters.c
)
target_include_directories(rbbs
  PRIVATE include ${stringzilla_SOURCE_DIR}/include)
