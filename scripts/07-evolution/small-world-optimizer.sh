#!/usr/bin/env bash
# =============================================================================
# small-world-optimizer.sh - Watts-Strogatz rewiring for small-world properties
# =============================================================================
# Phase 7: Graph Evolution
#
# Implements the Watts-Strogatz small-world network optimization:
#   1. Analyzes current graph clustering and path lengths
#   2. Identifies candidates for "shortcut" links (cross-cluster connections)
#   3. Generates rewiring suggestions based on:
#      - Shared tags across distant clusters
#      - Folder boundary crossings
#      - Bridge potential (connects otherwise disconnected regions)
#   4. Optionally injects shortcut links
#
# References:
#   - Watts-Strogatz Model: https://en.wikipedia.org/wiki/Watts%E2%80%93Strogatz_model
#   - research/05-automation-patterns.md Section 4
#
# Usage:
#   ./small-world-optimizer.sh --vault <name> [--output <dir>]
#                              [--beta <0.0-1.0>] [--max-shortcuts <n>]
#                              [--auto-link] [--dry-run]
#
# Options:
#   --beta <float>         Rewiring probability (default: 0.1)
#   --max-shortcuts <n>    Maximum shortcuts to generate (default: 50)
#   --auto-link            Automatically inject shortcut links
#
# Outputs:
#   output/07-evolution/small-world-analysis.json   - Current graph analysis
#   output/07-evolution/shortcut-suggestions.json   - Suggested shortcuts
#   output/07-evolution/shortcut-link-map.json      - Ready for link-injector.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

BETA=0.1
MAX_SHORTCUTS=50
AUTO_LINK=false

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --beta)          BETA="$2";         shift 2 ;;
    --max-shortcuts) MAX_SHORTCUTS="$2"; shift 2 ;;
    --auto-link)     AUTO_LINK=true;    shift ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "07-evolution")

log info "=== Small-World Optimizer: $VAULT ==="
log info "Beta (rewiring probability): $BETA"
log info "Max shortcuts: $MAX_SHORTCUTS"

# ---------------------------------------------------------------------------
# 1. Export graph with cluster context
# ---------------------------------------------------------------------------
log info "Exporting graph with cluster context..."
obs_eval "
  const resolved = app.metadataCache.resolvedLinks;
  const files = app.vault.getMarkdownFiles();

  const nodeData = {};
  files.forEach(f => {
    const cache = app.metadataCache.getCache(f.path);
    nodeData[f.path] = {
      folder: f.path.split('/').slice(0, -1).join('/'),
      topFolder: f.path.split('/')[0] || '',
      tags: cache?.tags?.map(t => t.tag) || [],
      outLinks: Object.keys(resolved[f.path] || {}),
      name: f.name.replace('.md', '')
    };
  });

  // Build in-degree
  const inDeg = {};
  Object.entries(resolved).forEach(([src, targets]) => {
    Object.keys(targets).forEach(t => { inDeg[t] = (inDeg[t] || 0) + 1; });
  });

  Object.keys(nodeData).forEach(path => {
    nodeData[path].inDegree = inDeg[path] || 0;
    nodeData[path].outDegree = nodeData[path].outLinks.length;
  });

  JSON.stringify(nodeData);
" > "$OUT/_graph_context.json"

# ---------------------------------------------------------------------------
# 2. Compute small-world metrics and generate shortcuts
# ---------------------------------------------------------------------------
log info "Computing small-world metrics and generating shortcuts..."
python3 << 'PYEOF'
import json
import random
import math
from collections import defaultdict, deque

out_dir = """OUT"""
beta = float("""BETA""")
max_shortcuts = int("""MAX_SHORTCUTS""")

with open(f'{out_dir}/_graph_context.json') as f:
    nodes = json.load(f)

node_list = list(nodes.keys())
node_count = len(node_list)

# Build undirected adjacency for clustering analysis
undirected = defaultdict(set)
for path, data in nodes.items():
    for target in data['outLinks']:
        if target in nodes:
            undirected[path].add(target)
            undirected[target].add(path)

