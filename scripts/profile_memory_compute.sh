#!/bin/bash
#
# Memory vs Compute Bound Analysis for CoroGraph
# Target: Intel Xeon Gold 6242R (Cascade Lake)
#
# This script uses perf stat to collect counters that help determine
# whether the application is memory-bound or compute-bound.
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
OUTPUT_FILE="$OUTPUT_DIR/memory_compute_${TIMESTAMP}.txt"

echo "=========================================="
echo "Memory vs Compute Bound Analysis"
echo "Target: Intel Xeon Gold 6242R"
echo "=========================================="
echo "Executable: $EXECUTABLE"
echo "Arguments: $ARGS"
echo "Output: $OUTPUT_FILE"
echo "=========================================="

# Run with comprehensive counters for memory/compute analysis
# These counters work on Cascade Lake (6242R)
perf stat -o "$OUTPUT_FILE" \
    -e cycles \
    -e instructions \
    -e cache-references \
    -e cache-misses \
    -e LLC-loads \
    -e LLC-load-misses \
    -e LLC-stores \
    -e LLC-store-misses \
    -e L1-dcache-loads \
    -e L1-dcache-load-misses \
    -e L1-dcache-stores \
    -e dTLB-loads \
    -e dTLB-load-misses \
    -e branch-instructions \
    -e branch-misses \
    -e cpu-clock \
    -e task-clock \
    "$EXECUTABLE" $ARGS

echo ""
echo "Results saved to: $OUTPUT_FILE"
cat "$OUTPUT_FILE"

# Calculate and display derived metrics
echo ""
echo "=========================================="
echo "Derived Metrics:"
echo "=========================================="

# Parse the output file and calculate metrics
python3 - "$OUTPUT_FILE" << 'PYTHON_SCRIPT'
import sys
import re

def parse_perf_output(filename):
    metrics = {}
    with open(filename, 'r') as f:
        for line in f:
            # Match lines like "  1,234,567      cycles"
            match = re.search(r'^\s*([\d,]+)\s+(\S+)', line)
            if match:
                value = int(match.group(1).replace(',', ''))
                name = match.group(2)
                metrics[name] = value
    return metrics

try:
    m = parse_perf_output(sys.argv[1])

    print(f"IPC (Instructions Per Cycle): {m.get('instructions', 0) / m.get('cycles', 1):.3f}")
    print(f"  - IPC < 1.0 typically indicates memory-bound")
    print(f"  - IPC > 2.0 typically indicates compute-bound")
    print()

    l1_miss_rate = m.get('L1-dcache-load-misses', 0) / max(m.get('L1-dcache-loads', 1), 1) * 100
    print(f"L1 D-Cache Miss Rate: {l1_miss_rate:.2f}%")

    llc_miss_rate = m.get('LLC-load-misses', 0) / max(m.get('LLC-loads', 1), 1) * 100
    print(f"LLC Miss Rate: {llc_miss_rate:.2f}%")
    print(f"  - High LLC miss rate indicates memory bandwidth bound")
    print()

    branch_miss_rate = m.get('branch-misses', 0) / max(m.get('branch-instructions', 1), 1) * 100
    print(f"Branch Misprediction Rate: {branch_miss_rate:.2f}%")

    dtlb_miss_rate = m.get('dTLB-load-misses', 0) / max(m.get('dTLB-loads', 1), 1) * 100
    print(f"dTLB Miss Rate: {dtlb_miss_rate:.4f}%")
    print()

    print("Memory Bound Indicators:")
    print(f"  - Low IPC (< 1.0): {'YES' if m.get('instructions', 0) / m.get('cycles', 1) < 1.0 else 'NO'}")
    print(f"  - High L1 miss rate (> 5%): {'YES' if l1_miss_rate > 5 else 'NO'}")
    print(f"  - High LLC miss rate (> 20%): {'YES' if llc_miss_rate > 20 else 'NO'}")

except Exception as e:
    print(f"Could not calculate metrics: {e}")
PYTHON_SCRIPT
