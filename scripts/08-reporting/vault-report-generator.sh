#!/usr/bin/env bash
# =============================================================================
# vault-report-generator.sh - Create analysis report as a vault note
# =============================================================================
# Phase 8: Reporting (DeepGraph integration)
#
# Aggregates outputs from all analysis phases into a comprehensive markdown
# report and creates it as a note inside the vault. The report includes
# graph metrics, centrality rankings, community structure, health scores,
# and actionable recommendations.
#
# Usage:
#   ./vault-report-generator.sh --vault <name> [--output <dir>]
#                               [--note-path <path>] [--note-name <name>]
#
# Options:
#   --note-path <path>   Vault folder for the report (default: _reports)
#   --note-name <name>   Report note name (default: Graph Analysis Report)
#
# Prerequisites:
#   Run analysis scripts first to generate input data:
#     - network-metrics.sh        -> network-metrics.json
#     - graph-health-report.sh    -> graph-health.json
#     - centrality-analysis.sh    -> centrality-analysis.json
#     - community-detection.sh    -> communities.json
#     - missing-link-predictor.sh -> predicted-links.json (optional)
#
# Outputs:
#   output/08-reporting/vault-report.md    - Local copy of the report
#   Creates a note in the vault at <note-path>/<note-name>
#
# Requires: python3
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

NOTE_PATH="_reports"
NOTE_NAME="Graph Analysis Report"

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --note-path) NOTE_PATH="$2"; shift 2 ;;
    --note-name) NOTE_NAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault
check_python3

OUT=$(ensure_output_dir "08-reporting")
ANALYSIS_DIR="$OUTPUT_DIR/05-analysis"
MAINT_DIR="$OUTPUT_DIR/06-maintenance"

log info "=== Vault Report Generator: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Collect available analysis outputs
# ---------------------------------------------------------------------------
log info "Scanning for analysis outputs in $OUTPUT_DIR..."

python3 - "$ANALYSIS_DIR" "$MAINT_DIR" "$OUT" "$NOTE_NAME" << 'PYEOF'
import json
import sys
import os
from datetime import datetime

analysis_dir = sys.argv[1]
maint_dir = sys.argv[2]
out_dir = sys.argv[3]
note_name = sys.argv[4]

def load_json(path):
    """Load JSON file, return None if missing."""
    if os.path.isfile(path):
        with open(path) as f:
            return json.load(f)
    return None

# ---- Load available data ----
network = load_json(f"{analysis_dir}/network-metrics.json")
health = load_json(f"{analysis_dir}/graph-health.json")
centrality = load_json(f"{analysis_dir}/centrality-analysis.json")
communities = load_json(f"{analysis_dir}/communities.json")
predicted = load_json(f"{maint_dir}/predicted-links.json")

sources_found = []
if network: sources_found.append("network-metrics")
if health: sources_found.append("graph-health")
if centrality: sources_found.append("centrality-analysis")
if communities: sources_found.append("communities")
if predicted: sources_found.append("predicted-links")

print(f"Found {len(sources_found)} analysis sources: {', '.join(sources_found)}", file=sys.stderr)

if not sources_found:
    print("WARNING: No analysis outputs found. Run analysis scripts first.", file=sys.stderr)
    print("Generating skeleton report...", file=sys.stderr)

# ---- Build report ----
now = datetime.now().strftime("%Y-%m-%d %H:%M")
lines = []

# Frontmatter
lines.append("---")
lines.append(f"type: analysis_report")
lines.append(f"generated: {now}")
lines.append(f"sources: [{', '.join(sources_found)}]")
lines.append("---")
lines.append("")

lines.append(f"# {note_name}")
lines.append(f"*Generated: {now}*")
lines.append("")

# ---- Graph Overview ----
lines.append("## Graph Overview")
lines.append("")

