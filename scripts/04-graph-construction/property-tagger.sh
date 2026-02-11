#!/usr/bin/env bash
# =============================================================================
# property-tagger.sh - Batch set properties on multiple notes
# =============================================================================
# Phase 4: Graph Construction
#
# Sets frontmatter properties on multiple notes based on:
#   - Search query results (tag, path, property filters)
#   - Explicit file list
#   - Pattern matching
#
# Usage:
#   ./property-tagger.sh --vault <name> --name <prop> --value <val>
#                        [--type <text|list|number|checkbox|date>]
#                        [--query <search_query>] [--files <file_list>]
#                        [--path <folder>] [--output <dir>]
#
# Options:
#   --name <prop>     Property name to set
#   --value <val>     Property value
#   --type <type>     Property type (default: text)
#   --query <q>       Obsidian search query to find target files
#   --files <file>    Text file with one file path per line
#   --path <folder>   Apply to all files in this folder
#
# Outputs:
#   output/04-construction/property-tag-log.json  - Tagging results
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/obsidian_cli.sh"

PROP_NAME=""
PROP_VALUE=""
PROP_TYPE="text"
SEARCH_QUERY=""
FILES_LIST=""
FILTER_PATH=""

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)  PROP_NAME="$2";    shift 2 ;;
    --value) PROP_VALUE="$2";   shift 2 ;;
    --type)  PROP_TYPE="$2";    shift 2 ;;
    --query) SEARCH_QUERY="$2"; shift 2 ;;
    --files) FILES_LIST="$2";   shift 2 ;;
    --path)  FILTER_PATH="$2";  shift 2 ;;
    *) shift ;;
  esac
done

require_vault

[[ -z "$PROP_NAME" ]]  && die "Missing required --name <property>"
[[ -z "$PROP_VALUE" ]] && die "Missing required --value <value>"

OUT=$(ensure_output_dir "04-construction")

log info "=== Property Tagger: $VAULT ==="
log info "Setting: $PROP_NAME = $PROP_VALUE (type: $PROP_TYPE)"

# ---------------------------------------------------------------------------
# 1. Determine target files
# ---------------------------------------------------------------------------
TARGET_FILE=$(mktemp)
trap 'rm -f $TARGET_FILE' EXIT

if [[ -n "$FILES_LIST" && -f "$FILES_LIST" ]]; then
  log info "Using file list: $FILES_LIST"
  cp "$FILES_LIST" "$TARGET_FILE"
elif [[ -n "$SEARCH_QUERY" ]]; then
  log info "Searching for files matching: $SEARCH_QUERY"
  obs_cli "search query=\"$SEARCH_QUERY\" format=json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if isinstance(data, list):
    for f in data:
        print(f)
" > "$TARGET_FILE"
elif [[ -n "$FILTER_PATH" ]]; then
  log info "Listing files in: $FILTER_PATH"
  obs_cli "files folder=\"$FILTER_PATH\" ext=md" | while IFS= read -r line; do
    echo "$line"
  done > "$TARGET_FILE"
else
  die "Must specify one of: --query, --files, or --path"
fi

file_count=$(wc -l < "$TARGET_FILE" | tr -d '[:space:]')
log info "Target files: $file_count"

if [[ "$file_count" -eq 0 ]]; then
  log warn "No files matched. Nothing to do."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Apply property to each file
# ---------------------------------------------------------------------------
log info "Applying property to $file_count files..."

success=0
failed=0
i=0

while IFS= read -r filepath || [[ -n "$filepath" ]]; do
  filepath=$(echo "$filepath" | sed 's/^"//;s/"$//' | xargs)
  [[ -z "$filepath" ]] && continue

  ((i++))

  if [[ "$DRY_RUN" == "true" ]]; then
    log debug "[DRY RUN] property:set path=\"$filepath\" name=\"$PROP_NAME\" value=\"$PROP_VALUE\" type=$PROP_TYPE"
    ((success++))
  else
    output=$(obs_cli "property:set path=\"$filepath\" name=\"$PROP_NAME\" value=\"$PROP_VALUE\" type=$PROP_TYPE" 2>&1) || true
    if echo "$output" | grep -q '^Error:'; then
      ((failed++))
      log debug "Failed: $filepath"
    else
      ((success++))
    fi
  fi

  if (( i % 20 == 0 )) || (( i == file_count )); then
    progress_bar "$i" "$file_count" "Tagging"
  fi

  sleep "$BATCH_DELAY"
done < "$TARGET_FILE"

# ---------------------------------------------------------------------------
# 3. Write results
# ---------------------------------------------------------------------------
cat > "$OUT/property-tag-log.json" << EOF
{
  "vault": "$VAULT",
  "property": "$PROP_NAME",
  "value": "$PROP_VALUE",
  "type": "$PROP_TYPE",
  "total_files": $file_count,
  "success": $success,
  "failed": $failed,
  "query": "$SEARCH_QUERY",
  "path_filter": "$FILTER_PATH"
}
EOF

log info ""
log info "Property tagging complete."
log info "  Success: $success / $file_count"
[[ $failed -gt 0 ]] && log warn "  Failed: $failed"
log info "  Output: $OUT/property-tag-log.json"
