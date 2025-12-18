#!/bin/bash

# Memory Level Parallelism (MLP) and Bandwidth Analysis Script
# This script measures whether CoroGraph saturates memory bandwidth
# and how MLP scales with thread count.

set -e

# Configuration
GRAPH_PATH="${1:-}"
ALGORITHM="${2:-sssp}"
MAX_THREADS="${3:-40}"
OUTPUT_DIR="mlp_results_$(date +%Y%m%d_%H%M%S)"

if [ -z "$GRAPH_PATH" ]; then
    echo "Usage: $0 <graph_path> [algorithm] [max_threads]"
    echo "  algorithm: sssp, pr, cc, kcore (default: sssp)"
    echo "  max_threads: maximum thread count to test (default: 64)"
    exit 1
fi

# Determine binary based on algorithm
case $ALGORITHM in
    sssp)
        BINARY="./build/app/sssp/crg-sssp-perf"
        BINARY_ALT="./build/app/sssp/crg-sssp"
        ;;
    pr)
        BINARY="./build/app/pr/crg-pr"
        BINARY_ALT="./build/app/pr/crg-pr"
        ;;
    cc)
        BINARY="./build/app/cc/crg-cc-async"
        BINARY_ALT="./build/app/cc/crg-cc-async"
        ;;
    kcore)
        BINARY="./build/app/k-core/crg-kcore"
        BINARY_ALT="./build/app/k-core/crg-kcore"
        ;;
    *)
        echo "Unknown algorithm: $ALGORITHM"
        exit 1
        ;;
esac

# Try primary binary, fall back to alternate
if [ ! -f "$BINARY" ]; then
    if [ -f "$BINARY_ALT" ]; then
        BINARY="$BINARY_ALT"
    else
        echo "Binary not found: $BINARY"
        echo "Please build the project first:"
        echo "  mkdir -p build && cd build && cmake .. && make -j\$(nproc)"
        exit 1
    fi
fi

mkdir -p "$OUTPUT_DIR"

echo "=============================================="
echo "MLP and Memory Bandwidth Analysis"
echo "=============================================="
echo "Graph: $GRAPH_PATH"
echo "Algorithm: $ALGORITHM"
echo "Max threads: $MAX_THREADS"
echo "Output directory: $OUTPUT_DIR"
echo "=============================================="

# Check available perf events by actually testing them
echo ""
echo "Checking available perf events..."
PERF_EVENTS=""

# Function to test if a perf event works
test_perf_event() {
    perf stat -e "$1" true 2>/dev/null
    return $?
}

# Core memory events (widely available)
for event in cache-misses cache-references LLC-load-misses LLC-loads; do
    if test_perf_event "$event"; then
        PERF_EVENTS="$PERF_EVENTS,$event"
    fi
done

# Stall cycles (try different variants)
for event in cycle_activity.stalls_l3_miss cycle_activity.stalls_mem_any stalled-cycles-backend; do
    if test_perf_event "$event"; then
        PERF_EVENTS="$PERF_EVENTS,$event"
        break  # Only need one stall metric
    fi
done

# Remove leading comma
PERF_EVENTS="${PERF_EVENTS#,}"

if [ -z "$PERF_EVENTS" ]; then
    echo "Warning: No perf events available. Using basic timing only."
    USE_PERF=false
else
    echo "Using perf events: $PERF_EVENTS"
    USE_PERF=true
fi

# Thread counts to test (powers of 2 up to max, plus max itself)
THREAD_COUNTS=""
t=1
while [ $t -le $MAX_THREADS ]; do
    THREAD_COUNTS="$THREAD_COUNTS $t"
    t=$((t * 2))
done
# Add max_threads if not already included (e.g., 40 is not a power of 2)
last_added=$((t / 2))
if [ $last_added -ne $MAX_THREADS ]; then
    THREAD_COUNTS="$THREAD_COUNTS $MAX_THREADS"
fi
# Also add 20 for 40-core machine (half the cores)
if [ $MAX_THREADS -eq 40 ] && [[ ! "$THREAD_COUNTS" =~ " 20 " ]]; then
    THREAD_COUNTS="1 2 4 8 16 20 32 40"
