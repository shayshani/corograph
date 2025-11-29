#include "galois/Bag.h"
#include "galois/graphs/LCGraph.h"
#include "galois/substrate/ThreadPool.h"
#include <sys/ioctl.h>
#include <linux/perf_event.h>
#include <asm/unistd.h>
#include <unistd.h>
#include <cstring>
#include <sys/syscall.h>
#include <vector>

unsigned int stepShift = 13;
std::string inputFile;
unsigned int startNode = 9;
unsigned int reportNode = 4819611;
int numThreads = 1;

using Graph = galois::graphs::graph<uint32>;
struct UpdateRequestIndexer {
  typedef std::less<uint32> compare;
  unsigned shift;
  template <typename R> unsigned int operator()(const R &req) const {
    unsigned int t = req.dist >> shift;
    return t;
  }
};
constexpr static const unsigned CHUNK_SIZE = 512U;
constexpr static const unsigned CG_CHUNK_SIZE = 1024U;

using vw = galois::graphs::vertex_warp<uint32>;
using pw = galois::graphs::part_wrap<uint32>;
namespace gwl = galois::worklists;
using PSchunk = gwl::CM<CHUNK_SIZE, vw>;
using SGchunk = gwl::CM2<CG_CHUNK_SIZE, pw>;
using Ck = gwl::CK<CHUNK_SIZE, vw>;
using Ck2 = gwl::CK<CG_CHUNK_SIZE, pw>;
using OBIM = gwl::OBIM<UpdateRequestIndexer, PSchunk, SGchunk, Ck, Ck2>;

struct SSSP_F {
  unsigned int *vdata;
  explicit SSSP_F(unsigned int *_distance) : vdata(_distance) {}

  inline bool filterFunc(uint32 src, uint32 dis) const {
    return vdata[src] < dis;
  }
  inline bool gatherFunc(unsigned int updateVal, uint32 destId) const {
    if (updateVal < vdata[destId]) {
      vdata[destId] = updateVal;
      return true;
    }
    return false;
  }
  inline vw pushFunc(uint32 dst, uint32 newdis) const {
    return vw(dst, newdis);
  }
  static inline unsigned int applyWeight(unsigned int weight,
                                         unsigned int updateVal) {
    return updateVal + weight;
  }
};

template <typename OBIMTy = OBIM>
void deltaStepAlgo(Graph &graph, auto &initFrontier, uint32 *dist) {
  galois::runtime::asyncPriorityEdgeMap<OBIMTy>(
      graph, UpdateRequestIndexer{stepShift}, SSSP_F(dist),
      galois::iterate(initFrontier));
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
    printf("Usage : %s <filename> -t <numThreads> -delta <delta>\n", argv[0]);
    exit(1);
  }
  inputFile = std::string(argv[1]);
  numThreads = galois::setActiveThreads(numThreads);
}

