#!/usr/bin/env bash
# generate-vsix.sh
# Builds .vsix extension files from source repos and places them in vsix/.
#
# Usage:
#   bash generate-vsix.sh
#   bash generate-vsix.sh --local salesforcedx-vscode /path/to/local/clone
#   bash generate-vsix.sh --local einstein-gpt-for-vscode /path/to/local/clone
#
# Repos are configured in repos.conf (VSIX_REPOS array).
# By default, repos are cloned fresh into a temp directory.
# Use --local to point at existing local clones instead.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
info() { echo -e "${BLUE}   ·${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
VSIX_DIR="$SCRIPT_DIR/vsix"

# Source repos.conf
if [[ -f "$SCRIPT_DIR/repos.conf" ]]; then
  source "$SCRIPT_DIR/repos.conf"
fi

# Defaults if repos.conf not found
if [[ ${#VSIX_REPOS[@]:-0} -eq 0 ]]; then
  VSIX_REPOS=(
    "forcedotcom/salesforcedx-vscode@main"
    "forcedotcom/einstein-gpt-for-vscode@main"
  )
fi

# Helper to split "owner/repo@branch"
parse_repo() { echo "${1%%@*}"; }
parse_branch() {
  local branch="${1#*@}"
  [[ "$branch" == "$1" ]] && echo "main" || echo "$branch"
}

# Local path overrides (keyed by repo name)
declare -A LOCAL_PATHS

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      [[ -z "${2:-}" || -z "${3:-}" ]] && die "--local requires REPO_NAME and PATH arguments"
      LOCAL_PATHS["$2"]="$3"; shift 3 ;;
    -h|--help)
      echo "Usage: bash generate-vsix.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --local REPO_NAME PATH   Use local clone for a repo (e.g. --local salesforcedx-vscode /path/to/clone)"
      echo "  -h, --help               Show this help"
      echo ""
      echo "Configured VSIX repos (from repos.conf):"
      for entry in "${VSIX_REPOS[@]}"; do
        echo "  $(parse_repo "$entry") @ $(parse_branch "$entry")"
      done
      exit 0 ;;
    *)
      die "Unknown argument: $1" ;;
  esac
done

# ── Dependency check ─────────────────────────────────────────────────────────
for cmd in node npm gh; do
  command -v "$cmd" &>/dev/null || die "Missing required command: $cmd"
done

if ! command -v vsce &>/dev/null; then
  log "Installing @vscode/vsce globally..."
  npm install -g @vscode/vsce
fi

# ── Helper: clone or reuse a repo ────────────────────────────────────────────
TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

prepare_repo() {
  local repo="$1" branch="$2" local_path="$3"

  if [[ -n "$local_path" ]]; then
    [[ -d "$local_path" ]] || die "Local path does not exist: $local_path"
    echo "$local_path"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  TMPDIRS+=("$tmpdir")

  log "Cloning $repo@$branch..."
  gh repo clone "$repo" "$tmpdir/repo" -- --depth 1 --branch "$branch" || {
    warn "Could not clone $repo — skipping"
    echo ""
    return
  }
  echo "$tmpdir/repo"
}

# ── Helper: package a single extension directory ─────────────────────────────
package_extension() {
  local ext_dir="$1"
  local ext_name
  ext_name=$(basename "$ext_dir")

  if [[ ! -f "$ext_dir/package.json" ]]; then
    return
  fi

  # Skip if not a VS Code extension (no contributes or engines.vscode)
  if ! python3 -c "
import json, sys
p = json.load(open('$ext_dir/package.json'))
if 'vscode' not in p.get('engines', {}):
    sys.exit(1)
" 2>/dev/null; then
    return
  fi

  log "Packaging $ext_name..."
  (cd "$ext_dir" && vsce package --no-dependencies -o "$VSIX_DIR/") || {
    warn "Failed to package $ext_name"
    return
  }
  info "Packaged: $ext_name"
}

# ── Main ─────────────────────────────────────────────────────────────────────
mkdir -p "$VSIX_DIR"

# Clear existing vsix files
rm -f "$VSIX_DIR"/*.vsix
log "Cleared existing vsix/ contents"

# ── Build and package each VSIX repo ─────────────────────────────────────────
for vsix_entry in "${VSIX_REPOS[@]}"; do
  vsix_repo=$(parse_repo "$vsix_entry")
  vsix_branch=$(parse_branch "$vsix_entry")
  vsix_name="${vsix_repo##*/}"
  local_path="${LOCAL_PATHS[$vsix_name]:-}"

  log "Preparing $vsix_repo@$vsix_branch..."
  REPO_DIR=$(prepare_repo "$vsix_repo" "$vsix_branch" "$local_path")

  if [[ -z "$REPO_DIR" ]]; then
    continue
  fi

  log "Installing dependencies for $vsix_name..."
  if [[ -f "$REPO_DIR/yarn.lock" ]]; then
    (cd "$REPO_DIR" && yarn install --frozen-lockfile) || { warn "yarn install failed for $vsix_name — skipping"; continue; }
  else
    (cd "$REPO_DIR" && npm ci) || { warn "npm ci failed for $vsix_name — skipping"; continue; }
  fi

  log "Building $vsix_name..."
  if [[ -f "$REPO_DIR/yarn.lock" ]]; then
    (cd "$REPO_DIR" && yarn build) || { warn "Build failed for $vsix_name — skipping"; continue; }
  else
    (cd "$REPO_DIR" && npm run build) || { warn "Build failed for $vsix_name — skipping"; continue; }
  fi

  # Package each extension (monorepo with packages/ or single repo)
  if [[ -d "$REPO_DIR/packages" ]]; then
    for ext_dir in "$REPO_DIR"/packages/*/; do
      package_extension "$ext_dir"
    done
  else
    package_extension "$REPO_DIR"
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
vsix_total=$(find "$VSIX_DIR" -name '*.vsix' | wc -l | tr -d ' ')
log "Generated $vsix_total VSIX file(s) in: $VSIX_DIR"
ls -1 "$VSIX_DIR"/*.vsix 2>/dev/null | while read -r f; do info "$(basename "$f")"; done