# Compute local clustering coefficient (sampled)
sample_size = min(500, node_count)
sample = random.sample(node_list, sample_size) if node_count > 0 else []

clustering_coeffs = {}
for node in sample:
    neighbors = list(undirected.get(node, set()))
    k = len(neighbors)
    if k < 2:
        clustering_coeffs[node] = 0.0
        continue
    triangles = 0
    for i in range(len(neighbors)):
        for j in range(i + 1, len(neighbors)):
            if neighbors[j] in undirected.get(neighbors[i], set()):
                triangles += 1
    clustering_coeffs[node] = triangles / (k * (k - 1) / 2)

avg_clustering = sum(clustering_coeffs.values()) / len(clustering_coeffs) if clustering_coeffs else 0

# Approximate average path length (BFS from sample nodes)
path_sample_size = min(50, node_count)
path_sample = random.sample(node_list, path_sample_size) if node_count > 0 else []
total_distances = 0
total_pairs = 0

for start in path_sample:
    visited = {start: 0}
    queue = deque([start])
    while queue:
        current = queue.popleft()
        for neighbor in undirected.get(current, set()):
            if neighbor not in visited:
                visited[neighbor] = visited[current] + 1
                queue.append(neighbor)
    for dist in visited.values():
        if dist > 0:
            total_distances += dist
            total_pairs += 1

avg_path_length = total_distances / total_pairs if total_pairs > 0 else float('inf')

# Identify cluster boundaries (by top-level folder)
folder_clusters = defaultdict(list)
for path, data in nodes.items():
    folder_clusters[data['topFolder']].append(path)

# Watts-Strogatz shortcut generation
# Find pairs of nodes in DIFFERENT clusters that share tags
tag_index = defaultdict(set)
for path, data in nodes.items():
    for tag in data['tags']:
        tag_index[tag].add(path)

shortcuts = []
seen_pairs = set()

# Strategy 1: Cross-cluster tag-based shortcuts
for tag, members in tag_index.items():
    member_list = list(members)
    for i in range(len(member_list)):
        if len(shortcuts) >= max_shortcuts * 2:
            break
        for j in range(i + 1, min(i + 10, len(member_list))):
            a, b = member_list[i], member_list[j]
            if a not in nodes or b not in nodes:
                continue
            # Must be in different clusters
            if nodes[a]['topFolder'] == nodes[b]['topFolder']:
                continue
            # Must not already be connected
            if b in undirected.get(a, set()):
                continue
            pair_key = tuple(sorted([a, b]))
            if pair_key in seen_pairs:
                continue
            seen_pairs.add(pair_key)

            # Apply beta probability
            if random.random() > beta:
                continue

            shortcuts.append({
                'source': a,
                'source_name': nodes[a]['name'],
                'target': b,
                'target_name': nodes[b]['name'],
                'shared_tag': tag,
                'source_cluster': nodes[a]['topFolder'],
                'target_cluster': nodes[b]['topFolder'],
                'reason': f'cross_cluster_shared_tag:{tag}',
                'score': 2 + min(nodes[b].get('inDegree', 0) / 10, 3)
            })

# Strategy 2: Bridge potential (connect low-connectivity clusters)
cluster_sizes = {k: len(v) for k, v in folder_clusters.items()}
small_clusters = [k for k, v in cluster_sizes.items() if v < node_count * 0.05 and v > 1]

for cluster in small_clusters[:10]:
    if len(shortcuts) >= max_shortcuts * 2:
        break
    cluster_nodes = folder_clusters[cluster]
    # Find a hub in a large cluster to connect to
    large_clusters = [k for k, v in cluster_sizes.items() if v > node_count * 0.1]
    for lc in large_clusters[:3]:
        lc_nodes = folder_clusters[lc]
        # Pick highest in-degree node from large cluster
        best_target = max(lc_nodes, key=lambda n: nodes[n].get('inDegree', 0))
        # Pick random node from small cluster
        source = random.choice(cluster_nodes)
        pair_key = tuple(sorted([source, best_target]))
        if pair_key not in seen_pairs and best_target not in undirected.get(source, set()):
            seen_pairs.add(pair_key)
            shortcuts.append({
                'source': source,
                'source_name': nodes[source]['name'],
                'target': best_target,
                'target_name': nodes[best_target]['name'],
                'shared_tag': '',
                'source_cluster': cluster,
                'target_cluster': lc,
                'reason': 'bridge_small_to_large_cluster',
                'score': 5
            })

