#!/usr/bin/env bash
# =============================================================================
# semantic-linker.sh - Content-based similarity linking
# =============================================================================
# Phase 7: Evolution (DeepGraph integration)
#
# Builds an inverted term index from note content, computes pairwise Jaccard
# similarity, and suggests links between semantically related notes that
# aren't yet connected. Uses wikilinks, tags, and key terms as features.
#
# Usage:
#   ./semantic-linker.sh --vault <name> [--threshold <float>]
#                        [--max-links <n>] [--path <folder>] [--output <dir>]
#
# Options:
#   --threshold <float>   Minimum Jaccard similarity (default: 0.15)
#   --max-links <n>       Max suggestions per note (default: 5)
#   --path <folder>       Restrict to notes in this folder
#   --auto-link           Generate link-map and inject via link-injector.sh
#
# Outputs:
#   output/07-evolution/semantic-similarities.json   - Pairwise similarities
#   output/07-evolution/semantic-link-map.json       - Link-injector format
#   output/07-evolution/term-index-stats.json        - Term index statistics
#
# Requires: python3
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

SIM_THRESHOLD=0.15
MAX_LINKS=5
FILTER_PATH=""
AUTO_LINK=false

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) SIM_THRESHOLD="$2"; shift 2 ;;
    --max-links) MAX_LINKS="$2";     shift 2 ;;
    --path)      FILTER_PATH="$2";   shift 2 ;;
    --auto-link) AUTO_LINK=true;     shift   ;;
    *) shift ;;
  esac
done

require_vault
check_python3

OUT=$(ensure_output_dir "07-evolution")

log info "=== Semantic Linker: $VAULT ==="
log info "Similarity threshold: $SIM_THRESHOLD, max links/note: $MAX_LINKS"

# ---------------------------------------------------------------------------
# 1. Export metadata cache (frontmatter, links, tags per file)
# ---------------------------------------------------------------------------
log info "Exporting metadata cache..."

CACHE_JS='
(function() {
  const cache = app.metadataCache;
  const files = app.vault.getMarkdownFiles();
  const result = {};
  for (const file of files) {
    const fm = cache.getFileCache(file);
    if (!fm) continue;
    const entry = { path: file.path, tags: [], links: [], headings: [] };
    if (fm.tags) entry.tags = fm.tags.map(t => t.tag);
    if (fm.links) entry.links = fm.links.map(l => l.link);
    if (fm.headings) entry.headings = fm.headings.map(h => h.heading);
    if (fm.frontmatter) {
      entry.fm_keys = Object.keys(fm.frontmatter).filter(k => k !== "position");
    }
    result[file.path] = entry;
  }
  return JSON.stringify(result);
})()
'

CACHE_JSON=$(obs_eval "$CACHE_JS")

if [[ -z "$CACHE_JSON" || "$CACHE_JSON" == "null" || "$CACHE_JSON" == "{}" ]]; then
  die "No metadata cache available. Is the vault open?"
fi

# Also get resolved links for "already linked" filtering
LINKS_JSON=$(obs_eval 'JSON.stringify(app.metadataCache.resolvedLinks)')

# ---------------------------------------------------------------------------
# 2. Build term index and compute similarities
# ---------------------------------------------------------------------------
log info "Building term index and computing similarities..."

python3 << 'PYEOF' "$CACHE_JSON" "$LINKS_JSON" "$OUT" "$SIM_THRESHOLD" "$MAX_LINKS" "$FILTER_PATH"
import json
import sys
import re
from collections import defaultdict

cache_json = sys.argv[1]
links_json = sys.argv[2]
out_dir = sys.argv[3]
sim_threshold = float(sys.argv[4])
max_links = int(sys.argv[5])
filter_path = sys.argv[6] if len(sys.argv) > 6 else ""

cache = json.loads(cache_json)
resolved = json.loads(links_json) if links_json and links_json != "null" else {}

# ---- Filter by path if specified ----
if filter_path:
    cache = {p: v for p, v in cache.items() if p.startswith(filter_path)}

print(f"Processing {len(cache)} notes...", file=sys.stderr)

# ---- Build existing link set ----
existing_links = set()
for src, targets in resolved.items():
    for tgt in targets:
        existing_links.add((src, tgt))

# ---- Extract feature terms per note ----
def extract_terms(entry):
    """Extract feature terms from a note's metadata."""
    terms = set()

    # Tags (strong signal)
    for tag in entry.get("tags", []):
        terms.add(f"tag:{tag.lstrip('#')}")

    # Wikilinks (the notes this file links to)
    for link in entry.get("links", []):
        terms.add(f"link:{link}")

    # Headings (topic indicators)
    for heading in entry.get("headings", []):
        # Split heading into words, keep meaningful ones
        words = re.findall(r'[A-Za-z]{3,}', heading)
        for w in words:
            terms.add(f"heading:{w.lower()}")

    # Frontmatter keys (structural signal)
    for key in entry.get("fm_keys", []):
        terms.add(f"fmkey:{key}")

    # Folder path components (contextual signal)
    path = entry.get("path", "")
    parts = path.split("/")[:-1]  # exclude filename
    for part in parts:
        terms.add(f"folder:{part}")

    return terms

