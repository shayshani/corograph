#!/bin/bash
#
# Top-Down Microarchitecture Analysis for CoroGraph
# Target: Intel Xeon Gold 6242R (Cascade Lake)
#
# This uses Intel's Top-Down methodology to break down where cycles are spent:
# - Frontend Bound: Instruction fetch/decode bottlenecks
# - Backend Bound: Execution bottlenecks (further split into Memory/Core)
# - Bad Speculation: Mispredicted branches
# - Retiring: Useful work
#
# For Cascade Lake, we use the perf topdown groups
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
OUTPUT_FILE="$OUTPUT_DIR/topdown_${TIMESTAMP}.txt"

echo "=========================================="
echo "Top-Down Microarchitecture Analysis"
echo "Target: Intel Xeon Gold 6242R"
echo "=========================================="
echo "Executable: $EXECUTABLE"
echo "Arguments: $ARGS"
echo "Output: $OUTPUT_FILE"
echo "=========================================="

# Try perf stat with --topdown (available in newer perf versions)
# This automatically calculates the top-down metrics
echo "Running top-down analysis..."
perf stat -o "$OUTPUT_FILE" --topdown -a -- "$EXECUTABLE" $ARGS 2>&1 || {
    echo "Top-down mode not available, falling back to manual counters..."

    # Manual counters for top-down Level 1
    perf stat -o "$OUTPUT_FILE" \
        -e cycles \
        -e instructions \
        -e topdown-total-slots \
        -e topdown-slots-issued \
        -e topdown-slots-retired \
        -e topdown-fetch-bubbles \
        -e topdown-recovery-bubbles \
        "$EXECUTABLE" $ARGS 2>&1 || {
            echo "Topdown events not available, using approximation..."

            # Fallback: Use approximation counters
            perf stat -o "$OUTPUT_FILE" \
                -e cycles \
                -e instructions \
                -e uops_issued.any \
                -e uops_retired.retire_slots \
                -e idq_uops_not_delivered.core \
                -e int_misc.recovery_cycles \
                -e cpu/event=0xa3,umask=0x14,cmask=0x14,name=stalls_mem_any/ \
                -e cpu/event=0xa3,umask=0x04,cmask=0x04,name=stalls_total/ \
                -e cycle_activity.stalls_l1d_miss \
                -e cycle_activity.stalls_l2_miss \
                -e cycle_activity.stalls_l3_miss \
                -e cycle_activity.stalls_mem_any \
                "$EXECUTABLE" $ARGS
        }
}

echo ""
echo "Results saved to: $OUTPUT_FILE"
cat "$OUTPUT_FILE"

echo ""
echo "=========================================="
echo "Interpretation Guide:"
echo "=========================================="
echo "Top-Down Level 1 Categories:"
echo "  - Frontend Bound: CPU starved for instructions (I-cache miss, decode)"
echo "  - Backend Bound:  Execution units busy/stalled"
echo "    -> Memory Bound: Waiting for data from memory"
echo "    -> Core Bound:   Execution port saturation"
echo "  - Bad Speculation: Work thrown away due to misprediction"
echo "  - Retiring:        Actual useful work"
echo ""
echo "For graph algorithms like SSSP, expect:"
echo "  - High Backend Bound (especially Memory Bound)"
echo "  - Moderate Bad Speculation (irregular branches)"
echo "  - Low Retiring (memory latency dominates)"
