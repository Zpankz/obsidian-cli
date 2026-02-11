#!/usr/bin/env bash
# =============================================================================
# outline-extractor.sh - Extract heading structures for all notes
# =============================================================================
# Phase 2: Entity Extraction
#
# Extracts the heading hierarchy from every markdown file, producing
# a structural map of the vault's content organization.
#
# Usage:
#   ./outline-extractor.sh --vault <name> [--output <dir>] [--limit <n>]
#
# Options:
#   --limit <n>    Max files to process (default: all)
#
# Outputs:
#   output/02-extraction/outlines.json          - All outlines keyed by path
#   output/02-extraction/heading-stats.json     - Heading depth/count statistics
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

LIMIT=""

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "02-extraction")

log info "=== Outline Extractor: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Bulk extract headings via eval (much faster than per-file outline cmd)
# ---------------------------------------------------------------------------
log info "Extracting all heading structures via eval..."

limit_js=""
[[ -n "$LIMIT" ]] && limit_js=".slice(0, $LIMIT)"

obs_eval "
  const outlines = {};
  const files = app.vault.getMarkdownFiles()${limit_js};
  for (const file of files) {
    const cache = app.metadataCache.getCache(file.path);
    if (cache?.headings && cache.headings.length > 0) {
      outlines[file.path] = cache.headings.map(h => ({
        level: h.level,
        heading: h.heading,
        line: h.position?.start?.line || 0
      }));
    }
  }
  JSON.stringify(outlines);
" > "$OUT/outlines.json"

# ---------------------------------------------------------------------------
# 2. Compute heading statistics
# ---------------------------------------------------------------------------
log info "Computing heading statistics..."
python3 -c "
import json
from collections import defaultdict

with open('$OUT/outlines.json') as f:
    outlines = json.load(f)

total_files = len(outlines)
total_headings = 0
level_counts = defaultdict(int)
depth_distribution = defaultdict(int)
files_by_heading_count = defaultdict(int)

for path, headings in outlines.items():
    total_headings += len(headings)
    max_depth = 0
    for h in headings:
        level_counts[h['level']] += 1
        max_depth = max(max_depth, h['level'])
    depth_distribution[max_depth] += 1
    # Bucket heading counts
    count = len(headings)
    if count <= 3:
        bucket = '1-3'
    elif count <= 10:
        bucket = '4-10'
    elif count <= 25:
        bucket = '11-25'
    else:
        bucket = '26+'
    files_by_heading_count[bucket] += 1

avg_headings = round(total_headings / total_files, 1) if total_files > 0 else 0

stats = {
    'vault': '$VAULT',
    'files_with_headings': total_files,
    'total_headings': total_headings,
    'avg_headings_per_file': avg_headings,
    'level_distribution': {f'h{k}': v for k, v in sorted(level_counts.items())},
    'max_depth_distribution': {f'depth_{k}': v for k, v in sorted(depth_distribution.items())},
    'heading_count_buckets': dict(files_by_heading_count)
}

with open('$OUT/heading-stats.json', 'w') as f:
    json.dump(stats, f, indent=2)

print(f'Files with headings: {total_files}')
print(f'Total headings: {total_headings} (avg {avg_headings}/file)')
print(f'Level distribution:')
for level, count in sorted(level_counts.items()):
    print(f'  H{level}: {count}')
"

log info "Outline extraction complete. Output: $OUT/"
log info "  outlines.json       (heading structures)"
log info "  heading-stats.json  (statistics)"
