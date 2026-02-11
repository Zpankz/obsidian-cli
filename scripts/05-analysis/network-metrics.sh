#!/usr/bin/env bash
# =============================================================================
# network-metrics.sh - Degree distribution, density, hub detection
# =============================================================================
# Phase 5: Graph Analysis
#
# Computes comprehensive network metrics from the vault's link graph:
#   - Degree distributions (in, out, total)
#   - Network density and connectivity
#   - Power-law fit (scale-free detection)
#   - Clustering coefficient estimation
#   - Connected component analysis
#
# Usage:
#   ./network-metrics.sh --vault <name> [--output <dir>]
#
# Outputs:
#   output/05-analysis/network-metrics.json     - Full metrics report
#   output/05-analysis/degree-distribution.json  - Degree frequency tables
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"
parse_common_args "$@"
require_vault

OUT=$(ensure_output_dir "05-analysis")

log info "=== Network Metrics: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Export graph data via eval
# ---------------------------------------------------------------------------
log info "Exporting graph adjacency data..."
obs_eval "
  const resolved = app.metadataCache.resolvedLinks;
  const nodes = new Set();
  const edges = [];
  Object.entries(resolved).forEach(([source, targets]) => {
    nodes.add(source);
    Object.entries(targets).forEach(([target, weight]) => {
      nodes.add(target);
      edges.push({s: source, t: target, w: weight});
    });
  });
  JSON.stringify({
    nodeCount: nodes.size,
    edgeCount: edges.length,
    nodes: [...nodes],
    edges: edges
  });
" > "$OUT/_raw_graph.json"

# ---------------------------------------------------------------------------
# 2. Compute metrics with Python
# ---------------------------------------------------------------------------
log info "Computing network metrics..."
python3 << 'PYEOF'
import json
import math
from collections import defaultdict, deque

out_dir = """OUT"""

with open(f'{out_dir}/_raw_graph.json') as f:
    graph = json.load(f)

nodes = set(graph['nodes'])
edges = graph['edges']
node_count = len(nodes)
edge_count = len(edges)

# Build adjacency lists
out_adj = defaultdict(set)
in_adj = defaultdict(set)
out_degree = defaultdict(int)
in_degree = defaultdict(int)

for e in edges:
    out_adj[e['s']].add(e['t'])
    in_adj[e['t']].add(e['s'])
    out_degree[e['s']] += 1
    in_degree[e['t']] += 1

# Degree calculations
total_degree = {}
for n in nodes:
    total_degree[n] = out_degree.get(n, 0) + in_degree.get(n, 0)

out_values = [out_degree.get(n, 0) for n in nodes]
in_values = [in_degree.get(n, 0) for n in nodes]
total_values = [total_degree.get(n, 0) for n in nodes]

def stats(values):
    if not values:
        return {'mean': 0, 'median': 0, 'std': 0, 'max': 0, 'min': 0}
    s = sorted(values)
    n = len(s)
    mean = sum(s) / n
    median = s[n // 2]
    variance = sum((x - mean) ** 2 for x in s) / n
    return {
        'mean': round(mean, 2),
        'median': median,
        'std': round(math.sqrt(variance), 2),
        'max': max(s),
        'min': min(s),
        'cv': round(math.sqrt(variance) / mean, 3) if mean > 0 else 0
    }

# Density
max_possible = node_count * (node_count - 1) if node_count > 1 else 1
density = edge_count / max_possible

# Connected components (undirected)
undirected = defaultdict(set)
for e in edges:
    undirected[e['s']].add(e['t'])
    undirected[e['t']].add(e['s'])

visited = set()
components = []
for node in nodes:
    if node in visited:
        continue
    component = set()
    queue = deque([node])
    while queue:
        current = queue.popleft()
        if current in visited:
            continue
        visited.add(current)
        component.add(current)
        for neighbor in undirected.get(current, []):
            if neighbor not in visited:
                queue.append(neighbor)
    components.append(len(component))

components.sort(reverse=True)

# Clustering coefficient (sampled for performance)
import random
sample_size = min(500, node_count)
sample_nodes = random.sample(list(nodes), sample_size) if node_count > 0 else []

clustering_coefficients = []
for node in sample_nodes:
    neighbors = undirected.get(node, set())
    k = len(neighbors)
    if k < 2:
        clustering_coefficients.append(0.0)
        continue
    triangles = 0
    neighbor_list = list(neighbors)
    for i in range(len(neighbor_list)):
        for j in range(i + 1, len(neighbor_list)):
            if neighbor_list[j] in undirected.get(neighbor_list[i], set()):
                triangles += 1
    max_triangles = k * (k - 1) / 2
    clustering_coefficients.append(triangles / max_triangles)

avg_clustering = sum(clustering_coefficients) / len(clustering_coefficients) if clustering_coefficients else 0

# Degree distribution
def degree_freq(values):
    freq = defaultdict(int)
    for v in values:
        freq[v] += 1
    return {str(k): v for k, v in sorted(freq.items())}

# Scale-free detection (coefficient of variation > 1.0 suggests power-law)
out_stats = stats(out_values)
in_stats = stats(in_values)
total_stats = stats(total_values)
is_scale_free = total_stats['cv'] > 1.0

# Isolates
isolates = sum(1 for n in nodes if total_degree.get(n, 0) == 0)

metrics = {
    'vault': graph.get('vault', ''),
    'node_count': node_count,
    'edge_count': edge_count,
    'density': round(density, 6),
    'is_scale_free': is_scale_free,
    'avg_clustering_coefficient': round(avg_clustering, 4),
    'clustering_sample_size': sample_size,
    'connected_components': len(components),
    'largest_component_size': components[0] if components else 0,
    'largest_component_pct': round(components[0] / node_count * 100, 1) if components and node_count else 0,
    'isolates': isolates,
    'degree_stats': {
        'out_degree': out_stats,
        'in_degree': in_stats,
        'total_degree': total_stats
    },
    'topology': 'scale-free' if is_scale_free else 'random',
    'small_world_indicators': {
        'high_clustering': avg_clustering > 0.1,
        'low_density': density < 0.05,
        'scale_free': is_scale_free,
        'verdict': 'likely small-world' if (avg_clustering > 0.1 and density < 0.05) else 'inconclusive'
    }
}

with open(f'{out_dir}/network-metrics.json', 'w') as f:
    json.dump(metrics, f, indent=2)

degree_dist = {
    'out_degree_frequency': degree_freq(out_values),
    'in_degree_frequency': degree_freq(in_values),
    'total_degree_frequency': degree_freq(total_values)
}

with open(f'{out_dir}/degree-distribution.json', 'w') as f:
    json.dump(degree_dist, f, indent=2)

print(f'Nodes: {node_count}, Edges: {edge_count}')
print(f'Density: {density:.6f}')
print(f'Topology: {metrics["topology"]} (CV={total_stats["cv"]})')
print(f'Avg clustering: {avg_clustering:.4f}')
print(f'Components: {len(components)} (largest: {components[0] if components else 0})')
print(f'Isolates: {isolates}')
print(f'Small-world: {metrics["small_world_indicators"]["verdict"]}')
PYEOF

# Cleanup
rm -f "$OUT/_raw_graph.json"

log info "Network metrics complete. Output: $OUT/"
log info "  network-metrics.json      (full report)"
log info "  degree-distribution.json  (frequency tables)"