note_terms = {}
term_index = defaultdict(set)  # term -> set of note paths

for path, entry in cache.items():
    terms = extract_terms(entry)
    note_terms[path] = terms
    for term in terms:
        term_index[term].add(path)

# ---- Term index statistics ----
term_stats = {
    "total_notes": len(note_terms),
    "total_unique_terms": len(term_index),
    "term_type_counts": {},
    "top_terms": []
}

type_counts = defaultdict(int)
for term in term_index:
    prefix = term.split(":")[0]
    type_counts[prefix] += 1
term_stats["term_type_counts"] = dict(type_counts)

top_terms = sorted(term_index.items(), key=lambda x: len(x[1]), reverse=True)[:30]
term_stats["top_terms"] = [{"term": t, "note_count": len(ns)} for t, ns in top_terms]

with open(f"{out_dir}/term-index-stats.json", "w") as f:
    json.dump(term_stats, f, indent=2)

# ---- Compute pairwise Jaccard similarity ----
# Optimization: only compare notes that share at least one term
note_paths = sorted(note_terms.keys())
similarities = []
link_suggestions = defaultdict(list)  # note -> [(target, score), ...]

checked = set()
for term, members in term_index.items():
    member_list = sorted(members)
    for i, note_a in enumerate(member_list):
        for note_b in member_list[i+1:]:
            pair = (note_a, note_b)
            if pair in checked:
                continue
            checked.add(pair)

            terms_a = note_terms[note_a]
            terms_b = note_terms[note_b]

            intersection = len(terms_a & terms_b)
            union = len(terms_a | terms_b)
            jaccard = intersection / union if union > 0 else 0

            if jaccard < sim_threshold:
                continue

            # Check if already linked (either direction)
            already_linked = (
                (note_a, note_b) in existing_links or
                (note_b, note_a) in existing_links
            )

            if already_linked:
                continue

            # Shared terms breakdown
            shared = terms_a & terms_b
            shared_by_type = defaultdict(list)
            for t in shared:
                prefix, value = t.split(":", 1)
                shared_by_type[prefix].append(value)

            entry = {
                "source": note_a,
                "target": note_b,
                "jaccard": round(jaccard, 4),
                "shared_terms": intersection,
                "total_terms": union,
                "shared_by_type": dict(shared_by_type)
            }
            similarities.append(entry)

            link_suggestions[note_a].append((note_b, jaccard))
            link_suggestions[note_b].append((note_a, jaccard))

# Sort by similarity descending
similarities.sort(key=lambda x: x["jaccard"], reverse=True)

# ---- Build link map (top N per note) ----
link_map = {}
for note, candidates in link_suggestions.items():
    candidates.sort(key=lambda x: x[1], reverse=True)
    top = candidates[:max_links]
    if top:
        # Strip .md for wikilink targets
        link_map[note] = [tgt.replace(".md", "") for tgt, _ in top]

# ---- Output ----
result = {
    "total_notes_analyzed": len(note_terms),
    "similarity_threshold": sim_threshold,
    "total_similar_pairs": len(similarities),
    "notes_with_suggestions": len(link_map),
    "total_suggested_links": sum(len(v) for v in link_map.values()),
    "top_similarities": similarities[:100]
}

with open(f"{out_dir}/semantic-similarities.json", "w") as f:
    json.dump(result, f, indent=2)

with open(f"{out_dir}/semantic-link-map.json", "w") as f:
    json.dump(link_map, f, indent=2)

print(f"Similar pairs found: {len(similarities)}")
print(f"Notes with suggestions: {len(link_map)}")
print(f"Total suggested links: {sum(len(v) for v in link_map.values())}")
if similarities:
    top = similarities[0]
    print(f"Top pair: {top['source']} <-> {top['target']} (Jaccard={top['jaccard']})")
PYEOF

# ---------------------------------------------------------------------------
# 3. Optionally inject links
# ---------------------------------------------------------------------------
if [[ "$AUTO_LINK" == "true" ]]; then
  log info "Auto-linking enabled. Injecting semantic links..."
  if [[ -f "$SCRIPT_DIR/../04-graph-construction/link-injector.sh" ]]; then
    bash "$SCRIPT_DIR/../04-graph-construction/link-injector.sh" \
      --vault "$VAULT" --input "$OUT/semantic-link-map.json" --strategy append
  else
    log warn "link-injector.sh not found. Link map saved to: $OUT/semantic-link-map.json"
  fi
fi

log info "Semantic linking complete."
log info "  Similarities: $OUT/semantic-similarities.json"
log info "  Link map: $OUT/semantic-link-map.json"
log info "  Term stats: $OUT/term-index-stats.json"
