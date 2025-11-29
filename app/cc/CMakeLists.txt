add_executable(crg-cc crg-cc.cpp)
target_link_libraries(crg-cc PRIVATE Galois::shmem)

add_executable(crg-cc-async crg-cc-async.cpp)
target_link_libraries(crg-cc-async PRIVATE Galois::shmem)

add_executable(crg-cc-perf crg-cc-perf.cpp)
target_link_libraries(crg-cc-perf PRIVATE Galois::shmem)