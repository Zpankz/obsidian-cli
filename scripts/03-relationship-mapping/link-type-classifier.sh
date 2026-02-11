#!/usr/bin/env bash
# =============================================================================
# link-type-classifier.sh - Classify links by type
# =============================================================================
# Phase 3: Relationship Mapping
#
# Classifies all links in the vault by their type:
#   - Wikilinks: [[target]] and [[target|alias]]
#   - Embeds: ![[file]] (images, transclusions)
#   - Frontmatter links: wikilinks in YAML properties
#   - Tag references: inline #tag usage
#
# Usage:
#   ./link-type-classifier.sh --vault <name> [--output <dir>]
#
# Outputs:
#   output/03-relationships/link-types.json        - All links with types
#   output/03-relationships/link-type-stats.json   - Distribution statistics
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"
parse_common_args "$@"
require_vault

OUT=$(ensure_output_dir "03-relationships")

log info "=== Link Type Classifier: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Extract all link types via eval
# ---------------------------------------------------------------------------
log info "Classifying all link types via eval..."
obs_eval "
  const linkData = {};
  const files = app.vault.getMarkdownFiles();
  for (const file of files) {
    const cache = app.metadataCache.getCache(file.path);
    if (!cache) continue;
    const entry = { wikilinks: [], embeds: [], frontmatterLinks: [], tags: [] };

    // Inline wikilinks
    if (cache.links) {
      entry.wikilinks = cache.links.map(l => ({
        target: l.link,
        display: l.displayText || l.link,
        hasAlias: l.displayText !== l.link && l.displayText !== undefined
      }));
    }

    // Embeds (![[...]])
    if (cache.embeds) {
      entry.embeds = cache.embeds.map(e => ({
        target: e.link,
        display: e.displayText || e.link
      }));
    }

    // Frontmatter links (wikilinks in YAML properties)
    if (cache.frontmatterLinks) {
      entry.frontmatterLinks = cache.frontmatterLinks.map(l => ({
        target: l.link,
        key: l.key || 'unknown',
        display: l.displayText || l.link
      }));
    }

    // Inline tags
    if (cache.tags) {
      entry.tags = cache.tags.map(t => t.tag);
    }

    if (entry.wikilinks.length + entry.embeds.length +
        entry.frontmatterLinks.length + entry.tags.length > 0) {
      linkData[file.path] = entry;
    }
  }
  JSON.stringify(linkData);
" > "$OUT/link-types.json"

# ---------------------------------------------------------------------------
# 2. Compute statistics
# ---------------------------------------------------------------------------
log info "Computing link type statistics..."
python3 -c "
import json
from collections import defaultdict

with open('$OUT/link-types.json') as f:
    data = json.load(f)

total_files = len(data)
totals = {'wikilinks': 0, 'embeds': 0, 'frontmatterLinks': 0, 'tags': 0}
files_with = {'wikilinks': 0, 'embeds': 0, 'frontmatterLinks': 0, 'tags': 0}
aliased_links = 0
unique_targets = {'wikilinks': set(), 'embeds': set(), 'frontmatterLinks': set()}
fm_link_keys = defaultdict(int)

for path, entry in data.items():
    for link_type in totals:
        items = entry.get(link_type, [])
        count = len(items)
        totals[link_type] += count
        if count > 0:
            files_with[link_type] += 1

        # Count aliased wikilinks
        if link_type == 'wikilinks':
            aliased_links += sum(1 for l in items if l.get('hasAlias'))
            for l in items:
                unique_targets['wikilinks'].add(l['target'])
        elif link_type == 'embeds':
            for l in items:
                unique_targets['embeds'].add(l['target'])
        elif link_type == 'frontmatterLinks':
            for l in items:
                unique_targets['frontmatterLinks'].add(l['target'])
                fm_link_keys[l.get('key', 'unknown')] += 1

grand_total = sum(totals.values())

stats = {
    'vault': '$VAULT',
    'files_analyzed': total_files,
    'grand_total_links': grand_total,
    'by_type': {
        'wikilinks': {
            'total': totals['wikilinks'],
            'unique_targets': len(unique_targets['wikilinks']),
            'files_with': files_with['wikilinks'],
            'aliased': aliased_links,
            'pct_of_total': round(totals['wikilinks'] / grand_total * 100, 1) if grand_total else 0
        },
        'embeds': {
            'total': totals['embeds'],
            'unique_targets': len(unique_targets['embeds']),
            'files_with': files_with['embeds'],
            'pct_of_total': round(totals['embeds'] / grand_total * 100, 1) if grand_total else 0
        },
        'frontmatter_links': {
            'total': totals['frontmatterLinks'],
            'unique_targets': len(unique_targets['frontmatterLinks']),
            'files_with': files_with['frontmatterLinks'],
            'top_keys': dict(sorted(fm_link_keys.items(), key=lambda x: x[1], reverse=True)[:10]),
            'pct_of_total': round(totals['frontmatterLinks'] / grand_total * 100, 1) if grand_total else 0
        },
        'inline_tags': {
            'total': totals['tags'],
            'files_with': files_with['tags'],
            'pct_of_total': round(totals['tags'] / grand_total * 100, 1) if grand_total else 0
        }
    }
}

with open('$OUT/link-type-stats.json', 'w') as f:
    json.dump(stats, f, indent=2)

print(f'Grand total links: {grand_total}')
for lt, info in stats['by_type'].items():
    print(f'  {lt}: {info[\"total\"]} ({info[\"pct_of_total\"]}%)')
"

log info "Link type classification complete. Output: $OUT/"
log info "  link-types.json       (per-file link data)"
log info "  link-type-stats.json  (distribution stats)"
