# CoroGraph Code Walkthrough Session

This document captures a detailed walkthrough of the CoroGraph project, a graph processing framework using C++20 coroutines for cache efficiency.

## Table of Contents
1. [Project Overview](#project-overview)
2. [SSSP Implementation (crg-sssp.cpp)](#sssp-implementation)
3. [Graph Data Structures (Partition_Graph.h)](#graph-data-structures)
4. [The partition() Function](#the-partition-function)
5. [Executor and Coroutines (Executor_ForEach.h)](#executor-and-coroutines)
6. [OBIM Work Queue (Obim.h)](#obim-work-queue)

---

## Project Overview

CoroGraph is a graph processing framework that uses C++20 coroutines to improve cache efficiency. The key insight is that graph algorithms often have poor cache performance because they follow pointers to random memory locations. CoroGraph addresses this by:

1. **Reorganizing graph data** into cache-line-aligned structures
2. **Using coroutines** to prefetch data before it's needed
3. **Partitioning vertices** to improve locality

The project implements several graph algorithms including SSSP (Single Source Shortest Path), BFS, and PageRank.

---

## SSSP Implementation

**File:** `/Users/sysny/Desktop/Masters/corograph/app/sssp/crg-sssp.cpp`

### Global Configuration

```cpp
unsigned int stepShift = 13;      // Delta for delta-stepping (2^13 = 8192)
std::string inputFile;
unsigned int startNode = 9;       // Source vertex for SSSP
unsigned int reportNode = 4819611;// Vertex to report distance for
int numThreads = 1;
```

### Graph Type Definition

```cpp
using Graph = galois::graphs::graph<uint32>;
```

This creates a graph type where edge weights are 32-bit unsigned integers.

### UpdateRequestIndexer - Priority Bucket Assignment

```cpp
struct UpdateRequestIndexer {
  typedef std::less<uint32> compare;  // Lower distance = higher priority
  unsigned shift;
  template <typename R> unsigned int operator()(const R &req) const {
    unsigned int t = req.dist >> shift;  // Divide distance by 2^shift
    return t;
  }
};
```

**Purpose:** Groups work items into priority buckets. If `stepShift = 13`:
- Distance 0-8191 → bucket 0
- Distance 8192-16383 → bucket 1
- etc.

This is the "delta" in delta-stepping SSSP.

### Work Item Types

```cpp
using vw = galois::graphs::vertex_warp<uint32>;  // (vertex_id, distance)
using pw = galois::graphs::part_wrap<uint32>;     // (vertex_id, new_distance)
```

- **vw (vertex_warp):** Used in scatter phase - "process vertex V which has distance D"
- **pw (part_wrap):** Used in gather phase - "update vertex V to distance D"

### Queue Types

```cpp
using PSchunk = gwl::CM<CHUNK_SIZE, vw>;   // Scatter queue chunks
using SGchunk = gwl::CM2<CG_CHUNK_SIZE, pw>; // Gather queue chunks
using Ck = gwl::CK<CHUNK_SIZE, vw>;
using Ck2 = gwl::CK<CG_CHUNK_SIZE, pw>;
using OBIM = gwl::OBIM<UpdateRequestIndexer, PSchunk, SGchunk, Ck, Ck2>;
```

### SSSP_F - The Algorithm Functions

```cpp
struct SSSP_F {
  unsigned int *vdata; // distance array
  explicit SSSP_F(unsigned int *_distance) : vdata(_distance) {}
```

#### filterFunc - Should we skip this work item?

```cpp
  inline bool filterFunc(uint32 src, uint32 dis) const {
    return vdata[src] < dis;  // true = skip
  }
```

Returns `true` if we should SKIP processing. We skip if we already found a better path to this vertex.

#### gatherFunc - Apply an update

```cpp
  inline bool gatherFunc(unsigned int updateVal, uint32 destId) const {
    if (updateVal < vdata[destId]) {
      vdata[destId] = updateVal;
      return true;  // Update was applied, add to frontier
    }
    return false;   // No improvement, don't add to frontier
  }
```

Called during gather phase. Returns `true` if the update improved the distance (meaning we need to process this vertex's neighbors).

#### pushFunc - Create a work item

```cpp
  inline vw pushFunc(uint32 dst, uint32 newdis) const {
    return vw(dst, newdis);
  }
```

Creates a work item to add to the frontier.

#### applyWeight - Calculate new distance

```cpp
  static inline unsigned int applyWeight(unsigned int weight, unsigned int updateVal) {
    return updateVal + weight;
  }
```

For SSSP: new_distance = current_distance + edge_weight.

### deltaStepAlgo - Entry Point

```cpp
template <typename OBIMTy = OBIM>
void deltaStepAlgo(Graph &graph, auto &initFrontier, uint32 *dist) {
  galois::runtime::asyncPriorityEdgeMap<OBIMTy>(
      graph, UpdateRequestIndexer{stepShift}, SSSP_F(dist),
      galois::iterate(initFrontier));
}
```

This is the entry point that calls into the Galois runtime.

### main() - Setup and Execution

```cpp
int main(int argc, char **argv) {
  // 1. Initialize thread pool and runtime
  galois::substrate::ThreadPool tp;
  // ... various runtime initialization ...

  // 2. Parse arguments and load graph
  init_galois(argc, argv);
  Graph G;
  galois::graphs::init_graph(G, P);

  // 3. Partition the graph (KEY STEP!)
  partition(G, numThreads);

  // 4. Pre-allocate memory
  galois::preAlloc(numThreads + approxNodeData / galois::runtime::pagePoolSize());

  // 5. Initialize distances
  auto *distance = new uint32[G.numV];
  for (uint32 i = 0; i < G.numV; i++) {
    distance[i] = MAX_NUM;  // "infinity"
  }
  distance[startNode] = 0;

  // 6. Create initial frontier
  galois::InsertBag<vw> initFrontier;
  initFrontier.push_back(vw(source, 0));

  // 7. Run the algorithm
  deltaStepAlgo(G, initFrontier, distance);
}
```

---

## Graph Data Structures

**File:** `/Users/sysny/Desktop/Masters/corograph/libcoro/include/galois/graphs/Partition_Graph.h`

### vtxArr - Per-Vertex Cache-Aligned Structure

```cpp
struct vtxArr{
    uint16_t deg1, deg2;   // 4 bytes: inline/outline degree counts
    uint32_t PE[14];       // 56 bytes: edge data storage
    uint32_t offset;       // 4 bytes: overflow offset
};// Total: 64 bytes = exactly one cache line!
```

**Why 64 bytes?** Modern CPUs fetch memory in 64-byte "cache lines". By making each vertex exactly 64 bytes, when we access a vertex, we get ALL its data in one memory fetch.

#### The PE Array - Clever Bit Packing

The 14-element PE array stores edge information in pairs:
- PE[0]: partition_id (18 bits) + count (14 bits)
- PE[1]: offset into that partition's edges

Each pair describes edges going to one partition:
- **partition_id:** Which partition do these edges go to?
- **count:** How many edges?
- **offset:** Where to find the actual edge data?

With 14 slots (7 pairs), we can store edges to up to 7 different partitions inline.

### graph Struct - Three Storage Systems

```cpp
template<class ET>
struct graph{
    // === Original CSR Format ===
    uint32 numV;           // Number of vertices
    uint32 numE;           // Number of edges
    uint32* offset;        // offset[v] = start of v's edges
    uint32* edge;          // edge[i] = destination of edge i
    ET *edgeWeight;        // edgeWeight[i] = weight of edge i

    // === Partition Information ===
    uint32 numPart;        // Number of partitions
    uint32 PartSize;       // Vertices per partition
    uint32* vtxPart;       // vtxPart[v] = which partition v belongs to

    // === New Cache-Friendly Storage ===
    vtxArr* plgraph;       // One vtxArr per vertex (64B aligned)
    uint32* pledge;        // Overflow for vertices with >7 edge groups
    uint32* highedge;      // Actual edge data for large groups
};
```

### What is a Partition?

A partition is simply a range of vertex IDs:
- Partition 0: vertices 0 to PartSize-1
- Partition 1: vertices PartSize to 2*PartSize-1
- etc.

**Purpose:** When processing edges, if we know "these 10 edges all go to partition 3", we can:
1. Prefetch partition 3's data once
2. Process all 10 edges while it's in cache

### The Three Storage Arrays

#### plgraph - Main Per-Vertex Storage
One `vtxArr` per vertex. Contains inline edge groups for vertices with ≤7 different destination partitions.

#### pledge - Overflow for Many Edge Groups
For vertices with >7 destination partitions, the extra groups spill into `pledge`:

```
vtxArr.offset points here
        ↓
pledge: [part_id|count][offset][part_id|count][offset]...
```

#### highedge - Storage for Large Edge Groups
When a vertex has many edges (>2) to the same partition:

```
Small group (≤2 edges): stored directly in vtxArr.PE
    PE[2i]   = part_id | count
    PE[2i+1] = (dest1 << 18) | (weight1)   // packed directly

Large group (>2 edges): stored in highedge
    PE[2i]   = part_id | count
    PE[2i+1] = offset into highedge

    highedge[offset] = dest1
    highedge[offset+1] = weight1
    highedge[offset+2] = dest2
    ...
```

---

## The partition() Function

**File:** `/Users/sysny/Desktop/Masters/corograph/libcoro/include/galois/graphs/Partition_Graph.h`

This function converts the CSR graph into the cache-friendly format.

### Phase 1: Calculate Partition Size

```cpp
template<typename ET>
void partition(graph<ET>& g, int _numPart = 0) {
    g.numPart = _numPart;
    if(!_numPart) g.numPart = getActiveThreads() * 4;  // Default: 4 partitions per thread
    g.PartSize = (g.numV + g.numPart - 1) / g.numPart;  // Ceiling division
```

### Phase 2: First Pass - Count Space Needed

```cpp
    g.vtxPart = new uint32[g.numV];
    parallel_for(0, g.numV, [&](uint32 i) {
        g.vtxPart[i] = i / g.PartSize;  // Assign each vertex to its partition
    });

    g.plgraph = (vtxArr*)aligned_alloc(64, sizeof(vtxArr) * g.numV);  // 64-byte aligned!

    uint32* pledgeCnt = new uint32[getActiveThreads()]();  // Per-thread overflow count
    uint32* edgeCnt = new uint32[getActiveThreads()]();    // Per-thread edge count
```

The first pass scans each vertex to count:
- How many overflow slots needed in `pledge`
- How many edge slots needed in `highedge`

```cpp
    parallel_for(0, g.numV, [&](uint32 v) {
        // For each vertex, count edges to each partition
        // If >7 partitions: add to pledgeCnt
        // If any partition has >2 edges: add to edgeCnt
    });
```

### Phase 3: Allocate Storage

```cpp
    // Calculate prefix sums for offsets
    uint32 plgS = 0, edgS = 0;
    for(int i = 0; i < getActiveThreads(); i++) {
        uint32 t1 = pledgeCnt[i], t2 = edgeCnt[i];
        pledgeCnt[i] = plgS; edgeCnt[i] = edgS;
        plgS += t1; edgS += t2;
    }

    g.pledge = new uint32[plgS];
    g.highedge = new uint32[edgS];
```

### Phase 4: Second Pass - Fill In Data

```cpp
    parallel_for(0, g.numV, [&](uint32 v) {
        vtxArr& va = g.plgraph[v];
        // ... fill in va.deg1, va.deg2, va.PE[], va.offset
        // ... fill in pledge[] and highedge[] as needed
    });
```

For each vertex, this phase:
1. Groups edges by destination partition
2. For each group:
   - If ≤7 groups total: store in vtxArr.PE
   - If >7 groups: first 7 in PE, rest in pledge
   - If group has ≤2 edges: pack directly
   - If group has >2 edges: store in highedge

---

## Executor and Coroutines

**File:** `/Users/sysny/Desktop/Masters/corograph/libcoro/include/galois/runtime/Executor_ForEach.h`

### High-Level Algorithm Flow

The algorithm executes in three phases that repeat until no work remains:

```
┌─────────────────────────────────────────────────────────────────┐
│                         MAIN LOOP                                │
│                                                                  │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐                  │
│  │ SCATTER  │───→│   SYNC   │───→│  GATHER  │───→ (repeat)     │
│  └──────────┘    └──────────┘    └──────────┘                  │
│                                                                  │
│  Pop vertices    Push updates    Pop partition                   │
│  from priority   to partition    Apply updates                   │
│  queue           queues          Generate new                    │
│  Generate                        frontier items                  │
│  updates                                                         │
└─────────────────────────────────────────────────────────────────┘
```

### ThreadLocalData - What Each Thread Has

```cpp
struct ThreadLocalData {
    galois::runtime::FixedSizeBag<Ck*, 256> tmp;  // Chunks being processed

    // Double-buffered update storage
    std::vector<pw>* facing;    // Updates being generated
    std::vector<pw>* facing2;   // Updates ready to send

    // Double-buffered frontier
    galois::runtime::FixedSizeBag<vw, 128>* low;   // New frontier items (low priority)
    galois::runtime::FixedSizeBag<vw, 128>* high;  // New frontier items (high priority)

    // The three coroutines
    Corobj<bool> scatter_coro;
    Corobj<bool> gather_coro;
    Corobj<bool> sync_coro;
};
```

### The Three Coroutines

#### coro_scatter - Process Vertices, Generate Updates

```cpp
Corobj<bool> coro_scatter(auto &ctx2, auto &tmp) {
    co_yield false;  // Initial pause
    for (;;) {
        for (int id = 0; id < (int)tmp.size(); id += 64) {
            // PREFETCH: Request 64 vertices from memory
            for (int prid = id; prid < std::min(id + 64, (int)tmp.size()); prid++) {
                _mm_prefetch(&graph.plgraph[(*tmp[prid]).vid], _MM_HINT_T0);
            }

            co_yield false;  // PAUSE: Let prefetch complete

            // PROCESS: Now data is in cache, process 64 vertices
            for (int prid = id; prid < std::min(id + 64, (int)tmp.size()); prid++) {
                // For each edge of this vertex:
                //   newDist = currentDist + edgeWeight
                //   ctx2[destPartition].push_back({destVertex, newDist})
            }
        }
        co_yield true;  // DONE: Signal batch complete
    }
}
```

**Key insight:** By prefetching 64 vertices, then pausing, then processing them, we ensure the data is in cache when we need it.

#### coro_gather - Apply Updates to Vertices

```cpp
Corobj<bool> coro_gather(auto &updates, auto &newFrontier) {
    co_yield false;
    for (;;) {
        for (int id = 0; id < (int)updates.size(); id += 64) {
            // PREFETCH distance array for 64 destination vertices
            for (int prid = id; prid < std::min(id + 64, (int)updates.size()); prid++) {
                _mm_prefetch(&distance[updates[prid].vid], _MM_HINT_T0);
            }

            co_yield false;  // PAUSE

            // PROCESS: Apply updates
            for (int prid = id; prid < std::min(id + 64, (int)updates.size()); prid++) {
                auto& update = updates[prid];
                if (update.dist < distance[update.vid]) {
                    distance[update.vid] = update.dist;
                    newFrontier.push_back({update.vid, update.dist});
                }
            }
        }
        co_yield true;
    }
}
```

### Main Loop - runQueueSimple2()

```cpp
void runQueueSimple2() {
    while (true) {
        // 1. SCATTER PHASE
        doScatter();

        // 2. SYNC - Push accumulated updates to partition queues
        doSync();

        // 3. GATHER PHASE
        doGather();

        // 4. Check termination
        term.localTermination(...);
        substrate::getSystemBarrier().wait();
        if (allDone) break;
    }
}
```

### Why Coroutines Help

Traditional approach (BAD for cache):
```cpp
for each vertex v in frontier:
    access graph.plgraph[v]  // CACHE MISS - wait 100+ cycles
    process edges
```

Coroutine approach (GOOD for cache):
```cpp
// Prefetch 64 vertices
for i = 0 to 63:
    prefetch graph.plgraph[frontier[i]]

co_yield  // Do other work while memory loads

// Now process - data is in cache!
for i = 0 to 63:
    access graph.plgraph[frontier[i]]  // CACHE HIT - fast!
    process edges
```

---

## OBIM Work Queue

**File:** `/Users/sysny/Desktop/Masters/corograph/libcoro/include/galois/worklists/Obim.h`

OBIM (Ordered By Integer Metric) manages two queue systems:
1. **Scatter queue:** Priority-ordered buckets for vertices to process
2. **Gather queues:** Per-partition queues for updates to apply

### Template Parameters

```cpp
template <typename Indexer,     // Calculates priority bucket
          typename Container,   // Queue type for scatter (priority buckets)
          typename Container2,  // Queue type for gather (partition queues)
          typename Ck,          // Chunk type for scatter
          typename Ck2>         // Chunk type for gather
struct OBIM { ... };
```

### ThreadData - Per-Thread State

```cpp
struct ThreadData {
    galois::flat_map<Index, Container*, std::less<Index>> local;  // Priority → Queue
    Index curIndex;           // Current priority being processed
    Index scanStart;          // Lowest priority to scan from
    Container* current;       // Currently active queue
    unsigned int lastMasterVersion;  // For lazy synchronization

    Container2* currentP;     // Current partition being gathered
    uint32_t Pid;             // Current partition ID
    Container2** localPQ;     // Pointer to partition queues (NUMA-aware copy)
};
```

### Shared Data Structures

```cpp
substrate::PerThreadStorage<ThreadData> data;  // Per-thread state

// For lazy synchronization of priority buckets
substrate::PaddedLock<true> masterLock;
std::deque<std::pair<Index, Container*>> masterLog;
std::atomic<unsigned int> masterVersion;

// Gather phase queues
substrate::PerSocketStorage<ConExtLinkedQueue<Container2, true>> gatherQ;
Container2** partitionQueue;  // One queue per partition
uint32_t numP;                // Number of partitions
```

### Constructor

```cpp
OBIM(uint32_t _numP, const Indexer& x = Indexer())
    : numP(_numP), masterVersion(0), indexer(x),
      data(this->earliest, _numP),
      earliest(std::numeric_limits<Index>::min())
{
    // Create one queue per partition
    partitionQueue = new Container2*[_numP];
    for(uint32_t i=0; i<_numP; i++){
        partitionQueue[i] = new Container2(i);
    }

    // Give each thread a reference to the partition queues
    for (unsigned i = 0; i < runtime::activeThreads; ++i) {
        ThreadData &o = *data.getRemote(i);
        o.updatePQ(partitionQueue);
    }
}
```

### push() - Add to Scatter Queue

```cpp
void push(const value_type& val) {
    Index index = indexer(val);  // Get priority bucket
    ThreadData& p = *data.getLocal();

    // Fast path: same bucket as before
    if (index == p.curIndex && p.current) {
        p.current->push(val);
        return;
    }

    // Slow path: find or create the bucket
    Container* C = updateLocalOrCreate(p, index);

    // Update scan start if this is lower priority
    if (this->compare(index, p.scanStart))
        p.scanStart = index;

    // Update current if this is higher priority
    if (this->compare(index, p.curIndex)) {
        p.curIndex = index;
        p.current = C;
    }

    C->push(val);
}
```

### Lazy Synchronization

When a thread creates a new priority bucket, it adds to a shared log:

```cpp
Container* slowUpdateLocalOrCreate(ThreadData& p, Index i) {
    // Try to acquire lock
    do {
        updateLocal(p);  // Sync with master log
        auto it = p.local.find(i);
        if (it != p.local.end())
            return it->second;
    } while (!masterLock.try_lock());

    // Create new bucket
    C2 = new Container();
    p.local[i] = C2;

    // Add to master log for other threads
    masterLog.push_back(std::make_pair(i, C2));
    masterVersion.fetch_add(1);

    masterLock.unlock();
    return C2;
}
```

Other threads lazily sync via `updateLocal()`:

```cpp
bool updateLocal(ThreadData& p) {
    if (p.lastMasterVersion != masterVersion.load()) {
        // Catch up with the master log
        for (; p.lastMasterVersion < masterVersion.load(); ++p.lastMasterVersion) {
            auto logEntry = masterLog[p.lastMasterVersion];
            p.local[logEntry.first] = logEntry.second;
        }
        return true;
    }
    return false;
}
```

### pop2() - Get Work from Scatter Queue

```cpp
Ck* pop2() {
    ThreadData& p = *data.getLocal();
    Container* C = p.current;
    Ck* item = nullptr;

    // Try current bucket first
    if(C) item = C->pop2();
    if(item) return item;

    // Current bucket empty, search for more work
    return slowPop2(p);
}
```

### slowPop2() - Search for More Work

```cpp
Ck* slowPop2(ThreadData& p) {
    // Find minimum scan start across threads
    Index msS = p.scanStart;
    if (localLeader) {
        for (unsigned i = 0; i < runtime::activeThreads; ++i) {
            Index o = data.getRemote(i)->scanStart;
            if (this->compare(o, msS))
                msS = o;
        }
    }

    // Scan buckets starting from minimum
    for (auto ii = p.local.lower_bound(msS); ii != p.local.end(); ++ii) {
        Ck* item = ii->second->pop2();
        if (item) {
            p.current = ii->second;
            p.curIndex = ii->first;
            p.scanStart = ii->first;
            return item;
        }
    }
    return nullptr;
}
```

### scatter() - Queue Updates for Gather Phase

```cpp
void scatter(ThreadData &p, uint32_t pid, const part_type& pt) {
    if(p.localPQ[pid]->push(pt)) {  // Returns true if queue was empty
        gatherQ.getLocal()->push(p.localPQ[pid]);  // Add to gather list
    }
}
```

### pop_part() and pop_gather() - Gather Phase

```cpp
bool pop_part() {
    ThreadData& p = *data.getLocal();
    p.currentP = popPart();  // Get a partition queue
    return p.currentP != nullptr;
}

Ck2* pop_gather() {
    ThreadData& p = *data.getLocal();
    return p.currentP->pop();  // Get updates from that partition
}
```

### popPart() - Work Stealing

```cpp
Container2* popPart() {
    int id = substrate::ThreadPool::getTID();

    // Try own queue first
    Container2* r = popPartByID(id);
    if (r) return r;

    // Steal from others
    for (int i = id + 1; i < (int)gatherQ.size(); ++i) {
        r = popPartByID(i);
        if (r) return r;
    }
    for (int i = 0; i < id; ++i) {
        r = popPartByID(i);
        if (r) return r;
    }
    return nullptr;
}
```

### Complete OBIM Flow Diagram

```
                    SCATTER PHASE
                    ─────────────
    ┌─────────────────────────────────────────┐
    │  Priority Buckets (scatter queue)        │
    │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐       │
    │  │  0  │ │  1  │ │  2  │ │ ... │       │
    │  └──┬──┘ └──┬──┘ └──┬──┘ └─────┘       │
    │     │       │       │                   │
    │     └───────┴───────┴─────────┐        │
    │                               │        │
    │                         pop2()/pop3()  │
    │                               ↓        │
    │                    ┌──────────────┐    │
    │                    │  Thread gets │    │
    │                    │  chunk of    │    │
    │                    │  vertices    │    │
    │                    └──────────────┘    │
    └─────────────────────────────────────────┘
                          │
                          │ Generate updates
                          │ (newDist = dist + weight)
                          ↓
                    SYNC PHASE
                    ──────────
    ┌─────────────────────────────────────────┐
    │                                         │
    │         scatter(partition, update)      │
    │                    │                    │
    │                    ↓                    │
    │  Partition Queues (gather queues)       │
    │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐       │
    │  │ P0  │ │ P1  │ │ P2  │ │ ... │       │
    │  └─────┘ └─────┘ └─────┘ └─────┘       │
    │                                         │
    └─────────────────────────────────────────┘
                          │
                          │ pop_part() + pop_gather()
                          ↓
                    GATHER PHASE
                    ────────────
    ┌─────────────────────────────────────────┐
    │                                         │
    │  Thread claims partition Px             │
    │  Applies all updates to vertices in Px  │
    │  If update improved distance:           │
    │      push(vertex, newDist) → back to    │
    │      scatter queue for next round       │
    │                                         │
    └─────────────────────────────────────────┘
                          │
                          │ New frontier items
                          ↓
                    [REPEAT until empty]
```

---

## Summary

CoroGraph achieves high performance through:

1. **Cache-line aligned structures:** Each vertex's data fits in exactly 64 bytes
2. **Partitioning:** Groups vertices so related data is accessed together
3. **Coroutines with prefetching:** Hides memory latency by requesting data before it's needed
4. **Three-phase execution:** Scatter generates updates, Sync distributes them, Gather applies them
5. **Priority scheduling:** Delta-stepping processes low-distance vertices first
6. **Work stealing:** Threads can take work from other threads to maintain load balance

The key insight is that random memory access patterns in graph algorithms cause cache misses, and CoroGraph reorganizes both the data layout AND the execution pattern to maximize cache hits.
