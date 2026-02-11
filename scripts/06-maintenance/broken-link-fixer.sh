#!/usr/bin/env bash
# =============================================================================
# broken-link-fixer.sh - Detect and report unresolved links with fix suggestions
# =============================================================================
# Phase 6: Maintenance
#
# Analyzes all unresolved (broken) links in the vault and suggests fixes:
#   - Fuzzy match against existing file names
#   - Path-corrected suggestions (moved files)
#   - Create-note suggestions for genuinely missing topics
#
# Usage:
#   ./broken-link-fixer.sh --vault <name> [--output <dir>] [--threshold <n>]
#
# Options:
#   --threshold <n>   Minimum fuzzy match score 0-100 (default: 70)
#
# Outputs:
#   output/06-maintenance/broken-links.json       - All broken links with suggestions
#   output/06-maintenance/broken-link-fixes.json   - Actionable fix commands
#   output/06-maintenance/broken-links-report.txt  - Human-readable report
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

THRESHOLD=70

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) THRESHOLD="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "06-maintenance")

log info "=== Broken Link Fixer: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Export unresolved links and file list via eval
# ---------------------------------------------------------------------------
log info "Exporting unresolved links and file index..."
obs_eval "
  const unresolved = app.metadataCache.unresolvedLinks;
  const files = app.vault.getMarkdownFiles().map(f => ({
    path: f.path,
    name: f.name.replace('.md', ''),
    basename: f.basename
  }));

  // Flatten unresolved: { sourceFile: { brokenLink: count } }
  const broken = [];
  Object.entries(unresolved).forEach(([source, targets]) => {
    Object.entries(targets).forEach(([target, count]) => {
      broken.push({ source, target, count });
    });
  });

  JSON.stringify({ broken, files });
" > "$OUT/_broken_context.json"

# ---------------------------------------------------------------------------
# 2. Generate fix suggestions with fuzzy matching
# ---------------------------------------------------------------------------
log info "Generating fix suggestions (threshold: $THRESHOLD%)..."
python3 << 'PYEOF'
import json
from difflib import SequenceMatcher

out_dir = """OUT"""
threshold = int("""THRESHOLD""")

with open(f'{out_dir}/_broken_context.json') as f:
    data = json.load(f)

broken = data['broken']
files = data['files']

# Build name index for fuzzy matching
name_index = {}
for f in files:
    name_lower = f['name'].lower()
    name_index[name_lower] = f
    # Also index without common prefixes/suffixes
    for prefix in ['AP', 'L_', 'G_']:
        if name_lower.startswith(prefix.lower()):
            name_index[name_lower[len(prefix):]] = f

def fuzzy_match(target, top_n=3):
    """Find closest matching file names."""
    target_lower = target.lower().replace('.md', '')
    matches = []

    # Exact match check
    if target_lower in name_index:
        return [{'file': name_index[target_lower], 'score': 100, 'method': 'exact'}]

    # Fuzzy matching
    for f in files:
        name_lower = f['name'].lower()
        score = SequenceMatcher(None, target_lower, name_lower).ratio() * 100
        if score >= threshold:
            matches.append({'file': f, 'score': round(score, 1), 'method': 'fuzzy'})

    # Also check if target is a substring of any file name
    for f in files:
        if target_lower in f['name'].lower() or f['name'].lower() in target_lower:
            existing = [m for m in matches if m['file']['path'] == f['path']]
            if existing:
                existing[0]['score'] = max(existing[0]['score'], 85)
                existing[0]['method'] = 'substring'
            else:
                matches.append({'file': f, 'score': 85, 'method': 'substring'})

    matches.sort(key=lambda x: x['score'], reverse=True)
    return matches[:top_n]

# Process broken links
results = []
fixable = 0
create_needed = 0

# Aggregate broken links by target
from collections import defaultdict
target_sources = defaultdict(list)
for b in broken:
    target_sources[b['target']].append({'source': b['source'], 'count': b['count']})

for target, sources in sorted(target_sources.items(), key=lambda x: sum(s['count'] for s in x[1]), reverse=True):
    total_refs = sum(s['count'] for s in sources)
    matches = fuzzy_match(target)

    entry = {
        'broken_link': target,
        'total_references': total_refs,
        'source_count': len(sources),
        'sources': sources[:10],
        'suggestions': []
    }

    if matches:
        fixable += 1
        for m in matches:
            entry['suggestions'].append({
                'suggested_path': m['file']['path'],
                'suggested_name': m['file']['name'],
                'match_score': m['score'],
                'match_method': m['method']
            })
        entry['action'] = 'rename_link'
    else:
        create_needed += 1
        entry['action'] = 'create_note'
        entry['suggestions'] = [{
            'action': f'Create note: {target}',
            'reason': f'Referenced by {len(sources)} files ({total_refs} times)'
        }]

    results.append(entry)

output = {
    'total_broken_links': len(target_sources),
    'total_references': sum(sum(s['count'] for s in sources) for sources in target_sources.values()),
    'fixable_with_rename': fixable,
    'needs_new_note': create_needed,
    'match_threshold': threshold,
    'results': results
}

with open(f'{out_dir}/broken-links.json', 'w') as f:
    json.dump(output, f, indent=2)

# Generate fix commands
fixes = []
for r in results:
    if r['action'] == 'rename_link' and r['suggestions']:
        best = r['suggestions'][0]
        if best['match_score'] >= 90:
            fixes.append({
                'broken': r['broken_link'],
                'fix_to': best['suggested_name'],
                'confidence': 'high' if best['match_score'] >= 95 else 'medium',
                'score': best['match_score']
            })

with open(f'{out_dir}/broken-link-fixes.json', 'w') as f:
    json.dump(fixes, f, indent=2)

# Human-readable report
with open(f'{out_dir}/broken-links-report.txt', 'w') as f:
    f.write(f'Broken Link Report\n')
    f.write(f'{"=" * 70}\n\n')
    f.write(f'Total broken links: {len(target_sources)}\n')
    f.write(f'Total references: {output["total_references"]}\n')
    f.write(f'Fixable with rename: {fixable}\n')
    f.write(f'Need new note: {create_needed}\n\n')

    f.write(f'Top broken links (by reference count):\n')
    f.write(f'{"-" * 70}\n')
    for r in results[:30]:
        f.write(f'\n  [[{r["broken_link"]}]] - {r["total_references"]} refs from {r["source_count"]} files\n')
        if r['suggestions'] and r['action'] == 'rename_link':
            for s in r['suggestions'][:2]:
                f.write(f'    -> {s["suggested_name"]} ({s["match_score"]}% {s["match_method"]})\n')
        elif r['action'] == 'create_note':
            f.write(f'    -> Create new note\n')

print(f'Broken links: {len(target_sources)}')
print(f'Fixable: {fixable}, Need creation: {create_needed}')
print(f'High-confidence fixes: {len(fixes)}')
PYEOF

rm -f "$OUT/_broken_context.json"

log info "Broken link analysis complete. Output: $OUT/"
log info "  broken-links.json         (full analysis)"
log info "  broken-link-fixes.json    (actionable fixes)"
log info "  broken-links-report.txt   (human-readable)"
