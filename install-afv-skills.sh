#!/usr/bin/env bash
# install-afv-skills.sh
# Installs latest AFV skills from forcedotcom/afv-library.
#
# Usage:
#   bash install-afv-skills.sh
#   bash install-afv-skills.sh --local /path/to/afv-library
#   curl -fsSL <url-to-this-script> | bash
#
# Auth: requires `gh` CLI (logged in) OR GITHUB_TOKEN env var set.

set -euo pipefail

# ── Colors (defined early so die() works during dep checks) ───────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}==>${NC} $*"; }
info() { echo -e "${BLUE}   ·${NC} $*"; }
warn() { echo -e "${YELLOW}WARN:${NC} $*"; }
die()  { echo -e "${RED}ERROR:${NC} $*" >&2; exit 1; }
step() { echo -e "\n${GREEN}━━${NC} $*"; }

# ── OS detection ─────────────────────────────────────────────────────────────
OS="$(uname -s)"
case "$OS" in
  Darwin) IS_MACOS=true  ;;
  Linux)  IS_MACOS=false ;;
  *)      die "Unsupported OS: $OS" ;;
esac

# ── Argument parsing ─────────────────────────────────────────────────────────
LOCAL_LIBRARY_PATH=""
RUN_VSIX=true
RUN_SKILLS=true
RUN_NIGHTLY=true
RUN_PLUGINS=true
INTERACTIVE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      [[ -z "${2:-}" ]] && die "--local requires a path argument"
      LOCAL_LIBRARY_PATH="$2"
      shift 2 ;;
    --no-vsix)    RUN_VSIX=false;    shift ;;
    --no-skills)  RUN_SKILLS=false;  shift ;;
    --no-nightly) RUN_NIGHTLY=false; shift ;;
    --no-plugins) RUN_PLUGINS=false; shift ;;
    -i|--interactive) INTERACTIVE=true; shift ;;
    -h|--help)
      echo "Usage: bash install-afv-skills.sh [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --local PATH     Use local clone of afv-library"
      echo "  --no-vsix        Skip VSIX extension installation"
      echo "  --no-skills      Skip AFV skills installation"
      echo "  --no-nightly     Skip SF CLI nightly update"
      echo "  --no-plugins     Skip SF CLI plugin linking"
      echo "  -i, --interactive  Prompt before each step"
      echo "  -h, --help       Show this help"
      exit 0 ;;
    *)
      die "Unknown argument: $1\nUsage: bash install-afv-skills.sh [--help]"
      ;;
  esac
done

# ── Interactive multi-select ──────────────────────────────────────────────────
if $INTERACTIVE && [[ -t 0 || -t 2 ]]; then
  STEP_NAMES=("Install VSIX extensions" "Install AFV skills" "Update SF CLI to nightly" "Clone/build/link SF plugins")
  STEP_VARS=(RUN_VSIX RUN_SKILLS RUN_NIGHTLY RUN_PLUGINS)
  STEP_COUNT=${#STEP_NAMES[@]}
  CURSOR=0

  draw_menu() {
    for i in "${!STEP_NAMES[@]}"; do
      local var="${STEP_VARS[$i]}"
      local on="${!var}"
      local marker; $on && marker="${GREEN}[x]${NC}" || marker="${YELLOW}[ ]${NC}"
      local arrow="   "
      [[ $i -eq $CURSOR ]] && arrow="${BLUE} ▸ ${NC}"
      echo -e "${arrow}${marker} ${STEP_NAMES[$i]}"
    done
    echo ""
    echo -e "  ${BLUE}↑/↓${NC} move  ${BLUE}space${NC} toggle  ${BLUE}a${NC} all  ${BLUE}n${NC} none  ${GREEN}enter${NC} confirm"
  }

  clear_menu() {
    printf "\033[%dA\033[J" "$(( STEP_COUNT + 2 ))"
  }

  echo ""
  echo -e "${GREEN}Select steps to run:${NC}"
  echo ""
  draw_menu

  while true; do
    # Read a single keypress
    IFS= read -rsn1 key </dev/tty
    # Handle escape sequences (arrow keys)
    if [[ "$key" == $'\x1b' ]]; then
      read -rsn2 seq </dev/tty
      key+="$seq"
    fi

    case "$key" in
      $'\x1b[A'|k)  # Up arrow or k
        (( CURSOR = (CURSOR - 1 + STEP_COUNT) % STEP_COUNT ))
        ;;
      $'\x1b[B'|j)  # Down arrow or j
        (( CURSOR = (CURSOR + 1) % STEP_COUNT ))
        ;;
      " ")  # Space — toggle current item
        local_var="${STEP_VARS[$CURSOR]}"
        if ${!local_var}; then
          eval "$local_var=false"
        else
          eval "$local_var=true"
        fi
        ;;
      a|A)  # All on
        for v in "${STEP_VARS[@]}"; do eval "$v=true"; done
        ;;
      n|N)  # All off
        for v in "${STEP_VARS[@]}"; do eval "$v=false"; done
        ;;
      "")  # Enter — confirm
        break
        ;;
    esac
    clear_menu
    draw_menu
  done
  echo ""
