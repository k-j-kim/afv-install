#!/usr/bin/env bash
# generate-vsix.sh
# Builds .vsix extension files from source repos and places them in vsix/.
#
# Usage:
#   bash generate-vsix.sh
#   bash generate-vsix.sh --local salesforcedx-vscode /path/to/local/clone
#
# Repos are configured in repos.conf (VSIX_REPOS and VSIX_DEPS arrays).
# By default, repos are cloned fresh into a shared temp workspace.
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
    "forcedotcom/salesforcedx-vscode-einstein-gpt@main"
  )
fi
if [[ ${#VSIX_DEPS[@]:-0} -eq 0 ]]; then
  VSIX_DEPS=(
    "forcedotcom/cline-fork@agenticChat"
  )
fi

# Helper to split "owner/repo@branch"
parse_repo() { echo "${1%%@*}"; }
parse_branch() {
  local branch="${1#*@}"
  [[ "$branch" == "$1" ]] && echo "main" || echo "$branch"
}

# Local path overrides stored as "name=path" entries
LOCAL_PATHS=()

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      [[ -z "${2:-}" || -z "${3:-}" ]] && die "--local requires REPO_NAME and PATH arguments"
      LOCAL_PATHS+=("$2=$3"); shift 3 ;;
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
      echo ""
      echo "Dependency repos:"
      for entry in "${VSIX_DEPS[@]}"; do
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

# ── Shared workspace ─────────────────────────────────────────────────────────
# All repos (deps + vsix) are cloned as siblings in a single workspace dir
# so they can reference each other via relative paths.
WORKSPACE=$(mktemp -d)
cleanup() { rm -rf "$WORKSPACE"; }
trap cleanup EXIT

log "Workspace: $WORKSPACE"

# Look up a local path override by repo name
get_local_path() {
  local name="$1"
  for _lp in "${LOCAL_PATHS[@]+"${LOCAL_PATHS[@]}"}"; do
    if [[ "${_lp%%=*}" == "$name" ]]; then
      echo "${_lp#*=}"; return
    fi
  done
  echo ""
}

# Clone a repo into the workspace (or symlink a local path)
clone_to_workspace() {
  local entry="$1"
  local repo=$(parse_repo "$entry")
  local branch=$(parse_branch "$entry")
  local name="${repo##*/}"
  local local_path
  local_path=$(get_local_path "$name")

  if [[ -n "$local_path" ]]; then
    [[ -d "$local_path" ]] || die "Local path does not exist: $local_path"
    ln -sf "$local_path" "$WORKSPACE/$name"
    info "Using local: $name -> $local_path"
  else
    log "Cloning $repo@$branch..."
    gh repo clone "$repo" "$WORKSPACE/$name" -- --depth 1 --branch "$branch" || {
      warn "Could not clone $repo — skipping"
      return 1
    }
  fi
  return 0
}

# Install npm/yarn dependencies for a repo in the workspace
install_deps() {
  local name="$1"
  local dir="$WORKSPACE/$name"
  [[ -d "$dir" ]] || return 1

  log "Installing dependencies for $name..."
  if [[ -f "$dir/yarn.lock" ]]; then
    (cd "$dir" && yarn install --frozen-lockfile) || { warn "yarn install failed for $name"; return 1; }
  else
    (cd "$dir" && npm ci) || (cd "$dir" && npm install) || { warn "npm install failed for $name"; return 1; }
  fi
}

# ── Clone dependency repos ───────────────────────────────────────────────────
for dep_entry in "${VSIX_DEPS[@]}"; do
  dep_repo=$(parse_repo "$dep_entry")
  dep_name="${dep_repo##*/}"
  clone_to_workspace "$dep_entry" || continue
  install_deps "$dep_name" || warn "Dependency $dep_name install failed — builds may fail"
done

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

  clone_to_workspace "$vsix_entry" || continue
  install_deps "$vsix_name" || continue

  REPO_DIR="$WORKSPACE/$vsix_name"

  # Check if repo has a native vscode:package script
  has_vscode_package=false
  if python3 -c "import json; p=json.load(open('$REPO_DIR/package.json')); exit(0 if 'vscode:package' in p.get('scripts',{}) else 1)" 2>/dev/null; then
    has_vscode_package=true
  fi

  if $has_vscode_package; then
    log "Building and packaging $vsix_name (using vscode:package)..."
    (cd "$REPO_DIR" && npm run compile && npm run vscode:package) || { warn "vscode:package failed for $vsix_name — skipping"; continue; }

    # Collect generated vsix files
    find "$REPO_DIR" -name '*.vsix' -print0 | while IFS= read -r -d '' vsix_file; do
      cp "$vsix_file" "$VSIX_DIR/"
      info "Collected: $(basename "$vsix_file")"
    done
  else
    log "Building $vsix_name..."
    (cd "$REPO_DIR" && npm run build) || { warn "Build failed for $vsix_name — skipping"; continue; }

    log "Packaging $vsix_name..."
    (cd "$REPO_DIR" && npx vsce package --no-dependencies -o "$VSIX_DIR/") || { warn "Packaging failed for $vsix_name — skipping"; continue; }

    # Collect generated vsix files (monorepo with packages/)
    if [[ -d "$REPO_DIR/packages" ]]; then
      for ext_dir in "$REPO_DIR"/packages/*/; do
        [[ -f "$ext_dir/package.json" ]] || continue
        python3 -c "import json; p=json.load(open('$ext_dir/package.json')); exit(0 if 'vscode' in p.get('engines',{}) else 1)" 2>/dev/null || continue
        ext_name=$(basename "$ext_dir")
        log "Packaging $ext_name..."
        (cd "$ext_dir" && npx vsce package --no-dependencies -o "$VSIX_DIR/") || { warn "Failed to package $ext_name"; continue; }
        info "Packaged: $ext_name"
      done
    fi
  fi
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
vsix_total=$(find "$VSIX_DIR" -name '*.vsix' | wc -l | tr -d ' ')
log "Generated $vsix_total VSIX file(s) in: $VSIX_DIR"
ls -1 "$VSIX_DIR"/*.vsix 2>/dev/null | while read -r f; do info "$(basename "$f")"; done
