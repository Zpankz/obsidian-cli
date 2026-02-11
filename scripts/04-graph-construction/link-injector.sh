#!/usr/bin/env bash
# =============================================================================
# link-injector.sh - Add wikilinks to existing notes
# =============================================================================
# Phase 4: Graph Construction
#
# Injects wikilinks into existing notes to build graph connections.
# Supports multiple injection strategies:
#   - Append "See also" section with related links
#   - Prepend related links after frontmatter
#   - Insert links at specific heading sections
#
# Usage:
#   ./link-injector.sh --vault <name> --input <file> [--output <dir>]
#                      [--strategy <append|prepend>] [--section <heading>]
#                      [--dry-run]
#
# Options:
#   --input <file>       JSON file mapping source files to target links
#   --strategy <type>    append (default) or prepend
#   --section <heading>  Heading name to inject under (e.g. "Related")
#
# Input JSON format:
#   {
#     "source-file.md": ["target1", "target2", "target3"],
#     "other-file.md": ["target4"]
#   }
#
# Outputs:
#   output/04-construction/link-inject-log.json  - Injection results
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

INPUT_FILE=""
STRATEGY="append"
SECTION_HEADING="See also"

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)    INPUT_FILE="$2";      shift 2 ;;
    --strategy) STRATEGY="$2";        shift 2 ;;
    --section)  SECTION_HEADING="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

[[ -z "$INPUT_FILE" ]] && die "Missing required --input <file>"
[[ ! -f "$INPUT_FILE" ]] && die "Input file not found: $INPUT_FILE"

OUT=$(ensure_output_dir "04-construction")

log info "=== Link Injector: $VAULT ==="
log info "Strategy: $STRATEGY"
log info "Input: $INPUT_FILE"

# ---------------------------------------------------------------------------
# 1. Process link injection map
# ---------------------------------------------------------------------------
python3 << 'PYTHON_SCRIPT'
import json
import subprocess
import os
import sys
import time

vault = os.environ.get("VAULT", "")
obsidian_bin = os.environ.get("OBSIDIAN_BIN", "obsidian")
input_file = """INPUT_FILE"""
strategy = """STRATEGY"""
section_heading = """SECTION_HEADING"""
output_dir = """OUT"""
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

with open(input_file) as f:
    link_map = json.load(f)

results = []
total = len(link_map)

for i, (source, targets) in enumerate(link_map.items()):
    # Build wikilinks
    wikilinks = ' | '.join(f'[[{t}]]' for t in targets)

    if strategy == 'append':
        content = f"\\n\\n## {section_heading}\\n\\n{wikilinks}"
        cmd = f'append path="{source}" content="{content}"'
    elif strategy == 'prepend':
        content = f"{section_heading}: {wikilinks}\\n\\n"
        cmd = f'prepend path="{source}" content="{content}"'
    else:
        content = f"\\n\\n## {section_heading}\\n\\n{wikilinks}"
        cmd = f'append path="{source}" content="{content}"'

    output = obs_cli(cmd)
    status = 'injected' if output is not None else 'failed'

    results.append({
        'source': source,
        'targets': targets,
        'target_count': len(targets),
        'strategy': strategy,
        'status': status
    })

    if (i + 1) % 10 == 0 or i == total - 1:
        print(f'  Progress: {i + 1}/{total}', file=sys.stderr)

    time.sleep(float(os.environ.get('BATCH_DELAY', '0.05')))

log_data = {
    'vault': vault,
    'strategy': strategy,
    'total_files': total,
    'injected': sum(1 for r in results if r['status'] == 'injected'),
    'failed': sum(1 for r in results if r['status'] == 'failed'),
    'total_links_added': sum(r['target_count'] for r in results if r['status'] == 'injected'),
    'results': results
}

with open(os.path.join(output_dir, 'link-inject-log.json'), 'w') as f:
    json.dump(log_data, f, indent=2)

print(f"\nInjected links in {log_data['injected']}/{total} files")
print(f"Total links added: {log_data['total_links_added']}")
PYTHON_SCRIPT

log info "Link injection complete. Output: $OUT/link-inject-log.json"
