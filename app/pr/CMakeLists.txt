add_executable(crg-pr crg-pr.cpp)
target_link_libraries(crg-pr PRIVATE Galois::shmem)

add_executable(crg-pr-perf crg-pr-perf.cpp)
target_link_libraries(crg-pr-perf PRIVATE Galois::shmem)

# Version with work counters enabled
add_executable(crg-pr-perf-count crg-pr-perf.cpp)
target_link_libraries(crg-pr-perf-count PRIVATE Galois::shmem)
target_compile_definitions(crg-pr-perf-count PRIVATE COUNT_WORK)

