#!/usr/bin/env bash
# =============================================================================
# adjacency-export.sh - Export full resolved/unresolved link graph as JSON
# =============================================================================
# Phase 3: Relationship Mapping
#
# Exports the complete link graph from Obsidian's metadata cache:
#   - Resolved links (adjacency list: source -> {target: count})
#   - Unresolved links (broken wikilinks)
#   - Edge list format for graph tools (NetworkX, Gephi, etc.)
#
# Usage:
#   ./adjacency-export.sh --vault <name> [--output <dir>] [--format <type>]
#
# Options:
#   --format <type>   Output format: json (default), graphml, edgelist, csv
#
# Outputs:
#   output/03-relationships/resolved-links.json     - Full adjacency list
#   output/03-relationships/unresolved-links.json   - Broken links
#   output/03-relationships/edge-list.csv            - Edge list for graph tools
#   output/03-relationships/graph-summary.json       - Graph statistics
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

FORMAT="json"

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format) FORMAT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "03-relationships")

log info "=== Adjacency Export: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Export resolved links (the core graph)
# ---------------------------------------------------------------------------
log info "Exporting resolved links adjacency list..."
obs_eval "JSON.stringify(app.metadataCache.resolvedLinks)" > "$OUT/resolved-links.json"

# ---------------------------------------------------------------------------
# 2. Export unresolved links
# ---------------------------------------------------------------------------
log info "Exporting unresolved links..."
obs_eval "JSON.stringify(app.metadataCache.unresolvedLinks)" > "$OUT/unresolved-links.json"

# ---------------------------------------------------------------------------
# 3. Generate edge list and statistics
# ---------------------------------------------------------------------------
log info "Generating edge list and graph statistics..."
python3 -c "
import json
import csv

with open('$OUT/resolved-links.json') as f:
    resolved = json.load(f)

with open('$OUT/unresolved-links.json') as f:
    unresolved = json.load(f)

# Build edge list
edges = []
nodes = set()
for source, targets in resolved.items():
    nodes.add(source)
    for target, weight in targets.items():
        nodes.add(target)
        edges.append({
            'source': source,
            'target': target,
            'weight': weight,
            'resolved': True
        })

# Add unresolved edges
unresolved_count = 0
for source, targets in unresolved.items():
    for target, weight in targets.items():
        unresolved_count += 1
        edges.append({
            'source': source,
            'target': target,
            'weight': weight,
            'resolved': False
        })

# Write edge list CSV
with open('$OUT/edge-list.csv', 'w', newline='') as f:
    writer = csv.DictWriter(f, fieldnames=['source', 'target', 'weight', 'resolved'])
    writer.writeheader()
    writer.writerows(edges)

# Compute statistics
in_degree = {}
out_degree = {}
for source, targets in resolved.items():
    out_degree[source] = out_degree.get(source, 0) + len(targets)
    for target in targets:
        in_degree[target] = in_degree.get(target, 0) + 1

total_resolved = sum(len(t) for t in resolved.values())
density = total_resolved / (len(nodes) * (len(nodes) - 1)) if len(nodes) > 1 else 0

# Degree distributions
in_values = sorted(in_degree.values(), reverse=True)
out_values = sorted(out_degree.values(), reverse=True)

summary = {
    'vault': '$VAULT',
    'nodes': len(nodes),
    'resolved_edges': total_resolved,
    'unresolved_edges': unresolved_count,
    'total_edges': total_resolved + unresolved_count,
    'density': round(density, 6),
    'avg_out_degree': round(sum(out_values) / len(out_values), 2) if out_values else 0,
    'avg_in_degree': round(sum(in_values) / len(in_values), 2) if in_values else 0,
    'max_out_degree': out_values[0] if out_values else 0,
    'max_in_degree': in_values[0] if in_values else 0,
    'median_out_degree': out_values[len(out_values)//2] if out_values else 0,
    'median_in_degree': in_values[len(in_values)//2] if in_values else 0,
    'isolates': sum(1 for n in nodes if in_degree.get(n, 0) == 0 and out_degree.get(n, 0) == 0)
}

with open('$OUT/graph-summary.json', 'w') as f:
    json.dump(summary, f, indent=2)

print(f'Nodes: {summary[\"nodes\"]}')
print(f'Resolved edges: {summary[\"resolved_edges\"]}')
print(f'Unresolved edges: {summary[\"unresolved_edges\"]}')
print(f'Density: {summary[\"density\"]}')
print(f'Avg out-degree: {summary[\"avg_out_degree\"]}')
print(f'Avg in-degree: {summary[\"avg_in_degree\"]}')
print(f'Isolates: {summary[\"isolates\"]}')
"

log info "Adjacency export complete. Output: $OUT/"
log info "  resolved-links.json    (adjacency list)"
log info "  unresolved-links.json  (broken links)"
log info "  edge-list.csv          (for graph tools)"
log info "  graph-summary.json     (statistics)"