if network:
    basic = network.get("basic_stats", network)
    nodes = basic.get("total_nodes", basic.get("nodes", "?"))
    edges = basic.get("total_edges", basic.get("edges", "?"))
    density = basic.get("density", "?")
    if isinstance(density, float):
        density = f"{density:.4f}"

    lines.append(f"| Metric | Value |")
    lines.append(f"|--------|-------|")
    lines.append(f"| Nodes | {nodes:,} |" if isinstance(nodes, int) else f"| Nodes | {nodes} |")
    lines.append(f"| Edges | {edges:,} |" if isinstance(edges, int) else f"| Edges | {edges} |")
    lines.append(f"| Density | {density} |")

    if "components" in network:
        comp = network["components"]
        lines.append(f"| Connected components | {comp.get('weakly_connected', comp.get('count', '?'))} |")

    if "topology" in network:
        topo = network["topology"]
        lines.append(f"| Topology | {topo.get('classification', '?')} |")

    lines.append("")
elif centrality:
    lines.append(f"| Metric | Value |")
    lines.append(f"|--------|-------|")
    lines.append(f"| Nodes | {centrality.get('total_nodes', '?'):,} |")
    lines.append(f"| Edges | {centrality.get('total_edges', '?'):,} |")
    lines.append("")
else:
    lines.append("*Run `network-metrics.sh` to populate this section.*")
    lines.append("")

# ---- Health Score ----
if health:
    lines.append("## Graph Health")
    lines.append("")
    score = health.get("health_score", health.get("score", "?"))
    grade = health.get("health_grade", health.get("grade", "?"))
    lines.append(f"**Health Score: {score}/100 (Grade: {grade})**")
    lines.append("")

    counts = health.get("counts", health)
    orphans = counts.get("orphans", "?")
    deadends = counts.get("deadends", counts.get("dead_ends", "?"))
    unresolved = counts.get("unresolved", counts.get("unresolved_links", "?"))

    lines.append(f"| Issue | Count |")
    lines.append(f"|-------|-------|")
    lines.append(f"| Orphan notes (no incoming links) | {orphans} |")
    lines.append(f"| Dead-end notes (no outgoing links) | {deadends} |")
    lines.append(f"| Unresolved links | {unresolved} |")
    lines.append("")

    recs = health.get("recommendations", [])
    if recs:
        lines.append("### Recommendations")
        lines.append("")
        for rec in recs[:5]:
            if isinstance(rec, str):
                lines.append(f"- {rec}")
            elif isinstance(rec, dict):
                lines.append(f"- **{rec.get('category', '?')}**: {rec.get('message', rec.get('action', '?'))}")
        lines.append("")

# ---- Centrality Rankings ----
if centrality:
    lines.append("## Centrality Analysis")
    lines.append("")

    lines.append("### Top Authorities (PageRank)")
    lines.append("")
    lines.append("| Rank | Note | Score |")
    lines.append("|------|------|-------|")
    for i, entry in enumerate(centrality.get("top_by_pagerank", [])[:10], 1):
        node = entry["node"]
        score = entry["score"]
        lines.append(f"| {i} | [[{node}]] | {score:.6f} |")
    lines.append("")

    lines.append("### Top Bridges (Betweenness)")
    lines.append("")
    lines.append("| Rank | Note | Score |")
    lines.append("|------|------|-------|")
    for i, entry in enumerate(centrality.get("top_by_betweenness", [])[:10], 1):
        node = entry["node"]
        score = entry["score"]
        lines.append(f"| {i} | [[{node}]] | {score:.6f} |")
    lines.append("")

    lines.append("### Top Connectors (Closeness)")
    lines.append("")
    lines.append("| Rank | Note | Score |")
    lines.append("|------|------|-------|")
    for i, entry in enumerate(centrality.get("top_by_closeness", [])[:10], 1):
        node = entry["node"]
        score = entry["score"]
        lines.append(f"| {i} | [[{node}]] | {score:.6f} |")
    lines.append("")

    # Role distribution
    role_counts = centrality.get("role_counts", {})
    if role_counts:
        lines.append("### Structural Roles")
        lines.append("")
        lines.append("| Role | Count |")
        lines.append("|------|-------|")
        for role, count in sorted(role_counts.items(), key=lambda x: x[1], reverse=True):
            lines.append(f"| {role} | {count:,} |")
        lines.append("")

