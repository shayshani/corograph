
add_executable(crg-sssp crg-sssp.cpp)
target_link_libraries(crg-sssp PRIVATE Galois::shmem)

add_executable(crg-sssp-perf crg-sssp-perf.cpp)
target_link_libraries(crg-sssp-perf PRIVATE Galois::shmem)

# Version with work counters enabled
add_executable(crg-sssp-perf-count crg-sssp-perf.cpp)
target_link_libraries(crg-sssp-perf-count PRIVATE Galois::shmem)
target_compile_definitions(crg-sssp-perf-count PRIVATE COUNT_WORK)