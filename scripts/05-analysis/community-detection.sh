#!/usr/bin/env bash
# =============================================================================
# community-detection.sh - Algorithmic community detection
# =============================================================================
# Phase 5: Analysis (DeepGraph integration)
#
# Detects communities using label propagation with modularity scoring.
# Computes modularity (Q), identifies inter-community bridges, and
# exports membership for visualization.
#
# Usage:
#   ./community-detection.sh --vault <name> [--min-community <n>] [--output <dir>]
#
# Outputs:
#   output/05-analysis/communities.json          - Full community assignments
#   output/05-analysis/community-report.txt      - Human-readable summary
#
# Requires: python3 (no external deps - pure Python implementation)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

MIN_COMMUNITY=3

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-community) MIN_COMMUNITY="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault
check_python3

OUT=$(ensure_output_dir "05-analysis")

log info "=== Community Detection: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Export graph
# ---------------------------------------------------------------------------
log info "Exporting resolved links..."

LINKS_JSON=$(obs_eval 'JSON.stringify(app.metadataCache.resolvedLinks)')

if [[ -z "$LINKS_JSON" || "$LINKS_JSON" == "null" || "$LINKS_JSON" == "{}" ]]; then
  die "No resolved links found. Is the vault open?"
fi

# ---------------------------------------------------------------------------
# 2. Detect communities via label propagation + modularity
# ---------------------------------------------------------------------------
log info "Running community detection..."

python3 << 'PYEOF' "$LINKS_JSON" "$OUT" "$MIN_COMMUNITY"
import json
import sys
import random
from collections import defaultdict

links_json = sys.argv[1]
out_dir = sys.argv[2]
min_community = int(sys.argv[3])

links = json.loads(links_json)

# ---- Build undirected adjacency ----
adj = defaultdict(set)
all_nodes = set()

for src, targets in links.items():
    src_c = src.replace(".md", "")
    all_nodes.add(src_c)
    for tgt in targets:
        tgt_c = tgt.replace(".md", "")
        all_nodes.add(tgt_c)
        adj[src_c].add(tgt_c)
        adj[tgt_c].add(src_c)

node_list = sorted(all_nodes)
n = len(node_list)
m = sum(len(v) for v in adj.values()) // 2  # undirected edge count

if n == 0:
    print("ERROR: No nodes found", file=sys.stderr)
    sys.exit(1)

# ---- Label Propagation Algorithm ----
# Each node starts with its own label, then iteratively adopts the most
# frequent label among its neighbors. Converges to communities.

labels = {node: i for i, node in enumerate(node_list)}
max_iterations = 50

random.seed(42)
for iteration in range(max_iterations):
    changed = 0
    order = list(node_list)
    random.shuffle(order)

    for node in order:
        neighbors = adj.get(node, set())
        if not neighbors:
            continue

        # Count neighbor labels
        label_counts = defaultdict(int)
        for nb in neighbors:
            label_counts[labels[nb]] += 1

        # Pick most frequent (break ties randomly)
        max_count = max(label_counts.values())
        best_labels = [lbl for lbl, cnt in label_counts.items() if cnt == max_count]
        new_label = random.choice(best_labels)

        if new_label != labels[node]:
            labels[node] = new_label
            changed += 1

    if changed == 0:
        break

# ---- Group nodes by label ----
raw_communities = defaultdict(list)
for node, label in labels.items():
    raw_communities[label].append(node)

# Filter by min size and sort by size descending
communities = {
    f"community_{i}": sorted(members)
    for i, (_, members) in enumerate(
        sorted(raw_communities.items(), key=lambda x: len(x[1]), reverse=True)
    )
    if len(members) >= min_community
}

# Nodes in small clusters go to "unclustered"
clustered_nodes = set()
for members in communities.values():
    clustered_nodes.update(members)
unclustered = sorted(all_nodes - clustered_nodes)

# ---- Compute modularity ----
# Q = (1/2m) * sum_ij [ A_ij - (k_i * k_j) / (2m) ] * delta(c_i, c_j)
if m > 0:
    # Build community assignment map
    node_community = {}
    for cname, members in communities.items():
        for node in members:
            node_community[node] = cname

    degree = {node: len(adj.get(node, set())) for node in node_list}

    Q = 0.0
    for src in node_list:
        for tgt in adj.get(src, set()):
            if node_community.get(src) == node_community.get(tgt) and \
               src in node_community and tgt in node_community:
                Q += 1.0 - (degree[src] * degree[tgt]) / (2.0 * m)
    Q /= (2.0 * m)
