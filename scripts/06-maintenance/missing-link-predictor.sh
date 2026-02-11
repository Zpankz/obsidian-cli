#!/usr/bin/env bash
# =============================================================================
# missing-link-predictor.sh - Predict missing links via graph structure
# =============================================================================
# Phase 6: Maintenance (DeepGraph integration)
#
# Uses common-neighbor and Jaccard-coefficient heuristics to predict links
# that "should" exist based on the graph's structural patterns. If nodes A
# and B share many neighbors but aren't directly linked, a link is likely
# missing.
#
# Usage:
#   ./missing-link-predictor.sh --vault <name> [--threshold <n>]
#                               [--max-predictions <n>] [--output <dir>]
#
# Options:
#   --threshold <n>        Minimum common neighbors to predict (default: 3)
#   --max-predictions <n>  Maximum predictions to output (default: 100)
#   --auto-link            Generate link-map for link-injector.sh
#
# Outputs:
#   output/06-maintenance/predicted-links.json        - Ranked predictions
#   output/06-maintenance/predicted-link-map.json     - Link-injector format
#
# Requires: python3
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

THRESHOLD=3
MAX_PREDICTIONS=100
AUTO_LINK=false

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold)       THRESHOLD="$2";       shift 2 ;;
    --max-predictions) MAX_PREDICTIONS="$2"; shift 2 ;;
    --auto-link)       AUTO_LINK=true;       shift   ;;
    *) shift ;;
  esac
done

require_vault
check_python3

OUT=$(ensure_output_dir "06-maintenance")

log info "=== Missing Link Predictor: $VAULT ==="
log info "Threshold: >= $THRESHOLD common neighbors"

# ---------------------------------------------------------------------------
# 1. Export graph
# ---------------------------------------------------------------------------
log info "Exporting resolved links..."

LINKS_JSON=$(obs_eval 'JSON.stringify(app.metadataCache.resolvedLinks)')

if [[ -z "$LINKS_JSON" || "$LINKS_JSON" == "null" || "$LINKS_JSON" == "{}" ]]; then
  die "No resolved links found. Is the vault open?"
fi

# ---------------------------------------------------------------------------
# 2. Predict missing links
# ---------------------------------------------------------------------------
log info "Analyzing graph structure for missing links..."

python3 << 'PYEOF' "$LINKS_JSON" "$OUT" "$THRESHOLD" "$MAX_PREDICTIONS"
import json
import sys
from collections import defaultdict

links_json = sys.argv[1]
out_dir = sys.argv[2]
threshold = int(sys.argv[3])
max_predictions = int(sys.argv[4])

links = json.loads(links_json)

# ---- Build undirected adjacency ----
adj = defaultdict(set)
directed_edges = set()
all_nodes = set()

for src, targets in links.items():
    src_c = src.replace(".md", "")
    all_nodes.add(src_c)
    for tgt in targets:
        tgt_c = tgt.replace(".md", "")
        all_nodes.add(tgt_c)
        adj[src_c].add(tgt_c)
        adj[tgt_c].add(src_c)
        directed_edges.add((src_c, tgt_c))

n = len(all_nodes)
print(f"Graph: {n} nodes, {len(directed_edges)} directed edges", file=sys.stderr)

# ---- Predict missing links using common neighbors ----
# For each pair of nodes that are NOT directly linked but share neighbors,
# compute: (1) common neighbor count, (2) Jaccard coefficient, (3) Adamic-Adar index

predictions = []

# Only check nodes that have at least some connectivity (optimization)
active_nodes = [nd for nd in all_nodes if len(adj.get(nd, set())) >= 2]
print(f"Checking {len(active_nodes)} active nodes...", file=sys.stderr)

