#!/usr/bin/env bash
# =============================================================================
# graph-health-report.sh - Comprehensive graph health assessment
# =============================================================================
# Phase 5: Graph Analysis
#
# Produces a comprehensive health report covering:
#   - Orphan files (no incoming links)
#   - Dead-end files (no outgoing links)
#   - Unresolved/broken links
#   - Connectivity metrics
#   - Health score (0-100)
#   - Actionable recommendations
#
# Usage:
#   ./graph-health-report.sh --vault <name> [--output <dir>]
#
# Outputs:
#   output/05-analysis/graph-health.json   - Full health report
#   output/05-analysis/graph-health.txt    - Human-readable report
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"
parse_common_args "$@"
require_vault

OUT=$(ensure_output_dir "05-analysis")

log info "=== Graph Health Report: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Collect health data from CLI commands
# ---------------------------------------------------------------------------
log info "Collecting graph health data..."

total_files=$(obs_cli "files ext=md total" | tr -d '[:space:]')
orphan_count=$(obs_cli "orphans total" | tr -d '[:space:]')
deadend_count=$(obs_cli "deadends total" | tr -d '[:space:]')
unresolved_count=$(obs_cli "unresolved total" | tr -d '[:space:]')

log info "Files: $total_files, Orphans: $orphan_count, Deadends: $deadend_count, Unresolved: $unresolved_count"

# ---------------------------------------------------------------------------
# 2. Get orphan and deadend lists
# ---------------------------------------------------------------------------
log info "Listing orphan and deadend files..."
obs_cli "orphans all" > "$OUT/_orphans.txt"
obs_cli "deadends all" > "$OUT/_deadends.txt"

# ---------------------------------------------------------------------------
# 3. Get top unresolved links
# ---------------------------------------------------------------------------
log info "Analyzing unresolved links..."
obs_cli "unresolved counts" > "$OUT/_unresolved.txt"

# ---------------------------------------------------------------------------
# 4. Compute health metrics via eval
# ---------------------------------------------------------------------------
log info "Computing detailed health metrics..."
obs_eval "
  const resolved = app.metadataCache.resolvedLinks;
  const unresolved = app.metadataCache.unresolvedLinks;

  let totalResolved = 0;
  let totalUnresolved = 0;
  const outDeg = {};
  const inDeg = {};

  Object.entries(resolved).forEach(([src, targets]) => {
    outDeg[src] = Object.keys(targets).length;
    totalResolved += Object.keys(targets).length;
    Object.keys(targets).forEach(t => {
      inDeg[t] = (inDeg[t] || 0) + 1;
    });
  });

  Object.values(unresolved).forEach(targets => {
    totalUnresolved += Object.keys(targets).length;
  });

  const nodes = new Set([...Object.keys(resolved), ...Object.keys(inDeg)]);
  const connected = [...nodes].filter(n => (outDeg[n] || 0) + (inDeg[n] || 0) > 0).length;

  JSON.stringify({
    totalResolved,
    totalUnresolved,
    nodeCount: nodes.size,
    connectedNodes: connected,
    avgOutDegree: Object.values(outDeg).length > 0 ? (Object.values(outDeg).reduce((a,b) => a+b, 0) / Object.values(outDeg).length).toFixed(2) : 0,
    avgInDegree: Object.values(inDeg).length > 0 ? (Object.values(inDeg).reduce((a,b) => a+b, 0) / Object.values(inDeg).length).toFixed(2) : 0,
    maxOutDegree: Math.max(...Object.values(outDeg), 0),
    maxInDegree: Math.max(...Object.values(inDeg), 0)
  });
" > "$OUT/_eval_metrics.json"

# ---------------------------------------------------------------------------
# 5. Build health report
# ---------------------------------------------------------------------------
log info "Building health report..."
python3 << 'PYEOF'
import json

out_dir = """OUT"""
total_files = int("""total_files""")
orphan_count = int("""orphan_count""")
deadend_count = int("""deadend_count""")
unresolved_count = int("""unresolved_count""")

with open(f'{out_dir}/_eval_metrics.json') as f:
    metrics = json.load(f)

# Parse orphan list
orphans = []
with open(f'{out_dir}/_orphans.txt') as f:
    for line in f:
        line = line.strip()
        if line:
            orphans.append(line)

# Parse deadend list
deadends = []
with open(f'{out_dir}/_deadends.txt') as f:
    for line in f:
        line = line.strip()
        if line:
            deadends.append(line)

# Parse unresolved links
unresolved_links = []
with open(f'{out_dir}/_unresolved.txt') as f:
    for line in f:
        parts = line.strip().split('\t')
        if len(parts) >= 2:
            try:
                unresolved_links.append({'link': parts[0], 'count': int(parts[1])})
            except ValueError:
                pass
unresolved_links.sort(key=lambda x: x['count'], reverse=True)

# Calculate health score (0-100)
orphan_pct = orphan_count / total_files * 100 if total_files else 0
deadend_pct = deadend_count / total_files * 100 if total_files else 0
connected_pct = int(metrics.get('connectedNodes', 0)) / total_files * 100 if total_files else 0
resolved_ratio = int(metrics.get('totalResolved', 0)) / max(int(metrics.get('totalResolved', 0)) + int(metrics.get('totalUnresolved', 0)), 1) * 100

