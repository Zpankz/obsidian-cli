#!/usr/bin/env bash
# =============================================================================
# metadata-cache-dump.sh - Export full metadata cache via eval
# =============================================================================
# Phase 2: Entity Extraction
#
# Dumps the complete Obsidian metadata cache including:
#   - Frontmatter, headings, sections, links, embeds, tags, list items
#   - Per-file cache entries with positional data
#   - File cache statistics
#
# This is the most comprehensive extraction, capturing everything Obsidian
# knows about each file's structure.
#
# Usage:
#   ./metadata-cache-dump.sh --vault <name> [--output <dir>] [--slim]
#
# Options:
#   --slim    Exclude positional data to reduce output size
#
# Outputs:
#   output/02-extraction/metadata-cache.json    - Full metadata cache
#   output/02-extraction/cache-stats.json       - Cache statistics
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

SLIM=false

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --slim) SLIM=true; shift ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "02-extraction")

log info "=== Metadata Cache Dump: $VAULT ==="
[[ "$SLIM" == "true" ]] && log info "Slim mode: excluding positional data"

# ---------------------------------------------------------------------------
# 1. Export metadata cache via eval
# ---------------------------------------------------------------------------
# We chunk the export to avoid output size limits
log info "Exporting metadata cache (this may take a moment)..."

if [[ "$SLIM" == "true" ]]; then
  obs_eval "
    const cache = {};
    const files = app.vault.getMarkdownFiles();
    for (const file of files) {
      const c = app.metadataCache.getCache(file.path);
      if (!c) continue;
      cache[file.path] = {
        hasLinks: (c.links?.length || 0) > 0,
        linkCount: c.links?.length || 0,
        hasEmbeds: (c.embeds?.length || 0) > 0,
        embedCount: c.embeds?.length || 0,
        hasTags: (c.tags?.length || 0) > 0,
        tagCount: c.tags?.length || 0,
        headingCount: c.headings?.length || 0,
        sectionCount: c.sections?.length || 0,
        listItemCount: c.listItems?.length || 0,
        hasFrontmatter: c.frontmatter != null,
        frontmatterKeys: c.frontmatter ? Object.keys(c.frontmatter).filter(k => k !== 'position') : [],
        tags: c.tags?.map(t => t.tag) || [],
        links: c.links?.map(l => l.link) || [],
        embeds: c.embeds?.map(e => e.link) || []
      };
    }
    JSON.stringify(cache);
  " > "$OUT/metadata-cache.json"
else
  obs_eval "
    const cache = {};
    const files = app.vault.getMarkdownFiles();
    for (const file of files) {
      const c = app.metadataCache.getCache(file.path);
      if (!c) continue;
      const entry = {};
      if (c.frontmatter) {
        const fm = {...c.frontmatter};
        delete fm.position;
        entry.frontmatter = fm;
      }
      if (c.headings) entry.headings = c.headings.map(h => ({level: h.level, heading: h.heading}));
      if (c.tags) entry.tags = c.tags.map(t => t.tag);
      if (c.links) entry.links = c.links.map(l => ({link: l.link, displayText: l.displayText}));
      if (c.embeds) entry.embeds = c.embeds.map(e => ({link: e.link, displayText: e.displayText}));
      if (c.sections) entry.sectionTypes = c.sections.map(s => s.type);
      entry.listItemCount = c.listItems?.length || 0;
      cache[file.path] = entry;
    }
    JSON.stringify(cache);
  " > "$OUT/metadata-cache.json"
fi

# ---------------------------------------------------------------------------
# 2. Compute cache statistics
# ---------------------------------------------------------------------------
log info "Computing cache statistics..."
python3 -c "
import json

with open('$OUT/metadata-cache.json') as f:
    cache = json.load(f)

total = len(cache)
with_links = sum(1 for v in cache.values() if v.get('linkCount', len(v.get('links', []))) > 0)
with_tags = sum(1 for v in cache.values() if v.get('tagCount', len(v.get('tags', []))) > 0)
with_embeds = sum(1 for v in cache.values() if v.get('embedCount', len(v.get('embeds', []))) > 0)
with_fm = sum(1 for v in cache.values() if v.get('hasFrontmatter', bool(v.get('frontmatter'))))
with_headings = sum(1 for v in cache.values() if v.get('headingCount', len(v.get('headings', []))) > 0)

total_links = sum(v.get('linkCount', len(v.get('links', []))) for v in cache.values())
total_tags = sum(v.get('tagCount', len(v.get('tags', []))) for v in cache.values())
total_embeds = sum(v.get('embedCount', len(v.get('embeds', []))) for v in cache.values())

stats = {
    'vault': '$VAULT',
    'total_cached_files': total,
    'files_with_links': with_links,
    'files_with_tags': with_tags,
    'files_with_embeds': with_embeds,
    'files_with_frontmatter': with_fm,
    'files_with_headings': with_headings,
    'total_inline_links': total_links,
    'total_inline_tags': total_tags,
    'total_embeds': total_embeds,
    'coverage': {
        'links_pct': round(with_links / total * 100, 1) if total else 0,
        'tags_pct': round(with_tags / total * 100, 1) if total else 0,
        'embeds_pct': round(with_embeds / total * 100, 1) if total else 0,
        'frontmatter_pct': round(with_fm / total * 100, 1) if total else 0,
        'headings_pct': round(with_headings / total * 100, 1) if total else 0
    }
}

with open('$OUT/cache-stats.json', 'w') as f:
    json.dump(stats, f, indent=2)

print(f'Cached files: {total}')
print(f'Links: {total_links} across {with_links} files ({stats[\"coverage\"][\"links_pct\"]}%)')
print(f'Tags:  {total_tags} across {with_tags} files ({stats[\"coverage\"][\"tags_pct\"]}%)')
print(f'Embeds: {total_embeds} across {with_embeds} files ({stats[\"coverage\"][\"embeds_pct\"]}%)')
print(f'Frontmatter: {with_fm} files ({stats[\"coverage\"][\"frontmatter_pct\"]}%)')
"

log info "Metadata cache dump complete. Output: $OUT/"
log info "  metadata-cache.json  (full cache)"
log info "  cache-stats.json     (statistics)"
