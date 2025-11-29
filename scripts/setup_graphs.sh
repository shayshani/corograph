#!/bin/bash
#
# Download and convert graphs for CoroGraph benchmarking
# Uses graphs from KONECT (same as paper) and SNAP
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GRAPHS_DIR="${PROJECT_DIR}/graphs"

mkdir -p "$GRAPHS_DIR"
cd "$GRAPHS_DIR"

echo "=========================================="
echo "CoroGraph Graph Setup Script"
echo "=========================================="
echo "Graphs directory: $GRAPHS_DIR"
echo ""

# Function to download and extract
download_graph() {
    local name="$1"
    local url="$2"
    local archive="$3"
    local edgefile="$4"

    if [ -f "${name}.adj" ]; then
        echo "[SKIP] ${name}.adj already exists"
        return
    fi

    echo "[DOWNLOAD] $name from $url"
    if [ ! -f "$archive" ]; then
        wget -q --show-progress "$url" -O "$archive"
    fi

    echo "[EXTRACT] $archive"
    if [ -f "$edgefile" ]; then
        echo "  (edge file already extracted)"
    elif [[ "$archive" == *.tar.gz ]] || [[ "$archive" == *.tgz ]]; then
        tar -xzf "$archive"
    elif [[ "$archive" == *.gz ]]; then
        # gunzip to stdout, faster than gunzip -k
        gunzip -c "$archive" > "$edgefile"
    elif [[ "$archive" == *.zip ]]; then
        unzip -o "$archive"
    fi

    echo "[CONVERT] $edgefile -> ${name}.adj"
    python3 "$SCRIPT_DIR/snap_to_adj.py" "$edgefile" "${name}.adj" --no-weights

    echo "[DONE] ${name}.adj created"
    echo ""
}

# Function for KONECT format (space-separated, may have header lines starting with %)
download_konect_graph() {
    local name="$1"
    local url="$2"
    local archive="$3"
    local edgefile="$4"

    if [ -f "${name}.adj" ]; then
        echo "[SKIP] ${name}.adj already exists"
        return
    fi

    echo "[DOWNLOAD] $name from $url"
    if [ ! -f "$archive" ]; then
        wget -q --show-progress "$url" -O "$archive"
    fi

    echo "[EXTRACT] $archive"
    if [[ "$archive" == *.tar.bz2 ]]; then
        tar -xjf "$archive"
    elif [[ "$archive" == *.tar.gz ]] || [[ "$archive" == *.tgz ]]; then
        tar -xzf "$archive"
    fi

    # KONECT files use % for comments, convert to # for our parser
    echo "[PREPROCESS] Converting KONECT format"
    if [ -f "$edgefile" ]; then
        sed 's/^%/#/g' "$edgefile" > "${name}_edges.txt"
        edgefile="${name}_edges.txt"
    fi

    echo "[CONVERT] $edgefile -> ${name}.adj"
    python3 "$SCRIPT_DIR/snap_to_adj.py" "$edgefile" "${name}.adj" --no-weights

    echo "[DONE] ${name}.adj created"
    echo ""
}

echo "=========================================="
echo "Downloading graphs used in the paper"
echo "=========================================="
echo ""

# 1. LiveJournal (SNAP) - ~5M vertices, ~69M edges
echo "--- LiveJournal (LJ) ---"
download_graph "livejournal" \
    "https://snap.stanford.edu/data/soc-LiveJournal1.txt.gz" \
    "soc-LiveJournal1.txt.gz" \
    "soc-LiveJournal1.txt"

# 2. Orkut (SNAP) - ~3M vertices, ~117M edges (undirected = ~234M directed)
echo "--- Orkut (OR) ---"
download_graph "orkut" \
    "https://snap.stanford.edu/data/bigdata/communities/com-orkut.ungraph.txt.gz" \
    "com-orkut.ungraph.txt.gz" \
    "com-orkut.ungraph.txt"

# 3. Twitter (from KONECT or alternative source)
# The paper uses Twitter with 41M vertices, 1.47B edges
# This is a large download (~5GB compressed)
echo "--- Twitter (TW) ---"
if [ -f "twitter.adj" ]; then
    echo "[SKIP] twitter.adj already exists"
else
    echo "[INFO] Twitter graph is very large (~26GB). Download manually if needed:"
    echo "       URL: http://konect.cc/networks/twitter_mpi/"
    echo "       Or use: https://snap.stanford.edu/data/twitter-2010.html"
    echo ""
fi

# 4. Friendster (SNAP) - ~66M vertices, ~1.8B edges
# Very large - skip by default
echo "--- Friendster (FT) ---"
if [ -f "friendster.adj" ]; then
    echo "[SKIP] friendster.adj already exists"
else
    echo "[INFO] Friendster graph is very large (~31GB). Download manually if needed:"
    echo "       URL: https://snap.stanford.edu/data/com-Friendster.html"
    echo "       wget https://snap.stanford.edu/data/bigdata/communities/com-friendster.ungraph.txt.gz"
    echo ""
fi

# 5. RMAT-24 (Synthetic) - Generate using graph generator
echo "--- RMAT-24 (RM) ---"
if [ -f "rmat24.adj" ]; then
    echo "[SKIP] rmat24.adj already exists"
else
    echo "[INFO] RMAT-24 is a synthetic graph. Generate using a graph generator if needed."
    echo "       Typical parameters: 2^24 vertices, ~520M edges, a=0.57, b=c=0.19, d=0.05"
    echo ""
fi

# Additional smaller graphs for testing
echo "=========================================="
echo "Additional test graphs"
echo "=========================================="
echo ""

# roadNet-CA (SNAP) - smaller graph for quick tests
echo "--- roadNet-CA (road network) ---"
download_graph "roadnet-ca" \
    "https://snap.stanford.edu/data/roadNet-CA.txt.gz" \
    "roadNet-CA.txt.gz" \
    "roadNet-CA.txt"

# web-Google (SNAP) - medium size
echo "--- web-Google ---"
download_graph "web-google" \
    "https://snap.stanford.edu/data/web-Google.txt.gz" \
    "web-Google.txt.gz" \
    "web-Google.txt"

echo "=========================================="
echo "Graph Setup Complete!"
echo "=========================================="
echo ""
echo "Available graphs in $GRAPHS_DIR:"
ls -lh "$GRAPHS_DIR"/*.adj 2>/dev/null || echo "No .adj files found"
echo ""
echo "To use with CoroGraph:"
echo "  ./build/app/sssp/crg-sssp-perf -f graphs/livejournal.adj -t 8 -delta 13"
echo ""
