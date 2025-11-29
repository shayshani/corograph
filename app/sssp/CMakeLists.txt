
add_executable(crg-sssp crg-sssp.cpp)
target_link_libraries(crg-sssp PRIVATE Galois::shmem)

add_executable(crg-sssp-perf crg-sssp-perf.cpp)
target_link_libraries(crg-sssp-perf PRIVATE Galois::shmem)