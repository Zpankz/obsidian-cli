#!/usr/bin/env bash
# =============================================================================
# batch-note-creator.sh - Create notes from CSV/JSON with properties
# =============================================================================
# Phase 4: Graph Construction
#
# Creates multiple notes from a structured input file (JSON or CSV),
# setting frontmatter properties and optionally injecting wikilinks.
#
# Usage:
#   ./batch-note-creator.sh --vault <name> --input <file> [--output <dir>]
#                           [--path <folder>] [--template <file>]
#
# Options:
#   --input <file>     JSON or CSV file with note definitions
#   --path <folder>    Target folder in vault (default: root)
#   --template <file>  Markdown template with {{property}} placeholders
#
# Input JSON format:
#   [
#     {
#       "name": "note-name",
#       "content": "# Title\n\nBody text with [[wikilinks]]",
#       "properties": { "type": "concept", "tags": ["tag1", "tag2"] }
#     }
#   ]
#
# Input CSV format:
#   name,content,type,tags
#   note-name,"# Title\n\nBody",concept,"tag1,tag2"
#
# Outputs:
#   output/04-construction/batch-create-log.json  - Creation results log
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

INPUT_FILE=""
TARGET_PATH=""
TEMPLATE_FILE=""

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)    INPUT_FILE="$2";    shift 2 ;;
    --path)     TARGET_PATH="$2";   shift 2 ;;
    --template) TEMPLATE_FILE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

[[ -z "$INPUT_FILE" ]] && die "Missing required --input <file>"
[[ ! -f "$INPUT_FILE" ]] && die "Input file not found: $INPUT_FILE"

OUT=$(ensure_output_dir "04-construction")

log info "=== Batch Note Creator: $VAULT ==="
log info "Input: $INPUT_FILE"
[[ -n "$TARGET_PATH" ]] && log info "Target path: $TARGET_PATH"

# ---------------------------------------------------------------------------
# 1. Parse input and create notes
# ---------------------------------------------------------------------------
python3 << 'PYTHON_SCRIPT'
import json
import csv
import subprocess
import sys
import os
import time

vault = os.environ.get("VAULT", "")
obsidian_bin = os.environ.get("OBSIDIAN_BIN", "obsidian")
input_file = """INPUT_FILE"""
target_path = """TARGET_PATH"""
template_file = """TEMPLATE_FILE"""
output_dir = """OUT"""
dry_run = os.environ.get("DRY_RUN", "false") == "true"

def obs_cli(cmd):
    """Run obsidian CLI command and return output."""
    full_cmd = f'{obsidian_bin} {cmd} vault={vault}'
    if dry_run:
        print(f'[DRY RUN] {full_cmd}', file=sys.stderr)
        return ''
    try:
        result = subprocess.run(full_cmd, shell=True, capture_output=True, text=True, timeout=10)
        output = result.stdout.strip()
        # Strip timestamp lines
        lines = [l for l in output.split('\n')
                 if not (len(l) > 19 and l[4] == '-' and l[7] == '-' and l[10] == ' ')]
        clean = '\n'.join(lines).strip()
        if clean.startswith('Error:'):
            print(f'CLI error: {clean}', file=sys.stderr)
            return None
        return clean
    except Exception as e:
        print(f'Exception: {e}', file=sys.stderr)
        return None

def load_template():
    """Load markdown template if provided."""
    if template_file and os.path.isfile(template_file):
        with open(template_file) as f:
            return f.read()
    return None

def apply_template(template, note):
    """Replace {{property}} placeholders in template."""
    result = template
    props = note.get('properties', {})
    result = result.replace('{{name}}', note.get('name', ''))
    for key, value in props.items():
        placeholder = '{{' + key + '}}'
        if isinstance(value, list):
            result = result.replace(placeholder, ', '.join(str(v) for v in value))
        else:
            result = result.replace(placeholder, str(value))
    return result

def load_notes():
    """Load notes from JSON or CSV."""
    ext = os.path.splitext(input_file)[1].lower()
    if ext == '.json':
        with open(input_file) as f:
            return json.load(f)
    elif ext == '.csv':
        notes = []
        with open(input_file) as f:
            reader = csv.DictReader(f)
            for row in reader:
                note = {
                    'name': row.get('name', ''),
                    'content': row.get('content', ''),
                    'properties': {}
                }
                for key, value in row.items():
                    if key not in ('name', 'content'):
                        note['properties'][key] = value
                notes.append(note)
        return notes
    else:
        print(f'Unsupported input format: {ext}', file=sys.stderr)
        sys.exit(1)

# Load data
notes = load_notes()
template = load_template()
results = []

print(f'Creating {len(notes)} notes...', file=sys.stderr)

for i, note in enumerate(notes):
    name = note.get('name', f'untitled-{i}')

    # Build content
    if template:
        content = apply_template(template, note)
    else:
        content = note.get('content', f'# {name}')

    # Build CLI command
    path_arg = f'path="{target_path}"' if target_path else ''
    safe_content = content.replace('"', '\\"').replace('\n', '\\n')

    result_entry = {
        'name': name,
        'status': 'pending',
        'properties_set': []
    }

    # Create note
    output = obs_cli(f'create name="{name}" {path_arg} content="{safe_content}"')
    if output is not None:
        result_entry['status'] = 'created'

        # Set properties
        props = note.get('properties', {})
        for key, value in props.items():
            file_arg = f'file="{name}.md"' if not target_path else f'path="{target_path}/{name}.md"'
            if isinstance(value, list):
                val_str = ','.join(str(v) for v in value)
                prop_type = 'list'
            elif isinstance(value, bool):
                val_str = str(value).lower()
                prop_type = 'checkbox'
            elif isinstance(value, (int, float)):
                val_str = str(value)
                prop_type = 'number'
            else:
                val_str = str(value)
                prop_type = 'text'

            prop_output = obs_cli(f'property:set {file_arg} name="{key}" value="{val_str}" type={prop_type}')
            if prop_output is not None:
                result_entry['properties_set'].append(key)
    else:
        result_entry['status'] = 'failed'

    results.append(result_entry)

    # Progress
    if (i + 1) % 10 == 0 or i == len(notes) - 1:
        print(f'  Progress: {i + 1}/{len(notes)}', file=sys.stderr)

    time.sleep(float(os.environ.get('BATCH_DELAY', '0.05')))

# Write results log
log_data = {
    'vault': vault,
    'total_attempted': len(notes),
    'created': sum(1 for r in results if r['status'] == 'created'),
    'failed': sum(1 for r in results if r['status'] == 'failed'),
    'results': results
}

with open(os.path.join(output_dir, 'batch-create-log.json'), 'w') as f:
    json.dump(log_data, f, indent=2)

print(f"\nCreated: {log_data['created']}/{log_data['total_attempted']}")
if log_data['failed'] > 0:
    print(f"Failed: {log_data['failed']}")
PYTHON_SCRIPT

log info "Batch creation complete. Output: $OUT/batch-create-log.json"
