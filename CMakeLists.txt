cmake_minimum_required(VERSION 3.28)
project(rbs LANGUAGES CXX)

option(RBS_USE_MIMALLOC "Use mimalloc for memory allocation" ON)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(FetchContent)

FetchContent_Declare(
  concurrentqueue_proj
  QUIET
  GIT_REPOSITORY https://github.com/cameron314/concurrentqueue.git
  GIT_TAG v1.0.4
)

FetchContent_Declare(
  stringzilla
  QUIET GIT_REPOSITORY https://github.com/ashvardanian/stringzilla.git
  GIT_TAG v3.12.5
)
FetchContent_MakeAvailable(concurrentqueue_proj)
FetchContent_MakeAvailable(stringzilla)

if (RBS_USE_MIMALLOC)
  FetchContent_Declare(
    mimalloc
    QUIET GIT_REPOSITORY https://github.com/microsoft/mimalloc.git
    GIT_TAG v3.0.8
  )

  FetchContent_MakeAvailable(mimalloc)

  set(RBS_MIMALLOC_LIB mimalloc-static)
else()
  set(RBS_MIMALLOC_LIB "")
endif()

include(CheckCXXCompilerFlag)
string(APPEND CMAKE_CXX_FLAGS " -march=native")
string(APPEND CMAKE_CXX_FLAGS " -fno-plt")
string(APPEND CMAKE_CXX_FLAGS " -fno-rtti")
string(APPEND CMAKE_CXX_FLAGS " -ffast-math")
string(APPEND CMAKE_CXX_FLAGS " -fassociative-math")
string(APPEND CMAKE_CXX_FLAGS " -fno-math-errno")
string(APPEND CMAKE_CXX_FLAGS " -fmerge-all-constants")
string(APPEND CMAKE_CXX_FLAGS " -fno-stack-protector")
if (RBS_PROFILE_MODE)
  string(APPEND CMAKE_CXX_FLAGS " -fno-inline")
  string(APPEND CMAKE_CXX_FLAGS " -fno-omit-frame-pointer")
  string(APPEND CMAKE_CXX_FLAGS " -fno-unroll-loops")
  string(APPEND CMAKE_CXX_FLAGS " -fno-inline-functions")
else()
  set(CMAKE_INTERPROCEDURAL_OPTIMIZATION_RELEASE TRUE)
  string(APPEND CMAKE_CXX_FLAGS " -finline-functions")
  string(APPEND CMAKE_CXX_FLAGS " -fomit-frame-pointer")
  string(APPEND CMAKE_CXX_FLAGS " -funroll-loops")
endif()

set(RBS_SOURCE_FILES
  bin/rbs.cpp
)

file(GLOB RBS_HEADER_FILES CONFIGURE_DEPENDS
  "bin/*.hpp"
)

add_executable(rbs
  ${RBS_SOURCE_FILES}
)
target_include_directories(rbs PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/bin
)

# Use same sanitizer flags for the test
target_link_libraries(rbs PRIVATE concurrentqueue stringzilla ${RBS_MIMALLOC_LIB})

if (DEFINED RBS_CLANG_TIDY)
  set(clang_tidy_outputs)

  foreach(sourcefile_long IN LISTS RBS_SOURCE_FILES)
    get_filename_component(sourcefile ${sourcefile_long} NAME)
    set(outputfile "${CMAKE_CURRENT_BINARY_DIR}/clang-tidy-${sourcefile}.lnt")

    add_custom_command(
      OUTPUT ${outputfile}
      COMMAND ${RBS_CLANG_TIDY} ${sourcefile_long}
        --config-file=${CMAKE_CURRENT_SOURCE_DIR}/.clang-tidy
        2>&1 | tee ${outputfile}
      DEPENDS ${sourcefile_long}
      COMMENT "Running clang-tidy on ${sourcefile}..."
    )

    list(APPEND clang_tidy_outputs ${outputfile})
  endforeach()

  add_custom_target(rbs_clang_tidy_check ALL
    DEPENDS ${clang_tidy_outputs}
    COMMENT "Running clang-tidy on all source files..."
  )
endif()

if (DEFINED RBS_CLANG_FORMAT)
  add_custom_target(rbs_clang_format_check ALL
    COMMAND ${RBS_CLANG_FORMAT} --dry-run --Werror
            ${RBS_SOURCE_FILES} ${RBS_HEADER_FILES}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Checking code format..."
  )

  add_custom_target(rbs_clang_format_fix
    COMMAND ${RBS_CLANG_FORMAT} -i
            ${RBS_SOURCE_FILES} ${RBS_HEADER_FILES}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Fixing clang-format..."
  )
endif()