else:
    Q = 0.0

# ---- Identify inter-community edges (bridges) ----
bridge_edges = []
bridge_node_counts = defaultdict(int)

for src in node_list:
    src_comm = None
    for cname, members in communities.items():
        if src in members:
            src_comm = cname
            break
    if not src_comm:
        continue

    for tgt in adj.get(src, set()):
        tgt_comm = None
        for cname, members in communities.items():
            if tgt in members:
                tgt_comm = cname
                break
        if tgt_comm and src_comm != tgt_comm:
            if src < tgt:  # avoid duplicates
                bridge_edges.append({"source": src, "target": tgt,
                                     "from_community": src_comm,
                                     "to_community": tgt_comm})
            bridge_node_counts[src] += 1

# Top bridge nodes
top_bridges = sorted(bridge_node_counts.items(), key=lambda x: x[1], reverse=True)[:20]

# ---- Community themes (top folders per community) ----
community_themes = {}
for cname, members in communities.items():
    folder_counts = defaultdict(int)
    for node in members:
        parts = node.split("/")
        if len(parts) > 1:
            folder_counts[parts[0]] += 1
        else:
            folder_counts["(root)"] += 1
    top_folders = sorted(folder_counts.items(), key=lambda x: x[1], reverse=True)[:3]
    community_themes[cname] = [{"folder": f, "count": c} for f, c in top_folders]

# ---- Output ----
result = {
    "total_nodes": n,
    "total_edges": m,
    "communities_found": len(communities),
    "modularity": round(Q, 4),
    "min_community_size": min_community,
    "algorithm": "label_propagation",
    "community_sizes": {cname: len(members) for cname, members in communities.items()},
    "community_themes": community_themes,
    "communities": communities,
    "unclustered_count": len(unclustered),
    "unclustered": unclustered[:50],
    "inter_community_edges": len(bridge_edges),
    "top_bridge_nodes": [{"node": nd, "cross_community_links": cnt} for nd, cnt in top_bridges],
    "sample_bridges": bridge_edges[:30]
}

with open(f"{out_dir}/communities.json", "w") as f:
    json.dump(result, f, indent=2)

# ---- Text report ----
lines = []
lines.append("Community Detection Report")
lines.append("=" * 60)
lines.append(f"Nodes: {n:,}  |  Edges: {m:,}")
lines.append(f"Algorithm: Label Propagation (max 50 iterations)")
lines.append(f"Min community size: {min_community}")
lines.append(f"Modularity (Q): {Q:.4f}")
lines.append(f"  (Q > 0.3 indicates strong community structure)")
lines.append("")
lines.append(f"Communities found: {len(communities)}")
lines.append(f"Unclustered nodes: {len(unclustered)}")
lines.append(f"Inter-community edges: {len(bridge_edges)}")
lines.append("")

lines.append("Community Summary:")
lines.append("-" * 60)
for cname, members in sorted(communities.items(), key=lambda x: len(x[1]), reverse=True):
    themes = community_themes.get(cname, [])
    theme_str = ", ".join(f"{t['folder']}({t['count']})" for t in themes)
    lines.append(f"  {cname}: {len(members):,} nodes  [{theme_str}]")

lines.append("")
lines.append("Top Bridge Nodes (cross-community connectors):")
lines.append("-" * 60)
for nd, cnt in top_bridges:
    lines.append(f"  {nd:<45s}  {cnt} cross-community links")

with open(f"{out_dir}/community-report.txt", "w") as f:
    f.write("\n".join(lines))

print(f"Communities: {len(communities)}, Modularity: {Q:.4f}")
print(f"Largest: {max(len(m) for m in communities.values()) if communities else 0} nodes")
print(f"Inter-community edges: {len(bridge_edges)}")
PYEOF

log info "Community detection complete."
log info "  JSON: $OUT/communities.json"
log info "  Report: $OUT/community-report.txt"
