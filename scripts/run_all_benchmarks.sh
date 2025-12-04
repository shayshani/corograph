#!/bin/bash
#
# Comprehensive CoroGraph Benchmark Script
# Runs all algorithms on all graphs
#
# Two modes:
#   MODE=perf   - Measure hardware perf counters (MLP, IPC, Memory Bound)
#   MODE=count  - Measure prefetch counts (only for coroutine-based algorithms)
#
# Algorithm types:
#   Coroutine-based (use Executor_ForEach.h with batched prefetching):
#     - sssp, kcore
#   Synchronous (use Executor_EdgeMap.h or do_all, no coroutine prefetching):
#     - pr, wcc
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
GRAPHS_DIR="${PROJECT_DIR}/graphs"

# Configuration
THREADS="${THREADS:-1}"  # Default 1 thread (for MLP analysis)
DELTA="${DELTA:-13}"     # Default delta for SSSP
MODE="${MODE:-perf}"     # perf or count

# Algorithms to run (space-separated). Set ALGOS env var to override.
# For MODE=count, only coroutine-based algorithms are valid: sssp, kcore
# For MODE=perf, all algorithms are valid: sssp, kcore, pr, wcc
if [ "$MODE" == "count" ]; then
    ALGOS="${ALGOS:-sssp kcore}"
else
    ALGOS="${ALGOS:-sssp kcore pr wcc}"
fi

# Output directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${PROJECT_DIR}/benchmark_results/${MODE}_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo "=========================================="
echo "CoroGraph Comprehensive Benchmark"
echo "=========================================="
echo "Mode: $MODE"
echo "Threads: $THREADS"
echo "Delta (SSSP): $DELTA"
echo "Algorithms: $ALGOS"
echo "Output directory: $OUTPUT_DIR"
echo ""
echo "Algorithm Types:"
echo "  Coroutine-based (batched prefetching): sssp, kcore"
echo "  Synchronous (no coroutine prefetching): pr, wcc"
echo "=========================================="
echo ""

# Check if executables exist
check_executable() {
    local exe="$1"
    if [ ! -f "$exe" ]; then
        echo "ERROR: Executable not found: $exe"
        echo "Please build first: cd build && cmake .. && make -j\$(nproc)"
        exit 1
    fi
}

# Define algorithms and their executables
# Format: ALGORITHMS[name]="executable"
# Format: ALGO_TYPE[name]="coroutine" or "sync"
declare -A ALGORITHMS
declare -A ALGORITHMS_COUNT
declare -A ALGO_TYPE

# Coroutine-based algorithms (use Executor_ForEach.h)
ALGORITHMS["sssp"]="${BUILD_DIR}/app/sssp/crg-sssp-perf"
ALGORITHMS_COUNT["sssp"]="${BUILD_DIR}/app/sssp/crg-sssp-perf-count"
ALGO_TYPE["sssp"]="coroutine"

ALGORITHMS["kcore"]="${BUILD_DIR}/app/k-core/crg-kcore-perf"
ALGORITHMS_COUNT["kcore"]="${BUILD_DIR}/app/k-core/crg-kcore-perf-count"
ALGO_TYPE["kcore"]="coroutine"

# Synchronous algorithms (use Executor_EdgeMap.h or do_all)
ALGORITHMS["pr"]="${BUILD_DIR}/app/pr/crg-pr-perf"
ALGO_TYPE["pr"]="sync"

ALGORITHMS["wcc"]="${BUILD_DIR}/app/cc/crg-cc-perf"
ALGO_TYPE["wcc"]="sync"

# Validate algorithms for count mode
if [ "$MODE" == "count" ]; then
    for algo in $ALGOS; do
        if [ "${ALGO_TYPE[$algo]}" != "coroutine" ]; then
            echo "ERROR: Algorithm '$algo' is not coroutine-based and cannot be used with MODE=count"
            echo "Only coroutine-based algorithms (sssp, kcore) support prefetch counting."
            exit 1
        fi
    done
