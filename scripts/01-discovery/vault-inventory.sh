#!/usr/bin/env bash
# =============================================================================
# vault-inventory.sh - Enumerate all vault files with metadata
# =============================================================================
# Phase 1: Discovery & Inventory
#
# Collects a complete inventory of the vault including:
#   - File paths, names, extensions, sizes
#   - Created/modified timestamps
#   - Folder structure
#   - File type distribution
#
# Usage:
#   ./vault-inventory.sh --vault <name> [--output <dir>]
#
# Outputs:
#   output/01-discovery/vault-inventory.json   - Full file inventory
#   output/01-discovery/folder-tree.txt        - Folder hierarchy
#   output/01-discovery/file-type-stats.json   - Extension distribution
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"
parse_common_args "$@"
require_vault

OUT=$(ensure_output_dir "01-discovery")

log info "=== Vault Inventory: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Basic vault stats
# ---------------------------------------------------------------------------
log info "Collecting vault statistics..."
vault_size=$(obs_cli "vault info=size" | tr -d '[:space:]')
file_count=$(obs_cli "files total" | tr -d '[:space:]')
md_count=$(obs_cli "files ext=md total" | tr -d '[:space:]')
folder_list=$(obs_cli "folders")

log info "Vault size: $vault_size bytes, Files: $file_count, Markdown: $md_count"

# ---------------------------------------------------------------------------
# 2. Folder tree
# ---------------------------------------------------------------------------
log info "Extracting folder structure..."
echo "$folder_list" > "$OUT/folder-tree.txt"
folder_count=$(echo "$folder_list" | grep -c . || echo 0)
log info "Folders: $folder_count"

# ---------------------------------------------------------------------------
# 3. Full file listing via eval (batch - much faster than per-file queries)
# ---------------------------------------------------------------------------
log info "Exporting full file inventory via eval..."
obs_eval "
  const files = app.vault.getFiles().map(f => ({
    path: f.path,
    name: f.name,
    extension: f.extension,
    size: f.stat?.size || 0,
    created: f.stat?.ctime || 0,
    modified: f.stat?.mtime || 0
  }));
  JSON.stringify(files);
" > "$OUT/vault-inventory.json"

# ---------------------------------------------------------------------------
# 4. File type distribution
# ---------------------------------------------------------------------------
log info "Computing file type distribution..."
python3 -c "
import json

with open('$OUT/vault-inventory.json') as f:
    files = json.load(f)

ext_counts = {}
ext_sizes = {}
for fobj in files:
    ext = fobj.get('extension', 'none') or 'none'
    ext_counts[ext] = ext_counts.get(ext, 0) + 1
    ext_sizes[ext] = ext_sizes.get(ext, 0) + fobj.get('size', 0)

stats = {
    'vault_name': '$VAULT',
    'total_files': len(files),
    'total_size_bytes': sum(f.get('size', 0) for f in files),
    'folder_count': $folder_count,
    'extensions': sorted(
        [{'extension': k, 'count': v, 'total_bytes': ext_sizes[k]}
         for k, v in ext_counts.items()],
        key=lambda x: x['count'], reverse=True
    )
}

with open('$OUT/file-type-stats.json', 'w') as f:
    json.dump(stats, f, indent=2)

print(f'File types: {len(ext_counts)}')
for item in stats['extensions'][:10]:
    print(f\"  .{item['extension']}: {item['count']} files ({item['total_bytes']:,} bytes)\")
"

log info "Inventory complete. Output: $OUT/"
log info "  vault-inventory.json  ($file_count files)"
log info "  folder-tree.txt       ($folder_count folders)"
log info "  file-type-stats.json  (type distribution)"
