# afv-install

Installs the latest AFV skills and rules into the Einstein for Developers VS Code extension.

## What it does

1. **Removes** existing AFV skill directories from `Skills-Salesforce/`
2. **Installs** all skills from [`forcedotcom/afv-library`](https://github.com/forcedotcom/afv-library)
3. **Updates** `a4v-expert-global-rule.md` in `Rules/` from [`forcedotcom/cline-fork`](https://github.com/forcedotcom/cline-fork) *(skipped gracefully if you don't have access)*

## Requirements

- [`gh`](https://cli.github.com) CLI, logged in (`gh auth login`) — **or** `GITHUB_TOKEN` set in your environment
- `python3` — for rule extraction from TypeScript

Both can be installed via Homebrew if missing:

```bash
brew install gh python
gh auth login
```

> **Note:** `forcedotcom/afv-library` and `forcedotcom/cline-fork` are private Salesforce repos.
> You need org access to use this script. Steps that fail due to missing access are skipped with a warning.

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/k-j-kim/afv-install/main/install-afv-skills.sh | bash
```

Or download and run locally:

```bash
bash install-afv-skills.sh
```

### Install from a local repo

If you have a local clone of `afv-library`, you can install skills directly from it:

```bash
bash install-afv-skills.sh --local /path/to/afv-library
```

Or via curl (use `bash -s --` to pass arguments through the pipe):

```bash
curl -fsSL https://raw.githubusercontent.com/k-j-kim/afv-install/main/install-afv-skills.sh | bash -s -- --local /path/to/afv-library
```

This skips the GitHub download for skills and copies from the local `skills/` subdirectory instead. The rules update from `cline-fork` still runs if GitHub auth is available.