# ---- Communities ----
if communities:
    lines.append("## Community Structure")
    lines.append("")
    lines.append(f"**{communities.get('communities_found', '?')} communities detected** "
                 f"(modularity Q = {communities.get('modularity', '?')})")
    lines.append("")

    if communities.get("modularity", 0) > 0.3:
        lines.append("> Strong community structure detected (Q > 0.3)")
    elif communities.get("modularity", 0) > 0.1:
        lines.append("> Moderate community structure (0.1 < Q < 0.3)")
    else:
        lines.append("> Weak community structure (Q < 0.1)")
    lines.append("")

    sizes = communities.get("community_sizes", {})
    themes = communities.get("community_themes", {})
    if sizes:
        lines.append("| Community | Size | Primary Folders |")
        lines.append("|-----------|------|-----------------|")
        for cname, size in sorted(sizes.items(), key=lambda x: x[1], reverse=True)[:15]:
            theme_list = themes.get(cname, [])
            theme_str = ", ".join(f"{t['folder']}({t['count']})" for t in theme_list[:3])
            lines.append(f"| {cname} | {size:,} | {theme_str} |")
        lines.append("")

    bridges = communities.get("top_bridge_nodes", [])
    if bridges:
        lines.append("### Cross-Community Bridge Nodes")
        lines.append("")
        for b in bridges[:10]:
            lines.append(f"- [[{b['node']}]] ({b['cross_community_links']} cross-community links)")
        lines.append("")

# ---- Missing Link Predictions ----
if predicted:
    lines.append("## Predicted Missing Links")
    lines.append("")
    lines.append(f"**{predicted.get('total_predictions', 0)} link predictions** "
                 f"({predicted.get('high_confidence', 0)} high confidence)")
    lines.append("")

    preds = predicted.get("predictions", [])
    if preds:
        lines.append("| Source | Target | Score | Common Neighbors |")
        lines.append("|--------|--------|-------|------------------|")
        for p in preds[:15]:
            lines.append(f"| [[{p['source']}]] | [[{p['target']}]] | "
                         f"{p.get('adamic_adar', p.get('jaccard', 0)):.3f} | "
                         f"{p.get('common_neighbors', '?')} |")
        lines.append("")

# ---- Footer ----
lines.append("---")
lines.append(f"*Report generated by obsidian-cli knowledge graph scripts.*")
lines.append(f"*Sources: {', '.join(sources_found) if sources_found else 'none'}*")

report_md = "\n".join(lines)

# Save local copy
with open(f"{out_dir}/vault-report.md", "w") as f:
    f.write(report_md)

# Write report content to stdout for the bash script to create as vault note
print(report_md)
PYEOF

# ---------------------------------------------------------------------------
# 2. Create the report as a vault note
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" != "true" ]]; then
  log info "Creating report note in vault: $NOTE_PATH/$NOTE_NAME"

  REPORT_CONTENT=$(cat "$OUT/vault-report.md")

  # Escape for CLI
  ESCAPED_CONTENT=$(echo "$REPORT_CONTENT" | python3 -c "
import sys, json
content = sys.stdin.read()
print(json.dumps(content))
")

  obs_cli "create name=\"$NOTE_PATH/$NOTE_NAME\" content=$ESCAPED_CONTENT" || {
    log warn "Could not create note (may already exist). Report saved locally."
  }
else
  log info "[DRY RUN] Would create note: $NOTE_PATH/$NOTE_NAME"
fi

log info "Report generation complete."
log info "  Local copy: $OUT/vault-report.md"
log info "  Vault note: $NOTE_PATH/$NOTE_NAME"
