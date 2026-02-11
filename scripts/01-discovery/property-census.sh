#!/usr/bin/env bash
# =============================================================================
# property-census.sh - Catalog all properties and their distributions
# =============================================================================
# Phase 1: Discovery & Inventory
#
# Enumerates every property used across the vault, including:
#   - Property names and usage counts
#   - Property type inference (text, list, number, etc.)
#   - Top values per property
#   - Coverage stats (% of files using each property)
#
# Usage:
#   ./property-census.sh --vault <name> [--output <dir>]
#
# Outputs:
#   output/01-discovery/property-census.json     - Full property catalog
#   output/01-discovery/property-summary.txt     - Human-readable summary
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"
parse_common_args "$@"
require_vault

OUT=$(ensure_output_dir "01-discovery")

log info "=== Property Census: $VAULT ==="

# ---------------------------------------------------------------------------
# 1. Get all properties with counts
# ---------------------------------------------------------------------------
log info "Enumerating all properties with counts..."
obs_cli "properties all counts format=yaml" > "$OUT/_raw_properties.txt"

# ---------------------------------------------------------------------------
# 2. Get total file count for coverage calculation
# ---------------------------------------------------------------------------
total_files=$(obs_cli "files ext=md total" | tr -d '[:space:]')
log info "Total markdown files: $total_files"

# ---------------------------------------------------------------------------
# 3. Export frontmatter schema via eval (batch approach)
# ---------------------------------------------------------------------------
log info "Analyzing property types and values via eval..."
obs_eval "
  const files = app.vault.getMarkdownFiles();
  const propStats = {};
  for (const file of files) {
    const cache = app.metadataCache.getCache(file.path);
    const fm = cache?.frontmatter;
    if (!fm) continue;
    for (const [key, value] of Object.entries(fm)) {
      if (key === 'position') continue;
      if (!propStats[key]) {
        propStats[key] = { count: 0, types: {}, sampleValues: [] };
      }
      propStats[key].count++;
      const t = Array.isArray(value) ? 'list' :
                typeof value === 'boolean' ? 'checkbox' :
                typeof value === 'number' ? 'number' :
                (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}/.test(value)) ? 'date' : 'text';
      propStats[key].types[t] = (propStats[key].types[t] || 0) + 1;
      if (propStats[key].sampleValues.length < 5 && value !== null && value !== undefined) {
        const sv = Array.isArray(value) ? value.slice(0, 3).join(', ') : String(value).slice(0, 100);
        if (!propStats[key].sampleValues.includes(sv)) propStats[key].sampleValues.push(sv);
      }
    }
  }
  JSON.stringify(propStats);
" > "$OUT/_raw_prop_stats.json"

# ---------------------------------------------------------------------------
# 4. Build structured census
# ---------------------------------------------------------------------------
log info "Building property census report..."
python3 -c "
import json

with open('$OUT/_raw_prop_stats.json') as f:
    stats = json.load(f)

total_files = $total_files
properties = []
for name, data in sorted(stats.items(), key=lambda x: x[1]['count'], reverse=True):
    primary_type = max(data['types'], key=data['types'].get) if data['types'] else 'unknown'
    properties.append({
        'name': name,
        'count': data['count'],
        'coverage_pct': round(data['count'] / total_files * 100, 1) if total_files > 0 else 0,
        'primary_type': primary_type,
        'type_distribution': data['types'],
        'sample_values': data['sampleValues']
    })

census = {
    'vault': '$VAULT',
    'total_files': total_files,
    'unique_properties': len(properties),
    'properties': properties
}

with open('$OUT/property-census.json', 'w') as f:
    json.dump(census, f, indent=2)

# Human-readable summary
with open('$OUT/property-summary.txt', 'w') as f:
    f.write(f'Property Census: $VAULT\n')
    f.write(f'={\"=\" * 50}\n')
    f.write(f'Total files: {total_files}\n')
    f.write(f'Unique properties: {len(properties)}\n\n')
    f.write(f'{\"Name\":<30} {\"Count\":>6} {\"Coverage\":>8} {\"Type\":<10}\n')
    f.write(f'{\"-\" * 60}\n')
    for p in properties[:50]:
        f.write(f\"{p['name']:<30} {p['count']:>6} {p['coverage_pct']:>7.1f}% {p['primary_type']:<10}\n\")
    if len(properties) > 50:
        f.write(f'... and {len(properties) - 50} more properties\n')

print(f'Unique properties: {len(properties)}')
for p in properties[:10]:
    print(f\"  {p['name']}: {p['count']} files ({p['coverage_pct']}%) [{p['primary_type']}]\")
"

# Cleanup temp files
rm -f "$OUT/_raw_properties.txt" "$OUT/_raw_prop_stats.json"

log info "Property census complete. Output: $OUT/"
log info "  property-census.json  (full catalog)"
log info "  property-summary.txt  (human-readable)"