fi

# Check all executables
echo "Checking executables..."
for algo in $ALGOS; do
    if [ "$MODE" == "count" ]; then
        exe="${ALGORITHMS_COUNT[$algo]}"
    else
        exe="${ALGORITHMS[$algo]}"
    fi
    check_executable "$exe"
    echo "  [OK] $algo (${ALGO_TYPE[$algo]}): $exe"
done
echo ""

# Find available graphs
echo "Finding available graphs..."
GRAPHS=()
for adj in "$GRAPHS_DIR"/*.adj; do
    if [ -f "$adj" ]; then
        GRAPHS+=("$adj")
        echo "  [OK] $(basename "$adj")"
    fi
done

if [ ${#GRAPHS[@]} -eq 0 ]; then
    echo "ERROR: No .adj graph files found in $GRAPHS_DIR"
    echo "Run ./scripts/setup_graphs.sh first"
    exit 1
fi
echo ""

# Summary CSV file
SUMMARY_FILE="${OUTPUT_DIR}/summary.csv"
if [ "$MODE" == "count" ]; then
    echo "algorithm,graph,threads,prefetches,time_sec,algo_type" > "$SUMMARY_FILE"
else
    echo "algorithm,graph,threads,mlp,ipc,memory_stall_pct,memory_bound_pct,all_loads,l3_miss_loads,l3_miss_total,time_sec,algo_type" > "$SUMMARY_FILE"
fi

# Function to parse perf output and extract metrics
parse_perf_output() {
    local output_file="$1"
    local algo="$2"
    local graph="$3"
    local threads="$4"
    local algo_type="$5"

    # Extract values from [PERF] lines
    local cycles=$(grep '\[PERF\] cycles:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local instructions=$(grep '\[PERF\] instructions:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local pending=$(grep '\[PERF\] l1d_pend_miss.pending:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local pending_cycles=$(grep '\[PERF\] l1d_pend_miss.pending_cycles:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local stalls_mem=$(grep '\[PERF\] cycle_activity.stalls_mem_any:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local all_loads=$(grep '\[PERF\] mem_inst_retired.all_loads:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local l3_miss_loads=$(grep '\[PERF\] mem_load_retired.l3_miss:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local l3_miss_total=$(grep '\[PERF\] longest_lat_cache.miss:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')

    # Extract time
    local time_sec=$(grep -E '^time:' "$output_file" | awk '{print $2}' | sort -n | head -1)

    # Calculate metrics using Python for precision
    python3 - "$cycles" "$instructions" "$pending" "$pending_cycles" "$stalls_mem" "$all_loads" "$l3_miss_loads" "$l3_miss_total" "$time_sec" "$algo" "$graph" "$threads" "$algo_type" "$SUMMARY_FILE" << 'PYTHON_SCRIPT'
import sys

cycles = int(sys.argv[1]) if sys.argv[1] else 0
instructions = int(sys.argv[2]) if sys.argv[2] else 0
pending = int(sys.argv[3]) if sys.argv[3] else 0
pending_cycles = int(sys.argv[4]) if sys.argv[4] else 0
stalls_mem = int(sys.argv[5]) if sys.argv[5] else 0
all_loads = int(sys.argv[6]) if sys.argv[6] else 0
l3_miss_loads = int(sys.argv[7]) if sys.argv[7] else 0
l3_miss_total = int(sys.argv[8]) if sys.argv[8] else 0
time_sec = float(sys.argv[9]) if sys.argv[9] else 0
algo = sys.argv[10]
graph = sys.argv[11]
threads = sys.argv[12]
algo_type = sys.argv[13]
summary_file = sys.argv[14]

# Calculate metrics
ipc = instructions / cycles if cycles > 0 else 0
mlp = pending / pending_cycles if pending_cycles > 0 else 0
mem_stall = pending_cycles / cycles * 100 if cycles > 0 else 0
mem_bound = stalls_mem / cycles * 100 if cycles > 0 else 0

# Append to summary
with open(summary_file, 'a') as f:
    f.write(f"{algo},{graph},{threads},{mlp:.2f},{ipc:.2f},{mem_stall:.1f},{mem_bound:.1f},{all_loads},{l3_miss_loads},{l3_miss_total},{time_sec:.3f},{algo_type}\n")

print(f"  MLP: {mlp:.2f}, IPC: {ipc:.2f}, MemStall: {mem_stall:.1f}%, MemBound: {mem_bound:.1f}%, Time: {time_sec:.3f}s")
PYTHON_SCRIPT
}

# Function to parse count output and extract metrics
parse_count_output() {
    local output_file="$1"
    local algo="$2"
    local graph="$3"
    local threads="$4"
    local algo_type="$5"

    # Extract prefetch count from [WORK] lines
    local prefetches=$(grep '\[WORK\] prefetches:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')

    # Extract time
    local time_sec=$(grep -E '^time:' "$output_file" | awk '{print $2}' | sort -n | head -1)

    # Append to summary
    echo "$algo,$graph,$threads,$prefetches,$time_sec,$algo_type" >> "$SUMMARY_FILE"

    echo "  Prefetches: $prefetches, Time: ${time_sec}s"
}

# Run benchmarks
echo "=========================================="
echo "Running Benchmarks (MODE=$MODE)"
echo "=========================================="
echo ""

for graph_path in "${GRAPHS[@]}"; do
    graph_name=$(basename "$graph_path" .adj)

    echo "=========================================="
    echo "Graph: $graph_name"
    echo "=========================================="

    for algo in $ALGOS; do
        if [ "$MODE" == "count" ]; then
            exe="${ALGORITHMS_COUNT[$algo]}"
        else
            exe="${ALGORITHMS[$algo]}"
        fi
        algo_type="${ALGO_TYPE[$algo]}"
        output_file="${OUTPUT_DIR}/${algo}_${graph_name}.txt"

        echo ""
        echo "--- $algo ($algo_type) on $graph_name ---"

        # Build command based on algorithm
        if [ "$algo" == "sssp" ]; then
            cmd="$exe -f $graph_path -t $THREADS -delta $DELTA"
        else
            cmd="$exe -f $graph_path -t $THREADS"
        fi

        echo "Command: $cmd"

        # Run and capture output
        if $cmd 2>&1 | tee "$output_file"; then
            if [ "$MODE" == "count" ]; then
                parse_count_output "$output_file" "$algo" "$graph_name" "$THREADS" "$algo_type"
            else
                parse_perf_output "$output_file" "$algo" "$graph_name" "$THREADS" "$algo_type"
            fi
        else
            echo "  [ERROR] $algo failed on $graph_name"
        fi
    done

    echo ""
done

echo ""
echo "=========================================="
echo "Benchmark Complete!"
echo "=========================================="
echo ""
echo "Summary saved to: $SUMMARY_FILE"
echo ""
echo "Results:"
column -t -s, "$SUMMARY_FILE"
echo ""
echo "Detailed outputs in: $OUTPUT_DIR"
echo ""

if [ "$MODE" == "perf" ]; then
    # Generate comparison with paper (if applicable)
    echo "=========================================="
    echo "Comparison with Paper Results"
    echo "=========================================="
    echo ""
    echo "Paper reports for 8 threads on LiveJournal:"
    echo "  SSSP: Memory Bound ~28.3%"
    echo "  PR:   Memory Bound ~27.4%"
    echo "  WCC:  Memory Bound ~30.4%"
    echo "  k-core: Memory Bound ~31.6%"
    echo ""
    echo "Your results (Memory Bound %):"
    grep "livejournal" "$SUMMARY_FILE" 2>/dev/null | while read line; do
        algo=$(echo "$line" | cut -d, -f1)
        mem_bound=$(echo "$line" | cut -d, -f7)
        echo "  $algo: $mem_bound%"
    done
    echo ""
fi