fi

echo ""
echo "Thread counts to test: $THREAD_COUNTS"
echo ""

# Results file
RESULTS_FILE="$OUTPUT_DIR/results.csv"
echo "threads,time_sec,cache_misses,cache_refs,llc_misses,llc_loads,mem_stall_cycles,cycles,instructions,ipc" > "$RESULTS_FILE"

# Run tests
for threads in $THREAD_COUNTS; do
    echo "----------------------------------------------"
    echo "Running with $threads thread(s)..."
    echo "----------------------------------------------"

    OUTPUT_FILE="$OUTPUT_DIR/run_t${threads}.txt"
    PERF_FILE="$OUTPUT_DIR/perf_t${threads}.txt"

    if [ "$USE_PERF" = true ]; then
        # Run with perf stat
        perf stat -e cycles,instructions,$PERF_EVENTS \
            -o "$PERF_FILE" \
            $BINARY "$GRAPH_PATH" -t $threads 2>&1 | tee "$OUTPUT_FILE"

        # Parse perf output
        CYCLES=$(grep -E "^\s+[0-9].*cycles" "$PERF_FILE" | awk '{print $1}' | tr -d ',')
        INSTRUCTIONS=$(grep -E "^\s+[0-9].*instructions" "$PERF_FILE" | awk '{print $1}' | tr -d ',')
        CACHE_MISSES=$(grep "cache-misses" "$PERF_FILE" | awk '{print $1}' | tr -d ',' || echo "0")
        CACHE_REFS=$(grep "cache-references" "$PERF_FILE" | awk '{print $1}' | tr -d ',' || echo "0")
        LLC_MISSES=$(grep "LLC-load-misses" "$PERF_FILE" | awk '{print $1}' | tr -d ',' || echo "0")
        LLC_LOADS=$(grep "LLC-loads" "$PERF_FILE" | awk '{print $1}' | tr -d ',' || echo "0")
        MEM_STALLS=$(grep -E "stalls_mem_any|stalls_l3_miss" "$PERF_FILE" | head -1 | awk '{print $1}' | tr -d ',' || echo "0")

        # Calculate IPC
        if [ -n "$CYCLES" ] && [ "$CYCLES" != "0" ] && [ -n "$INSTRUCTIONS" ]; then
            IPC=$(echo "scale=3; $INSTRUCTIONS / $CYCLES" | bc)
        else
            IPC="0"
        fi
    else
        # Run without perf
        $BINARY "$GRAPH_PATH" -t $threads 2>&1 | tee "$OUTPUT_FILE"
        CYCLES="0"
        INSTRUCTIONS="0"
        CACHE_MISSES="0"
        CACHE_REFS="0"
        LLC_MISSES="0"
        LLC_LOADS="0"
        MEM_STALLS="0"
        IPC="0"
    fi

    # Extract execution time from output
    TIME_SEC=$(grep -E "time:|Time:" "$OUTPUT_FILE" | head -1 | grep -oE "[0-9]+\.[0-9]+" || echo "0")

    # Save to CSV
    echo "$threads,$TIME_SEC,$CACHE_MISSES,$CACHE_REFS,$LLC_MISSES,$LLC_LOADS,$MEM_STALLS,$CYCLES,$INSTRUCTIONS,$IPC" >> "$RESULTS_FILE"

    echo ""
    echo "Time: ${TIME_SEC}s, IPC: $IPC, LLC Misses: $LLC_MISSES"
    echo ""

    # Small delay between runs
    sleep 2
done

echo ""
echo "=============================================="
echo "Analysis Complete"
echo "=============================================="

# Generate summary
SUMMARY_FILE="$OUTPUT_DIR/summary.txt"
cat > "$SUMMARY_FILE" << EOF
MLP and Memory Bandwidth Analysis Summary
==========================================
Graph: $GRAPH_PATH
Algorithm: $ALGORITHM
Date: $(date)

Results saved to: $RESULTS_FILE