# Scoring rubric
score = 100
score -= min(orphan_pct * 0.5, 20)       # -0.5 per orphan%, max -20
score -= min(deadend_pct * 0.3, 15)       # -0.3 per deadend%, max -15
score -= min(unresolved_count * 0.01, 15) # -0.01 per unresolved, max -15
score += min(connected_pct * 0.2, 20)     # +0.2 per connected%, max +20
score = max(0, min(100, round(score)))

# Recommendations
recommendations = []
if orphan_pct > 10:
    recommendations.append(f'HIGH: {orphan_count} orphan files ({orphan_pct:.1f}%) have no incoming links. Review and connect them.')
elif orphan_pct > 5:
    recommendations.append(f'MEDIUM: {orphan_count} orphan files ({orphan_pct:.1f}%). Consider linking from index notes.')
if deadend_pct > 30:
    recommendations.append(f'HIGH: {deadend_count} dead-end files ({deadend_pct:.1f}%) have no outgoing links. Add cross-references.')
elif deadend_pct > 15:
    recommendations.append(f'MEDIUM: {deadend_count} dead-end files ({deadend_pct:.1f}%). Add "See also" sections.')
if unresolved_count > 100:
    recommendations.append(f'HIGH: {unresolved_count} unresolved links. Run broken-link-fixer to identify fixable links.')
elif unresolved_count > 20:
    recommendations.append(f'MEDIUM: {unresolved_count} unresolved links. Review and fix or create target notes.')
if float(metrics.get('avgOutDegree', 0)) < 3:
    recommendations.append('LOW: Average out-degree is low. Consider adding more cross-references between notes.')
if not recommendations:
    recommendations.append('Graph health is excellent! No immediate actions needed.')

report = {
    'vault': '',
    'health_score': score,
    'health_grade': 'A' if score >= 90 else 'B' if score >= 75 else 'C' if score >= 60 else 'D' if score >= 40 else 'F',
    'summary': {
        'total_files': total_files,
        'orphan_files': orphan_count,
        'orphan_pct': round(orphan_pct, 1),
        'deadend_files': deadend_count,
        'deadend_pct': round(deadend_pct, 1),
        'unresolved_links': unresolved_count,
        'resolved_links': int(metrics.get('totalResolved', 0)),
        'connected_nodes': int(metrics.get('connectedNodes', 0)),
        'connected_pct': round(connected_pct, 1),
        'avg_out_degree': float(metrics.get('avgOutDegree', 0)),
        'avg_in_degree': float(metrics.get('avgInDegree', 0)),
        'max_out_degree': int(metrics.get('maxOutDegree', 0)),
        'max_in_degree': int(metrics.get('maxInDegree', 0)),
        'resolved_ratio_pct': round(resolved_ratio, 1)
    },
    'recommendations': recommendations,
    'orphan_files': orphans[:50],
    'deadend_sample': deadends[:50],
    'top_unresolved': unresolved_links[:30]
}

with open(f'{out_dir}/graph-health.json', 'w') as f:
    json.dump(report, f, indent=2)

# Human-readable report
with open(f'{out_dir}/graph-health.txt', 'w') as f:
    f.write(f'Graph Health Report\n')
    f.write(f'{"=" * 60}\n\n')
    f.write(f'Health Score: {score}/100 (Grade: {report["health_grade"]})\n\n')

    f.write(f'Overview:\n')
    f.write(f'  Total files:      {total_files}\n')
    f.write(f'  Resolved links:   {metrics.get("totalResolved", 0)}\n')
    f.write(f'  Unresolved links: {unresolved_count}\n')
    f.write(f'  Connected nodes:  {metrics.get("connectedNodes", 0)} ({connected_pct:.1f}%)\n')
    f.write(f'  Avg out-degree:   {metrics.get("avgOutDegree", 0)}\n')
    f.write(f'  Avg in-degree:    {metrics.get("avgInDegree", 0)}\n\n')

    f.write(f'Issues:\n')
    f.write(f'  Orphans:    {orphan_count} ({orphan_pct:.1f}%)\n')
    f.write(f'  Dead-ends:  {deadend_count} ({deadend_pct:.1f}%)\n')
    f.write(f'  Unresolved: {unresolved_count}\n\n')

    f.write(f'Recommendations:\n')
    for rec in recommendations:
        f.write(f'  - {rec}\n')

    if unresolved_links:
        f.write(f'\nTop unresolved links:\n')
        for ul in unresolved_links[:15]:
            f.write(f"  {ul['link']}: {ul['count']} references\n")

print(f'Health Score: {score}/100 (Grade: {report["health_grade"]})')
print(f'Orphans: {orphan_count} ({orphan_pct:.1f}%)')
print(f'Dead-ends: {deadend_count} ({deadend_pct:.1f}%)')
print(f'Unresolved: {unresolved_count}')
for rec in recommendations[:3]:
    print(f'  {rec}')
PYEOF

# Cleanup
rm -f "$OUT/_orphans.txt" "$OUT/_deadends.txt" "$OUT/_unresolved.txt" "$OUT/_eval_metrics.json"

log info "Graph health report complete. Output: $OUT/"
log info "  graph-health.json  (full report)"
log info "  graph-health.txt   (human-readable)"
