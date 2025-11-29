#!/bin/bash
#
# Hotspot Analysis for CoroGraph
# Target: Intel Xeon Gold 6242R (Cascade Lake)
#
# Uses perf record + perf report to identify which functions
# consume the most CPU time
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
PERF_DATA="$OUTPUT_DIR/perf_${TIMESTAMP}.data"
REPORT_FILE="$OUTPUT_DIR/hotspots_${TIMESTAMP}.txt"

echo "=========================================="
echo "Hotspot Analysis (CPU Profiling)"
echo "Target: Intel Xeon Gold 6242R"
echo "=========================================="
echo "Executable: $EXECUTABLE"
echo "Arguments: $ARGS"
echo "=========================================="

# Record with call graph (DWARF for accuracy)
echo "Recording profile data..."
perf record -g --call-graph dwarf -o "$PERF_DATA" -- "$EXECUTABLE" $ARGS

echo ""
echo "Generating report..."

# Generate flat profile (top functions by time)
echo "====================================================" > "$REPORT_FILE"
echo "TOP FUNCTIONS BY CPU TIME (Flat Profile)" >> "$REPORT_FILE"
echo "====================================================" >> "$REPORT_FILE"
perf report -i "$PERF_DATA" --stdio --no-children --sort=overhead,symbol 2>/dev/null | head -50 >> "$REPORT_FILE"

echo "" >> "$REPORT_FILE"
echo "====================================================" >> "$REPORT_FILE"
echo "TOP FUNCTIONS WITH CALL GRAPH (Callers)" >> "$REPORT_FILE"
echo "====================================================" >> "$REPORT_FILE"
perf report -i "$PERF_DATA" --stdio --sort=overhead,symbol 2>/dev/null | head -80 >> "$REPORT_FILE"

echo ""
echo "Results saved to: $REPORT_FILE"
echo "Perf data saved to: $PERF_DATA"
echo ""
echo "To interactively explore:"
echo "  perf report -i $PERF_DATA"
echo ""
echo "To generate flame graph (if FlameGraph is installed):"
echo "  perf script -i $PERF_DATA | stackcollapse-perf.pl | flamegraph.pl > flamegraph.svg"

cat "$REPORT_FILE"
