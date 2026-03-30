#!/usr/bin/env bash
# install-afv-skills.sh
# Installs latest AFV skills from forcedotcom/afv-library and optionally
# updates rules from forcedotcom/cline-fork (agenticChat branch).
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)
      [[ -z "${2:-}" ]] && die "--local requires a path argument"
      LOCAL_LIBRARY_PATH="$2"
      shift 2
      ;;
    *)
      die "Unknown argument: $1\nUsage: bash install-afv-skills.sh [--local /path/to/afv-library]"
      ;;
  esac
done

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

  if ! command -v python3 &>/dev/null; then
    if $IS_MACOS; then
      missing+=("python3          →  brew install python  OR  xcode-select --install")
    else
      missing+=("python3          →  sudo apt install python3  OR  sudo dnf install python3")
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
if $IS_MACOS; then
  EINSTEIN_DIR="$HOME/Library/Application Support/Code/User/globalStorage/salesforce.salesforcedx-einstein-gpt"
else
  EINSTEIN_DIR="$HOME/.config/Code/User/globalStorage/salesforce.salesforcedx-einstein-gpt"
fi
SKILLS_DIR="$EINSTEIN_DIR/Skills-Salesforce"
RULES_DIR="$EINSTEIN_DIR/Rules"

AFV_LIBRARY_REPO="forcedotcom/afv-library"
AFV_LIBRARY_BRANCH="main"
AFV_SKILLS_SUBDIR="skills"

SF_PLUGIN_REPOS=(
  "salesforcecli/plugin-templates"
)
SF_PLUGINS_DIR="$HOME/.sf-local-plugins"

INSTALL_REPO="k-j-kim/afv-install"
INSTALL_REPO_BRANCH="main"

CLINE_FORK_REPO="forcedotcom/cline-fork"
CLINE_FORK_BRANCH="agenticChat"
CLINE_RULES_FILE="src/core/context/instructions/user-instructions/a4dDefaultRules.ts"

# Deprecated rule file names (from a4dDefaultRules.ts) to clean up
DEPRECATED_RULES=(
  "a4dRules-no-edit.md"
  "a4d-general-rules-no-edit.md"
  "a4d-app-dev-rules-no-edit.md"
  "a4d-apex-rules-no-edit.md"
  "a4d-lwc-rules-no-edit.md"
  "a4d-mobile-rules-no-edit.md"
  "a4d-agent-script-rules-no-edit.md"
)

# ── Auth ──────────────────────────────────────────────────────────────────────
USE_GH=false
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
  USE_GH=true
elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
  USE_GH=false
elif [[ -n "$LOCAL_LIBRARY_PATH" ]]; then
  warn "No GitHub auth found — rules update from $CLINE_FORK_REPO will be skipped"
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

# Downloads a single file's raw content via GitHub API.
# Returns non-zero silently on failure (caller decides how to handle).
download_file_content() {
  local repo="$1" path="$2" branch="$3"
  if [[ "$USE_GH" == "true" ]]; then
    gh api "repos/$repo/contents/$path?ref=$branch" --jq '.content' 2>/dev/null | base64 --decode
  else
    curl -fsSL \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://raw.githubusercontent.com/$repo/$branch/$path" 2>/dev/null
  fi
}

# ── Step 1: Install VSIX extensions ──────────────────────────────────────────
step "Step 1: Installing VS Code extensions from vsix/..."

VSIX_DIR=""
TMPDIR_VSIX=""

# Try local vsix/ first (running from a clone), otherwise download from repo
if [[ -n "$SCRIPT_DIR" && -d "$SCRIPT_DIR/vsix" ]]; then
  VSIX_DIR="$SCRIPT_DIR/vsix"
else
  log "Downloading vsix/ from $INSTALL_REPO..."
  if TMPDIR_VSIX=$(download_tarball "$INSTALL_REPO" "$INSTALL_REPO_BRANCH"); then
    if [[ -d "$TMPDIR_VSIX/repo/vsix" ]]; then
      VSIX_DIR="$TMPDIR_VSIX/repo/vsix"
    else
      warn "No vsix/ directory found in $INSTALL_REPO — skipping VSIX installation"
    fi
  else
    warn "Could not download $INSTALL_REPO — skipping VSIX installation"
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

[[ -n "$TMPDIR_VSIX" ]] && rm -rf "$TMPDIR_VSIX"

# ── Steps 2 & 3: Remove old + install fresh AFV skills ───────────────────────
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
  step "Step 3: Installing skills from $AFV_LIBRARY_REPO..."
  if ! TMPDIR_LIBRARY=$(download_tarball "$AFV_LIBRARY_REPO" "$AFV_LIBRARY_BRANCH"); then
    warn "Skipping skills update — could not access $AFV_LIBRARY_REPO"
    warn "Request access at: https://github.com/$AFV_LIBRARY_REPO"
  else
    LIBRARY_SKILLS_PATH="$TMPDIR_LIBRARY/repo/$AFV_SKILLS_SUBDIR"
    if [[ ! -d "$LIBRARY_SKILLS_PATH" ]]; then
      rm -rf "$TMPDIR_LIBRARY"
      warn "Expected '$AFV_SKILLS_SUBDIR/' directory not found in $AFV_LIBRARY_REPO — skipping skills update"
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

  [[ -n "$TMPDIR_LIBRARY" ]] && rm -rf "$TMPDIR_LIBRARY"
  log "Installed $copied_count skill(s) to: $SKILLS_DIR"
