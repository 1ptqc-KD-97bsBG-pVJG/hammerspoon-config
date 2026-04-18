# Local Model Harness Setup

## Current checkpoint

This repository is being built as a repo-managed Hammerspoon configuration rooted at the repository itself.

The current implemented checkpoint provides:

- `init.lua` bootstrap and reload watcher
- shared configuration in `config.lua`
- core modules under `llm/`
- clipboard actions with explicit clipboard model profiles
- action-specific context policies for clipboard actions
- Developer Mode context toggles for additive debugging context
- a menubar item and configurable hotkeys
- explicit `Prepare Clipboard Model` flow for safe model switching
- diagnostics capture for clipboard bake-off runs

## Planned setup flow

1. Install Hammerspoon.
2. Point `~/.hammerspoon` at this repository.
3. Grant Accessibility access to Hammerspoon.
4. Reload Hammerspoon after editing any Lua file in this repo.
5. Keep `config.lua` public-safe and put machine-specific overrides in `config.local.lua`.
6. Run `scripts/run_precommit_checks.sh` before committing.

## Notes

- Zen is the intended primary browser for browser-aware actions and Open WebUI handoff.
- The eventual harness will talk to a local LM Studio server over HTTP.
- Script drafting will save generated scripts locally for review rather than executing them automatically.
- `config.local.lua` is intentionally untracked and should be used for any machine-specific paths, URLs, bundle IDs, or tokens.
- Clipboard actions now use one explicit active clipboard profile at a time:
  - `glm` uses native `/api/v1/chat` with reasoning disabled per request
  - `gpt_oss` uses `/v1/responses`
- The initial bake-off baseline is `clipboard.active_profile = "glm"`, but that is not intended to be the permanent default until both profiles are tested.
- By default, normal clipboard actions do not silently switch models. Use `Prepare Clipboard Model` or enable `backend.manage_clipboard_model` in `config.local.lua` if you want managed switching.
- Diagnostics for bake-off runs are written outside the repo to `storage.diagnostics_dir` when `clipboard.bakeoff_mode = true`.
- Context types and action defaults are documented in [Context Catalog](./context-catalog.md).
