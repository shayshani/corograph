#!/bin/bash
#
# Memory Level Parallelism (MLP) Analysis for CoroGraph
# Target: Intel Xeon Gold 6242R (Cascade Lake)
#
# MLP measures how many memory requests are outstanding simultaneously.
# Higher MLP = better at hiding memory latency (which is what coroutines aim to do!)
#
# Key counters:
# - l1d_pend_miss.pending: Total cycles with outstanding L1D misses (summed across all misses)
# - l1d_pend_miss.pending_cycles: Cycles with at least one outstanding L1D miss
#
# MLP = pending / pending_cycles
#   - MLP ~1: Sequential memory access (one miss at a time)
#   - MLP >4: Good parallelism (multiple outstanding misses)
#

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <executable> [args...]"
    echo "Example: $0 ./crg-sssp graph.bin -t 16 -delta 13"
    exit 1
fi

EXECUTABLE="$1"
shift
ARGS="$@"

OUTPUT_DIR="perf_results"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="$OUTPUT_DIR/mlp_${TIMESTAMP}.txt"

echo "=========================================="
echo "Memory Level Parallelism (MLP) Analysis"
echo "Target: Intel Xeon Gold 6242R"
echo "=========================================="
echo "Executable: $EXECUTABLE"
echo "Arguments: $ARGS"
echo "Output: $OUTPUT_FILE"
echo "=========================================="

# MLP counters for Cascade Lake
# Note: These are raw PMU events, may need adjustment based on exact CPU
perf stat -o "$OUTPUT_FILE" \
    -e cycles \
    -e instructions \
    -e l1d_pend_miss.pending \
    -e l1d_pend_miss.pending_cycles \
    -e l1d_pend_miss.fb_full \
    -e L1-dcache-load-misses \
    -e LLC-load-misses \
    -e mem_load_retired.l1_miss \
    -e mem_load_retired.l2_miss \
    -e mem_load_retired.l3_miss \
    "$EXECUTABLE" $ARGS

echo ""
echo "Results saved to: $OUTPUT_FILE"
cat "$OUTPUT_FILE"

# Calculate MLP
echo ""
echo "=========================================="
echo "MLP Calculation:"
echo "=========================================="

python3 - "$OUTPUT_FILE" << 'PYTHON_SCRIPT'
import sys
import re

def parse_perf_output(filename):
    metrics = {}
    with open(filename, 'r') as f:
        for line in f:
            # Match lines like "  1,234,567      l1d_pend_miss.pending"
            match = re.search(r'^\s*([\d,]+)\s+(\S+)', line)
            if match:
                value = int(match.group(1).replace(',', ''))
                name = match.group(2)
                metrics[name] = value
    return metrics

try:
    m = parse_perf_output(sys.argv[1])

    pending = m.get('l1d_pend_miss.pending', 0)
    pending_cycles = m.get('l1d_pend_miss.pending_cycles', 0)
    cycles = m.get('cycles', 0)
    fb_full = m.get('l1d_pend_miss.fb_full', 0)

    print(f"l1d_pend_miss.pending:        {pending:,}")
    print(f"l1d_pend_miss.pending_cycles: {pending_cycles:,}")
    print(f"l1d_pend_miss.fb_full:        {fb_full:,}")
    print(f"Total cycles:                 {cycles:,}")
    print()

    if pending_cycles > 0:
        mlp = pending / pending_cycles
        print(f"MLP (Memory Level Parallelism): {mlp:.2f}")
        print()
        print("Interpretation:")
        print(f"  - MLP = 1.0: Sequential memory access (bad)")
        print(f"  - MLP = 2-4: Some parallelism")
        print(f"  - MLP > 4:   Good parallelism (coroutines working!)")
        print(f"  - MLP > 8:   Excellent parallelism")
        print()
        if mlp < 2:
            print("  -> Your code has LOW memory parallelism")
            print("     Coroutine prefetching may not be effective")
        elif mlp < 4:
            print("  -> Your code has MODERATE memory parallelism")
        else:
            print("  -> Your code has GOOD memory parallelism")
            print("     Coroutine prefetching is helping!")
    else:
        print("Could not calculate MLP (no pending cycles recorded)")

    # Calculate memory stall fraction
    if cycles > 0 and pending_cycles > 0:
        stall_fraction = pending_cycles / cycles * 100
        print()
        print(f"Memory Stall Fraction: {stall_fraction:.1f}%")
        print(f"  (Percentage of cycles waiting for L1D misses)")

    # Fill buffer saturation
    if pending_cycles > 0 and fb_full > 0:
        fb_saturation = fb_full / pending_cycles * 100
        print()
        print(f"Fill Buffer Saturation: {fb_saturation:.1f}%")
        print(f"  (How often the miss queue is full - indicates memory pressure)")

except Exception as e:
    print(f"Could not calculate metrics: {e}")
PYTHON_SCRIPT
