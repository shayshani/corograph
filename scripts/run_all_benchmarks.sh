#!/bin/bash
#
# Comprehensive CoroGraph Benchmark Script
# Runs all algorithms on all graphs with performance counters
#
# Measures: MLP, IPC, Memory Bound (paper metric), execution time
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_DIR}/build"
GRAPHS_DIR="${PROJECT_DIR}/graphs"

# Configuration
THREADS="${THREADS:-1}"  # Default 1 thread (for MLP analysis)
DELTA="${DELTA:-13}"     # Default delta for SSSP
# Algorithms to run (space-separated). Set ALGOS env var to override.
# Available: sssp pr wcc kcore
ALGOS="${ALGOS:-sssp pr wcc}"  # kcore excluded due to memory issues

# Output directory
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${PROJECT_DIR}/benchmark_results/run_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo "=========================================="
echo "CoroGraph Comprehensive Benchmark"
echo "=========================================="
echo "Threads: $THREADS"
echo "Delta (SSSP): $DELTA"
echo "Algorithms: $ALGOS"
echo "Output directory: $OUTPUT_DIR"
echo "=========================================="
echo ""

# Check if executables exist
check_executable() {
    local exe="$1"
    if [ ! -f "$exe" ]; then
        echo "ERROR: Executable not found: $exe"
        echo "Please build first: cd build && make -j\$(nproc)"
        exit 1
    fi
}

# Define algorithms and their executables
declare -A ALGORITHMS
ALGORITHMS["sssp"]="${BUILD_DIR}/app/sssp/crg-sssp-perf"
ALGORITHMS["pr"]="${BUILD_DIR}/app/pr/crg-pr-perf"
ALGORITHMS["wcc"]="${BUILD_DIR}/app/cc/crg-cc-perf"
ALGORITHMS["kcore"]="${BUILD_DIR}/app/k-core/crg-kcore-perf"

# Check all executables
echo "Checking executables..."
for algo in "${!ALGORITHMS[@]}"; do
    check_executable "${ALGORITHMS[$algo]}"
    echo "  [OK] $algo: ${ALGORITHMS[$algo]}"
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
echo "algorithm,graph,threads,mlp,ipc,memory_stall_pct,memory_bound_pct,time_sec" > "$SUMMARY_FILE"

# Function to parse perf output and extract metrics
parse_output() {
    local output_file="$1"
    local algo="$2"
    local graph="$3"
    local threads="$4"

    # Extract values from [PERF] lines
    local cycles=$(grep '\[PERF\] cycles:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local instructions=$(grep '\[PERF\] instructions:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local pending=$(grep '\[PERF\] l1d_pend_miss.pending:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local pending_cycles=$(grep '\[PERF\] l1d_pend_miss.pending_cycles:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')
    local stalls_mem=$(grep '\[PERF\] cycle_activity.stalls_mem_any:' "$output_file" | awk -F': ' '{print $2}' | tr -d ' ')

    # Extract best time from output (match "time: X.XXX sec" but not "Total measured time:")
    local time_sec=$(grep -E '^time:' "$output_file" | awk '{print $2}' | sort -n | head -1)

    # Calculate metrics using Python for precision
    python3 - "$cycles" "$instructions" "$pending" "$pending_cycles" "$stalls_mem" "$time_sec" "$algo" "$graph" "$threads" "$SUMMARY_FILE" << 'PYTHON_SCRIPT'
import sys

cycles = int(sys.argv[1]) if sys.argv[1] else 0
instructions = int(sys.argv[2]) if sys.argv[2] else 0
pending = int(sys.argv[3]) if sys.argv[3] else 0
pending_cycles = int(sys.argv[4]) if sys.argv[4] else 0
stalls_mem = int(sys.argv[5]) if sys.argv[5] else 0
time_sec = float(sys.argv[6]) if sys.argv[6] else 0
algo = sys.argv[7]
graph = sys.argv[8]
threads = sys.argv[9]
summary_file = sys.argv[10]

# Calculate metrics
ipc = instructions / cycles if cycles > 0 else 0
mlp = pending / pending_cycles if pending_cycles > 0 else 0
mem_stall = pending_cycles / cycles * 100 if cycles > 0 else 0
mem_bound = stalls_mem / cycles * 100 if cycles > 0 else 0

# Append to summary
with open(summary_file, 'a') as f:
    f.write(f"{algo},{graph},{threads},{mlp:.2f},{ipc:.2f},{mem_stall:.1f},{mem_bound:.1f},{time_sec:.3f}\n")

print(f"  MLP: {mlp:.2f}, IPC: {ipc:.2f}, MemStall: {mem_stall:.1f}%, MemBound: {mem_bound:.1f}%, Time: {time_sec:.3f}s")
PYTHON_SCRIPT
}

# Run benchmarks
echo "=========================================="
echo "Running Benchmarks"
echo "=========================================="
echo ""

for graph_path in "${GRAPHS[@]}"; do
    graph_name=$(basename "$graph_path" .adj)

    echo "=========================================="
    echo "Graph: $graph_name"
    echo "=========================================="

    for algo in $ALGOS; do
        exe="${ALGORITHMS[$algo]}"
        output_file="${OUTPUT_DIR}/${algo}_${graph_name}.txt"

        echo ""
        echo "--- $algo on $graph_name ---"

        # Build command based on algorithm
        if [ "$algo" == "sssp" ]; then
            cmd="$exe -f $graph_path -t $THREADS -delta $DELTA"
        else
            cmd="$exe -f $graph_path -t $THREADS"
        fi

        echo "Command: $cmd"

        # Run and capture output
        if $cmd 2>&1 | tee "$output_file"; then
            parse_output "$output_file" "$algo" "$graph_name" "$THREADS"
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
