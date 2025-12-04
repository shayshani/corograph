#ifndef GALOIS_RUNTIME_WORK_COUNTERS_H
#define GALOIS_RUNTIME_WORK_COUNTERS_H

#include <cstdint>
#include <cstdio>

// Compile with -DCOUNT_WORK to enable work counters
#ifdef COUNT_WORK
namespace galois::runtime::counters {
  inline uint64_t prefetches{0};  // prefetch instructions issued

  inline void reset() {
    prefetches = 0;
  }

  inline void print() {
    fprintf(stderr, "\n[WORK] === WORK COUNTERS ===\n");
    fprintf(stderr, "[WORK] prefetches: %lu\n", prefetches);
    fprintf(stderr, "[WORK] ========================\n\n");
  }
}
#endif

#endif // GALOIS_RUNTIME_WORK_COUNTERS_H
