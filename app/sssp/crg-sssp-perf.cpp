#include "galois/Bag.h"
#include "galois/graphs/LCGraph.h"
#include "galois/substrate/ThreadPool.h"
#include <fstream>

unsigned int stepShift = 13;
std::string inputFile;
unsigned int startNode = 9;
unsigned int reportNode = 4819611;
int numThreads = 1;
bool skipInit = false;  // If true, load pre-partitioned graph

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

  Graph G;
  commandLine P(argc, argv);

  uint32 source = startNode;
  uint32 report = reportNode;

  // ============ INITIALIZATION PHASE ============
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

  // ============ WARMUP RUN (not timed in perf) ============
  std::cout << "=== WARMUP RUN ===\n";
  {
    for (uint32 i = 0; i < G.numV; i++) {
      distance[i] = MAX_NUM;
    }
    distance[startNode] = 0;
    galois::InsertBag<vw> initFrontier;
    initFrontier.push_back(vw(source, 0));
    deltaStepAlgo(G, initFrontier, distance);
  }

  // ============ MEASURED RUNS ============
  // Print marker for perf script to detect
  std::cout << "###PERF_START###\n";
  std::cout.flush();
  std::cerr.flush();

  // Small delay to ensure marker is flushed
  usleep(10000);  // 10ms

  double total_time = 0;
  for (uint32 iter = 0; iter < 5; iter++) {
    for (uint32 i = 0; i < G.numV; i++) {
      distance[i] = MAX_NUM;
    }
    distance[startNode] = 0;
    galois::InsertBag<vw> initFrontier;
    initFrontier.push_back(vw(source, 0));

    std::cout << "Running delta-step SSSP algorithm (iteration " << iter+1 << ")\n";
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

  // Small delay before end marker
  usleep(10000);  // 10ms

  std::cout << "###PERF_END###\n";
  std::cout.flush();
  std::cerr.flush();

  printf("Total measured time: %lf sec (5 iterations)\n", total_time);
  printf("Average time per iteration: %lf sec\n", total_time / 5.0);

  return 0;
}
