#!/usr/bin/env bash
# =============================================================================
# deadend-enricher.sh - Add outgoing links to dead-end notes
# =============================================================================
# Phase 6: Maintenance
#
# Identifies dead-end files (no outgoing links) and suggests outgoing
# connections based on content similarity, shared tags, and folder context.
#
# Usage:
#   ./deadend-enricher.sh --vault <name> [--output <dir>] [--auto-link]
#                         [--max-links <n>]
#
# Options:
#   --auto-link      Automatically inject suggested links
#   --max-links <n>  Max links to suggest per dead-end (default: 3)
#
# Outputs:
#   output/06-maintenance/deadend-suggestions.json  - Suggestions per dead-end
#   output/06-maintenance/deadend-link-map.json     - Ready for link-injector.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

AUTO_LINK=false
MAX_LINKS=3

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-link)  AUTO_LINK=true;  shift ;;
    --max-links)  MAX_LINKS="$2";  shift 2 ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "06-maintenance")

log info "=== Dead-end Enricher: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Identify dead-ends and gather context
# ---------------------------------------------------------------------------
log info "Identifying dead-end notes and gathering context..."
obs_eval "
  const resolved = app.metadataCache.resolvedLinks;
  const mdFiles = app.vault.getMarkdownFiles();

  // Files with no outgoing resolved links
  const deadends = mdFiles.filter(f => {
    const links = resolved[f.path];
    return !links || Object.keys(links).length === 0;
  });

  // Gather context for each dead-end
  const deadendData = deadends.map(f => {
    const cache = app.metadataCache.getCache(f.path);
    const fm = cache?.frontmatter || {};
    delete fm.position;
    return {
      path: f.path,
      name: f.name.replace('.md', ''),
      folder: f.path.split('/').slice(0, -1).join('/'),
      tags: cache?.tags?.map(t => t.tag) || [],
      headings: cache?.headings?.map(h => h.heading) || [],
      properties: Object.keys(fm)
    };
  });

  // Get popular targets (high in-degree) for suggestion
  const inDeg = {};
  Object.values(resolved).forEach(targets => {
    Object.keys(targets).forEach(t => { inDeg[t] = (inDeg[t] || 0) + 1; });
  });
  const popularTargets = Object.entries(inDeg)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 200)
    .map(([path, count]) => {
      const cache = app.metadataCache.getCache(path);
      return {
        path,
        name: path.split('/').pop().replace('.md', ''),
        folder: path.split('/').slice(0, -1).join('/'),
        inDegree: count,
        tags: cache?.tags?.map(t => t.tag) || []
      };
    });

  JSON.stringify({deadends: deadendData, popularTargets});
" > "$OUT/_deadend_context.json"

# ---------------------------------------------------------------------------
# 2. Generate enrichment suggestions
# ---------------------------------------------------------------------------
log info "Generating enrichment suggestions..."
python3 << 'PYEOF'
import json
from collections import defaultdict

out_dir = """OUT"""
max_links = int("""MAX_LINKS""")

with open(f'{out_dir}/_deadend_context.json') as f:
    data = json.load(f)

deadends = data['deadends']
popular = data['popularTargets']

# Build indexes
folder_popular = defaultdict(list)
tag_popular = defaultdict(list)
for p in popular:
    folder_popular[p['folder']].append(p)
    for tag in p['tags']:
        tag_popular[tag].append(p)

suggestions = []
link_map = {}

for de in deadends:
    scored = []

    # Strategy 1: Popular notes in same folder
    for target in folder_popular.get(de['folder'], [])[:5]:
        if target['path'] != de['path']:
            scored.append({
                'target_path': target['path'],
                'target_name': target['name'],
                'reason': 'same_folder_popular',
                'score': 3 + min(target['inDegree'] / 10, 5)
            })

    # Strategy 2: Shared tags with popular notes
    for tag in de['tags']:
        for target in tag_popular.get(tag, [])[:3]:
            if target['path'] != de['path']:
                existing = [s for s in scored if s['target_path'] == target['path']]
                if existing:
                    existing[0]['score'] += 2
                    existing[0]['reason'] += '+shared_tag'
                else:
                    scored.append({
                        'target_path': target['path'],
                        'target_name': target['name'],
                        'reason': f'shared_tag:{tag}',
                        'score': 2 + min(target['inDegree'] / 20, 3)
                    })

    # Strategy 3: Parent folder's index/hub note
    folder = de['folder']
    parent = '/'.join(folder.split('/')[:-1]) if '/' in folder else ''
    for target in popular:
        if target['folder'] == parent and target['inDegree'] > 20:
            existing = [s for s in scored if s['target_path'] == target['path']]
            if not existing:
                scored.append({
                    'target_path': target['path'],
                    'target_name': target['name'],
                    'reason': 'parent_hub',
                    'score': 4
                })

    # Deduplicate and sort
    seen = set()
    unique = []
    for s in sorted(scored, key=lambda x: x['score'], reverse=True):
        if s['target_path'] not in seen:
            seen.add(s['target_path'])
            unique.append(s)
    unique = unique[:max_links]

    entry = {
        'deadend_path': de['path'],
        'deadend_name': de['name'],
        'folder': de['folder'],
        'tags': de['tags'],
        'suggestion_count': len(unique),
        'suggestions': unique
    }
    suggestions.append(entry)

    if unique:
        link_map[de['path']] = [s['target_name'] for s in unique]

output = {
    'total_deadends': len(deadends),
    'deadends_with_suggestions': sum(1 for s in suggestions if s['suggestions']),
    'total_suggestions': sum(s['suggestion_count'] for s in suggestions),
    'max_links_per_note': max_links,
    'suggestions': suggestions
}

with open(f'{out_dir}/deadend-suggestions.json', 'w') as f:
    json.dump(output, f, indent=2)

with open(f'{out_dir}/deadend-link-map.json', 'w') as f:
    json.dump(link_map, f, indent=2)

print(f"Dead-ends found: {len(deadends)}")
print(f"With suggestions: {output['deadends_with_suggestions']}")
print(f"Total suggestions: {output['total_suggestions']}")
PYEOF

# ---------------------------------------------------------------------------
# 3. Auto-link if requested
# ---------------------------------------------------------------------------
if [[ "$AUTO_LINK" == "true" ]]; then
  log info "Auto-linking enabled. Injecting suggested links..."
  "$SCRIPT_DIR/../04-graph-construction/link-injector.sh" \
    --vault "$VAULT" \
    --input "$OUT/deadend-link-map.json" \
    --strategy append \
    --section "See also" \
    --output "$OUTPUT_DIR"
  log info "Auto-linking complete."
else
  log info "To auto-link dead-ends, re-run with --auto-link"
  log info "Or use: link-injector.sh --input $OUT/deadend-link-map.json"
fi

rm -f "$OUT/_deadend_context.json"

log info "Dead-end enricher complete. Output: $OUT/"
log info "  deadend-suggestions.json  (scored suggestions)"
log info "  deadend-link-map.json     (ready for link-injector)"