# Sort by score and limit
shortcuts.sort(key=lambda x: x['score'], reverse=True)
shortcuts = shortcuts[:max_shortcuts]

# Post-optimization metrics estimate
estimated_new_clustering = avg_clustering * 0.95  # shortcuts slightly reduce local clustering
estimated_new_path = avg_path_length * (1 - 0.1 * len(shortcuts) / max(node_count, 1))

# Small-world coefficient: sigma = (C/C_random) / (L/L_random)
# C_random ~ k/n, L_random ~ ln(n)/ln(k) for random graphs
avg_degree = sum(len(undirected.get(n, set())) for n in node_list) / max(node_count, 1)
c_random = avg_degree / max(node_count, 1)
l_random = math.log(max(node_count, 1)) / math.log(max(avg_degree, 2)) if avg_degree > 1 else float('inf')
sigma = (avg_clustering / max(c_random, 1e-10)) / (avg_path_length / max(l_random, 1e-10)) if c_random > 0 and l_random > 0 else 0

analysis = {
    'vault_nodes': node_count,
    'beta': beta,
    'avg_clustering_coefficient': round(avg_clustering, 4),
    'avg_path_length': round(avg_path_length, 2),
    'avg_degree': round(avg_degree, 2),
    'small_world_sigma': round(sigma, 3),
    'is_small_world': sigma > 1.0,
    'cluster_count': len(folder_clusters),
    'cluster_sizes': {k: len(v) for k, v in sorted(folder_clusters.items(), key=lambda x: len(x[1]), reverse=True)[:15]},
    'shortcuts_generated': len(shortcuts),
    'estimated_post_optimization': {
        'clustering': round(estimated_new_clustering, 4),
        'path_length': round(estimated_new_path, 2)
    }
}

with open(f'{out_dir}/small-world-analysis.json', 'w') as f:
    json.dump(analysis, f, indent=2)

with open(f'{out_dir}/shortcut-suggestions.json', 'w') as f:
    json.dump(shortcuts, f, indent=2)

# Build link map for link-injector
link_map = defaultdict(list)
for sc in shortcuts:
    link_map[sc['source']].append(sc['target_name'])
    # Bidirectional shortcut
    link_map[sc['target']].append(sc['source_name'])

with open(f'{out_dir}/shortcut-link-map.json', 'w') as f:
    json.dump(dict(link_map), f, indent=2)

print(f'Small-world sigma: {sigma:.3f} ({"yes" if sigma > 1.0 else "no"})')
print(f'Avg clustering: {avg_clustering:.4f}')
print(f'Avg path length: {avg_path_length:.2f}')
print(f'Shortcuts generated: {len(shortcuts)}')
print(f'Clusters: {len(folder_clusters)}')
PYEOF

# ---------------------------------------------------------------------------
# 3. Auto-link if requested
# ---------------------------------------------------------------------------
if [[ "$AUTO_LINK" == "true" ]]; then
  log info "Auto-linking shortcuts..."
  "$SCRIPT_DIR/../04-graph-construction/link-injector.sh" \
    --vault "$VAULT" \
    --input "$OUT/shortcut-link-map.json" \
    --strategy append \
    --section "Shortcuts" \
    --output "$OUTPUT_DIR"
  log info "Shortcut injection complete."
else
  log info "To inject shortcuts, re-run with --auto-link"
  log info "Or use: link-injector.sh --input $OUT/shortcut-link-map.json"
fi

rm -f "$OUT/_graph_context.json"

log info "Small-world optimization complete. Output: $OUT/"
log info "  small-world-analysis.json   (metrics & analysis)"
log info "  shortcut-suggestions.json   (suggested shortcuts)"
log info "  shortcut-link-map.json      (ready for link-injector)"
