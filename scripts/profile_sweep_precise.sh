#!/bin/bash
#
# Precise Performance Sweep for CoroGraph
# Measures ONLY the SSSP algorithm execution (excludes initialization)
#
# Uses crg-sssp-perf which has built-in perf_event instrumentation.
# The counters are enabled/disabled in code around just the algorithm.
#

set -e

if [ $# -lt 2 ]; then
    echo "Usage: $0 <executable> <graph_file> [delta]"
    echo "Example: $0 ./build/app/sssp/crg-sssp-perf ./graphs/orkut.adj 13"
    echo ""
    echo "NOTE: Must use crg-sssp-perf executable (has built-in perf instrumentation)"
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
echo ""
echo "NOTE: This uses built-in perf_event counters in crg-sssp-perf."
echo "      Counters are enabled ONLY during the 5 measured SSSP iterations."
echo "      Initialization, partitioning, and warmup are NOT counted."
echo ""

# Summary file
SUMMARY="$OUTPUT_DIR/summary_${GRAPH_NAME}.csv"
echo "graph,threads,mlp,ipc,memory_stall_pct,time_sec" > "$SUMMARY"

for T in $THREADS; do
    echo ""
    echo "=========================================="
    echo "Running with $T threads"
    echo "=========================================="

    PREFIX="${OUTPUT_DIR}/${GRAPH_NAME}_t${T}"

    # Run the instrumented executable - it measures itself!
    "$EXECUTABLE" -f "$GRAPH" -t "$T" -delta "$DELTA" 2>&1 | tee "${PREFIX}_output.txt"

    # Parse the output to extract perf results
    python3 - "${PREFIX}_output.txt" "$GRAPH_NAME" "$T" "$SUMMARY" << 'PYTHON_SCRIPT'
import sys
import re

filename = sys.argv[1]
graph_name = sys.argv[2]
threads = sys.argv[3]
summary_file = sys.argv[4]

with open(filename, 'r') as f:
    content = f.read()

# Parse perf results from output
cycles = 0
instructions = 0
pending = 0
pending_cycles = 0

# Look for [PERF] lines
for line in content.split('\n'):
    if '[PERF] cycles:' in line:
        cycles = int(line.split(':')[1].strip())
    elif '[PERF] instructions:' in line:
        instructions = int(line.split(':')[1].strip())
    elif '[PERF] l1d_pend_miss.pending:' in line:
        pending = int(line.split(':')[1].strip())
    elif '[PERF] l1d_pend_miss.pending_cycles:' in line:
        pending_cycles = int(line.split(':')[1].strip())

# Parse timing - get best of the 5 measured iterations
times = re.findall(r'time:\s+([\d.]+)\s+sec', content)
if times:
    time_sec = min(float(t) for t in times)
else:
    time_sec = 0

# Calculate metrics
mlp = pending / pending_cycles if pending_cycles > 0 else 0
ipc = instructions / cycles if cycles > 0 else 0
mem_stall = pending_cycles / cycles * 100 if cycles > 0 else 0

# Append to summary
with open(summary_file, 'a') as f:
    f.write(f"{graph_name},{threads},{mlp:.2f},{ipc:.2f},{mem_stall:.1f},{time_sec:.3f}\n")

print(f"\n  SUMMARY: MLP={mlp:.2f}, IPC={ipc:.2f}, MemStall={mem_stall:.1f}%, Time={time_sec:.3f}s")
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
