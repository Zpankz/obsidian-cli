#!/usr/bin/env bash
# =============================================================================
# frontmatter-export.sh - Export all frontmatter as structured data
# =============================================================================
# Phase 2: Entity Extraction
#
# Extracts YAML frontmatter from every markdown file in the vault,
# producing a unified dataset suitable for graph node creation.
#
# Usage:
#   ./frontmatter-export.sh --vault <name> [--output <dir>] [--path <folder>]
#
# Options:
#   --path <folder>    Only export frontmatter from files in this folder
#
# Outputs:
#   output/02-extraction/frontmatter-all.json      - All frontmatter keyed by path
#   output/02-extraction/frontmatter-entities.json  - Normalized entity list
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

FILTER_PATH=""

parse_common_args "$@"
# Additional args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) FILTER_PATH="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

OUT=$(ensure_output_dir "02-extraction")

log info "=== Frontmatter Export: $VAULT ==="
[[ -n "$FILTER_PATH" ]] && log info "Filter path: $FILTER_PATH"

# ---------------------------------------------------------------------------
# 1. Bulk export all frontmatter via eval
# ---------------------------------------------------------------------------
log info "Exporting all frontmatter via eval (batch)..."

filter_js=""
[[ -n "$FILTER_PATH" ]] && filter_js=".filter(f => f.path.startsWith('$FILTER_PATH'))"

obs_eval "
  const result = {};
  const files = app.vault.getMarkdownFiles()${filter_js};
  for (const file of files) {
    const cache = app.metadataCache.getCache(file.path);
    if (cache?.frontmatter) {
      const fm = {...cache.frontmatter};
      delete fm.position;
      result[file.path] = fm;
    }
  }
  JSON.stringify(result);
" > "$OUT/frontmatter-all.json"

# ---------------------------------------------------------------------------
# 2. Normalize into entity list
# ---------------------------------------------------------------------------
log info "Normalizing into entity list..."
python3 -c "
import json

with open('$OUT/frontmatter-all.json') as f:
    data = json.load(f)

entities = []
for path, fm in data.items():
    entity = {
        'path': path,
        'name': path.rsplit('/', 1)[-1].replace('.md', ''),
        'properties': fm,
        'property_count': len(fm),
        'has_tags': 'tags' in fm,
        'has_aliases': 'aliases' in fm
    }
    # Extract entity type from common patterns
    if 'entityType' in fm:
        entity['entity_type'] = fm['entityType']
    elif 'type' in fm:
        entity['entity_type'] = fm['type']
    else:
        # Infer from path
        parts = path.split('/')
        entity['entity_type'] = parts[0] if parts else 'unknown'

    entities.append(entity)

output = {
    'vault': '$VAULT',
    'total_files_with_frontmatter': len(entities),
    'entities': entities
}

with open('$OUT/frontmatter-entities.json', 'w') as f:
    json.dump(output, f, indent=2)

# Stats
type_counts = {}
for e in entities:
    t = e.get('entity_type', 'unknown')
    type_counts[t] = type_counts.get(t, 0) + 1

print(f'Files with frontmatter: {len(entities)}')
print(f'Entity types found:')
for t, c in sorted(type_counts.items(), key=lambda x: x[1], reverse=True)[:15]:
    print(f'  {t}: {c}')
"

log info "Frontmatter export complete. Output: $OUT/"
log info "  frontmatter-all.json       (raw frontmatter by path)"
log info "  frontmatter-entities.json  (normalized entities)"
