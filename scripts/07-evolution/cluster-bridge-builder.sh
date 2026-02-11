#!/usr/bin/env bash
# =============================================================================
# cluster-bridge-builder.sh - Add cross-cluster shortcut links
# =============================================================================
# Phase 7: Graph Evolution
#
# Creates bridge notes that connect different knowledge clusters:
#   1. Identifies distinct clusters (by folder structure or community detection)
#   2. Finds common themes across clusters (shared tags, properties)
#   3. Creates "Map of Content" (MOC) bridge notes linking clusters
#   4. Adds cross-references between cluster hub nodes
#
# Usage:
#   ./cluster-bridge-builder.sh --vault <name> [--output <dir>]
#                               [--min-cluster-size <n>] [--auto-create]
#
# Options:
#   --min-cluster-size <n>  Minimum cluster size to consider (default: 5)
#   --auto-create           Automatically create bridge notes
#
# Outputs:
#   output/07-evolution/cluster-analysis.json     - Cluster identification
#   output/07-evolution/bridge-proposals.json      - Proposed bridge notes
#   output/07-evolution/bridge-notes-input.json    - Ready for batch-note-creator
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

MIN_CLUSTER=5
AUTO_CREATE=false

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-cluster-size) MIN_CLUSTER="$2";   shift 2 ;;
    --auto-create)      AUTO_CREATE=true;   shift ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "07-evolution")

log info "=== Cluster Bridge Builder: $VAULT ==="
log info "Min cluster size: $MIN_CLUSTER"

# ---------------------------------------------------------------------------
# 1. Export cluster context
# ---------------------------------------------------------------------------
log info "Analyzing cluster structure..."
obs_eval "
  const resolved = app.metadataCache.resolvedLinks;
  const files = app.vault.getMarkdownFiles();

  const nodeData = {};
  const inDeg = {};

  Object.entries(resolved).forEach(([src, targets]) => {
    Object.keys(targets).forEach(t => { inDeg[t] = (inDeg[t] || 0) + 1; });
  });

  files.forEach(f => {
    const cache = app.metadataCache.getCache(f.path);
    const tags = cache?.tags?.map(t => t.tag) || [];
    const fm = cache?.frontmatter || {};
    delete fm.position;
    nodeData[f.path] = {
      name: f.name.replace('.md', ''),
      folder: f.path.split('/').slice(0, -1).join('/'),
      topFolder: f.path.split('/')[0] || '',
      tags,
      outLinks: Object.keys(resolved[f.path] || {}),
      inDegree: inDeg[f.path] || 0,
      outDegree: Object.keys(resolved[f.path] || {}).length,
      propertyKeys: Object.keys(fm)
    };
  });

  JSON.stringify(nodeData);
" > "$OUT/_cluster_context.json"

# ---------------------------------------------------------------------------
# 2. Identify clusters and generate bridge proposals
# ---------------------------------------------------------------------------
log info "Identifying clusters and generating bridge proposals..."
python3 << 'PYEOF'
import json
from collections import defaultdict

out_dir = """OUT"""
min_cluster = int("""MIN_CLUSTER""")

with open(f'{out_dir}/_cluster_context.json') as f:
    nodes = json.load(f)

# Identify clusters by folder structure (2-level)
clusters = defaultdict(list)
for path, data in nodes.items():
    folder = data.get('folder', '')
    top = data.get('topFolder', '')
    # Use top-level folder as primary cluster
    if top:
        clusters[top].append(path)

# Filter by minimum size
clusters = {k: v for k, v in clusters.items() if len(v) >= min_cluster}

# Analyze each cluster
cluster_analysis = []
for cluster_name, members in sorted(clusters.items(), key=lambda x: len(x[1]), reverse=True):
    # Find hub (highest in-degree in cluster)
    hub = max(members, key=lambda p: nodes[p].get('inDegree', 0))

    # Collect tags across cluster
    tag_counts = defaultdict(int)
    for m in members:
        for tag in nodes[m].get('tags', []):
            tag_counts[tag] += 1

    # Find cross-cluster links
    outbound_clusters = defaultdict(int)
    for m in members:
        for link in nodes[m].get('outLinks', []):
            if link in nodes:
                target_cluster = nodes[link].get('topFolder', '')
                if target_cluster and target_cluster != cluster_name:
                    outbound_clusters[target_cluster] += 1

    cluster_analysis.append({
        'name': cluster_name,
        'size': len(members),
        'hub_node': hub,
        'hub_name': nodes[hub]['name'],
        'hub_in_degree': nodes[hub]['inDegree'],
        'top_tags': dict(sorted(tag_counts.items(), key=lambda x: x[1], reverse=True)[:10]),
        'outbound_connections': dict(sorted(outbound_clusters.items(), key=lambda x: x[1], reverse=True)[:10]),
        'connectivity_pct': round(sum(outbound_clusters.values()) / max(len(members), 1) * 100, 1)
    })

# Find cluster pairs that share tags but have few connections
bridge_proposals = []
cluster_names = [c['name'] for c in cluster_analysis]

