add_executable(crg-pr crg-pr.cpp)
target_link_libraries(crg-pr PRIVATE Galois::shmem)

add_executable(crg-pr-perf crg-pr-perf.cpp)
target_link_libraries(crg-pr-perf PRIVATE Galois::shmem)

