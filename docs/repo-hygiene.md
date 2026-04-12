# Repo Hygiene

This project touches clipboard text, browser URLs, Finder paths, and generated scripts, so public-repo hygiene matters.

## Rules

- Never commit `config.local.lua`.
- Never commit generated handoff files, output notes, or script drafts.
- Do not add absolute local filesystem paths to docs or code comments.
- Do not log raw clipboard contents, browser URLs, headers, or bearer tokens.
- Keep example configs generic.

## Before each commit

Run:

```sh
scripts/run_precommit_checks.sh
```

If you want this to happen automatically, install the tracked git hook:

```sh
scripts/install_git_hooks.sh
```

## What the hygiene scan checks

- accidental absolute user-home paths
- Windows user-profile paths
- `file://` and `vscode://` links
- likely bearer tokens or API keys
- tracked `.DS_Store`
- tracked `config.local.lua`

## What it does not guarantee

It cannot prove that prose is harmless or that a screenshot, prompt sample, or example text is truly non-sensitive. It is a guardrail, not a substitute for a final human pass.
