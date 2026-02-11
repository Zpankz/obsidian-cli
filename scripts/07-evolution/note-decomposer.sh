#!/usr/bin/env bash
# =============================================================================
# note-decomposer.sh - Split large notes into atomic notes
# =============================================================================
# Phase 7: Graph Evolution
#
# Decomposes large notes into smaller, atomic Zettelkasten-style notes:
#   1. Extracts outline structure from source note
#   2. Creates one note per top-level heading section
#   3. Links child notes back to parent (bidirectional)
#   4. Sets properties on child notes
#
# Based on the automation pattern from research/05-automation-patterns.md
#
# Usage:
#   ./note-decomposer.sh --vault <name> --file <path>
#                        [--output <dir>] [--min-level <n>] [--dry-run]
#
# Options:
#   --file <path>       Source note to decompose (vault-relative path)
#   --min-level <n>     Minimum heading level to split on (default: 2 = H2)
#   --target-path <p>   Target folder for child notes (default: same as parent)
#
# Outputs:
#   output/07-evolution/decompose-log.json  - Decomposition results
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

SOURCE_FILE=""
MIN_LEVEL=2
TARGET_PATH=""

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)        SOURCE_FILE="$2"; shift 2 ;;
    --min-level)   MIN_LEVEL="$2";   shift 2 ;;
    --target-path) TARGET_PATH="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

[[ -z "$SOURCE_FILE" ]] && die "Missing required --file <path>"

OUT=$(ensure_output_dir "07-evolution")

log info "=== Note Decomposer: $VAULT ==="
log info "Source: $SOURCE_FILE"
log info "Split level: H$MIN_LEVEL"

# ---------------------------------------------------------------------------
# 1. Read source note outline and content
# ---------------------------------------------------------------------------
log info "Reading source note structure..."

# Get outline
obs_cli "outline path=\"$SOURCE_FILE\" format=md" > "$OUT/_source_outline.md"

# Get full content
obs_cli "read path=\"$SOURCE_FILE\"" > "$OUT/_source_content.md"

# Get frontmatter
obs_eval "
  const file = app.vault.getAbstractFileByPath('$SOURCE_FILE');
  if (!file) { JSON.stringify({error: 'File not found'}); }
  else {
    const cache = app.metadataCache.getCache(file.path);
    const fm = cache?.frontmatter ? {...cache.frontmatter} : {};
    delete fm.position;
    const headings = cache?.headings || [];
    JSON.stringify({frontmatter: fm, headings, path: file.path, name: file.name});
  }
" > "$OUT/_source_meta.json"

# ---------------------------------------------------------------------------
# 2. Parse and decompose
# ---------------------------------------------------------------------------
log info "Decomposing note..."
python3 << 'PYEOF'
import json
import subprocess
import os
import sys
import re
import time

vault = os.environ.get("VAULT", "")
obsidian_bin = os.environ.get("OBSIDIAN_BIN", "obsidian")
source_file = """SOURCE_FILE"""
min_level = int("""MIN_LEVEL""")
target_path = """TARGET_PATH"""
out_dir = """OUT"""
dry_run = os.environ.get("DRY_RUN", "false") == "true"

def obs_cli(cmd):
    full_cmd = f'{obsidian_bin} {cmd} vault={vault}'
    if dry_run:
        print(f'[DRY RUN] {full_cmd}', file=sys.stderr)
        return ''
    try:
        result = subprocess.run(full_cmd, shell=True, capture_output=True, text=True, timeout=10)
        output = result.stdout.strip()
        lines = [l for l in output.split('\n')
                 if not (len(l) > 19 and l[4] == '-' and l[7] == '-' and l[10] == ' ')]
        return '\n'.join(lines).strip()
    except Exception as e:
        print(f'Exception: {e}', file=sys.stderr)
        return None

# Load source metadata
with open(f'{out_dir}/_source_meta.json') as f:
    meta = json.load(f)

if 'error' in meta:
    print(f"Error: {meta['error']}", file=sys.stderr)
    sys.exit(1)

