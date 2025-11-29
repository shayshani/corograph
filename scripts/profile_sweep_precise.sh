#!/bin/bash
#
# Precise Performance Sweep for CoroGraph
# Measures ONLY the SSSP algorithm execution (excludes initialization)
#
# This script:
# 1. First runs the program to measure initialization time
# 2. Then runs perf with --delay to skip initialization
#

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <executable> <graph_file> [delta]"
    echo "Example: $0 ./build/app/sssp/crg-sssp-perf ./graphs/orkut.adj 13"
    echo ""
    echo "NOTE: Use crg-sssp-perf executable for precise measurements"
    exit 1
fi

EXECUTABLE="$1"
GRAPH="$2"
DELTA="${3:-13}"

THREADS="1 2 4 8"

OUTPUT_DIR="perf_results/sweep_precise_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"

GRAPH_NAME=$(basename "$GRAPH" .adj)

echo "=========================================="
echo "Precise Performance Sweep (Algorithm Only)"
echo "=========================================="
echo "Executable: $EXECUTABLE"
echo "Graph: $GRAPH ($GRAPH_NAME)"
echo "Delta: $DELTA"
echo "Thread counts: $THREADS"
echo "Output directory: $OUTPUT_DIR"
echo "=========================================="

# Summary file
SUMMARY="$OUTPUT_DIR/summary_${GRAPH_NAME}.csv"
echo "graph,threads,mlp,ipc,memory_stall_pct,l1_miss_rate,llc_miss_rate,stalls_l1d_pct,stalls_l2_pct,stalls_l3_pct,stalls_mem_pct,time_sec" > "$SUMMARY"

for T in $THREADS; do
    echo ""
    echo "=========================================="
    echo "Running with $T threads"
    echo "=========================================="

    PREFIX="${OUTPUT_DIR}/${GRAPH_NAME}_t${T}"

    # ==========================================
    # Step 0: Measure initialization time
    # ==========================================
    echo "[$T threads] Measuring initialization time..."
    INIT_OUTPUT=$(mktemp)
    "$EXECUTABLE" -f "$GRAPH" -t "$T" -delta "$DELTA" 2>&1 | tee "$INIT_OUTPUT" | head -30

    # Parse the output to find when ###PERF_START### appears
    # We'll estimate delay based on when the marker appears
    INIT_TIME_MS=$(python3 - "$INIT_OUTPUT" << 'PYTHON_SCRIPT'
import sys
import re

filename = sys.argv[1]
with open(filename, 'r') as f:
    content = f.read()

# Find elapsed time before PERF_START marker
# We look for the warmup time and add buffer
# The warmup run time gives us a good estimate
times = re.findall(r'time:\s+([\d.]+)\s+sec', content)

# First time is warmup - use it to estimate init time
# Init = load + partition + warmup
# We'll use 2x warmup as a safe estimate for init delay
if times:
    warmup_time = float(times[0])
    # Add some buffer for graph loading/partitioning
    # Estimate: init takes about as long as one SSSP run for small graphs,
    # more for large graphs due to I/O
    init_estimate_sec = warmup_time * 3 + 5  # 3x warmup + 5 sec buffer
    print(int(init_estimate_sec * 1000))  # Convert to milliseconds
else:
    print(10000)  # Default 10 second delay
PYTHON_SCRIPT
)
    rm -f "$INIT_OUTPUT"

    echo "[$T threads] Estimated init time: ${INIT_TIME_MS}ms, using delay for perf"

    # ==========================================
    # 1. MLP Analysis (with delayed start)
    # ==========================================
    echo "[$T threads] Running MLP analysis (delayed start: ${INIT_TIME_MS}ms)..."
    perf stat -D "$INIT_TIME_MS" -o "${PREFIX}_mlp.txt" \
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
    perf stat -D "$INIT_TIME_MS" -o "${PREFIX}_memcomp.txt" \
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
    perf stat -D "$INIT_TIME_MS" -o "${PREFIX}_stalls.txt" \
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
            times = re.findall(r'time:\s+([\d.]+)\s+sec', content)
            if times:
                # Return best of measured runs (skip warmup if present)
                # The crg-sssp-perf version has warmup as first, then 5 measured
                if len(times) > 1:
                    measured_times = [float(t) for t in times[1:]]
                else:
                    measured_times = [float(t) for t in times]
                return min(measured_times) if measured_times else 0
    except:
        pass
    return 0

# Parse all files
mlp_metrics = parse_perf_file(f"{prefix}_mlp.txt")
memcomp_metrics = parse_perf_file(f"{prefix}_memcomp.txt")
stalls_metrics = parse_perf_file(f"{prefix}_stalls.txt")

# Calculate MLP metrics
cycles = mlp_metrics.get('cycles', 1)
instructions = mlp_metrics.get('instructions', 0)
pending = mlp_metrics.get('l1d_pend_miss.pending', 0)
pending_cycles = mlp_metrics.get('l1d_pend_miss.pending_cycles', 1)

mlp = pending / pending_cycles if pending_cycles > 0 else 0
ipc = instructions / cycles if cycles > 0 else 0
mem_stall = pending_cycles / cycles * 100 if cycles > 0 else 0

# Calculate cache miss rates
l1_loads = memcomp_metrics.get('L1-dcache-loads', 1)
l1_misses = memcomp_metrics.get('L1-dcache-load-misses', 0)
llc_loads = memcomp_metrics.get('LLC-loads', 1)
llc_misses = memcomp_metrics.get('LLC-load-misses', 0)

l1_miss_rate = l1_misses / l1_loads * 100 if l1_loads > 0 else 0
llc_miss_rate = llc_misses / llc_loads * 100 if llc_loads > 0 else 0

# Calculate stall breakdown
stalls_cycles = stalls_metrics.get('cycles', 1)
stalls_l1d = stalls_metrics.get('cycle_activity.stalls_l1d_miss', 0) / stalls_cycles * 100
stalls_l2 = stalls_metrics.get('cycle_activity.stalls_l2_miss', 0) / stalls_cycles * 100
stalls_l3 = stalls_metrics.get('cycle_activity.stalls_l3_miss', 0) / stalls_cycles * 100
stalls_mem = stalls_metrics.get('cycle_activity.stalls_mem_any', 0) / stalls_cycles * 100

time_sec = parse_time(f"{prefix}_output.txt")

# Append to summary
with open(summary_file, 'a') as f:
    f.write(f"{graph_name},{threads},{mlp:.2f},{ipc:.2f},{mem_stall:.1f},{l1_miss_rate:.2f},{llc_miss_rate:.2f},{stalls_l1d:.1f},{stalls_l2:.1f},{stalls_l3:.1f},{stalls_mem:.1f},{time_sec:.3f}\n")

print(f"  MLP: {mlp:.2f}, IPC: {ipc:.2f}, Mem Stall: {mem_stall:.1f}%")
print(f"  Stalls - L1D: {stalls_l1d:.1f}%, L2: {stalls_l2:.1f}%, L3: {stalls_l3:.1f}%, Mem: {stalls_mem:.1f}%")
print(f"  Time: {time_sec:.3f}s")
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
