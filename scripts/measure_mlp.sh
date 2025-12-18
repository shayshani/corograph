#!/bin/bash

# Memory Level Parallelism (MLP) and Bandwidth Analysis Script
# This script measures whether CoroGraph saturates memory bandwidth
# and how MLP scales with thread count.
#
# Uses the -perf binaries which have built-in hardware counter instrumentation
# that measures ONLY the algorithm execution (not graph loading/initialization).
#
# Key metrics from crg-sssp-perf:
#   - MLP: l1d_pend_miss.pending / l1d_pend_miss.pending_cycles
#   - Memory Bound %: stalls_mem_any / cycles (comparable to VTune)

set -e

# Configuration
GRAPH_PATH="${1:-}"
ALGORITHM="${2:-sssp}"
MAX_THREADS="${3:-40}"
OUTPUT_DIR="mlp_results_$(date +%Y%m%d_%H%M%S)"

if [ -z "$GRAPH_PATH" ]; then
    echo "Usage: $0 <graph_path> [algorithm] [max_threads]"
    echo "  algorithm: sssp (default) - uses crg-sssp-perf with built-in MLP measurement"
    echo "  max_threads: maximum thread count to test (default: 40)"
    exit 1
fi

# Determine binary based on algorithm
# The -perf versions have built-in hardware counter instrumentation
case $ALGORITHM in
    sssp)
        BINARY="./build/app/sssp/crg-sssp-perf"
        ;;
    *)
        echo "Unknown or unsupported algorithm: $ALGORITHM"
        echo "Currently only 'sssp' has -perf version with built-in MLP measurement"
        exit 1
        ;;
esac

if [ ! -f "$BINARY" ]; then
    echo "Binary not found: $BINARY"
    echo "Please build the project first:"
    echo "  mkdir -p build && cd build && cmake .. && make -j\$(nproc)"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=============================================="
echo "MLP and Memory Bandwidth Analysis"
echo "=============================================="
echo "Graph: $GRAPH_PATH"
echo "Algorithm: $ALGORITHM"
echo "Binary: $BINARY"
echo "  (measures algorithm only, excludes graph loading/init)"
echo "Max threads: $MAX_THREADS"
echo "Output directory: $OUTPUT_DIR"
echo "=============================================="

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

# Results file - header matches what crg-sssp-perf outputs
RESULTS_FILE="$OUTPUT_DIR/results.csv"
echo "threads,time_sec,cycles,instructions,ipc,mlp,mem_bound_pct,l1_misses,llc_misses" > "$RESULTS_FILE"

# Run tests
for threads in $THREAD_COUNTS; do
    echo "----------------------------------------------"
    echo "Running with $threads thread(s)..."
    echo "----------------------------------------------"

    OUTPUT_FILE="$OUTPUT_DIR/run_t${threads}.txt"

    # Run the -perf binary which has built-in instrumentation
    $BINARY "$GRAPH_PATH" -t $threads 2>&1 | tee "$OUTPUT_FILE"

    # Parse output from crg-sssp-perf
    TIME_SEC=$(grep -E "^time:" "$OUTPUT_FILE" | grep -oE "[0-9]+\.[0-9]+" || echo "0")
    CYCLES=$(grep "cycles:" "$OUTPUT_FILE" | grep -oE "[0-9]+" | head -1 || echo "0")
    INSTRUCTIONS=$(grep "instructions:" "$OUTPUT_FILE" | grep -oE "[0-9]+" | head -1 || echo "0")
    IPC=$(grep "IPC:" "$OUTPUT_FILE" | grep -oE "[0-9]+\.[0-9]+" || echo "0")
    MLP=$(grep "MLP:" "$OUTPUT_FILE" | grep -oE "[0-9]+\.[0-9]+" || echo "0")
    MEM_BOUND=$(grep -E "Memory Bound %|Memory Stall %" "$OUTPUT_FILE" | grep -oE "[0-9]+\.[0-9]+" | head -1 || echo "0")
    L1_MISSES=$(grep "L1-dcache-load-misses:" "$OUTPUT_FILE" | grep -oE "[0-9]+" | head -1 || echo "0")
    LLC_MISSES=$(grep "LLC-load-misses:" "$OUTPUT_FILE" | grep -oE "[0-9]+" | head -1 || echo "0")

    # Save to CSV
    echo "$threads,$TIME_SEC,$CYCLES,$INSTRUCTIONS,$IPC,$MLP,$MEM_BOUND,$L1_MISSES,$LLC_MISSES" >> "$RESULTS_FILE"

    echo ""
    echo ">>> Time: ${TIME_SEC}s | IPC: $IPC | MLP: $MLP | Memory Bound: ${MEM_BOUND}%"
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
Binary: $BINARY
Date: $(date)

