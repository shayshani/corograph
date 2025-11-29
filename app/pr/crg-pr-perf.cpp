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

unsigned int stepShift = 13;
unsigned int startNode = 9;
unsigned int reportNode = 9;
int numThreads = 1;
const uint32 PSIZE = 18;

using Graph = galois::graphs::graph<uint32>;
struct UpdateRequestIndexer {
  typedef std::greater<uint32> compare;
  template <typename R> unsigned int operator()(const R &req) const {
    return 1;
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

const float alpha = 0.15;
const float epsilon = 0.000001;

struct PR_F {
  float *curpr;
  float *nextpr;
  uint32 *deg;
  explicit PR_F(float *_cpr, float *_npr, uint32 *_deg)
      : curpr(_cpr), nextpr(_npr), deg(_deg) {}

  inline bool filterFunc(uint32 src) const { return false; }
  inline uint32 scatterFunc(uint32 src) const { return curpr[src] / deg[src]; }
  inline bool gatherFunc(float updateVal, uint32 destId) const {
    nextpr[destId] += updateVal;
    return false;
  }
  inline uint32 pushFunc(uint32 dst, float newpr) const { return dst; }
  static inline float applyWeight(unsigned int weight, float updateVal) {
    return updateVal;
  }
};

template <typename OBIMTy = OBIM> void pr(Graph &graph, auto &all, PR_F &pr) {
  galois::InsertBag<uint32> Frontier, nextF;
  galois::runtime::syncExecutor exec(graph, pr);
  exec.EdgeMap(all, nextF);
  galois::do_all(
      galois::iterate(all),
      [&](const uint32 &n) {
        pr.nextpr[n] = 0.15 / graph.numV + (0.85 * pr.nextpr[n]);
        if (std::abs(pr.nextpr[n] - pr.curpr[n]) > epsilon) {
          Frontier.push_back(n);
          pr.curpr[n] = 0.0;
        }
      },
      galois::no_stats(), galois::loopname("Reset"));
  for (uint32 _ = 0; _ < 9; _++) {
    exec.EdgeMap(Frontier, nextF);
    galois::do_all(
        galois::iterate(all),
        [&](const uint32 &n) {
          pr.nextpr[n] = 0.15 / graph.numV + (0.85 * pr.nextpr[n]);
          if (std::abs(pr.nextpr[n] - pr.curpr[n]) > epsilon) {
            Frontier.push_back(n);
            pr.curpr[n] = 0.0;
          }
        },
        galois::no_stats(), galois::loopname("Reset"));
    std::swap(pr.nextpr, pr.curpr);
  }
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
  numThreads = galois::setActiveThreads(numThreads);
}

template <typename TMP> struct Range {
  TMP &tmp;
  Range(TMP &t) : tmp(t) {}
  void operator()(unsigned tid, unsigned total) { tmp.range(tid, total); }
};
template <typename TMP> void initRange(TMP &tmp) {
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

  temp all(G.numV);
  initRange(all);

  auto *curprv = new float[G.numV];
  auto *nextprv = new float[G.numV];
  PR_F prf(curprv, nextprv, G.deg);

  std::cout << "INFO: Using " << numThreads << " threads\n";

  // ============ MEASURED RUN (NO WARMUP) ============
  std::cout << "\n=== MEASURED RUN ===\n";

  galois::do_all(
      galois::iterate(all),
      [&](const uint32 &n) { curprv[n] = 1.0 / G.numV; }, galois::no_stats(),
      galois::loopname("Reset"));

  // START PERF COUNTING
  perf_start();

  struct timespec start, end;
  clock_gettime(CLOCK_REALTIME, &start);

  pr(G, all, prf);

  clock_gettime(CLOCK_REALTIME, &end);

  // STOP PERF COUNTING
  perf_stop();

  double time = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
  printf("time: %lf sec\n", time);

  // Verify result
  float maxpr = 0.0;
  for (uint32_t i = 0; i < G.numV; i++) {
    maxpr = std::max(maxpr, curprv[i]);
  }
  printf("max pr: %.8f\n", maxpr);

  // Print perf results
  perf_read_and_print();
  perf_cleanup();

  delete[] curprv;
  delete[] nextprv;
  return 0;
}
