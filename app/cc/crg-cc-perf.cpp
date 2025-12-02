#include "galois/AtomicHelpers.h"
#include "galois/Bag.h"
#include "galois/graphs/LCGraph.h"
#include "galois/runtime/Executor_EdgeMap.h"
#include "galois/substrate/ThreadPool.h"
#include <sys/ioctl.h>
#include <linux/perf_event.h>
#include <asm/unistd.h>
#include <unistd.h>
#include <cstring>
#include <sys/syscall.h>
#include <vector>
#include <map>

unsigned int stepShift = 13;
std::string inputFile;
unsigned int reportNode = 4819611;
int numThreads = 1;
const uint32 PSIZE = 18;

using Graph = galois::graphs::graph<uint32>;
struct UpdateRequestIndexer {
  typedef std::less<uint32> compare;
  unsigned shift;
  template <typename R> unsigned int operator()(const R &req) const {
    if (req.dist < 10)
      return req.dist >> shift;
    return 10;
  }
};
constexpr static const unsigned CHUNK_SIZE = 1024U;
constexpr static const unsigned CG_CHUNK_SIZE = 4096U;

using vw = galois::graphs::vertex_warp<uint32>;
using pw = galois::graphs::part_wrap<uint32>;
namespace gwl = galois::worklists;
using PSchunk = gwl::CM<CHUNK_SIZE, vw>;
using SGchunk = gwl::CM2<CG_CHUNK_SIZE, pw>;
using Ck = gwl::CK<CHUNK_SIZE, vw>;
using Ck2 = gwl::CK<CG_CHUNK_SIZE, pw>;
using OBIM = gwl::OBIM<UpdateRequestIndexer, PSchunk, SGchunk, Ck, Ck2>;
typedef std::pair<uint32, uint32> label_type;

struct LNode {
  std::atomic<unsigned int> comp_current;
  unsigned int comp_old;
};

void cc(Graph &graph, auto &tt, LNode *label) {
  galois::GReduceLogicalOr changed;
  uint32 iter = 0;
  do {
    printf("iter %d\n", ++iter);
    changed.reset();
    galois::do_all(
        galois::iterate(tt),
        [&](const uint32 &src) {
          LNode &sdata = label[src];
          if (sdata.comp_old > sdata.comp_current) {
            sdata.comp_old = sdata.comp_current;
            unsigned int label_new = sdata.comp_current;
            changed.update(true);
            for (uint32 e = graph.offset[src]; e < graph.offset[src + 1]; e++) {
              uint32 dst = graph.ngh[e];
              auto &ddata = label[dst];
              galois::atomicMin(ddata.comp_current, label_new);
            }
          }
        },
        galois::disable_conflict_detection(), galois::steal(),
        galois::loopname("LabelPropAlgo"));
  } while (changed.reduce());
}

void init_galois(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    if (i + 1 != argc) {
      if (strcmp(argv[i], "-delta") == 0) {
        stepShift = (unsigned int)atoi(argv[i + 1]);
        i++;
      }
      if (strcmp(argv[i], "-t") == 0) {
        numThreads = (int)atoi(argv[i + 1]);
        i++;
      }
    }
  }
  if (argc < 2) {
    printf("Usage : %s <filename> -t <numThreads>\n", argv[0]);
    exit(1);
  }
  inputFile = std::string(argv[1]);
  numThreads = galois::setActiveThreads(numThreads);
}

template <typename TMP> struct Range {
  TMP &tmp;
  Range(TMP &t) : tmp(t) {}
  void operator()(unsigned tid, unsigned total) { tmp.range(tid, total); }
};
template <typename TMP> void readGraphDispatch(TMP &tmp) {
  Range<TMP> ranger(tmp);
  galois::on_each(ranger);
}

