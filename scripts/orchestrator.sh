#!/usr/bin/env bash
# =============================================================================
# orchestrator.sh - Master runner for knowledge graph generation pipeline
# =============================================================================
# Runs all phases of the knowledge graph generation pipeline in sequence,
# or individual phases on demand.
#
# Usage:
#   ./orchestrator.sh --vault <name> [--phases <list>] [--output <dir>]
#
# Run all phases:
#   ./orchestrator.sh --vault distil
#
# Run specific phases:
#   ./orchestrator.sh --vault distil --phases 1,3,5
#   ./orchestrator.sh --vault distil --phases discovery,analysis
#
# Phase names / numbers:
#   1 | discovery      - Vault inventory, property census, tag taxonomy
#   2 | extraction     - Frontmatter export, outline extraction, metadata cache
#   3 | relationships  - Adjacency export, backlink census, link classification
#   4 | construction   - (Interactive - requires input files)
#   5 | analysis       - Network metrics, hub/authority report, health report
#   6 | maintenance    - Orphan linker, broken link fixer, deadend enricher
#   7 | evolution      - (Interactive - requires parameters)
#
# Options:
#   --vault <name>     Obsidian vault name (required)
#   --phases <list>    Comma-separated phase numbers or names (default: all read-only)
#   --output <dir>     Output directory (default: ./output)
#   --dry-run          Print commands without executing
#   --debug            Enable debug logging
#   --quiet            Suppress non-error output
#
# Environment:
#   VAULT              Alternative to --vault flag
#   OBSIDIAN_BIN       Path to obsidian binary (default: obsidian)
#   OUTPUT_DIR         Alternative to --output flag
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/obsidian_cli.sh"

PHASES=""

parse_common_args "$@"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --phases) PHASES="$2"; shift 2 ;;
    *) shift ;;
  esac
done

require_vault

# Default: run all read-only phases (1,2,3,5,6)
if [[ -z "$PHASES" ]]; then
  PHASES="1,2,3,5,6"
fi

# ---------------------------------------------------------------------------
# Phase execution
# ---------------------------------------------------------------------------
run_phase() {
  local phase="$1"
  local phase_name="$2"
  local start_time
  start_time=$(date +%s)

  echo ""
  echo "=================================================================="
  echo "  PHASE $phase: $phase_name"
  echo "=================================================================="
  echo ""

  shift 2
  local scripts=("$@")
  local failed=0

  for script in "${scripts[@]}"; do
    local script_name
    script_name=$(basename "$script" .sh)
    log info "--- Running: $script_name ---"

    if bash "$script" --vault "$VAULT" --output "$OUTPUT_DIR" ${DRY_RUN:+--dry-run} ${LOG_LEVEL:+--$( [[ "$LOG_LEVEL" == "debug" ]] && echo "debug" || echo "")}; then
      log info "--- $script_name: DONE ---"
    else
      log error "--- $script_name: FAILED ---"
      ((failed++))
    fi
    echo ""
  done

  local end_time
  end_time=$(date +%s)
  local duration=$(( end_time - start_time ))

  if (( failed > 0 )); then
    log warn "Phase $phase completed with $failed failures in ${duration}s"
  else
    log info "Phase $phase completed successfully in ${duration}s"
  fi

  return "$failed"
}

