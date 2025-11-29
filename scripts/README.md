# CoroGraph Performance Profiling Scripts

Performance analysis scripts for CoroGraph on Intel Xeon Gold 6242R (Cascade Lake).

## Prerequisites

```bash
# Install perf (usually comes with linux-tools)
sudo apt-get install linux-tools-common linux-tools-$(uname -r)

# Enable perf for non-root users (optional)
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid
echo 0 | sudo tee /proc/sys/kernel/kptr_restrict
```

## Quick Start

```bash
# Build the project first
cd /path/to/corograph
mkdir -p build && cd build
cmake .. && make -j$(nproc)

# Make scripts executable
chmod +x ../scripts/*.sh

# Run full analysis
../scripts/profile_full.sh ./crg-sssp /path/to/graph.bin -t 16 -delta 13
```

## Available Scripts

### 1. `profile_memory_compute.sh` - Memory vs Compute Bound Analysis

Determines whether your application is memory-bound or compute-bound.

```bash
./scripts/profile_memory_compute.sh ./build/crg-sssp graph.bin -t 16 -delta 13
```

**Key Metrics:**
- **IPC (Instructions Per Cycle)**: < 1.0 = memory bound, > 2.0 = compute bound
- **L1 D-Cache Miss Rate**: High = poor cache locality
- **LLC Miss Rate**: High = memory bandwidth bound

### 2. `profile_mlp.sh` - Memory Level Parallelism Analysis

**This is the key script for evaluating coroutine effectiveness!**

```bash
./scripts/profile_mlp.sh ./build/crg-sssp graph.bin -t 16 -delta 13
```

**Key Metrics:**
- **MLP = l1d_pend_miss.pending / l1d_pend_miss.pending_cycles**
  - MLP ~1: Sequential memory access (coroutines NOT helping)
  - MLP 2-4: Moderate parallelism
  - MLP >4: Good parallelism (coroutines working!)
  - MLP >8: Excellent parallelism

**Interpretation:**
- If MLP is low (~1-2), the coroutine prefetching is not effective
- If MLP is high (>4), coroutines are successfully hiding memory latency

### 3. `profile_topdown.sh` - Top-Down Microarchitecture Analysis

Uses Intel's Top-Down methodology to categorize where cycles are spent.

```bash
./scripts/profile_topdown.sh ./build/crg-sssp graph.bin -t 16 -delta 13
```

**Categories:**
- **Frontend Bound**: Instruction fetch/decode issues
- **Backend Bound**: Execution stalls
  - Memory Bound: Waiting for data
  - Core Bound: Execution port saturation
- **Bad Speculation**: Branch misprediction
- **Retiring**: Useful work

### 4. `profile_hotspots.sh` - CPU Hotspot Analysis

Identifies which functions consume the most CPU time.

```bash
./scripts/profile_hotspots.sh ./build/crg-sssp graph.bin -t 16 -delta 13
```

**Output:**
- Top functions by CPU time
- Call graph showing callers/callees
- Perf data file for interactive exploration

### 5. `profile_full.sh` - Comprehensive Analysis

Runs all analyses and generates a single report.

```bash
./scripts/profile_full.sh ./build/crg-sssp graph.bin -t 16 -delta 13
```

## Understanding Results for CoroGraph

### Expected Profile for Graph Algorithms

Graph algorithms like SSSP typically show:
- **Low IPC** (0.3-0.8): Memory latency dominates
- **High Memory Bound** (50-80%): Irregular memory access patterns
- **Moderate Branch Misprediction** (5-15%): Data-dependent branches

### What CoroGraph Should Improve

CoroGraph uses coroutines to prefetch data. If working correctly:
- **MLP should increase** from ~1-2 (baseline) to 4+ (with coroutines)
- **Memory stall cycles should decrease**
- **Overall IPC should improve**

### Comparing Baseline vs CoroGraph

To evaluate coroutine effectiveness:

1. Run baseline (without coroutine prefetching) - if available
2. Run CoroGraph version
3. Compare MLP values

```bash
# If you have a baseline version:
./scripts/profile_mlp.sh ./baseline_sssp graph.bin -t 16
./scripts/profile_mlp.sh ./crg-sssp graph.bin -t 16

# Compare the MLP values
```

## Perf Events Reference (Cascade Lake)

### Memory Bound Events
```
L1-dcache-loads              # L1 data cache load accesses
L1-dcache-load-misses        # L1 data cache load misses
LLC-loads                    # Last level cache loads
LLC-load-misses              # Last level cache load misses
l1d_pend_miss.pending        # Cumulative outstanding L1D misses
l1d_pend_miss.pending_cycles # Cycles with outstanding L1D miss
l1d_pend_miss.fb_full        # Cycles fill buffer full (memory pressure)
cycle_activity.stalls_l1d_miss  # Cycles stalled on L1D miss
cycle_activity.stalls_l2_miss   # Cycles stalled on L2 miss
cycle_activity.stalls_l3_miss   # Cycles stalled on L3 miss
cycle_activity.stalls_mem_any   # Cycles stalled on any memory
```

### Prefetch Events
```
l2_rqsts.all_pf              # All L2 prefetch requests
l2_rqsts.pf_hit              # L2 prefetch hits
l2_rqsts.pf_miss             # L2 prefetch misses
sw_prefetch_access.t0        # Software prefetch T0 (L1)
sw_prefetch_access.nta       # Software prefetch NTA
```

### General Events
```
cycles                       # Total CPU cycles
instructions                 # Total instructions
branch-instructions          # Branch instructions
branch-misses                # Branch mispredictions
```

## Troubleshooting

### "Permission denied" for perf events

```bash
# Run as root, or:
echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid
```

### Events not available

Some events may not be available on all CPUs. Check available events:
```bash
perf list
```

### High overhead from profiling

Profiling adds some overhead. For accurate timing:
1. Run the application normally first for timing
2. Then run with perf for detailed metrics

## Output Files

All results are saved to `perf_results/` directory with timestamps:
- `memory_compute_YYYYMMDD_HHMMSS.txt`
- `mlp_YYYYMMDD_HHMMSS.txt`
- `topdown_YYYYMMDD_HHMMSS.txt`
- `hotspots_YYYYMMDD_HHMMSS.txt`
- `full_report_YYYYMMDD_HHMMSS.txt`
- `perf_YYYYMMDD_HHMMSS.data` (for interactive analysis)