fi

if [[ -n "$LOCAL_LIBRARY_PATH" ]]; then
  [[ -d "$LOCAL_LIBRARY_PATH" ]] || die "Local path does not exist: $LOCAL_LIBRARY_PATH"
fi

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
  local missing=()

  if ! command -v gh &>/dev/null; then
    if $IS_MACOS; then
      missing+=("gh (GitHub CLI)  →  brew install gh")
    else
      missing+=("gh (GitHub CLI)  →  https://github.com/cli/cli/blob/trunk/docs/install_linux.md")
    fi
  fi

  if ! command -v code &>/dev/null; then
    missing+=("code (VS Code CLI) →  Install VS Code and add 'code' to PATH")
  fi

  if ! command -v sf &>/dev/null; then
    missing+=("sf (Salesforce CLI) →  npm install -g @salesforce/cli")
  fi

  if ! command -v node &>/dev/null; then
    if $IS_MACOS; then
      missing+=("node             →  brew install node")
    else
      missing+=("node             →  https://nodejs.org/en/download/package-manager")
    fi
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}ERROR:${NC} Missing required dependencies:" >&2
    for m in "${missing[@]}"; do
      echo -e "  ${YELLOW}·${NC} $m" >&2
    done
    exit 1
  fi
}
check_deps

# ── Script directory (for locating bundled files like vsix/) ──────────────────
SCRIPT_DIR=""
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
if [[ "$SCRIPT_SOURCE" != "/dev/stdin" && "$SCRIPT_SOURCE" != "bash" && "$SCRIPT_SOURCE" != "-" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
fi

# ── Config ────────────────────────────────────────────────────────────────────

# Source repos.conf (local file or downloaded)
CONF_LOADED=false
if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/repos.conf" ]]; then
  source "$SCRIPT_DIR/repos.conf"
  CONF_LOADED=true
fi

# Helper to split "owner/repo@branch" into repo and branch parts
parse_repo() { echo "${1%%@*}"; }
parse_branch() {
  local branch="${1#*@}"
  [[ "$branch" == "$1" ]] && echo "main" || echo "$branch"
}

if $IS_MACOS; then
  EINSTEIN_DIR="$HOME/Library/Application Support/Code/User/globalStorage/salesforce.salesforcedx-einstein-gpt"
else
  EINSTEIN_DIR="$HOME/.config/Code/User/globalStorage/salesforce.salesforcedx-einstein-gpt"
fi
SKILLS_DIR="$EINSTEIN_DIR/Skills-Salesforce"
SF_PLUGINS_DIR="$HOME/.sf-local-plugins"

# Defaults (used if repos.conf was not loaded, e.g. curl | bash before downloading)
: "${INSTALL_REPO:="k-j-kim/afv-install@main"}"
: "${AFV_LIBRARY_REPO:="forcedotcom/afv-library@main"}"
: "${AFV_SKILLS_SUBDIR:="skills"}"
if ! declare -p SF_PLUGIN_REPOS &>/dev/null; then
  SF_PLUGIN_REPOS=(
    "salesforcecli/plugin-templates@main"
    "salesforcecli/plugin-deploy-retrieve@main"
  )
fi

# ── Auth ──────────────────────────────────────────────────────────────────────
USE_GH=false
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  USE_GH=true
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  USE_GH=false
elif [[ -n "$LOCAL_LIBRARY_PATH" ]]; then
  warn "No GitHub auth found — will use local path only"
else
  die "No GitHub auth found.\n   Run: gh auth login\n   Or:  export GITHUB_TOKEN=<token>"
fi

# Downloads a repo as a tarball into a temp directory, returns the temp dir path via stdout.
# Returns non-zero and prints a human-readable error to stderr on failure.
# Caller is responsible for rm -rf on the returned path.
download_tarball() {
  local repo="$1" branch="$2"
  local tmpdir
  tmpdir=$(mktemp -d)

  log "Downloading $repo@$branch..." >&2

  local dl_ok=true
  if [[ "$USE_GH" == "true" ]]; then
    gh api "repos/$repo/tarball/$branch" > "$tmpdir/repo.tar.gz" 2>/dev/null || dl_ok=false
  else
    curl -fsSL \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/$repo/tarball/$branch" \
      -o "$tmpdir/repo.tar.gz" 2>/dev/null || dl_ok=false
  fi

  # GitHub returns a JSON error body (not a tarball) when the repo is inaccessible.
  if [[ "$dl_ok" == "false" ]] || ! tar -tzf "$tmpdir/repo.tar.gz" &>/dev/null; then
    rm -rf "$tmpdir"
    echo -e "${RED}ERROR:${NC} Could not download $repo — no access or repo not found." >&2
    echo -e "       Check your GitHub auth or request access to the repo." >&2
    return 1
  fi

  mkdir -p "$tmpdir/repo"
  tar -xzf "$tmpdir/repo.tar.gz" -C "$tmpdir/repo" --strip-components=1
  echo "$tmpdir"
}

# ── Step 1: Install VSIX extensions ──────────────────────────────────────────
if $RUN_VSIX; then
  step "Step 1: Installing VS Code extensions from vsix/..."

  VSIX_DIR=""
  TMPDIR_VSIX=""

  # Try local vsix/ first (running from a clone), otherwise download from repo
  if [[ -n "$SCRIPT_DIR" && -d "$SCRIPT_DIR/vsix" ]]; then
    VSIX_DIR="$SCRIPT_DIR/vsix"
  else
    log "Downloading vsix/ from $(parse_repo "$INSTALL_REPO")..."
    if TMPDIR_VSIX=$(download_tarball "$(parse_repo "$INSTALL_REPO")" "$(parse_branch "$INSTALL_REPO")"); then
      if [[ -d "$TMPDIR_VSIX/repo/vsix" ]]; then
        VSIX_DIR="$TMPDIR_VSIX/repo/vsix"
      else
        warn "No vsix/ directory found in $(parse_repo "$INSTALL_REPO") — skipping VSIX installation"
      fi
    else
      warn "Could not download $(parse_repo "$INSTALL_REPO") — skipping VSIX installation"
    fi
  fi

  if [[ -n "$VSIX_DIR" ]]; then
    vsix_count=0
    for vsix_file in "$VSIX_DIR"/*.vsix; do
      [[ -f "$vsix_file" ]] || continue
      vsix_name=$(basename "$vsix_file")
      log "Installing $vsix_name..."
      code --install-extension "$vsix_file" --force || { warn "Failed to install $vsix_name"; continue; }
      info "Installed: $vsix_name"
      ((vsix_count++))
    done
    log "Installed $vsix_count VSIX extension(s)"
  fi

  [[ -n "${TMPDIR_VSIX:-}" ]] && rm -rf "$TMPDIR_VSIX"
else
  step "Step 1: Skipping VSIX installation (--no-vsix)"
fi

# ── Steps 2 & 3: Remove old + install fresh AFV skills ───────────────────────
if $RUN_SKILLS; then
  step "Step 2: Removing existing AFV skills from Skills-Salesforce/..."
  mkdir -p "$SKILLS_DIR"

  LIBRARY_SKILLS_PATH=""
  TMPDIR_LIBRARY=""

  if [[ -n "$LOCAL_LIBRARY_PATH" ]]; then
    step "Step 3: Installing skills from local path: $LOCAL_LIBRARY_PATH..."
    LIBRARY_SKILLS_PATH="$LOCAL_LIBRARY_PATH/$AFV_SKILLS_SUBDIR"
    if [[ ! -d "$LIBRARY_SKILLS_PATH" ]]; then
      die "Expected '$AFV_SKILLS_SUBDIR/' directory not found in $LOCAL_LIBRARY_PATH"
    fi
  else
    step "Step 3: Installing skills from $(parse_repo "$AFV_LIBRARY_REPO")..."
    if ! TMPDIR_LIBRARY=$(download_tarball "$(parse_repo "$AFV_LIBRARY_REPO")" "$(parse_branch "$AFV_LIBRARY_REPO")"); then
      warn "Skipping skills update — could not access $(parse_repo "$AFV_LIBRARY_REPO")"
      warn "Request access at: https://github.com/$(parse_repo "$AFV_LIBRARY_REPO")"
    else
      LIBRARY_SKILLS_PATH="$TMPDIR_LIBRARY/repo/$AFV_SKILLS_SUBDIR"
      if [[ ! -d "$LIBRARY_SKILLS_PATH" ]]; then
        rm -rf "$TMPDIR_LIBRARY"
        warn "Expected '$AFV_SKILLS_SUBDIR/' directory not found in $(parse_repo "$AFV_LIBRARY_REPO") — skipping skills update"
        LIBRARY_SKILLS_PATH=""
      fi
    fi
  fi

  if [[ -n "$LIBRARY_SKILLS_PATH" ]]; then
    # Step 2: remove all existing skills in the directory
    removed_count=0
    while IFS= read -r -d '' skill_dir; do
      skill_name=$(basename "$skill_dir")
      rm -rf "$skill_dir"
      info "Removed: $skill_name"
      ((removed_count++))
    done < <(find "$SKILLS_DIR" -mindepth 1 -maxdepth 1 -type d -print0)
    [[ $removed_count -eq 0 ]] && info "No existing skills to remove" || log "Removed $removed_count skill(s)"

    # Step 3: install fresh copies
    copied_count=0
    while IFS= read -r -d '' skill_dir; do
      skill_name=$(basename "$skill_dir")
      cp -r "$skill_dir" "$SKILLS_DIR/$skill_name"
      info "Installed: $skill_name"
      ((copied_count++))
    done < <(find "$LIBRARY_SKILLS_PATH" -mindepth 1 -maxdepth 1 -type d -print0)

    [[ -n "${TMPDIR_LIBRARY:-}" ]] && rm -rf "$TMPDIR_LIBRARY"
    log "Installed $copied_count skill(s) to: $SKILLS_DIR"
  fi
else
  step "Steps 2-3: Skipping skills installation (--no-skills)"
fi

# ── Step 4: Update SF CLI to nightly ─────────────────────────────────────────
if $RUN_NIGHTLY; then
  step "Step 4: Updating SF CLI to nightly..."
  log "Installing @salesforce/cli@nightly globally..."
  npm install @salesforce/cli@nightly --global || warn "Failed to install @salesforce/cli@nightly globally"
  log "Running sf update nightly..."
  sf update nightly || warn "Failed to run sf update nightly"
  info "SF CLI nightly update complete"
else
  step "Step 4: Skipping SF CLI nightly update (--no-nightly)"
fi

# ── Step 5: Clone, build, and link SF plugin repos ─────────────────────────
if $RUN_PLUGINS; then
  step "Step 5: Setting up local SF plugin repos..."
  mkdir -p "$SF_PLUGINS_DIR"

  for plugin_entry in "${SF_PLUGIN_REPOS[@]}"; do
    plugin_repo=$(parse_repo "$plugin_entry")
    plugin_branch=$(parse_branch "$plugin_entry")
    plugin_name="${plugin_repo##*/}"
    plugin_dir="$SF_PLUGINS_DIR/$plugin_name"

    if [[ -d "$plugin_dir/.git" ]]; then
      log "Updating existing clone: $plugin_name ($plugin_branch)"
      git -C "$plugin_dir" fetch origin && git -C "$plugin_dir" checkout "$plugin_branch" && git -C "$plugin_dir" reset --hard "origin/$plugin_branch" || {
        warn "Failed to update $plugin_name — removing and re-cloning"
        rm -rf "$plugin_dir"
      }
    fi

    if [[ ! -d "$plugin_dir" ]]; then
      log "Cloning $plugin_repo@$plugin_branch..."
      if [[ "$USE_GH" == "true" ]]; then
        gh repo clone "$plugin_repo" "$plugin_dir" -- --depth 1 --branch "$plugin_branch" || {
          warn "Could not clone $plugin_repo — skipping"
          continue
        }
      else
        git clone --depth 1 --branch "$plugin_branch" "https://x-access-token:${GITHUB_TOKEN}@github.com/${plugin_repo}.git" "$plugin_dir" || {
          warn "Could not clone $plugin_repo — skipping"
          continue
        }
      fi
    fi

    log "Installing dependencies for $plugin_name..."
    if [[ -f "$plugin_dir/yarn.lock" ]]; then
      (cd "$plugin_dir" && yarn install --frozen-lockfile) || { warn "yarn install failed for $plugin_name — skipping"; continue; }
    else
      (cd "$plugin_dir" && npm install) || { warn "npm install failed for $plugin_name — skipping"; continue; }
    fi

    log "Building $plugin_name..."
    (cd "$plugin_dir" && PATH="$plugin_dir/node_modules/.bin:$PATH" npm run build) || { warn "Build failed for $plugin_name — skipping link"; continue; }

    log "Linking $plugin_name to sf CLI..."
    sf plugins link "$plugin_dir" || { warn "Failed to link $plugin_name"; continue; }
    info "Linked: $plugin_name"
  done
else
  step "Step 5: Skipping SF plugin linking (--no-plugins)"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
log "Done!"
echo "   Skills dir  : $SKILLS_DIR"
echo "   Plugins dir : $SF_PLUGINS_DIR"