# Load source content
with open(f'{out_dir}/_source_content.md') as f:
    content = f.read()

headings = meta['headings']
parent_name = meta['name'].replace('.md', '')
parent_path = meta['path']
parent_folder = '/'.join(parent_path.split('/')[:-1])

if not target_path:
    target_path = parent_folder

# Split content by heading level
lines = content.split('\n')
sections = []
current_section = None

for i, line in enumerate(lines):
    heading_match = re.match(r'^(#{1,6})\s+(.+)$', line)
    if heading_match:
        level = len(heading_match.group(1))
        title = heading_match.group(2).strip()

        if level <= min_level:
            if current_section:
                sections.append(current_section)
            current_section = {
                'title': title,
                'level': level,
                'content_lines': [],
                'start_line': i
            }
        elif current_section:
            current_section['content_lines'].append(line)
    elif current_section:
        current_section['content_lines'].append(line)

if current_section:
    sections.append(current_section)

# Filter out very small sections
sections = [s for s in sections if len('\n'.join(s['content_lines']).strip()) > 20]

print(f'Found {len(sections)} sections to decompose', file=sys.stderr)

# Create child notes
results = []
child_names = []

for i, section in enumerate(sections):
    # Generate note name (sanitize title)
    safe_title = re.sub(r'[^\w\s-]', '', section['title']).strip()
    safe_title = re.sub(r'[\s]+', '-', safe_title).lower()
    note_name = f"{parent_name}--{safe_title}"

    body = '\n'.join(section['content_lines']).strip()

    # Build child note content with backlink to parent
    child_content = f"# {section['title']}\n\n"
    child_content += f"Parent: [[{parent_name}]]\n\n"
    child_content += body

    result = {
        'name': note_name,
        'title': section['title'],
        'status': 'pending',
        'content_length': len(child_content),
        'properties_set': []
    }

    # Create the note
    safe_content = child_content.replace('"', '\\"').replace('\n', '\\n')
    path_arg = f'path="{target_path}"' if target_path else ''

    output = obs_cli(f'create name="{note_name}" {path_arg} content="{safe_content}"')
    if output is not None:
        result['status'] = 'created'
        child_names.append(note_name)

        # Set properties
        file_ref = f'path="{target_path}/{note_name}.md"' if target_path else f'file="{note_name}.md"'
        props = {
            'parent': parent_name,
            'decomposed_from': parent_path,
            'section_index': str(i + 1)
        }
        for key, value in props.items():
            prop_out = obs_cli(f'property:set {file_ref} name="{key}" value="{value}" type=text')
            if prop_out is not None:
                result['properties_set'].append(key)
    else:
        result['status'] = 'failed'

    results.append(result)
    time.sleep(float(os.environ.get('BATCH_DELAY', '0.05')))

# Add forward links from parent to children
if child_names and not dry_run:
    links_section = "\n\n## Decomposed Sections\n\n"
    links_section += '\n'.join(f'- [[{name}]]' for name in child_names)
    safe_links = links_section.replace('"', '\\"').replace('\n', '\\n')
    obs_cli(f'append path="{source_file}" content="{safe_links}"')

# Write log
log_data = {
    'vault': vault,
    'source_file': source_file,
    'parent_name': parent_name,
    'target_path': target_path,
    'split_level': min_level,
    'sections_found': len(sections),
    'notes_created': sum(1 for r in results if r['status'] == 'created'),
    'notes_failed': sum(1 for r in results if r['status'] == 'failed'),
    'child_notes': child_names,
    'results': results
}

with open(f'{out_dir}/decompose-log.json', 'w') as f:
    json.dump(log_data, f, indent=2)

print(f"\nDecomposed into {log_data['notes_created']} child notes")
if log_data['notes_failed'] > 0:
    print(f"Failed: {log_data['notes_failed']}")
PYEOF

# Cleanup
rm -f "$OUT/_source_outline.md" "$OUT/_source_content.md" "$OUT/_source_meta.json"

log info "Note decomposition complete. Output: $OUT/decompose-log.json"
