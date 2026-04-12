# Hammerspoon Local Model Harness

This repository contains a repo-managed Hammerspoon configuration for running quick local-model workflows from macOS.

## Public repo guardrails

- Keep tracked defaults in `config.lua` generic and public-safe.
- Put any machine-specific overrides in `config.local.lua` and do not commit that file.
- Keep generated outputs, handoff files, and script drafts outside the repo.
- Run `scripts/run_precommit_checks.sh` before committing.
- If you want automatic local enforcement, install the repo hooks with `scripts/install_git_hooks.sh`.

## Safety checks

The repo includes:

- `scripts/check_repo_hygiene.sh` to scan tracked files for likely leaks
- `scripts/run_precommit_checks.sh` to run the hygiene scan and other lightweight checks
- `githooks/pre-commit` for optional local hook enforcement
- `.github/workflows/repo-hygiene.yml` so the same checks run in CI

## Local overrides

Copy `config.local.example.lua` to `config.local.lua` and customize that file for local paths, endpoint overrides, or browser bundle IDs.