//==============================================================================
// Perf event infrastructure - create our own counters and control them precisely
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

  // Define the events we want to measure
  struct {
    uint32_t type;
    uint64_t config;
    const char* name;
  } events[] = {
    // Cycles and instructions
    {PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES, "cycles"},
    {PERF_TYPE_HARDWARE, PERF_COUNT_HW_INSTRUCTIONS, "instructions"},

    // L1D pending miss events (for MLP calculation)
    // These are raw events for Intel: l1d_pend_miss.pending and l1d_pend_miss.pending_cycles
    // Event code: 0x48, umask: 0x01 for pending, 0x01 for pending_cycles
    {PERF_TYPE_RAW, 0x0148, "l1d_pend_miss.pending"},        // event=0x48, umask=0x01
    {PERF_TYPE_RAW, 0x0148 | (1ULL << 24), "l1d_pend_miss.pending_cycles"}, // with cmask=1

    // Cache misses
    {PERF_TYPE_HW_CACHE,
     PERF_COUNT_HW_CACHE_L1D | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16),
     "L1-dcache-load-misses"},
    {PERF_TYPE_HW_CACHE,
     PERF_COUNT_HW_CACHE_LL | (PERF_COUNT_HW_CACHE_OP_READ << 8) | (PERF_COUNT_HW_CACHE_RESULT_MISS << 16),
     "LLC-load-misses"},

    // cycle_activity.stalls_mem_any - cycles stalled due to memory subsystem (paper's "memory bound" metric)
    // Intel event code: 0xa3, umask: 0x14, cmask: 0x14 (for Cascade Lake / Skylake-X)
    {PERF_TYPE_RAW, 0x14a3 | (0x14ULL << 24), "cycle_activity.stalls_mem_any"},
  };

  for (auto& ev : events) {
    memset(&pe, 0, sizeof(pe));
    pe.type = ev.type;
    pe.size = sizeof(pe);
    pe.config = ev.config;
    pe.disabled = 1;          // Start disabled
    pe.exclude_kernel = 1;    // Don't count kernel
    pe.exclude_hv = 1;        // Don't count hypervisor

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

  // Calculate derived metrics
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

  // Initialize perf counters (but don't start counting yet)
  perf_init();

  Graph G;
  commandLine P(argc, argv);

  uint32 source = startNode;
  uint32 report = reportNode;

  // ============ INITIALIZATION PHASE (NOT MEASURED) ============
  galois::graphs::init_graph(G, P);
  std::cout << "Read " << G.numV << " nodes, " << G.numE << " edges\n";

  printf("Partition Graph\n");
  partition(G, numThreads);

  size_t approxNodeData = G.numV * 256;
  galois::preAlloc(
      numThreads +
      approxNodeData / galois::runtime::pagePoolSize());

  auto *distance = new uint32[G.numV];

  std::cout << "INFO: Using delta-step of " << (1 << stepShift) << "\n";

  // ============ WARMUP RUN (NOT MEASURED) ============
  std::cout << "=== WARMUP RUN (not measured) ===\n";
  {
    for (uint32 i = 0; i < G.numV; i++) {
      distance[i] = MAX_NUM;
    }
    distance[startNode] = 0;
    galois::InsertBag<vw> initFrontier;
    initFrontier.push_back(vw(source, 0));
    deltaStepAlgo(G, initFrontier, distance);
    std::cout << "Warmup complete\n";
  }

  // ============ MEASURED RUNS ============
  std::cout << "\n=== MEASURED RUNS (perf counting enabled) ===\n";

  // START PERF COUNTING HERE
  perf_start();

  double total_time = 0;
  for (uint32 iter = 0; iter < 5; iter++) {
    for (uint32 i = 0; i < G.numV; i++) {
      distance[i] = MAX_NUM;
    }
    distance[startNode] = 0;
    galois::InsertBag<vw> initFrontier;
    initFrontier.push_back(vw(source, 0));

    std::cout << "Running SSSP iteration " << iter+1 << "/5\n";
    struct timespec start, end;
    double time;
    clock_gettime(CLOCK_REALTIME, &start);
    deltaStepAlgo(G, initFrontier, distance);
    clock_gettime(CLOCK_REALTIME, &end);
    time = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
    total_time += time;
    printf("time: %lf sec\n", time);

    uint32_t maxdist = 0;
    for (uint32_t i = 0; i < G.numV; i++) {
      if (distance[i] != MAX_NUM)
        maxdist = std::max(maxdist, distance[i]);
    }
    printf("max distance: %d \n", maxdist);
  }

  // STOP PERF COUNTING HERE
  perf_stop();

  std::cout << "\n=== TIMING SUMMARY ===\n";
  printf("Total measured time: %lf sec (5 iterations)\n", total_time);
  printf("Average time per iteration: %lf sec\n", total_time / 5.0);
  printf("Best time would be: check individual times above\n");

  // Read and print perf results
  perf_read_and_print();

  perf_cleanup();

  return 0;
}
