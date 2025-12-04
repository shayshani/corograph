add_executable(crg-kcore-single crg-kcore-single.cpp)
target_link_libraries(crg-kcore-single PRIVATE Galois::shmem)

add_executable(crg-kcore crg-kcore.cpp)
target_link_libraries(crg-kcore PRIVATE Galois::shmem)

add_executable(crg-kcore-perf crg-kcore-perf.cpp)
target_link_libraries(crg-kcore-perf PRIVATE Galois::shmem)

# Version with work counters enabled
add_executable(crg-kcore-perf-count crg-kcore-perf.cpp)
target_link_libraries(crg-kcore-perf-count PRIVATE Galois::shmem)
target_compile_definitions(crg-kcore-perf-count PRIVATE COUNT_WORK)