for i, c1 in enumerate(cluster_analysis):
    for c2 in cluster_analysis[i+1:]:
        # Find shared tags
        shared_tags = set(c1['top_tags'].keys()) & set(c2['top_tags'].keys())
        if not shared_tags:
            continue

        # Check if they have direct connections
        direct_connections = c1.get('outbound_connections', {}).get(c2['name'], 0) + \
                           c2.get('outbound_connections', {}).get(c1['name'], 0)

        connectivity_ratio = direct_connections / max(min(c1['size'], c2['size']), 1)

        # Propose bridge if connectivity is low but shared interest is high
        if connectivity_ratio < 0.1 and len(shared_tags) >= 1:
            bridge_name = f"Bridge--{c1['name']}--{c2['name']}"
            shared_tag_str = ', '.join(list(shared_tags)[:5])

            # Find best nodes to link from each cluster (high-degree + shared tags)
            c1_members = clusters[c1['name']]
            c2_members = clusters[c2['name']]

            c1_best = sorted(
                [p for p in c1_members if set(nodes[p].get('tags', [])) & shared_tags],
                key=lambda p: nodes[p].get('inDegree', 0), reverse=True
            )[:5]

            c2_best = sorted(
                [p for p in c2_members if set(nodes[p].get('tags', [])) & shared_tags],
                key=lambda p: nodes[p].get('inDegree', 0), reverse=True
            )[:5]

            bridge_proposals.append({
                'bridge_name': bridge_name,
                'cluster_a': c1['name'],
                'cluster_a_size': c1['size'],
                'cluster_b': c2['name'],
                'cluster_b_size': c2['size'],
                'shared_tags': list(shared_tags),
                'direct_connections': direct_connections,
                'connectivity_ratio': round(connectivity_ratio, 3),
                'recommended_links_a': [nodes[p]['name'] for p in c1_best],
                'recommended_links_b': [nodes[p]['name'] for p in c2_best],
                'score': len(shared_tags) * 2 + (1 - connectivity_ratio) * 5
            })

bridge_proposals.sort(key=lambda x: x['score'], reverse=True)
bridge_proposals = bridge_proposals[:20]

# Generate batch-note-creator input for bridges
bridge_notes_input = []
for bp in bridge_proposals:
    links_a = '\n'.join(f'- [[{name}]]' for name in bp['recommended_links_a'])
    links_b = '\n'.join(f'- [[{name}]]' for name in bp['recommended_links_b'])
    tags_str = ' '.join(bp['shared_tags'][:3])

    content = f"# {bp['bridge_name']}\n\n"
    content += f"Bridge connecting **{bp['cluster_a']}** and **{bp['cluster_b']}**.\n\n"
    content += f"Shared themes: {tags_str}\n\n"
    content += f"## From {bp['cluster_a']}\n\n{links_a}\n\n"
    content += f"## From {bp['cluster_b']}\n\n{links_b}\n"

    bridge_notes_input.append({
        'name': bp['bridge_name'],
        'content': content,
        'properties': {
            'type': 'bridge',
            'clusters': f"{bp['cluster_a']},{bp['cluster_b']}",
            'shared_tags': ','.join(bp['shared_tags'][:5])
        }
    })

# Save outputs
output = {
    'total_clusters': len(cluster_analysis),
    'min_cluster_size': min_cluster,
    'cluster_analysis': cluster_analysis,
}
with open(f'{out_dir}/cluster-analysis.json', 'w') as f:
    json.dump(output, f, indent=2)

with open(f'{out_dir}/bridge-proposals.json', 'w') as f:
    json.dump(bridge_proposals, f, indent=2)

with open(f'{out_dir}/bridge-notes-input.json', 'w') as f:
    json.dump(bridge_notes_input, f, indent=2)

print(f'Clusters identified: {len(cluster_analysis)}')
print(f'Bridge proposals: {len(bridge_proposals)}')
for bp in bridge_proposals[:5]:
    print(f"  {bp['cluster_a']} <-> {bp['cluster_b']} "
          f"(shared: {len(bp['shared_tags'])} tags, connectivity: {bp['connectivity_ratio']:.3f})")
PYEOF

# ---------------------------------------------------------------------------
# 3. Auto-create bridges if requested
# ---------------------------------------------------------------------------
if [[ "$AUTO_CREATE" == "true" ]]; then
  log info "Auto-creating bridge notes..."
  "$SCRIPT_DIR/../04-graph-construction/batch-note-creator.sh" \
    --vault "$VAULT" \
    --input "$OUT/bridge-notes-input.json" \
    --path "_bridges" \
    --output "$OUTPUT_DIR"
  log info "Bridge creation complete."
else
  log info "To auto-create bridges, re-run with --auto-create"
  log info "Or use: batch-note-creator.sh --input $OUT/bridge-notes-input.json --path _bridges"
fi

rm -f "$OUT/_cluster_context.json"

log info "Cluster bridge builder complete. Output: $OUT/"
log info "  cluster-analysis.json     (cluster identification)"
log info "  bridge-proposals.json     (bridge proposals)"
log info "  bridge-notes-input.json   (ready for batch-note-creator)"
