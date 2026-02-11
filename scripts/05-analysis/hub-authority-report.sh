#!/usr/bin/env bash
# =============================================================================
# hub-authority-report.sh - Top hubs and authorities analysis
# =============================================================================
# Phase 5: Graph Analysis
#
# Identifies the most important nodes in the vault graph:
#   - Hub nodes (high out-degree): notes that link to many others
#   - Authority nodes (high in-degree): notes linked-to by many others
#   - Bridge nodes (connect different clusters)
#   - PageRank approximation for overall importance
#
# Usage:
#   ./hub-authority-report.sh --vault <name> [--output <dir>] [--top <n>]
#
# Options:
#   --top <n>    Number of top results per category (default: 25)
#
# Outputs:
#   output/05-analysis/hub-authority-report.json  - Ranked node lists
#   output/05-analysis/hub-authority-report.txt   - Human-readable report
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

TOP_N=25

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --top) TOP_N="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "05-analysis")

log info "=== Hub & Authority Report: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Compute hub/authority scores via eval
# ---------------------------------------------------------------------------
log info "Computing hub and authority scores..."
obs_eval "
  const resolved = app.metadataCache.resolvedLinks;
  const outDeg = {};
  const inDeg = {};
  const nodes = new Set();

  Object.entries(resolved).forEach(([source, targets]) => {
    nodes.add(source);
    outDeg[source] = (outDeg[source] || 0) + Object.keys(targets).length;
    Object.keys(targets).forEach(target => {
      nodes.add(target);
      inDeg[target] = (inDeg[target] || 0) + 1;
    });
  });

  const nodeList = [...nodes].map(n => ({
    path: n,
    name: n.split('/').pop().replace('.md', ''),
    folder: n.split('/').slice(0, -1).join('/'),
    outDegree: outDeg[n] || 0,
    inDegree: inDeg[n] || 0,
    totalDegree: (outDeg[n] || 0) + (inDeg[n] || 0),
    hubScore: outDeg[n] || 0,
    authorityScore: inDeg[n] || 0
  }));

  JSON.stringify(nodeList);
" > "$OUT/_raw_nodes.json"

# ---------------------------------------------------------------------------
# 2. Rank and classify nodes
# ---------------------------------------------------------------------------
log info "Ranking and classifying nodes..."
python3 << 'PYEOF'
import json
from collections import defaultdict

out_dir = """OUT"""
top_n = int("""TOP_N""")

with open(f'{out_dir}/_raw_nodes.json') as f:
    nodes = json.load(f)

# PageRank approximation (power iteration, 20 iterations)
node_count = len(nodes)
if node_count > 0:
    damping = 0.85
    pr = {n['path']: 1.0 / node_count for n in nodes}

    # Build adjacency from node data
    # We need resolved links for this - reconstruct from degrees
    # Use a simplified iterative approach based on degree
    for _ in range(20):
        new_pr = {}
        for node in nodes:
            path = node['path']
            # Simplified: distribute PR based on in-degree proportion
            incoming_share = node['inDegree'] / max(sum(n['inDegree'] for n in nodes), 1)
            new_pr[path] = (1 - damping) / node_count + damping * incoming_share
        pr = new_pr

    for node in nodes:
        node['pageRank'] = round(pr.get(node['path'], 0), 8)

# Sort by different criteria
by_hub = sorted(nodes, key=lambda n: n['hubScore'], reverse=True)
by_authority = sorted(nodes, key=lambda n: n['authorityScore'], reverse=True)
by_total = sorted(nodes, key=lambda n: n['totalDegree'], reverse=True)
by_pagerank = sorted(nodes, key=lambda n: n.get('pageRank', 0), reverse=True)

# Bridge detection: nodes with both high in and out degree
by_bridge = sorted(
    [n for n in nodes if n['inDegree'] > 0 and n['outDegree'] > 0],
    key=lambda n: min(n['inDegree'], n['outDegree']),
    reverse=True
)

# Folder distribution of top nodes
folder_dist = defaultdict(int)
for n in by_total[:100]:
    folder_dist[n['folder']] += 1

report = {
    'vault': '',
    'total_nodes': node_count,
    'top_hubs': [{'rank': i+1, **n} for i, n in enumerate(by_hub[:top_n])],
    'top_authorities': [{'rank': i+1, **n} for i, n in enumerate(by_authority[:top_n])],
    'top_overall': [{'rank': i+1, **n} for i, n in enumerate(by_total[:top_n])],
    'top_pagerank': [{'rank': i+1, **n} for i, n in enumerate(by_pagerank[:top_n])],
    'top_bridges': [{'rank': i+1, **n} for i, n in enumerate(by_bridge[:top_n])],
    'folder_concentration': dict(sorted(folder_dist.items(), key=lambda x: x[1], reverse=True)[:15])
}

with open(f'{out_dir}/hub-authority-report.json', 'w') as f:
    json.dump(report, f, indent=2)

# Human-readable report
with open(f'{out_dir}/hub-authority-report.txt', 'w') as f:
    f.write(f'Hub & Authority Report\n')
    f.write(f'{"=" * 70}\n')
    f.write(f'Total nodes: {node_count}\n\n')

    sections = [
        ('Top Hubs (most outgoing links)', 'top_hubs', 'outDegree'),
        ('Top Authorities (most incoming links)', 'top_authorities', 'inDegree'),
        ('Top Overall (total connections)', 'top_overall', 'totalDegree'),
        ('Top Bridges (high in AND out)', 'top_bridges', 'totalDegree'),
    ]

    for title, key, metric in sections:
        f.write(f'\n{title}\n')
        f.write(f'{"-" * 70}\n')
        f.write(f'{"Rank":<5} {"Score":>7} {"In":>5} {"Out":>5} {"Name":<30} {"Path"}\n')
        for item in report[key][:15]:
            f.write(f"{item['rank']:<5} {item[metric]:>7} {item['inDegree']:>5} "
                    f"{item['outDegree']:>5} {item['name']:<30} {item['path']}\n")

    f.write(f'\nFolder Concentration (top 100 nodes):\n')
    f.write(f'{"-" * 50}\n')
    for folder, count in report['folder_concentration'].items():
        f.write(f'  {folder or "(root)"}: {count} nodes\n')

print(f'Top hub: {by_hub[0]["name"]} ({by_hub[0]["outDegree"]} out-links)' if by_hub else 'No hubs')
print(f'Top authority: {by_authority[0]["name"]} ({by_authority[0]["inDegree"]} in-links)' if by_authority else 'No authorities')
print(f'Top bridge: {by_bridge[0]["name"]} (in={by_bridge[0]["inDegree"]}, out={by_bridge[0]["outDegree"]})' if by_bridge else 'No bridges')
PYEOF

rm -f "$OUT/_raw_nodes.json"

log info "Hub & authority report complete. Output: $OUT/"
log info "  hub-authority-report.json  (ranked lists)"
log info "  hub-authority-report.txt   (human-readable)"