# For each node, look at 2-hop neighbors (neighbors of neighbors)
checked = set()
for node_a in active_nodes:
    neighbors_a = adj.get(node_a, set())

    # 2-hop candidates: neighbors of neighbors
    candidates = set()
    for nb in neighbors_a:
        candidates.update(adj.get(nb, set()))

    # Remove self and existing neighbors
    candidates -= neighbors_a
    candidates.discard(node_a)

    for node_b in candidates:
        # Skip if already checked in reverse
        pair = tuple(sorted([node_a, node_b]))
        if pair in checked:
            continue
        checked.add(pair)

        neighbors_b = adj.get(node_b, set())

        # Common neighbors
        common = neighbors_a & neighbors_b
        cn_count = len(common)

        if cn_count < threshold:
            continue

        # Jaccard coefficient
        union = neighbors_a | neighbors_b
        jaccard = cn_count / len(union) if union else 0

        # Adamic-Adar index: sum of 1/log(degree) for common neighbors
        import math
        aa_score = 0.0
        for cn in common:
            deg = len(adj.get(cn, set()))
            if deg > 1:
                aa_score += 1.0 / math.log(deg)

        # Check if ANY directed edge exists
        has_forward = (node_a, node_b) in directed_edges
        has_backward = (node_b, node_a) in directed_edges

        # If completely unlinked (neither direction), it's a strong prediction
        if not has_forward and not has_backward:
            link_status = "unlinked"
            confidence = "high" if cn_count >= threshold * 2 else "medium"
        elif has_forward != has_backward:
            # One direction exists but not the other
            link_status = "one_way"
            confidence = "high"
        else:
            continue  # Already bidirectionally linked

        predictions.append({
            "source": pair[0],
            "target": pair[1],
            "common_neighbors": cn_count,
            "jaccard": round(jaccard, 4),
            "adamic_adar": round(aa_score, 4),
            "link_status": link_status,
            "confidence": confidence,
            "common_neighbor_names": sorted(list(common))[:5]
        })

# Sort by Adamic-Adar (best predictor), then common neighbors
predictions.sort(key=lambda x: (x["adamic_adar"], x["common_neighbors"]), reverse=True)
predictions = predictions[:max_predictions]

# ---- Generate link map for link-injector.sh ----
link_map = defaultdict(list)
for pred in predictions:
    if pred["link_status"] == "unlinked":
        link_map[pred["source"] + ".md"].append(pred["target"])
        link_map[pred["target"] + ".md"].append(pred["source"])
    elif pred["link_status"] == "one_way":
        # Add the missing direction
        if (pred["source"], pred["target"]) not in directed_edges:
            link_map[pred["source"] + ".md"].append(pred["target"])
        if (pred["target"], pred["source"]) not in directed_edges:
            link_map[pred["target"] + ".md"].append(pred["source"])

# ---- Stats ----
unlinked_count = sum(1 for p in predictions if p["link_status"] == "unlinked")
oneway_count = sum(1 for p in predictions if p["link_status"] == "one_way")
high_conf = sum(1 for p in predictions if p["confidence"] == "high")

# ---- Output ----
result = {
    "total_predictions": len(predictions),
    "unlinked_pairs": unlinked_count,
    "one_way_pairs": oneway_count,
    "high_confidence": high_conf,
    "threshold": threshold,
    "graph_stats": {
        "nodes": n,
        "directed_edges": len(directed_edges)
    },
    "predictions": predictions
}

with open(f"{out_dir}/predicted-links.json", "w") as f:
    json.dump(result, f, indent=2)

with open(f"{out_dir}/predicted-link-map.json", "w") as f:
    json.dump(dict(link_map), f, indent=2)

print(f"Predictions: {len(predictions)} ({high_conf} high confidence)")
print(f"  Unlinked pairs: {unlinked_count}")
print(f"  One-way pairs: {oneway_count}")
if predictions:
    top = predictions[0]
    print(f"  Top prediction: {top['source']} <-> {top['target']} "
          f"(AA={top['adamic_adar']}, CN={top['common_neighbors']})")
PYEOF

# ---------------------------------------------------------------------------
# 3. Optionally inject predicted links
# ---------------------------------------------------------------------------
if [[ "$AUTO_LINK" == "true" ]]; then
  log info "Auto-linking enabled. Injecting predicted links..."
  if [[ -f "$SCRIPT_DIR/../04-graph-construction/link-injector.sh" ]]; then
    bash "$SCRIPT_DIR/../04-graph-construction/link-injector.sh" \
      --vault "$VAULT" --input "$OUT/predicted-link-map.json" --strategy append
  else
    log warn "link-injector.sh not found. Link map saved to: $OUT/predicted-link-map.json"
  fi
fi

log info "Missing link prediction complete."
log info "  Predictions: $OUT/predicted-links.json"
log info "  Link map: $OUT/predicted-link-map.json"
log info "  (Feed link map into link-injector.sh to apply)"