Key Metrics to Analyze:
-----------------------
1. LLC Miss Rate = LLC-load-misses / LLC-loads
   - High rate + low bandwidth = poor MLP (few outstanding requests)
   - High rate + high bandwidth = good MLP (saturating memory)

2. Memory Stall Cycles / Total Cycles = Memory Bound %
   - This is what the paper reports (~28% for CoroGraph)

3. Scalability Analysis:
   - If time scales linearly with threads: compute bound
   - If time plateaus early: memory bandwidth bound
   - If time plateaus + low bandwidth: MLP limited

4. IPC (Instructions Per Cycle):
   - Low IPC (<1) typically indicates memory stalls
   - IPC should increase with prefetching effectiveness

To measure actual bandwidth utilization, also run:
  - Intel PCM: pcm-memory (if available)
  - likwid-perfctr -g MEM -C 0-$((MAX_THREADS-1)) $BINARY $GRAPH_PATH -t $MAX_THREADS

EOF

cat "$SUMMARY_FILE"

echo ""
echo "Results CSV: $RESULTS_FILE"
echo "Detailed output: $OUTPUT_DIR/"

# Optional: Generate plot script
PLOT_SCRIPT="$OUTPUT_DIR/plot_results.py"
cat > "$PLOT_SCRIPT" << 'PLOTEOF'
#!/usr/bin/env python3
import pandas as pd
import matplotlib.pyplot as plt
import sys

if len(sys.argv) < 2:
    print("Usage: python plot_results.py results.csv")
    sys.exit(1)

df = pd.read_csv(sys.argv[1])

fig, axes = plt.subplots(2, 2, figsize=(12, 10))

# Plot 1: Execution time vs threads
ax1 = axes[0, 0]
ax1.plot(df['threads'], df['time_sec'], 'b-o', linewidth=2, markersize=8)
ax1.set_xlabel('Threads')
ax1.set_ylabel('Time (seconds)')
ax1.set_title('Execution Time vs Thread Count')
ax1.set_xscale('log', base=2)
ax1.grid(True, alpha=0.3)

# Plot 2: Speedup
ax2 = axes[0, 1]
baseline_time = df['time_sec'].iloc[0]
speedup = baseline_time / df['time_sec']
ideal_speedup = df['threads']
ax2.plot(df['threads'], speedup, 'g-o', linewidth=2, markersize=8, label='Actual')
ax2.plot(df['threads'], ideal_speedup, 'r--', linewidth=1, label='Ideal')
ax2.set_xlabel('Threads')
ax2.set_ylabel('Speedup')
ax2.set_title('Scalability (Speedup vs Threads)')
ax2.set_xscale('log', base=2)
ax2.legend()
ax2.grid(True, alpha=0.3)

# Plot 3: IPC
ax3 = axes[1, 0]
ax3.plot(df['threads'], df['ipc'], 'm-o', linewidth=2, markersize=8)
ax3.set_xlabel('Threads')
ax3.set_ylabel('IPC')
ax3.set_title('Instructions Per Cycle')
ax3.set_xscale('log', base=2)
ax3.grid(True, alpha=0.3)

# Plot 4: LLC Miss Rate
ax4 = axes[1, 1]
if df['llc_loads'].iloc[0] > 0:
    miss_rate = df['llc_misses'] / df['llc_loads'] * 100
    ax4.plot(df['threads'], miss_rate, 'c-o', linewidth=2, markersize=8)
    ax4.set_ylabel('LLC Miss Rate (%)')
else:
    ax4.plot(df['threads'], df['llc_misses'], 'c-o', linewidth=2, markersize=8)
    ax4.set_ylabel('LLC Misses')
ax4.set_xlabel('Threads')
ax4.set_title('Last Level Cache Performance')
ax4.set_xscale('log', base=2)
ax4.grid(True, alpha=0.3)

plt.tight_layout()
plt.savefig(sys.argv[1].replace('.csv', '_plots.png'), dpi=150)
print(f"Plot saved to {sys.argv[1].replace('.csv', '_plots.png')}")
plt.show()
PLOTEOF

echo ""
echo "To visualize results: python3 $PLOT_SCRIPT $RESULTS_FILE"
