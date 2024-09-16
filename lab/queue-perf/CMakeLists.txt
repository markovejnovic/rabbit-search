project(queue-perf)

add_executable(queue-perf src/benchmarks.cpp)
target_include_directories(queue-perf PRIVATE include)
set_target_properties(queue-perf PROPERTIES CXX_STANDARD 20)
target_link_libraries(queue-perf benchmark)