should_run() {
  local phase_num="$1"
  local phase_name="$2"

  # Check if this phase is in the requested list
  IFS=',' read -ra requested <<< "$PHASES"
  for req in "${requested[@]}"; do
    req=$(echo "$req" | xargs)  # trim whitespace
    if [[ "$req" == "$phase_num" || "$req" == "$phase_name" || "$req" == "all" ]]; then
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Pipeline execution
# ---------------------------------------------------------------------------
PIPELINE_START=$(date +%s)
TOTAL_FAILURES=0

log info "=== Knowledge Graph Pipeline: $VAULT ==="
log info "Phases: $PHASES"
log info "Output: $OUTPUT_DIR"
echo ""

# Phase 1: Discovery & Inventory
if should_run 1 discovery; then
  run_phase 1 "Discovery & Inventory" \
    "$SCRIPT_DIR/01-discovery/vault-inventory.sh" \
    "$SCRIPT_DIR/01-discovery/property-census.sh" \
    "$SCRIPT_DIR/01-discovery/tag-taxonomy.sh" \
    || ((TOTAL_FAILURES++))
fi

# Phase 2: Entity Extraction
if should_run 2 extraction; then
  run_phase 2 "Entity Extraction" \
    "$SCRIPT_DIR/02-extraction/frontmatter-export.sh" \
    "$SCRIPT_DIR/02-extraction/outline-extractor.sh" \
    "$SCRIPT_DIR/02-extraction/metadata-cache-dump.sh" \
    || ((TOTAL_FAILURES++))
fi

# Phase 3: Relationship Mapping
if should_run 3 relationships; then
  run_phase 3 "Relationship Mapping" \
    "$SCRIPT_DIR/03-relationship-mapping/adjacency-export.sh" \
    "$SCRIPT_DIR/03-relationship-mapping/backlink-census.sh" \
    "$SCRIPT_DIR/03-relationship-mapping/link-type-classifier.sh" \
    || ((TOTAL_FAILURES++))
fi

# Phase 4: Graph Construction (interactive)
if should_run 4 construction; then
  log warn "Phase 4 (Construction) requires input files."
  log warn "Use individual scripts directly:"
  log warn "  batch-note-creator.sh --input <file>"
  log warn "  link-injector.sh --input <file>"
  log warn "  property-tagger.sh --name <prop> --value <val> --query <q>"
fi

# Phase 5: Graph Analysis
if should_run 5 analysis; then
  run_phase 5 "Graph Analysis" \
    "$SCRIPT_DIR/05-analysis/network-metrics.sh" \
    "$SCRIPT_DIR/05-analysis/hub-authority-report.sh" \
    "$SCRIPT_DIR/05-analysis/graph-health-report.sh" \
    || ((TOTAL_FAILURES++))
fi

# Phase 6: Maintenance
if should_run 6 maintenance; then
  run_phase 6 "Maintenance" \
    "$SCRIPT_DIR/06-maintenance/orphan-linker.sh" \
    "$SCRIPT_DIR/06-maintenance/broken-link-fixer.sh" \
    "$SCRIPT_DIR/06-maintenance/deadend-enricher.sh" \
    || ((TOTAL_FAILURES++))
fi

# Phase 7: Evolution (interactive)
if should_run 7 evolution; then
  log warn "Phase 7 (Evolution) requires parameters."
  log warn "Use individual scripts directly:"
  log warn "  note-decomposer.sh --file <path>"
  log warn "  small-world-optimizer.sh [--beta <float>]"
  log warn "  cluster-bridge-builder.sh [--auto-create]"
fi

# ---------------------------------------------------------------------------
# Pipeline summary
# ---------------------------------------------------------------------------
PIPELINE_END=$(date +%s)
PIPELINE_DURATION=$(( PIPELINE_END - PIPELINE_START ))

echo ""
echo "=================================================================="
echo "  PIPELINE COMPLETE"
echo "=================================================================="
echo ""
log info "Total time: ${PIPELINE_DURATION}s"
log info "Output directory: $OUTPUT_DIR"

if (( TOTAL_FAILURES > 0 )); then
  log warn "Completed with $TOTAL_FAILURES phase failure(s)"
  exit 1
else
  log info "All phases completed successfully"
fi

# List output files
echo ""
log info "Generated files:"
if command -v find &>/dev/null; then
  find "$OUTPUT_DIR" -type f \( -name "*.json" -o -name "*.txt" -o -name "*.csv" \) 2>/dev/null | sort | while read -r f; do
    size=$(wc -c < "$f" 2>/dev/null | xargs)
    echo "  $f ($size bytes)"
  done
fi
