#!/usr/bin/env bash
# =============================================================================
# orphan-linker.sh - Find and suggest links for orphan notes
# =============================================================================
# Phase 6: Maintenance
#
# Identifies orphan files (no incoming links) and suggests connections
# based on shared properties, tags, folder proximity, and name similarity.
#
# Usage:
#   ./orphan-linker.sh --vault <name> [--output <dir>] [--auto-link]
#
# Options:
#   --auto-link    Automatically inject suggested links (use with caution)
#
# Outputs:
#   output/06-maintenance/orphan-suggestions.json  - Link suggestions per orphan
#   output/06-maintenance/orphan-link-map.json     - Ready for link-injector.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

AUTO_LINK=false

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-link) AUTO_LINK=true; shift ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "06-maintenance")

log info "=== Orphan Linker: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Get orphan files and vault context for suggestion
# ---------------------------------------------------------------------------
log info "Identifying orphans and collecting context for suggestions..."
obs_eval "
  const resolved = app.metadataCache.resolvedLinks;
  const inDeg = {};
  Object.values(resolved).forEach(targets => {
    Object.keys(targets).forEach(t => { inDeg[t] = (inDeg[t] || 0) + 1; });
  });

  const mdFiles = app.vault.getMarkdownFiles();
  const orphans = mdFiles.filter(f => !inDeg[f.path]).map(f => {
    const cache = app.metadataCache.getCache(f.path);
    const fm = cache?.frontmatter || {};
    delete fm.position;
    const tags = cache?.tags?.map(t => t.tag) || [];
    const outLinks = cache?.links?.map(l => l.link) || [];
    return {
      path: f.path,
      name: f.name.replace('.md', ''),
      folder: f.path.split('/').slice(0, -1).join('/'),
      tags: tags,
      outLinks: outLinks,
      properties: Object.keys(fm),
      frontmatter: fm
    };
  });

  // Also get non-orphan files for matching
  const candidates = mdFiles.filter(f => inDeg[f.path] > 0).map(f => {
    const cache = app.metadataCache.getCache(f.path);
    const tags = cache?.tags?.map(t => t.tag) || [];
    return {
      path: f.path,
      name: f.name.replace('.md', ''),
      folder: f.path.split('/').slice(0, -1).join('/'),
      tags: tags,
      inDegree: inDeg[f.path] || 0
    };
  });

  JSON.stringify({orphans, candidates: candidates.slice(0, 2000)});
" > "$OUT/_orphan_context.json"

# ---------------------------------------------------------------------------
# 2. Generate link suggestions
# ---------------------------------------------------------------------------
log info "Generating link suggestions..."
python3 << 'PYEOF'
import json
from collections import defaultdict

out_dir = """OUT"""

with open(f'{out_dir}/_orphan_context.json') as f:
    data = json.load(f)

orphans = data['orphans']
candidates = data['candidates']

# Build lookup structures
folder_index = defaultdict(list)
tag_index = defaultdict(list)
for c in candidates:
    folder_index[c['folder']].append(c)
    for tag in c['tags']:
        tag_index[tag].append(c)

suggestions = []
link_map = {}

for orphan in orphans:
    scored_suggestions = []

    # Strategy 1: Same folder (folder siblings)
    siblings = folder_index.get(orphan['folder'], [])
    for sib in siblings[:10]:
        if sib['path'] != orphan['path']:
            scored_suggestions.append({
                'target': sib['path'],
                'target_name': sib['name'],
                'reason': 'same_folder',
                'score': 3
            })

    # Strategy 2: Shared tags
    for tag in orphan['tags']:
        for match in tag_index.get(tag, [])[:5]:
            if match['path'] != orphan['path']:
                # Check if already suggested
                existing = [s for s in scored_suggestions if s['target'] == match['path']]
                if existing:
                    existing[0]['score'] += 2
                    existing[0]['reason'] += '+shared_tag'
                else:
                    scored_suggestions.append({
                        'target': match['path'],
                        'target_name': match['name'],
                        'reason': f'shared_tag:{tag}',
                        'score': 2
                    })

    # Strategy 3: Notes the orphan links to (reverse-direction suggestion)
    for out_link in orphan.get('outLinks', []):
        # Find the target's other backlinkers to suggest as related
        for c in candidates:
            if c['name'] == out_link and c['path'] != orphan['path']:
                scored_suggestions.append({
                    'target': c['path'],
                    'target_name': c['name'],
                    'reason': 'linked_target',
                    'score': 4
                })

    # Sort by score and deduplicate
    seen = set()
    unique = []
    for s in sorted(scored_suggestions, key=lambda x: x['score'], reverse=True):
        if s['target'] not in seen:
            seen.add(s['target'])
            unique.append(s)
    unique = unique[:5]  # Top 5 suggestions per orphan

    entry = {
        'orphan_path': orphan['path'],
        'orphan_name': orphan['name'],
        'folder': orphan['folder'],
        'tags': orphan['tags'],
        'suggestions': unique
    }
    suggestions.append(entry)

    # Build link map for link-injector
    if unique:
        targets = [s['target_name'] for s in unique[:3]]
        link_map[orphan['path']] = targets

output = {
    'total_orphans': len(orphans),
    'orphans_with_suggestions': sum(1 for s in suggestions if s['suggestions']),
    'total_suggestions': sum(len(s['suggestions']) for s in suggestions),
    'suggestions': suggestions
}

with open(f'{out_dir}/orphan-suggestions.json', 'w') as f:
    json.dump(output, f, indent=2)

with open(f'{out_dir}/orphan-link-map.json', 'w') as f:
    json.dump(link_map, f, indent=2)

print(f"Orphans found: {len(orphans)}")
print(f"Orphans with suggestions: {output['orphans_with_suggestions']}")
print(f"Total suggestions: {output['total_suggestions']}")
PYEOF

# ---------------------------------------------------------------------------
# 3. Auto-link if requested
# ---------------------------------------------------------------------------
if [[ "$AUTO_LINK" == "true" ]]; then
  log info "Auto-linking enabled. Injecting suggested links..."
  "$SCRIPT_DIR/../04-graph-construction/link-injector.sh" \
    --vault "$VAULT" \
    --input "$OUT/orphan-link-map.json" \
    --strategy append \
    --section "Related" \
    --output "$OUTPUT_DIR"
  log info "Auto-linking complete."
else
  log info "To auto-link orphans, re-run with --auto-link"
  log info "Or use: link-injector.sh --input $OUT/orphan-link-map.json"
fi

rm -f "$OUT/_orphan_context.json"

log info "Orphan linker complete. Output: $OUT/"
log info "  orphan-suggestions.json  (scored suggestions)"
log info "  orphan-link-map.json     (ready for link-injector)"