fi

# ── Step 4: Rules from cline-fork ─────────────────────────────────────────────
step "Step 4: Attempting to fetch rules from $CLINE_FORK_REPO..."
mkdir -p "$RULES_DIR"

TS_CONTENT=""
if TS_CONTENT=$(download_file_content "$CLINE_FORK_REPO" "$CLINE_RULES_FILE" "$CLINE_FORK_BRANCH" 2>/dev/null); then
  log "Downloaded $CLINE_RULES_FILE"

  # Extract the a4vExpertGlobalRule template literal content
  # The pattern is: export const a4vExpertGlobalRule = `...`
  RULE_FILE="$RULES_DIR/a4v-expert-global-rule.md"
  # Write TS content to a temp file, then extract the rule via Python
  TS_TMPFILE=$(mktemp "${TMPDIR:-/tmp}/a4dDefaultRules.XXXXXX")
  printf '%s' "$TS_CONTENT" > "$TS_TMPFILE"

  python3 - "$TS_TMPFILE" "$RULE_FILE" <<'PYEOF'
import sys, re

ts_file, rule_file = sys.argv[1], sys.argv[2]

with open(ts_file, 'r') as f:
    content = f.read()

# Extract content of the a4vExpertGlobalRule template literal
match = re.search(
    r'export\s+const\s+a4vExpertGlobalRule\s*=\s*`([\s\S]*?)`\s*\nexport',
    content
)
if not match:
    match = re.search(
        r'const\s+a4vExpertGlobalRule\s*=\s*`([\s\S]*?)`',
        content
    )

if match:
    rule_content = match.group(1)
    rule_content = rule_content.replace('\\`', '`').replace('\\${', '${')
    with open(rule_file, 'w') as f:
        f.write(rule_content)
    print(f"  · Written: {rule_file}")
else:
    print("  · WARNING: Could not extract a4vExpertGlobalRule — pattern not matched", file=sys.stderr)
    sys.exit(1)
PYEOF
  rm -f "$TS_TMPFILE"
  info "Updated: a4v-expert-global-rule.md"

  # Remove deprecated rule files
  deprecated_removed=0
  for deprecated in "${DEPRECATED_RULES[@]}"; do
    target="$RULES_DIR/$deprecated"
    if [[ -f "$target" ]]; then
      rm -f "$target"
      info "Removed deprecated rule: $deprecated"
      ((deprecated_removed++))
    fi
  done
  [[ $deprecated_removed -gt 0 ]] && log "Removed $deprecated_removed deprecated rule file(s)"

else
  warn "Could not access $CLINE_FORK_REPO (no access or repo unavailable)"
  warn "Skipping rules update — Skills installation still succeeded"
fi

# ── Step 5: Clone, build, and link SF plugin repos ─────────────────────────
step "Step 5: Setting up local SF plugin repos..."
mkdir -p "$SF_PLUGINS_DIR"

for plugin_repo in "${SF_PLUGIN_REPOS[@]}"; do
  plugin_name="${plugin_repo##*/}"
  plugin_dir="$SF_PLUGINS_DIR/$plugin_name"

  if [[ -d "$plugin_dir/.git" ]]; then
    log "Updating existing clone: $plugin_name"
    git -C "$plugin_dir" fetch origin && git -C "$plugin_dir" reset --hard origin/main || {
      warn "Failed to update $plugin_name — removing and re-cloning"
      rm -rf "$plugin_dir"
    }
  fi

  if [[ ! -d "$plugin_dir" ]]; then
    log "Cloning $plugin_repo..."
    if [[ "$USE_GH" == "true" ]]; then
      gh repo clone "$plugin_repo" "$plugin_dir" -- --depth 1 || {
        warn "Could not clone $plugin_repo — skipping"
        continue
      }
    else
      git clone --depth 1 "https://x-access-token:${GITHUB_TOKEN}@github.com/${plugin_repo}.git" "$plugin_dir" || {
        warn "Could not clone $plugin_repo — skipping"
        continue
      }
    fi
  fi

  log "Installing dependencies for $plugin_name..."
  if [[ -f "$plugin_dir/yarn.lock" ]]; then
    (cd "$plugin_dir" && yarn install --frozen-lockfile) || { warn "yarn install failed for $plugin_name — skipping"; continue; }
  else
    (cd "$plugin_dir" && npm ci) || { warn "npm ci failed for $plugin_name — skipping"; continue; }
  fi

  log "Building $plugin_name..."
  if [[ -f "$plugin_dir/yarn.lock" ]]; then
    (cd "$plugin_dir" && yarn build) || { warn "Build failed for $plugin_name — skipping link"; continue; }
  else
    (cd "$plugin_dir" && npm run build) || { warn "Build failed for $plugin_name — skipping link"; continue; }
  fi

  log "Linking $plugin_name to sf CLI..."
  sf plugins link "$plugin_dir" || { warn "Failed to link $plugin_name"; continue; }
  info "Linked: $plugin_name"
done

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
log "Done!"
echo "   Skills dir  : $SKILLS_DIR"
echo "   Rules dir   : $RULES_DIR"
echo "   Plugins dir : $SF_PLUGINS_DIR"
