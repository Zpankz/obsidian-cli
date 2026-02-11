#!/usr/bin/env bash
# =============================================================================
# obsidian_cli.sh - Shared library for Obsidian CLI knowledge graph scripts
# =============================================================================
# Source this file in any script: source "$(dirname "$0")/../lib/obsidian_cli.sh"
#
# Provides:
#   - CLI wrapper with output parsing and error handling
#   - Vault configuration
#   - Logging utilities
#   - Output format helpers (JSON, TSV, CSV)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment or .env file)
# ---------------------------------------------------------------------------
VAULT="${VAULT:-}"
OBSIDIAN_BIN="${OBSIDIAN_BIN:-obsidian}"
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/output}"
LOG_LEVEL="${LOG_LEVEL:-info}"    # debug | info | warn | error
DRY_RUN="${DRY_RUN:-false}"
PARALLEL_WORKERS="${PARALLEL_WORKERS:-4}"
BATCH_DELAY="${BATCH_DELAY:-0.05}"  # seconds between CLI calls

# Timestamp prefix regex (Obsidian CLI prepends a loading line)
_TS_REGEX='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} '

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_log_levels=(debug info warn error)

_level_num() {
  local lvl="$1"
  for i in "${!_log_levels[@]}"; do
    [[ "${_log_levels[$i]}" == "$lvl" ]] && echo "$i" && return
  done
  echo 1  # default: info
}

log() {
  local level="$1"; shift
  local current_num; current_num=$(_level_num "$LOG_LEVEL")
  local msg_num;     msg_num=$(_level_num "$level")
  (( msg_num >= current_num )) || return 0
  local ts; ts=$(date '+%Y-%m-%d %H:%M:%S')
  local prefix
  case "$level" in
    debug) prefix="\033[36m[DEBUG]\033[0m" ;;
    info)  prefix="\033[32m[INFO]\033[0m"  ;;
    warn)  prefix="\033[33m[WARN]\033[0m"  ;;
    error) prefix="\033[31m[ERROR]\033[0m" ;;
  esac
  echo -e "${prefix} ${ts} $*" >&2
}

die() { log error "$@"; exit 1; }

# ---------------------------------------------------------------------------
# Vault validation
# ---------------------------------------------------------------------------
require_vault() {
  if [[ -z "$VAULT" ]]; then
    die "VAULT is not set. Export VAULT=<name> or pass --vault <name>."
  fi
}

# ---------------------------------------------------------------------------
# Output directory setup
# ---------------------------------------------------------------------------
ensure_output_dir() {
  local subdir="${1:-}"
  local target="$OUTPUT_DIR"
  [[ -n "$subdir" ]] && target="$OUTPUT_DIR/$subdir"
  mkdir -p "$target"
  echo "$target"
}

# ---------------------------------------------------------------------------
# Core CLI wrapper
# ---------------------------------------------------------------------------
# obs_cli <command...>
#   Runs obsidian CLI with vault parameter, strips timestamp prefix lines,
#   checks for errors, and returns clean output.
#
# Returns: 0 on success, 1 on error
# Outputs: clean CLI output on stdout, errors on stderr
obs_cli() {
  require_vault
  local cmd="$*"

  if [[ "$DRY_RUN" == "true" ]]; then
    log debug "[DRY RUN] $OBSIDIAN_BIN $cmd vault=$VAULT"
    return 0
  fi

  log debug "Running: $OBSIDIAN_BIN $cmd vault=$VAULT"

  local raw_output
  raw_output=$("$OBSIDIAN_BIN" $cmd vault="$VAULT" 2>&1) || true

  # Strip timestamp prefix lines
  local clean_output
  clean_output=$(echo "$raw_output" | grep -vE "$_TS_REGEX" || true)

  # Check for error responses
  if echo "$clean_output" | grep -q '^Error:'; then
    log error "CLI error: $clean_output"
    echo "$clean_output" >&2
    return 1
  fi

  echo "$clean_output"
}

# obs_eval <javascript_code>
#   Runs obsidian eval with the given JS code, strips the "=> " prefix.
obs_eval() {
  local code="$1"
  local result
  result=$(obs_cli "eval code=\"$code\"") || return 1
  # Strip the "=> " prefix from eval output
  echo "$result" | sed 's/^=> //'
}

