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
echo "graph,threads,mlp,ipc,memory_stall_pct,l1_miss_rate,llc_miss_rate,stalls_l1d_pct,stalls_l2_pct,stalls_l3_pct,stalls_mem_pct,frontend_bound_pct,bad_spec_pct,retiring_pct,backend_bound_pct,time_sec" > "$SUMMARY"

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
    # 4. Top-Down Analysis
    # ==========================================
    echo "[$T threads] Running Top-Down analysis..."
    perf stat -o "${PREFIX}_topdown.txt" \
        -e cpu/event=0x9c,umask=0x01,name=idq_uops_not_delivered.core/ \
        -e cpu/event=0x0e,umask=0x01,name=uops_issued.any/ \
        -e cpu/event=0xc2,umask=0x02,name=uops_retired.retire_slots/ \
        -e cpu/event=0x0d,umask=0x03,name=int_misc.recovery_cycles/ \
        -e cycles \
        -e instructions \
        "$EXECUTABLE" -f "$GRAPH" -t "$T" -delta "$DELTA" > /dev/null 2>&1

    # ==========================================
    # 5. Parse results and add to summary
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
                return min(float(t) for t in times)
    except:
        pass
    return 0

# Parse all files
mlp_metrics = parse_perf_file(f"{prefix}_mlp.txt")
memcomp_metrics = parse_perf_file(f"{prefix}_memcomp.txt")
stalls_metrics = parse_perf_file(f"{prefix}_stalls.txt")
topdown_metrics = parse_perf_file(f"{prefix}_topdown.txt")

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

# Calculate Top-Down metrics (simplified Level 1)
# Formula based on Intel's Top-Down methodology
td_cycles = topdown_metrics.get('cycles', 1)
pipeline_width = 4  # Cascade Lake has 4-wide pipeline
total_slots = td_cycles * pipeline_width

idq_not_delivered = topdown_metrics.get('idq_uops_not_delivered.core', 0)
uops_issued = topdown_metrics.get('uops_issued.any', 0)
uops_retired = topdown_metrics.get('uops_retired.retire_slots', 0)
recovery_cycles = topdown_metrics.get('int_misc.recovery_cycles', 0)

frontend_bound = idq_not_delivered / total_slots * 100 if total_slots > 0 else 0
bad_spec = (uops_issued - uops_retired + recovery_cycles * pipeline_width) / total_slots * 100 if total_slots > 0 else 0
retiring = uops_retired / total_slots * 100 if total_slots > 0 else 0
backend_bound = 100 - frontend_bound - bad_spec - retiring
backend_bound = max(0, backend_bound)  # Clamp to non-negative

time_sec = parse_time(f"{prefix}_output.txt")

# Append to summary
with open(summary_file, 'a') as f:
    f.write(f"{graph_name},{threads},{mlp:.2f},{ipc:.2f},{mem_stall:.1f},{l1_miss_rate:.2f},{llc_miss_rate:.2f},{stalls_l1d:.1f},{stalls_l2:.1f},{stalls_l3:.1f},{stalls_mem:.1f},{frontend_bound:.1f},{bad_spec:.1f},{retiring:.1f},{backend_bound:.1f},{time_sec:.3f}\n")

print(f"  MLP: {mlp:.2f}, IPC: {ipc:.2f}, Mem Stall: {mem_stall:.1f}%")
print(f"  Stalls - L1D: {stalls_l1d:.1f}%, L2: {stalls_l2:.1f}%, L3: {stalls_l3:.1f}%, Mem: {stalls_mem:.1f}%")
print(f"  Top-Down - Frontend: {frontend_bound:.1f}%, BadSpec: {bad_spec:.1f}%, Retiring: {retiring:.1f}%, Backend: {backend_bound:.1f}%")
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
