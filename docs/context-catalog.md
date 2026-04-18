# Context Catalog

This harness supports a small set of reusable context types. Actions should pull only the context they need by default, and Developer Mode can add optional context for debugging and power use.

## Supported Context Types

- `clipboard`
  - The current pasteboard text.
  - Best for rewrite, summary, reply drafting, error explanation, and script requests.
- `app`
  - The frontmost application name.
  - Useful when prompts should know whether text came from Mail, Signal, Codex, Terminal, or a browser.
- `window`
  - The current front window title.
  - Useful when the app alone is too coarse.
- `browser`
  - Active browser URL and page title when the frontmost app is a supported browser.
  - Useful for research-aware summaries, handoff actions, and page-specific rewrites.
- `finder`
  - Current Finder selection as POSIX paths.
  - Useful for file plans, script drafting, and future Finder-first helpers.
- `profile_metadata`
  - Active clipboard profile label, model, and API.
  - Mostly useful for diagnostics, bake-off runs, and debugging.
- `full_clipboard`
  - An action-level override that allows full clipboard capture instead of the instant-action truncation limit.
  - Best for handoff or save flows, not fast clipboard transforms.

## Current Default Usage

- `Summarize Clipboard`
  - default: `clipboard`, `app`, `window`
  - optional in Developer Mode: `browser`, `finder`, `profile_metadata`
- `Rewrite Clipboard Tersely`
  - default: `clipboard`, `app`, `window`
  - optional in Developer Mode: `browser`, `finder`, `profile_metadata`
- `Explain Clipboard Error`
  - default: `clipboard`, `app`, `window`
  - optional in Developer Mode: `browser`, `finder`, `profile_metadata`

## Developer Mode Context Toggles

When Developer Mode is on, the menu exposes additive toggles for:

- Include Clipboard
- Include Browser Context
- Include Finder Context
- Include Profile Metadata
- Use Full Clipboard

These toggles only add optional context. They do not remove any context that an action requires by default.