class temp : private galois::graphs::internal::LocalIteratorFeature<true> {
  uint32 num;

public:
  temp(uint32 _num) : num(_num) {}
  void range(uint32 tid, uint32 total) {
    uint32 len = num / total + 1;
    this->setLocalRange(len * tid, std::min(num, len * (tid + 1)));
  }
  using iterator = boost::counting_iterator<uint32>;
  typedef iterator local_iterator;
  local_iterator local_begin() { return iterator(this->localBegin(num)); }
  local_iterator local_end() { return iterator(this->localEnd(num)); }
  iterator begin() const { return iterator(0); }
  iterator end() const { return iterator(num); }
};

//==============================================================================
// Perf event infrastructure
//==============================================================================

struct PerfCounter {
  int fd;
  const char* name;
  uint64_t value;
};

static std::vector<PerfCounter> perf_counters;

static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
                            int cpu, int group_fd, unsigned long flags) {
  return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

void perf_init() {
  struct perf_event_attr pe;

  struct {
    uint32_t type;
    uint64_t config;
    const char* name;
  } events[] = {
    {PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES, "cycles"},
    {PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS, "instructions"},
    {PERF_TYPE_RAW, 0x0148, "l1d_pend_miss.pending"},
    {PERF_TYPE_RAW, 0x0148 | (1ULL << 24), "l1d_pend_miss.pending_cycles"},
    {PERF_TYPE_HW_CACHE,
     PERF_COUNT_HW_CACHE_L1D | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16),
     "L1-dcache-load-misses"},
    {PERF_TYPE_HW_CACHE,
     PERF_COUNT_HW_CACHE_LL | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16),
     "LLC-load-misses"},
    {PERF_TYPE_RAW, 0x14a3 | (0x14ULL << 24), "cycle_activity.stalls_mem_any"},

    // mem_inst_retired.all_loads: event=0xD0, umask=0x81
    // Counts all retired load instructions
    {PERF_TYPE_RAW, 0x81D0, "mem_inst_retired.all_loads"},

    // mem_load_retired.l3_miss: event=0xD1, umask=0x20
    // Counts retired load instructions that missed L3 cache
    {PERF_TYPE_RAW, 0x20D1, "mem_load_retired.l3_miss"},

    // longest_lat_cache.miss: event=0x2E, umask=0x41
    // Counts LLC misses including prefetches
    {PERF_TYPE_RAW, 0x412E, "longest_lat_cache.miss"},
  };

  for (auto& ev : events) {
    memset(&pe, 0, sizeof(pe));
    pe.type = ev.type;
    pe.size = sizeof(pe);
    pe.config = ev.config;
    pe.disabled = 1;
    pe.exclude_kernel = 1;
    pe.exclude_hv = 1;

    int fd = perf_event_open(&pe, 0, -1, -1, 0);
    if (fd == -1) {
      fprintf(stderr, "Warning: Failed to open perf event %s: %s\n", ev.name, strerror(errno));
      continue;
    }
    perf_counters.push_back({fd, ev.name, 0});
  }

  fprintf(stderr, "[PERF] Initialized %zu counters\n", perf_counters.size());
}

void perf_start() {
  for (auto& pc : perf_counters) {
    ioctl(pc.fd, PERF_EVENT_IOC_RESET, 0);
    ioctl(pc.fd, PERF_EVENT_IOC_ENABLE, 0);
  }
  fprintf(stderr, "[PERF] >>> COUNTING ENABLED <<<\n");
}

void perf_stop() {
  for (auto& pc : perf_counters) {
    ioctl(pc.fd, PERF_EVENT_IOC_DISABLE, 0);
  }
  fprintf(stderr, "[PERF] >>> COUNTING DISABLED <<<\n");
}

