#!/usr/bin/env bash
# =============================================================================
# backlink-census.sh - Per-file backlink counts and ranking
# =============================================================================
# Phase 3: Relationship Mapping
#
# Computes backlink (in-degree) counts for every file in the vault,
# identifying authority nodes (most linked-to) and peripheral nodes.
#
# Usage:
#   ./backlink-census.sh --vault <name> [--output <dir>] [--top <n>]
#
# Options:
#   --top <n>    Show top N results (default: 50)
#
# Outputs:
#   output/03-relationships/backlink-census.json   - Full backlink counts
#   output/03-relationships/backlink-ranking.txt   - Human-readable ranking
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

TOP_N=50

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --top) TOP_N="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "03-relationships")

log info "=== Backlink Census: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Compute backlinks from resolved links (single eval call)
# ---------------------------------------------------------------------------
log info "Computing backlink counts from resolved links..."
obs_eval "
  const backlinks = {};
  const outlinks = {};
  const resolved = app.metadataCache.resolvedLinks;
  Object.entries(resolved).forEach(([source, targets]) => {
    outlinks[source] = Object.keys(targets).length;
    Object.keys(targets).forEach(target => {
      backlinks[target] = (backlinks[target] || 0) + 1;
    });
  });
  const allFiles = app.vault.getMarkdownFiles().map(f => f.path);
  const census = allFiles.map(path => ({
    path: path,
    name: path.split('/').pop().replace('.md', ''),
    backlinks: backlinks[path] || 0,
    outlinks: outlinks[path] || 0,
    total: (backlinks[path] || 0) + (outlinks[path] || 0),
    ratio: outlinks[path] > 0 ? ((backlinks[path] || 0) / outlinks[path]).toFixed(2) : 'inf'
  })).sort((a, b) => b.backlinks - a.backlinks);
  JSON.stringify(census);
" > "$OUT/backlink-census.json"

# ---------------------------------------------------------------------------
# 2. Generate ranking and statistics
# ---------------------------------------------------------------------------
log info "Generating backlink ranking..."
python3 -c "
import json

with open('$OUT/backlink-census.json') as f:
    census = json.load(f)

total_files = len(census)
total_backlinks = sum(c['backlinks'] for c in census)
files_with_backlinks = sum(1 for c in census if c['backlinks'] > 0)
avg_backlinks = round(total_backlinks / total_files, 2) if total_files else 0

# Percentile thresholds
sorted_bl = sorted([c['backlinks'] for c in census], reverse=True)
p90 = sorted_bl[int(len(sorted_bl) * 0.1)] if sorted_bl else 0
p75 = sorted_bl[int(len(sorted_bl) * 0.25)] if sorted_bl else 0
p50 = sorted_bl[int(len(sorted_bl) * 0.5)] if sorted_bl else 0

# Classify nodes
hubs = [c for c in census if c['backlinks'] >= p90 and c['backlinks'] > 0]
authorities = [c for c in census if c['backlinks'] >= p75 and c['backlinks'] > 0]
peripheral = [c for c in census if c['backlinks'] <= 1]

top_n = $TOP_N

with open('$OUT/backlink-ranking.txt', 'w') as f:
    f.write(f'Backlink Census: \$VAULT\n')
    f.write(f'={\"=\" * 60}\n\n')
    f.write(f'Total files: {total_files}\n')
    f.write(f'Files with backlinks: {files_with_backlinks}\n')
    f.write(f'Total backlinks: {total_backlinks}\n')
    f.write(f'Average: {avg_backlinks}\n')
    f.write(f'P90: {p90}, P75: {p75}, P50: {p50}\n')
    f.write(f'Hub nodes (P90+): {len(hubs)}\n')
    f.write(f'Peripheral nodes (0-1 backlinks): {len(peripheral)}\n\n')
    f.write(f'Top {top_n} by backlinks:\n')
    f.write(f'{\"Rank\":<5} {\"Backlinks\":>9} {\"Outlinks\":>9} {\"Total\":>7} {\"Path\"}\n')
    f.write(f'{\"-\" * 80}\n')
    for i, c in enumerate(census[:top_n], 1):
        f.write(f\"{i:<5} {c['backlinks']:>9} {c['outlinks']:>9} {c['total']:>7} {c['path']}\n\")

print(f'Total files: {total_files}')
print(f'Files with backlinks: {files_with_backlinks}')
print(f'Average backlinks: {avg_backlinks}')
print(f'Hub nodes (P90): {len(hubs)}')
print(f'Top 5 authorities:')
for c in census[:5]:
    print(f\"  {c['backlinks']:>5} backlinks: {c['path']}\")
"

log info "Backlink census complete. Output: $OUT/"
log info "  backlink-census.json   (full counts)"
log info "  backlink-ranking.txt   (ranked listing)"
