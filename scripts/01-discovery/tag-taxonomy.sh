#!/usr/bin/env bash
# =============================================================================
# tag-taxonomy.sh - Extract complete tag hierarchy with counts
# =============================================================================
# Phase 1: Discovery & Inventory
#
# Builds a full tag taxonomy including:
#   - All tags with usage counts
#   - Tag hierarchy (nested tags like #parent/child)
#   - Tag co-occurrence matrix
#   - Cluster identification by tag groupings
#
# Usage:
#   ./tag-taxonomy.sh --vault <name> [--output <dir>]
#
# Outputs:
#   output/01-discovery/tag-taxonomy.json      - Full tag hierarchy
#   output/01-discovery/tag-cooccurrence.json   - Tag co-occurrence data
#   output/01-discovery/tag-summary.txt         - Human-readable summary
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"
parse_common_args "$@"
require_vault

OUT=$(ensure_output_dir "01-discovery")

log info "=== Tag Taxonomy: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Get all tags with counts (sorted by count)
# ---------------------------------------------------------------------------
log info "Extracting all tags with counts..."
obs_cli "tags all counts sort=count" > "$OUT/_raw_tags.txt"

# ---------------------------------------------------------------------------
# 2. Extract per-file tag data via eval (for co-occurrence)
# ---------------------------------------------------------------------------
log info "Extracting per-file tag data via eval..."
obs_eval "
  const fileTagMap = {};
  app.vault.getMarkdownFiles().forEach(file => {
    const cache = app.metadataCache.getCache(file.path);
    const tags = [];
    if (cache?.tags) tags.push(...cache.tags.map(t => t.tag));
    if (cache?.frontmatter?.tags) {
      const fmTags = cache.frontmatter.tags;
      if (Array.isArray(fmTags)) tags.push(...fmTags.map(t => t.startsWith('#') ? t : '#' + t));
      else if (typeof fmTags === 'string') tags.push(fmTags.startsWith('#') ? fmTags : '#' + fmTags);
    }
    if (tags.length > 0) fileTagMap[file.path] = [...new Set(tags)];
  });
  JSON.stringify(fileTagMap);
" > "$OUT/_raw_file_tags.json"

# ---------------------------------------------------------------------------
# 3. Build taxonomy and co-occurrence
# ---------------------------------------------------------------------------
log info "Building tag taxonomy and co-occurrence matrix..."
python3 -c "
import json
from collections import defaultdict

# Parse raw tag counts
tag_counts = {}
with open('$OUT/_raw_tags.txt') as f:
    for line in f:
        line = line.strip()
        if not line or '\t' not in line:
            continue
        parts = line.rsplit('\t', 1)
        if len(parts) == 2:
            tag, count = parts
            try:
                tag_counts[tag.strip()] = int(count.strip())
            except ValueError:
                pass

# Load per-file tags
with open('$OUT/_raw_file_tags.json') as f:
    file_tags = json.load(f)

# Build hierarchy
hierarchy = {}
for tag, count in sorted(tag_counts.items(), key=lambda x: x[1], reverse=True):
    parts = tag.lstrip('#').split('/')
    current = hierarchy
    for part in parts:
        if part not in current:
            current[part] = {'_count': 0, '_children': {}}
        current = current[part]['_children']
    # Set count on leaf
    node = hierarchy
    for part in parts:
        node = node[part]
        if part == parts[-1]:
            node['_count'] = count

# Build co-occurrence
cooccurrence = defaultdict(lambda: defaultdict(int))
for path, tags in file_tags.items():
    normalized = [t.lstrip('#') for t in tags]
    for i, t1 in enumerate(normalized):
        for t2 in normalized[i+1:]:
            cooccurrence[t1][t2] += 1
            cooccurrence[t2][t1] += 1

# Flatten co-occurrence for JSON
cooc_list = []
seen = set()
for t1, neighbors in cooccurrence.items():
    for t2, count in neighbors.items():
        key = tuple(sorted([t1, t2]))
        if key not in seen and count >= 2:
            seen.add(key)
            cooc_list.append({'tag_a': key[0], 'tag_b': key[1], 'co_occurrences': count})
cooc_list.sort(key=lambda x: x['co_occurrences'], reverse=True)

# Tag statistics
total_tags = len(tag_counts)
files_with_tags = len(file_tags)
root_tags = set()
for tag in tag_counts:
    root = tag.lstrip('#').split('/')[0]
    root_tags.add(root)

taxonomy = {
    'vault': '$VAULT',
    'total_unique_tags': total_tags,
    'files_with_tags': files_with_tags,
    'root_tag_groups': len(root_tags),
    'tags': [{'tag': t, 'count': c} for t, c in sorted(tag_counts.items(), key=lambda x: x[1], reverse=True)],
    'root_groups': sorted(list(root_tags))
}

with open('$OUT/tag-taxonomy.json', 'w') as f:
    json.dump(taxonomy, f, indent=2)

with open('$OUT/tag-cooccurrence.json', 'w') as f:
    json.dump(cooc_list[:200], f, indent=2)

# Human-readable summary
with open('$OUT/tag-summary.txt', 'w') as f:
    f.write(f'Tag Taxonomy: \$VAULT\n')
    f.write(f'={\"=\" * 50}\n')
    f.write(f'Unique tags: {total_tags}\n')
    f.write(f'Files with tags: {files_with_tags}\n')
    f.write(f'Root tag groups: {len(root_tags)}\n\n')
    f.write(f'Top 30 tags:\n')
    for item in taxonomy['tags'][:30]:
        f.write(f\"  {item['tag']:<40} {item['count']:>5}\n\")
    f.write(f'\nTop co-occurring pairs:\n')
    for pair in cooc_list[:20]:
        f.write(f\"  {pair['tag_a']} + {pair['tag_b']}: {pair['co_occurrences']}\n\")

print(f'Tags: {total_tags}, Root groups: {len(root_tags)}, Files with tags: {files_with_tags}')
"

# Cleanup
rm -f "$OUT/_raw_tags.txt" "$OUT/_raw_file_tags.json"

log info "Tag taxonomy complete. Output: $OUT/"
log info "  tag-taxonomy.json     (full hierarchy)"
log info "  tag-cooccurrence.json (co-occurrence pairs)"
log info "  tag-summary.txt       (human-readable)"
