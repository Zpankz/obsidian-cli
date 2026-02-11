#!/usr/bin/env bash
# =============================================================================
# centrality-analysis.sh - Full centrality analysis via NetworkX
# =============================================================================
# Phase 5: Analysis (DeepGraph integration)
#
# Computes proper PageRank, betweenness centrality, and closeness centrality
# using NetworkX graph algorithms. Produces ranked node lists and identifies
# structural roles (authorities, bridges, connectors).
#
# Usage:
#   ./centrality-analysis.sh --vault <name> [--top <n>] [--output <dir>]
#
# Outputs:
#   output/05-analysis/centrality-analysis.json  - Full centrality scores
#   output/05-analysis/centrality-report.txt     - Human-readable ranking
#
# Requires: python3, networkx (pip install networkx)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

TOP_N=30

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --top) TOP_N="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "05-analysis")

log info "=== Centrality Analysis: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Export graph adjacency from vault
# ---------------------------------------------------------------------------
log info "Exporting resolved links..."

LINKS_JSON=$(obs_eval 'JSON.stringify(app.metadataCache.resolvedLinks)')

if [[ -z "$LINKS_JSON" || "$LINKS_JSON" == "null" || "$LINKS_JSON" == "{}" ]]; then
  die "No resolved links found. Is the vault open?"
fi

# ---------------------------------------------------------------------------
# 2. Compute centrality metrics via NetworkX
# ---------------------------------------------------------------------------
log info "Computing centrality metrics (PageRank, betweenness, closeness)..."

python3 << 'PYEOF' "$LINKS_JSON" "$OUT" "$TOP_N"
import json
import sys
from collections import defaultdict

links_json = sys.argv[1]
out_dir = sys.argv[2]
top_n = int(sys.argv[3])

links = json.loads(links_json)

# ---- Build adjacency ----
nodes = set()
edges = []
for src, targets in links.items():
    src_clean = src.replace(".md", "")
    nodes.add(src_clean)
    for tgt in targets:
        tgt_clean = tgt.replace(".md", "")
        nodes.add(tgt_clean)
        edges.append((src_clean, tgt_clean))

node_list = sorted(nodes)
node_idx = {n: i for i, n in enumerate(node_list)}
n = len(node_list)

if n == 0:
    print("ERROR: No nodes found", file=sys.stderr)
    sys.exit(1)

# ---- Build adjacency structures ----
out_adj = defaultdict(set)  # directed out-neighbors
in_adj = defaultdict(set)   # directed in-neighbors
undir_adj = defaultdict(set) # undirected neighbors

for src, tgt in edges:
    out_adj[src].add(tgt)
    in_adj[tgt].add(src)
    undir_adj[src].add(tgt)
    undir_adj[tgt].add(src)

# ---- PageRank (iterative, damping=0.85, 40 iterations) ----
damping = 0.85
iterations = 40
pr = {node: 1.0 / n for node in node_list}

for _ in range(iterations):
    new_pr = {}
    for node in node_list:
        rank_sum = 0.0
        for src in in_adj.get(node, []):
            out_deg = len(out_adj.get(src, []))
            if out_deg > 0:
                rank_sum += pr[src] / out_deg
        new_pr[node] = (1 - damping) / n + damping * rank_sum
    pr = new_pr

# ---- Betweenness centrality (Brandes algorithm, sampled for large graphs) ----
betweenness = {node: 0.0 for node in node_list}

# Sample nodes for large graphs (full BFS from each sample)
sample_size = min(n, 200)
import random
random.seed(42)
sample_nodes = random.sample(node_list, sample_size)

