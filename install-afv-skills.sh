#!/usr/bin/env bash
# install-afv-skills.sh
# Installs latest AFV skills from forcedotcom/afv-library and optionally
# updates rules from forcedotcom/cline-fork (agenticChat branch).
#
# Usage:
#   bash install-afv-skills.sh
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

# ── Dependency check ──────────────────────────────────────────────────────────
# Tools not available on macOS by default:
#   gh      — GitHub CLI:  brew install gh
#   python3 — Python 3:    brew install python  (or: xcode-select --install)
check_deps() {
  local missing=()

  if ! command -v gh &>/dev/null; then
    missing+=("gh (GitHub CLI)  →  brew install gh")
  fi

  if ! command -v python3 &>/dev/null; then
    missing+=("python3          →  brew install python  OR  xcode-select --install")
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

# ── Config ────────────────────────────────────────────────────────────────────
EINSTEIN_DIR="$HOME/Library/Application Support/Code/User/globalStorage/salesforce.salesforcedx-einstein-gpt"
SKILLS_DIR="$EINSTEIN_DIR/Skills-Salesforce"
RULES_DIR="$EINSTEIN_DIR/Rules"

AFV_LIBRARY_REPO="forcedotcom/afv-library"
AFV_LIBRARY_BRANCH="main"
AFV_SKILLS_SUBDIR="skills"

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
else
  die "No GitHub auth found.\n   Run: gh auth login\n   Or:  export GITHUB_TOKEN=<token>"
fi

# Downloads a repo as a tarball into a temp directory, returns the temp dir path.
# Caller is responsible for rm -rf on the returned path.
# All diagnostic output goes to stderr so stdout is clean for the path return value.
download_tarball() {
  local repo="$1" branch="$2"
  local tmpdir
  tmpdir=$(mktemp -d)

  log "Downloading $repo@$branch..." >&2
  if [[ "$USE_GH" == "true" ]]; then
    gh api "repos/$repo/tarball/$branch" > "$tmpdir/repo.tar.gz"
  else
    curl -fsSL \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/$repo/tarball/$branch" \
      -o "$tmpdir/repo.tar.gz"
  fi

  mkdir -p "$tmpdir/repo"
  tar -xzf "$tmpdir/repo.tar.gz" -C "$tmpdir/repo" --strip-components=1
  echo "$tmpdir"
}

# Downloads a single file's raw content via GitHub API.
download_file_content() {
  local repo="$1" path="$2" branch="$3"
  if [[ "$USE_GH" == "true" ]]; then
    gh api "repos/$repo/contents/$path?ref=$branch" --jq '.content' | base64 --decode
  else
    curl -fsSL \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://raw.githubusercontent.com/$repo/$branch/$path"
  fi
}

# ── Step 1: Remove AFV skills from Skills/ ────────────────────────────────────
step "Step 1: Removing existing AFV skills from Skills/..."
mkdir -p "$SKILLS_DIR"

# We'll identify which skill directories to remove after downloading the library.
# First pass: capture current skill names from the library.
TMPDIR_LIBRARY=$(download_tarball "$AFV_LIBRARY_REPO" "$AFV_LIBRARY_BRANCH")

LIBRARY_SKILLS_PATH="$TMPDIR_LIBRARY/repo/$AFV_SKILLS_SUBDIR"
if [[ ! -d "$LIBRARY_SKILLS_PATH" ]]; then
  rm -rf "$TMPDIR_LIBRARY"
  die "Expected '$AFV_SKILLS_SUBDIR/' directory not found in $AFV_LIBRARY_REPO"
fi

removed_count=0
while IFS= read -r -d '' skill_dir; do
  skill_name=$(basename "$skill_dir")
  target="$SKILLS_DIR/$skill_name"
  if [[ -d "$target" ]]; then
    rm -rf "$target"
    info "Removed: $skill_name"
    ((removed_count++))
  fi
done < <(find "$LIBRARY_SKILLS_PATH" -mindepth 1 -maxdepth 1 -type d -print0)

if [[ $removed_count -eq 0 ]]; then
  info "No matching AFV skills found to remove (Skills/ may already be clean)"
else
  log "Removed $removed_count AFV skill(s)"
fi

# ── Step 2: Copy skills from afv-library ─────────────────────────────────────
step "Step 2: Installing skills from $AFV_LIBRARY_REPO..."
mkdir -p "$SKILLS_DIR"

copied_count=0
while IFS= read -r -d '' skill_dir; do
  skill_name=$(basename "$skill_dir")
  target="$SKILLS_DIR/$skill_name"
  cp -r "$skill_dir" "$target"
  info "Installed: $skill_name"
  ((copied_count++))
done < <(find "$LIBRARY_SKILLS_PATH" -mindepth 1 -maxdepth 1 -type d -print0)

rm -rf "$TMPDIR_LIBRARY"
log "Installed $copied_count skill(s) to: $SKILLS_DIR"

# ── Step 3: Rules from cline-fork ─────────────────────────────────────────────
step "Step 3: Attempting to fetch rules from $CLINE_FORK_REPO..."
mkdir -p "$RULES_DIR"

TS_CONTENT=""
if TS_CONTENT=$(download_file_content "$CLINE_FORK_REPO" "$CLINE_RULES_FILE" "$CLINE_FORK_BRANCH" 2>/dev/null); then
  log "Downloaded $CLINE_RULES_FILE"

  # Extract the a4vExpertGlobalRule template literal content
  # The pattern is: export const a4vExpertGlobalRule = `...`
  RULE_FILE="$RULES_DIR/a4v-expert-global-rule.md"
  # Write TS content to a temp file, then extract the rule via Python
  TS_TMPFILE=$(mktemp /tmp/a4dDefaultRules.XXXXXX.ts)
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

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
log "Done!"
echo "   Skills dir : $SKILLS_DIR"
echo "   Rules dir  : $RULES_DIR"