# ---------------------------------------------------------------------------
# Batch processing helpers
# ---------------------------------------------------------------------------

# run_parallel <func_name> <file_with_args>
#   Runs func_name for each line in file_with_args, up to PARALLEL_WORKERS
#   at a time.
run_parallel() {
  local func="$1"
  local args_file="$2"
  local pids=()
  local running=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    "$func" "$line" &
    pids+=($!)
    ((running++))

    if (( running >= PARALLEL_WORKERS )); then
      wait "${pids[0]}" 2>/dev/null || true
      pids=("${pids[@]:1}")
      ((running--))
    fi

    sleep "$BATCH_DELAY"
  done < "$args_file"

  # Wait for remaining
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
}

# ---------------------------------------------------------------------------
# Output formatting helpers
# ---------------------------------------------------------------------------

# to_json_array <file_with_lines>
#   Converts newline-separated values to a JSON array.
to_json_array() {
  local input="${1:--}"
  if [[ "$input" == "-" ]]; then
    python3 -c "
import sys, json
lines = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps(lines, indent=2))
"
  else
    python3 -c "
import json
with open('$input') as f:
    lines = [l.strip() for l in f if l.strip()]
print(json.dumps(lines, indent=2))
"
  fi
}

# tsv_to_json <file.tsv> [header_line]
#   Converts TSV to JSON array of objects. If header_line is provided,
#   uses it as column names; otherwise uses first line.
tsv_to_json() {
  local file="$1"
  local header="${2:-}"
  python3 -c "
import csv, json, sys
with open('$file') as f:
    reader = csv.DictReader(f, delimiter='\t', fieldnames=$( [[ -n "$header" ]] && echo "\"$header\".split('\t')" || echo "None" ))
    rows = list(reader)
print(json.dumps(rows, indent=2))
"
}

# ---------------------------------------------------------------------------
# Common argument parsing
# ---------------------------------------------------------------------------
parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vault)   VAULT="$2";      shift 2 ;;
      --output)  OUTPUT_DIR="$2";  shift 2 ;;
      --dry-run) DRY_RUN=true;    shift   ;;
      --debug)   LOG_LEVEL=debug;  shift   ;;
      --quiet)   LOG_LEVEL=error;  shift   ;;
      --workers) PARALLEL_WORKERS="$2"; shift 2 ;;
      --help|-h) _show_help; exit 0 ;;
      *)         break ;;
    esac
  done
}

_show_help() {
  cat <<EOF
Common options:
  --vault <name>     Obsidian vault name (or set VAULT env var)
  --output <dir>     Output directory (default: ./output)
  --dry-run          Print commands without executing
  --debug            Enable debug logging
  --quiet            Suppress non-error output
  --workers <n>      Parallel workers (default: 4)
  --help, -h         Show this help

EOF
}

# ---------------------------------------------------------------------------
# Progress indicator
# ---------------------------------------------------------------------------
progress_bar() {
  local current="$1"
  local total="$2"
  local label="${3:-Progress}"
  local pct=$(( current * 100 / total ))
  local filled=$(( pct / 2 ))
  local empty=$(( 50 - filled ))
  printf "\r%s [%-${filled}s%-${empty}s] %d/%d (%d%%)" \
    "$label" \
    "$(printf '#%.0s' $(seq 1 "$filled" 2>/dev/null) || true)" \
    "" \
    "$current" "$total" "$pct" >&2
  (( current == total )) && echo >&2
}

# ---------------------------------------------------------------------------
# File count for progress tracking
# ---------------------------------------------------------------------------
count_vault_files() {
  obs_cli "files ext=md total" | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
# require_python_module <module_name> [pip_package_name]
#   Checks that a Python module is importable. Dies with install instructions
#   if not found.
require_python_module() {
  local module="$1"
  local pip_name="${2:-$module}"
  if ! python3 -c "import $module" 2>/dev/null; then
    die "Python module '$module' not found. Install with: pip install $pip_name"
  fi
}

# check_python3
#   Verify python3 is available.
check_python3() {
  if ! command -v python3 &>/dev/null; then
    die "python3 is required but not found in PATH."
  fi
}

log info "obsidian_cli.sh loaded (vault=${VAULT:-<unset>})"