Results saved to: $RESULTS_FILE

Key Metrics Explanation:
------------------------
1. MLP (Memory Level Parallelism):
   = l1d_pend_miss.pending / l1d_pend_miss.pending_cycles
   - Measures average number of outstanding L1D misses when at least one miss exists
   - Higher is better (more parallel memory requests)
   - Typical range: 1-10+ depending on workload

2. Memory Bound %:
   = cycle_activity.stalls_mem_any / cycles
   - Fraction of cycles stalled waiting for memory
   - This is comparable to VTune's "Memory Bound" metric (paper reports ~28% for CoroGraph)
   - Lower is better

3. IPC (Instructions Per Cycle):
   - Low IPC (<1) typically indicates memory stalls
   - Higher is better

Scalability Analysis:
---------------------
- If time scales linearly with threads: compute bound (good)
- If time plateaus early + high MLP: memory bandwidth saturated
- If time plateaus early + low MLP: MLP limited (room for improvement!)

EOF

cat "$SUMMARY_FILE"

echo ""
echo "Results CSV: $RESULTS_FILE"
echo "Detailed output: $OUTPUT_DIR/"

# Generate plot script
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

# Plot 3: MLP
ax3 = axes[1, 0]
if 'mlp' in df.columns and df['mlp'].iloc[0] > 0:
    ax3.plot(df['threads'], df['mlp'], 'm-o', linewidth=2, markersize=8)
    ax3.set_ylabel('MLP')
    ax3.set_title('Memory Level Parallelism')
else:
    ax3.plot(df['threads'], df['ipc'], 'm-o', linewidth=2, markersize=8)
    ax3.set_ylabel('IPC')
    ax3.set_title('Instructions Per Cycle')
ax3.set_xlabel('Threads')
ax3.set_xscale('log', base=2)
ax3.grid(True, alpha=0.3)

# Plot 4: Memory Bound %
ax4 = axes[1, 1]
if 'mem_bound_pct' in df.columns and df['mem_bound_pct'].iloc[0] > 0:
    ax4.plot(df['threads'], df['mem_bound_pct'], 'r-o', linewidth=2, markersize=8)
    ax4.set_ylabel('Memory Bound (%)')
    ax4.set_title('Memory Bound % (stalls_mem_any/cycles)')
    ax4.axhline(y=28, color='g', linestyle='--', label='CoroGraph paper (~28%)')
    ax4.legend()
else:
    ax4.plot(df['threads'], df['llc_misses'], 'c-o', linewidth=2, markersize=8)
    ax4.set_ylabel('LLC Misses')
    ax4.set_title('Last Level Cache Misses')
ax4.set_xlabel('Threads')
ax4.set_xscale('log', base=2)
ax4.grid(True, alpha=0.3)

plt.tight_layout()
output_file = sys.argv[1].replace('.csv', '_plots.png')
plt.savefig(output_file, dpi=150)
print(f"Plot saved to {output_file}")
plt.show()
PLOTEOF

echo ""
echo "To visualize results: python3 $PLOT_SCRIPT $RESULTS_FILE"
