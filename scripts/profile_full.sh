#!/bin/bash
#
# Full Performance Analysis Suite for CoroGraph
# Target: Intel Xeon Gold 6242R (Cascade Lake)
#
# Runs all profiling scripts and generates a comprehensive report
#

set -e

if [ $# -lt 1 ]; then
    echo "Usage: $0 <executable> [args...]"
    echo "Example: $0 ./crg-sssp graph.bin -t 16 -delta 13"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXECUTABLE="$1"
shift
ARGS="$@"

OUTPUT_DIR="perf_results"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_FILE="$OUTPUT_DIR/full_report_${TIMESTAMP}.txt"

echo "=========================================="
echo "Full Performance Analysis Suite"
echo "Target: Intel Xeon Gold 6242R"
echo "=========================================="
echo "Executable: $EXECUTABLE"
echo "Arguments: $ARGS"
echo "Report: $REPORT_FILE"
echo "=========================================="

{
    echo "====================================================="
    echo "COROGRAPH PERFORMANCE ANALYSIS REPORT"
    echo "====================================================="
    echo "Date: $(date)"
    echo "Executable: $EXECUTABLE"
    echo "Arguments: $ARGS"
    echo "CPU: $(lscpu | grep 'Model name' | cut -d: -f2 | xargs)"
    echo "Threads: $(nproc)"
    echo ""

    echo "====================================================="
    echo "1. BASIC TIMING (Warmup Run)"
    echo "====================================================="
    time "$EXECUTABLE" $ARGS 2>&1 || true
    echo ""

    echo "====================================================="
    echo "2. MEMORY VS COMPUTE BOUND ANALYSIS"
    echo "====================================================="
    perf stat \
        -e cycles \
        -e instructions \
        -e cache-references \
        -e cache-misses \
        -e LLC-loads \
        -e LLC-load-misses \
        -e L1-dcache-loads \
        -e L1-dcache-load-misses \
        -e branch-instructions \
        -e branch-misses \
        "$EXECUTABLE" $ARGS 2>&1 || true
    echo ""

    echo "====================================================="
    echo "3. MEMORY LEVEL PARALLELISM (MLP)"
    echo "====================================================="
    perf stat \
        -e cycles \
        -e l1d_pend_miss.pending \
        -e l1d_pend_miss.pending_cycles \
        -e l1d_pend_miss.fb_full \
        "$EXECUTABLE" $ARGS 2>&1 || true
    echo ""

    echo "====================================================="
    echo "4. MEMORY STALLS BREAKDOWN"
    echo "====================================================="
    perf stat \
        -e cycles \
        -e cycle_activity.stalls_l1d_miss \
        -e cycle_activity.stalls_l2_miss \
        -e cycle_activity.stalls_l3_miss \
        -e cycle_activity.stalls_mem_any \
        "$EXECUTABLE" $ARGS 2>&1 || true
    echo ""

    echo "====================================================="
    echo "5. PREFETCH EFFECTIVENESS"
    echo "====================================================="
    perf stat \
        -e l2_rqsts.all_pf \
        -e l2_rqsts.pf_hit \
        -e l2_rqsts.pf_miss \
        -e sw_prefetch_access.t0 \
        -e sw_prefetch_access.nta \
        "$EXECUTABLE" $ARGS 2>&1 || true
    echo ""

    echo "====================================================="
    echo "ANALYSIS SUMMARY"
    echo "====================================================="
    echo "To interpret these results:"
    echo ""
    echo "IPC (Instructions Per Cycle):"
    echo "  < 1.0 = Memory bound"
    echo "  > 2.0 = Compute bound"
    echo ""
    echo "MLP = l1d_pend_miss.pending / l1d_pend_miss.pending_cycles"
    echo "  ~1 = Sequential memory access (coroutines NOT helping)"
    echo "  >4 = Good parallelism (coroutines helping!)"
    echo ""
    echo "Memory Stall Fraction = stalls_mem_any / cycles"
    echo "  >50% = Severely memory bound"
    echo ""

} 2>&1 | tee "$REPORT_FILE"

echo ""
echo "=========================================="
echo "Report saved to: $REPORT_FILE"
echo "=========================================="
