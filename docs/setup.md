# Local Model Harness Setup

## Current checkpoint

This repository is being built as a repo-managed Hammerspoon configuration rooted at the repository itself.

The current implemented checkpoint provides:

- `init.lua` bootstrap and reload watcher
- shared configuration in `config.lua`
- core modules under `llm/`
- a menubar item and placeholder hotkeys

The user-facing model actions are not implemented yet in this checkpoint.

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
