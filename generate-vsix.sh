#!/usr/bin/env bash
# generate-vsix.sh
# Builds .vsix extension files from source repos and places them in vsix/.
#
# Usage:
#   bash generate-vsix.sh
#   bash generate-vsix.sh --salesforcedx-vscode /path/to/local/clone
#   bash generate-vsix.sh --einstein-gpt /path/to/local/clone
#
# By default, repos are cloned fresh into a temp directory.
# Use --<name> flags to point at existing local clones instead.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
info() { echo -e "${BLUE}   ·${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
VSIX_DIR="$SCRIPT_DIR/vsix"

# Repos
SALESFORCEDX_VSCODE_REPO="forcedotcom/salesforcedx-vscode"
EINSTEIN_GPT_REPO="forcedotcom/einstein-gpt-for-vscode"

# Local path overrides
LOCAL_SALESFORCEDX_VSCODE=""
LOCAL_EINSTEIN_GPT=""

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --salesforcedx-vscode)
      [[ -z "${2:-}" ]] && die "--salesforcedx-vscode requires a path"
      LOCAL_SALESFORCEDX_VSCODE="$2"; shift 2 ;;
    --einstein-gpt)
      [[ -z "${2:-}" ]] && die "--einstein-gpt requires a path"
      LOCAL_EINSTEIN_GPT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: bash generate-vsix.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --salesforcedx-vscode PATH   Use local clone of $SALESFORCEDX_VSCODE_REPO"
      echo "  --einstein-gpt PATH          Use local clone of $EINSTEIN_GPT_REPO"
      echo "  -h, --help                   Show this help"
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
  local repo="$1" local_path="$2"

  if [[ -n "$local_path" ]]; then
    [[ -d "$local_path" ]] || die "Local path does not exist: $local_path"
    echo "$local_path"
    return
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  TMPDIRS+=("$tmpdir")

  log "Cloning $repo..."
  gh repo clone "$repo" "$tmpdir/repo" -- --depth 1 || {
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

# ── salesforcedx-vscode (monorepo) ───────────────────────────────────────────
log "Preparing $SALESFORCEDX_VSCODE_REPO..."
SDXV_DIR=$(prepare_repo "$SALESFORCEDX_VSCODE_REPO" "$LOCAL_SALESFORCEDX_VSCODE")

if [[ -n "$SDXV_DIR" ]]; then
  log "Installing dependencies..."
  if [[ -f "$SDXV_DIR/yarn.lock" ]]; then
    (cd "$SDXV_DIR" && yarn install --frozen-lockfile) || die "yarn install failed for salesforcedx-vscode"
  else
    (cd "$SDXV_DIR" && npm ci) || die "npm ci failed for salesforcedx-vscode"
  fi

  log "Building..."
  if [[ -f "$SDXV_DIR/yarn.lock" ]]; then
    (cd "$SDXV_DIR" && yarn build) || die "Build failed for salesforcedx-vscode"
  else
    (cd "$SDXV_DIR" && npm run build) || die "Build failed for salesforcedx-vscode"
  fi

  # Package each extension in packages/
  if [[ -d "$SDXV_DIR/packages" ]]; then
    for ext_dir in "$SDXV_DIR"/packages/*/; do
      package_extension "$ext_dir"
    done
  else
    # Single extension repo
    package_extension "$SDXV_DIR"
  fi
fi

# ── einstein-gpt-for-vscode ─────────────────────────────────────────────────
log "Preparing $EINSTEIN_GPT_REPO..."
EGPT_DIR=$(prepare_repo "$EINSTEIN_GPT_REPO" "$LOCAL_EINSTEIN_GPT")

if [[ -n "$EGPT_DIR" ]]; then
  log "Installing dependencies..."
  if [[ -f "$EGPT_DIR/yarn.lock" ]]; then
    (cd "$EGPT_DIR" && yarn install --frozen-lockfile) || die "yarn install failed for einstein-gpt"
  else
    (cd "$EGPT_DIR" && npm ci) || die "npm ci failed for einstein-gpt"
  fi

  log "Building..."
  if [[ -f "$EGPT_DIR/yarn.lock" ]]; then
    (cd "$EGPT_DIR" && yarn build) || die "Build failed for einstein-gpt"
  else
    (cd "$EGPT_DIR" && npm run build) || die "Build failed for einstein-gpt"
  fi

  # Package — could be monorepo or single
  if [[ -d "$EGPT_DIR/packages" ]]; then
    for ext_dir in "$EGPT_DIR"/packages/*/; do
      package_extension "$ext_dir"
    done
  else
    package_extension "$EGPT_DIR"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
vsix_total=$(find "$VSIX_DIR" -name '*.vsix' | wc -l | tr -d ' ')
log "Generated $vsix_total VSIX file(s) in: $VSIX_DIR"
ls -1 "$VSIX_DIR"/*.vsix 2>/dev/null | while read -r f; do info "$(basename "$f")"; done
