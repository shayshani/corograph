#!/usr/bin/env python3
"""
Convert SNAP edge list format to PBBS adjacency format.

SNAP format:
  # comments
  src dst
  src dst
  ...

PBBS adjacency format:
  AdjacencyGraph
  <num_vertices>
  <num_edges>
  <offset_0>
  <offset_1>
  ...
  <offset_n>
  <edge_0>
  <edge_1>
  ...
  <edge_m>
  [optional: weights]
"""

import sys
from collections import defaultdict

def convert_snap_to_adj(input_file, output_file, add_weights=True):
    print(f"Reading {input_file}...")

    # Read edges and build adjacency list
    adj = defaultdict(list)
    max_node = 0
    edge_count = 0

    with open(input_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            if len(parts) >= 2:
                src, dst = int(parts[0]), int(parts[1])
                adj[src].append(dst)
                max_node = max(max_node, src, dst)
                edge_count += 1

    num_vertices = max_node + 1
    print(f"Vertices: {num_vertices}, Edges: {edge_count}")

    # Sort adjacency lists
    for v in adj:
        adj[v].sort()

    # Calculate offsets
    print("Calculating offsets...")
    offsets = []
    current_offset = 0
    for v in range(num_vertices):
        offsets.append(current_offset)
        current_offset += len(adj[v])

    # Write output
    print(f"Writing {output_file}...")
    with open(output_file, 'w') as f:
        if add_weights:
            f.write("WeightedAdjacencyGraph\n")
        else:
            f.write("AdjacencyGraph\n")
        f.write(f"{num_vertices}\n")
        f.write(f"{edge_count}\n")

        # Write offsets
        for offset in offsets:
            f.write(f"{offset}\n")

        # Write edges (and weights if needed)
        for v in range(num_vertices):
            for neighbor in adj[v]:
                f.write(f"{neighbor}\n")

        # Write weights (all 1s for unweighted graph)
        if add_weights:
            for v in range(num_vertices):
                for _ in adj[v]:
                    f.write("1\n")

    print("Done!")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <input.txt> <output.adj> [--no-weights]")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]
    add_weights = "--no-weights" not in sys.argv

    convert_snap_to_adj(input_file, output_file, add_weights)