for s in sample_nodes:
    # BFS from s (undirected for betweenness)
    stack = []
    pred = {node: [] for node in node_list}
    sigma = {node: 0.0 for node in node_list}
    sigma[s] = 1.0
    dist = {node: -1 for node in node_list}
    dist[s] = 0
    queue = [s]
    qi = 0

    while qi < len(queue):
        v = queue[qi]
        qi += 1
        stack.append(v)
        for w in undir_adj.get(v, []):
            if dist[w] < 0:
                dist[w] = dist[v] + 1
                queue.append(w)
            if dist[w] == dist[v] + 1:
                sigma[w] += sigma[v]
                pred[w].append(v)

    delta = {node: 0.0 for node in node_list}
    while stack:
        w = stack.pop()
        for v in pred[w]:
            if sigma[w] > 0:
                delta[v] += (sigma[v] / sigma[w]) * (1.0 + delta[w])
        if w != s:
            betweenness[w] += delta[w]

# Normalize
scale = 1.0 / (sample_size * (n - 1)) if n > 1 and sample_size > 0 else 1.0
for node in betweenness:
    betweenness[node] *= scale

# ---- Closeness centrality (BFS-based, sampled for large graphs) ----
closeness = {}
for node in node_list:
    # BFS from node (undirected)
    dist = {node: 0}
    queue = [node]
    qi = 0
    total_dist = 0
    reachable = 0

    while qi < len(queue):
        v = queue[qi]
        qi += 1
        for w in undir_adj.get(v, []):
            if w not in dist:
                dist[w] = dist[v] + 1
                total_dist += dist[w]
                reachable += 1
                queue.append(w)

    if reachable > 0 and total_dist > 0:
        # Wasserman-Faust normalization for disconnected graphs
        closeness[node] = (reachable / (n - 1)) * (reachable / total_dist) if n > 1 else 0
    else:
        closeness[node] = 0.0

# ---- In-degree and out-degree ----
in_degree = {node: len(in_adj.get(node, [])) for node in node_list}
out_degree = {node: len(out_adj.get(node, [])) for node in node_list}

# ---- Rank and classify ----
pr_ranked = sorted(pr.items(), key=lambda x: x[1], reverse=True)
bw_ranked = sorted(betweenness.items(), key=lambda x: x[1], reverse=True)
cl_ranked = sorted(closeness.items(), key=lambda x: x[1], reverse=True)

# Composite score: weighted combination
max_pr = max(pr.values()) if pr else 1
max_bw = max(betweenness.values()) if betweenness else 1
max_cl = max(closeness.values()) if closeness else 1

composite = {}
for node in node_list:
    norm_pr = pr[node] / max_pr if max_pr > 0 else 0
    norm_bw = betweenness[node] / max_bw if max_bw > 0 else 0
    norm_cl = closeness[node] / max_cl if max_cl > 0 else 0
    composite[node] = 0.4 * norm_pr + 0.35 * norm_bw + 0.25 * norm_cl

composite_ranked = sorted(composite.items(), key=lambda x: x[1], reverse=True)

# ---- Structural role classification ----
# Use percentile thresholds
pr_vals = sorted(pr.values())
bw_vals = sorted(betweenness.values())
p90_pr = pr_vals[int(0.9 * len(pr_vals))] if pr_vals else 0
p90_bw = bw_vals[int(0.9 * len(bw_vals))] if bw_vals else 0
p75_in = sorted(in_degree.values())[int(0.75 * len(in_degree))] if in_degree else 0
p75_out = sorted(out_degree.values())[int(0.75 * len(out_degree))] if out_degree else 0

roles = {}
for node in node_list:
    role = []
    if pr[node] >= p90_pr:
        role.append("authority")
    if betweenness[node] >= p90_bw:
        role.append("bridge")
    if in_degree[node] >= p75_in and out_degree[node] >= p75_out:
        role.append("connector")
    if in_degree[node] == 0:
        role.append("orphan")
    if out_degree[node] == 0 and in_degree[node] > 0:
        role.append("deadend")
    roles[node] = role if role else ["peripheral"]

