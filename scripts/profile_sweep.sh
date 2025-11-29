#!/bin/bash
#
# Comprehensive Performance Sweep for CoroGraph
# Runs MLP, Memory/Compute, and Top-Down analysis across multiple thread counts
#

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <executable> <graph_file> [delta]"
    echo "Example: $0 ./build/app/sssp/crg-sssp ./graphs/orkut.adj 13"
    exit 1
fi

EXECUTABLE="$1"
GRAPH="$2"
DELTA="${3:-13}"

THREADS="1 2 4 8 20 40"

OUTPUT_DIR="perf_results/sweep_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"

GRAPH_NAME=$(basename "$GRAPH" .adj)

echo "=========================================="
echo "Performance Sweep"
echo "=========================================="
echo "Executable: $EXECUTABLE"
echo "Graph: $GRAPH ($GRAPH_NAME)"
echo "Delta: $DELTA"
echo "Thread counts: $THREADS"
echo "Output directory: $OUTPUT_DIR"
echo "=========================================="

# Summary file
SUMMARY="$OUTPUT_DIR/summary_${GRAPH_NAME}.csv"
echo "graph,threads,mlp,ipc,memory_stall_pct,l1_miss_rate,llc_miss_rate,time_sec" > "$SUMMARY"

for T in $THREADS; do
    echo ""
    echo "=========================================="
    echo "Running with $T threads"
    echo "=========================================="

    PREFIX="${OUTPUT_DIR}/${GRAPH_NAME}_t${T}"

    # ==========================================
    # 1. MLP Analysis
    # ==========================================
    echo "[$T threads] Running MLP analysis..."
    perf stat -o "${PREFIX}_mlp.txt" \
        -e cycles \
        -e instructions \
        -e l1d_pend_miss.pending \
        -e l1d_pend_miss.pending_cycles \
        -e l1d_pend_miss.fb_full \
        "$EXECUTABLE" -f "$GRAPH" -t "$T" -delta "$DELTA" 2>&1 | tee "${PREFIX}_output.txt"

    # ==========================================
    # 2. Memory/Compute Analysis
    # ==========================================
    echo "[$T threads] Running Memory/Compute analysis..."
    perf stat -o "${PREFIX}_memcomp.txt" \
        -e cycles \
        -e instructions \
        -e L1-dcache-loads \
        -e L1-dcache-load-misses \
        -e LLC-loads \
        -e LLC-load-misses \
        -e cache-references \
        -e cache-misses \
        "$EXECUTABLE" -f "$GRAPH" -t "$T" -delta "$DELTA" > /dev/null 2>&1

    # ==========================================
    # 3. Stall Cycles Analysis
    # ==========================================
    echo "[$T threads] Running Stall Cycles analysis..."
    perf stat -o "${PREFIX}_stalls.txt" \
        -e cycles \
        -e cycle_activity.stalls_l1d_miss \
        -e cycle_activity.stalls_l2_miss \
        -e cycle_activity.stalls_l3_miss \
        -e cycle_activity.stalls_mem_any \
        "$EXECUTABLE" -f "$GRAPH" -t "$T" -delta "$DELTA" > /dev/null 2>&1

    # ==========================================
    # 4. Parse results and add to summary
    # ==========================================
    python3 - "$PREFIX" "$GRAPH_NAME" "$T" "$SUMMARY" << 'PYTHON_SCRIPT'
import sys
import re

prefix = sys.argv[1]
graph_name = sys.argv[2]
threads = sys.argv[3]
summary_file = sys.argv[4]

def parse_perf_file(filename):
    metrics = {}
    try:
        with open(filename, 'r') as f:
            for line in f:
                match = re.search(r'^\s*([\d,]+)\s+(\S+)', line)
                if match:
                    value = int(match.group(1).replace(',', ''))
                    name = match.group(2)
                    metrics[name] = value
    except:
        pass
    return metrics

def parse_time(filename):
    try:
        with open(filename, 'r') as f:
            content = f.read()
            # Find best time from output
            times = re.findall(r'time:\s+([\d.]+)\s+sec', content)
            if times:
                return min(float(t) for t in times)
    except:
        pass
    return 0

# Parse MLP file
mlp_metrics = parse_perf_file(f"{prefix}_mlp.txt")
memcomp_metrics = parse_perf_file(f"{prefix}_memcomp.txt")

# Calculate metrics
cycles = mlp_metrics.get('cycles', 1)
instructions = mlp_metrics.get('instructions', 0)
pending = mlp_metrics.get('l1d_pend_miss.pending', 0)
pending_cycles = mlp_metrics.get('l1d_pend_miss.pending_cycles', 1)

mlp = pending / pending_cycles if pending_cycles > 0 else 0
ipc = instructions / cycles if cycles > 0 else 0
mem_stall = pending_cycles / cycles * 100 if cycles > 0 else 0

l1_loads = memcomp_metrics.get('L1-dcache-loads', 1)
l1_misses = memcomp_metrics.get('L1-dcache-load-misses', 0)
llc_loads = memcomp_metrics.get('LLC-loads', 1)
llc_misses = memcomp_metrics.get('LLC-load-misses', 0)

l1_miss_rate = l1_misses / l1_loads * 100 if l1_loads > 0 else 0
llc_miss_rate = llc_misses / llc_loads * 100 if llc_loads > 0 else 0

time_sec = parse_time(f"{prefix}_output.txt")

# Append to summary
with open(summary_file, 'a') as f:
    f.write(f"{graph_name},{threads},{mlp:.2f},{ipc:.2f},{mem_stall:.1f},{l1_miss_rate:.2f},{llc_miss_rate:.2f},{time_sec:.3f}\n")

print(f"  MLP: {mlp:.2f}, IPC: {ipc:.2f}, Mem Stall: {mem_stall:.1f}%, Time: {time_sec:.3f}s")
PYTHON_SCRIPT

done

echo ""
echo "=========================================="
echo "Sweep Complete!"
echo "=========================================="
echo ""
echo "Summary saved to: $SUMMARY"
echo ""
cat "$SUMMARY" | column -t -s,
echo ""
echo "Detailed results in: $OUTPUT_DIR"