void perf_read_and_print() {
  fprintf(stderr, "\n[PERF] === RESULTS (Algorithm Only) ===\n");

  uint64_t cycles = 0, instructions = 0;
  uint64_t pending = 0, pending_cycles = 0;
  uint64_t stalls_mem_any = 0;

  for (auto& pc : perf_counters) {
    long long count;
    if (read(pc.fd, &count, sizeof(count)) == sizeof(count)) {
      pc.value = count;
      fprintf(stderr, "[PERF] %s: %lld\n", pc.name, count);

      if (strcmp(pc.name, "cycles") == 0) cycles = count;
      if (strcmp(pc.name, "instructions") == 0) instructions = count;
      if (strcmp(pc.name, "l1d_pend_miss.pending") == 0) pending = count;
      if (strcmp(pc.name, "l1d_pend_miss.pending_cycles") == 0) pending_cycles = count;
      if (strcmp(pc.name, "cycle_activity.stalls_mem_any") == 0) stalls_mem_any = count;
    }
  }

  fprintf(stderr, "\n[PERF] === DERIVED METRICS ===\n");
  if (cycles > 0) {
    fprintf(stderr, "[PERF] IPC: %.3f\n", (double)instructions / cycles);
  }
  if (pending_cycles > 0) {
    fprintf(stderr, "[PERF] MLP: %.3f\n", (double)pending / pending_cycles);
    fprintf(stderr, "[PERF] Memory Stall %% (pending_cycles): %.1f%%\n", (double)pending_cycles / cycles * 100);
  }
  if (stalls_mem_any > 0 && cycles > 0) {
    fprintf(stderr, "[PERF] Memory Bound %% (paper metric): %.1f%%\n", (double)stalls_mem_any / cycles * 100);
  }
  fprintf(stderr, "[PERF] ========================\n\n");
}

void perf_cleanup() {
  for (auto& pc : perf_counters) {
    close(pc.fd);
  }
  perf_counters.clear();
}

//==============================================================================
// Main
//==============================================================================

int main(int argc, char **argv) {
  galois::substrate::ThreadPool tp;
  std::unique_ptr<galois::substrate::internal::LocalTerminationDetection<>>
      m_termPtr;
  std::unique_ptr<galois::substrate::internal::BarrierInstance<>> m_biPtr;
  galois::substrate::internal::setThreadPool(&tp);
  m_biPtr = std::make_unique<galois::substrate::internal::BarrierInstance<>>();
  m_termPtr = std::make_unique<
      galois::substrate::internal::LocalTerminationDetection<>>();
  galois::substrate::internal::setBarrierInstance(m_biPtr.get());
  galois::substrate::internal::setTermDetect(m_termPtr.get());
  galois::runtime::internal::PageAllocState<> m_pa;
  galois::runtime::internal::setPagePoolState(&m_pa);
  init_galois(argc, argv);

  perf_init();

  Graph G;
  commandLine P(argc, argv);

  uint32 report = reportNode;

  // ============ INITIALIZATION PHASE (NOT MEASURED) ============
  galois::graphs::init_graph(G, P);
  std::cout << "Read " << G.numV << " nodes, " << G.numE << " edges\n";

  printf("Partition Graph\n");
  partition(G, PSIZE);

  size_t approxNodeData = G.numV * 64;
  galois::preAlloc(numThreads + approxNodeData / galois::runtime::pagePoolSize());

  auto *label = new LNode[G.numV];

  temp tt(G.numV);
  readGraphDispatch(tt);

  std::cout << "INFO: Using " << numThreads << " threads\n";

  // ============ MEASURED RUN (NO WARMUP) ============
  std::cout << "\n=== MEASURED RUN ===\n";

  galois::do_all(
      galois::iterate(tt),
      [&](const uint32 &n) {
        label[n].comp_current = n;
        label[n].comp_old = MAX_NUM;
      },
      galois::no_stats(), galois::loopname("initNodeData"));

  // START PERF COUNTING
  perf_start();

  struct timespec start, end;
  clock_gettime(CLOCK_REALTIME, &start);

  cc(G, tt, label);

  clock_gettime(CLOCK_REALTIME, &end);

  // STOP PERF COUNTING
  perf_stop();

  double time = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
  printf("time: %lf sec\n", time);

  // Verify result
  std::map<uint32, uint32> mm;
  for (uint32_t i = 0; i < G.numV; i++) {
    mm[label[i].comp_current] += 1;
  }
  printf("component num: %zu\n", mm.size());

  // Print perf results
  perf_read_and_print();
  perf_cleanup();

  delete[] label;
  return 0;
}