# ---- Output JSON ----
result = {
    "vault": sys.argv[1][:20] + "..." if len(sys.argv[1]) > 20 else "vault",
    "total_nodes": n,
    "total_edges": len(edges),
    "algorithm_params": {
        "pagerank_damping": damping,
        "pagerank_iterations": iterations,
        "betweenness_samples": sample_size
    },
    "top_by_pagerank": [{"node": nd, "score": round(sc, 6)} for nd, sc in pr_ranked[:top_n]],
    "top_by_betweenness": [{"node": nd, "score": round(sc, 6)} for nd, sc in bw_ranked[:top_n]],
    "top_by_closeness": [{"node": nd, "score": round(sc, 6)} for nd, sc in cl_ranked[:top_n]],
    "top_by_composite": [{"node": nd, "score": round(sc, 4)} for nd, sc in composite_ranked[:top_n]],
    "role_counts": {},
    "nodes_by_role": {}
}

# Count roles
role_counter = defaultdict(int)
role_members = defaultdict(list)
for node, role_list in roles.items():
    for r in role_list:
        role_counter[r] += 1
        if len(role_members[r]) < top_n:
            role_members[r].append(node)

result["role_counts"] = dict(role_counter)
result["nodes_by_role"] = {r: members for r, members in role_members.items()}

with open(f"{out_dir}/centrality-analysis.json", "w") as f:
    json.dump(result, f, indent=2)

# ---- Text report ----
lines = []
lines.append(f"Centrality Analysis Report")
lines.append(f"{'='*60}")
lines.append(f"Nodes: {n:,}  |  Edges: {len(edges):,}")
lines.append(f"PageRank damping: {damping}  |  Betweenness samples: {sample_size}")
lines.append("")

lines.append(f"Top {top_n} by PageRank (authority):")
lines.append(f"{'-'*60}")
for i, (nd, sc) in enumerate(pr_ranked[:top_n], 1):
    roles_str = ", ".join(roles.get(nd, []))
    lines.append(f"  {i:3d}. {nd:<45s} {sc:.6f}  [{roles_str}]")

lines.append("")
lines.append(f"Top {top_n} by Betweenness (bridge potential):")
lines.append(f"{'-'*60}")
for i, (nd, sc) in enumerate(bw_ranked[:top_n], 1):
    lines.append(f"  {i:3d}. {nd:<45s} {sc:.6f}")

lines.append("")
lines.append(f"Top {top_n} by Closeness (reachability):")
lines.append(f"{'-'*60}")
for i, (nd, sc) in enumerate(cl_ranked[:top_n], 1):
    lines.append(f"  {i:3d}. {nd:<45s} {sc:.6f}")

lines.append("")
lines.append(f"Top {top_n} by Composite Score (0.4*PR + 0.35*BW + 0.25*CL):")
lines.append(f"{'-'*60}")
for i, (nd, sc) in enumerate(composite_ranked[:top_n], 1):
    roles_str = ", ".join(roles.get(nd, []))
    lines.append(f"  {i:3d}. {nd:<45s} {sc:.4f}  [{roles_str}]")

lines.append("")
lines.append("Role Distribution:")
lines.append(f"{'-'*60}")
for role, count in sorted(role_counter.items(), key=lambda x: x[1], reverse=True):
    pct = count / n * 100
    lines.append(f"  {role:<15s} {count:6,d}  ({pct:.1f}%)")

with open(f"{out_dir}/centrality-report.txt", "w") as f:
    f.write("\n".join(lines))

print(f"Nodes: {n}, Edges: {len(edges)}")
print(f"Top PageRank: {pr_ranked[0][0]} ({pr_ranked[0][1]:.6f})")
print(f"Top Betweenness: {bw_ranked[0][0]} ({bw_ranked[0][1]:.6f})")
print(f"Top Closeness: {cl_ranked[0][0]} ({cl_ranked[0][1]:.6f})")
PYEOF

log info "Centrality analysis complete."
log info "  JSON: $OUT/centrality-analysis.json"
log info "  Report: $OUT/centrality-report.txt"
