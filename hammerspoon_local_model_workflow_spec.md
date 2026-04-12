# Hammerspoon Local Model Workflow Spec

## Purpose

Implement a **Hammerspoon-based local model harness** for the main macOS user that can:

- trigger local model actions with hotkeys and menu bar actions
- capture useful context automatically from the current app/session
- send requests to the local model server running under a separate macOS user
- return results quickly in lightweight ways
- escalate bigger tasks into a chat UI when needed
- eventually support saving outputs into a notes system once one is chosen

This should be treated as a **fast action layer** and **context harness**, not a full chat UI.

---

## High-level architecture

### Current setup

The intended deployment uses a split architecture:

- one interactive macOS user session for day-to-day use
- one separate local inference service or account that runs LM Studio and model serving
- optional external tooling on another machine or host

The Hammerspoon implementation should run in the **interactive macOS user session** and talk to the model server running under the **local inference service/account**.

### Core design principle

Treat the layers separately:

- **Hammerspoon** = capture + launch + lightweight action layer
- **LM Studio / model server** = inference backend
- **Open WebUI** = deeper local chat / multi-turn workspace
- **future notes system** = durable storage, not decided yet

Do **not** make Hammerspoon the main chat application.

---

## Important constraints

### 1. Memory is constrained in practice

Even though the machine has 128 GB unified memory, large local models and long contexts push the machine hard.

Important implications:

- cold starts will happen often
- ejecting the currently loaded model and loading another model from storage may be common
- the harness should assume the target model might not already be loaded
- the UX should make model choice explicit or intelligently default to a lightweight model
- the implementation should be careful not to encourage loading many large models at once

This means the harness should prefer:

- a **cheap default model** for instant actions
- optional escalation to bigger/slower models only when requested
- clear user feedback when a request may be slow because of model load time

### 2. Notes system is not finalized

The user wants a notes/second-brain system but has **not** settled on one.

Implications:

- do not hardcode Obsidian, Notion, Apple Notes, etc.
- if saving outputs is implemented, use a simple adapter pattern
- the safest default is writing markdown/text files to a configurable folder
- design save/export functionality so a notes backend can be swapped later

### 3. The system should be useful without switching users

The user does **not** want to switch into the inference user to interact with models.

Implications:

- Hammerspoon should assume the backend is already reachable over HTTP
- it should not depend on interactive access to the inference user’s desktop session
- if possible, infer server status through API calls or helper scripts instead of relying on the LM Studio GUI

### 4. External agent tooling is separate

This Hammerspoon implementation is **not** a replacement for external agent tooling.

It should complement the existing stack by providing:

- quick local actions
- context-aware helper workflows
- a fast path to local models without involving other orchestration layers

---

## Backend assumptions

### Model server

Assume an **OpenAI-compatible HTTP endpoint** backed by LM Studio.

Likely endpoints:

- same-machine local endpoint from the main user: `http://localhost:1234/v1`
- if localhost is not appropriate in the final setup, allow configuration of a custom endpoint

Make the endpoint configurable in `init.lua` or a separate config file.

### Current local model roster

Assume the following models exist or may exist:

- `zai-org/glm-4.7-flash`
- `qwen3.5-122b-a10b`
- `qwen/qwen3-coder-next`
- `qwen/qwen3-vl-8b`

Suggested default roles:

- `glm-4.7-flash` = quick local helper / default action model
- `qwen3.5-122b-a10b` = deeper planning / heavier reasoning
- `qwen/qwen3-coder-next` = coding-oriented bounded tasks
- `qwen/qwen3-vl-8b` = visual/screenshot tasks

The harness should not assume all models are always loaded.

---

## Product goals for Hammerspoon

### Primary goals

1. **One-keystroke local model actions**
2. **Automatic context capture** where reasonable
3. **Fast feedback** for simple tasks
4. **Escalation path** for deeper work
5. **Menu bar visibility** for local inference status

### Non-goals for v1

- full multi-turn chat UI
- complete queue management
- persistent conversation memory system
- autonomous tool-heavy agent loops
- a final notes system integration

---

## Recommended user experience

### Action categories

Implement three categories of actions.

#### A. Instant actions

These should complete quickly and return results immediately.

Examples:

- summarize clipboard
- rewrite selected text
- explain copied error/log block
- convert rough text into bullet points
- draft a commit message from clipboard diff/summary

Preferred output modes:

- macOS notification
- alert/modal
- copy result back to clipboard
- optional tiny floating webview/panel

Use the cheap/fast local model by default.

#### B. Escalation actions

These should send the captured context into a deeper workspace.

Examples:

- send clipboard + browser URL into Open WebUI
- send Finder-selected file list into Open WebUI
- open a new local chat seeded with selected text and metadata

This is the right path for larger or more ambiguous tasks.

#### C. Save/export actions

These should store outputs externally.

Because the notes system is undecided, start with:

- save markdown to a configurable folder
- append to an inbox file
- write structured output to a handoff folder

Use a backend-agnostic save adapter.

---

## Hammerspoon capabilities to use

Relevant modules:

- `hs.hotkey` for global hotkeys
- `hs.pasteboard` for clipboard access
- `hs.menubar` for menu bar UI
- `hs.http` for calling the local model server
- `hs.task` for helper scripts / shell integration
- `hs.application` for current app detection
- `hs.window` for frontmost window title/context
- `hs.osascript` or `hs.applescript` for app-specific context capture when needed
- `hs.pathwatcher` for file-based handoff integration later
- `hs.notify` or `hs.alert` for lightweight result delivery

Use plain Lua modules and small composable functions. Avoid building a giant monolith in `init.lua`.

---

## Recommended code structure

Use a small module layout instead of one huge file.

Suggested structure:

```text
~/.hammerspoon/
  init.lua
  config.lua
  llm/
    client.lua
    models.lua
    prompts.lua
    actions.lua
    context.lua
    status.lua
    ui.lua
    storage.lua
```

### Suggested module responsibilities

#### `config.lua`

- server base URL
- API key if needed
- default models
- folders for save/export
- feature flags
- timeouts

#### `client.lua`

- OpenAI-compatible request wrapper
- request building
- HTTP calls
- timeout/error handling
- optional helper for model listing/status

#### `models.lua`

- model role mapping
- default model per action type
- optional “bigger model” overrides
- logic for warning on likely cold starts

#### `prompts.lua`

- prompt templates for common actions
- compressed/terse output instructions for quick actions
- model-specific behavior if needed

#### `context.lua`

- clipboard capture
- current app name
- window title
- browser URL/title extraction if feasible
- Finder selection if feasible
- normalize captured context into a clean payload

#### `actions.lua`

- user-facing commands such as:
  - summarizeClipboard()
  - rewriteSelection()
  - explainClipboardError()
  - sendToOpenWebUI()
  - saveClipboardSummary()

#### `status.lua`

- backend status checks
- loaded model status if available
- busy/idle state if inferable
- queue/active request status later

#### `ui.lua`

- hotkey bindings
- menu bar item
- alerts/notifications
- simple chooser/picker if needed

#### `storage.lua`

- save-to-file backend
- simple markdown export
- future notes adapter abstraction

---

## Context capture strategy

The value of Hammerspoon here is not just hotkeys; it is **automatic context capture**.

### Minimum viable context capture

Capture at least:

- clipboard text
- frontmost application name
- frontmost window title

### Useful next-level context

Where possible, add app-specific capture:

- browser URL/title for Safari/Chrome/Arc
- Finder selection paths
- current file path or project info from the front app if obtainable

Do this conservatively. Do not make the whole system fragile because one app-specific automation path breaks.

### Context object example

Normalize context into something like:

```json
{
  "source": "clipboard",
  "app": "Zed",
  "window_title": "bug.log — project",
  "url": null,
  "selection": null,
  "clipboard": "<clipboard text>"
}
```

Prompt templates should consume this cleanly.

---

## Model strategy for Hammerspoon

Because memory/cold starts matter, the harness should be very opinionated.

### Default behavior

Use `glm-4.7-flash` for instant actions unless the user explicitly requests something else.

Why:

- lower latency
- less painful if a load/eject cycle is needed
- good fit for bounded utility tasks

### Escalation behavior

Allow optional escalation to:

- `qwen3.5-122b-a10b` for planning / heavy reasoning
- `qwen/qwen3-coder-next` for coding-oriented actions

### Visual actions

Do not send screenshots/doc/image tasks to text-only models.

Reserve `qwen/qwen3-vl-8b` for explicit visual workflows.

### User-facing consequences

The UI should make it clear when an action may be slow because:

- the selected model is probably not loaded
- a larger model is being requested
- a visual model is being used

Even a simple alert such as “Using heavy model; may cold-start” is enough.

---

## Recommended first features (v1)

Build only these first.

### 1. Summarize clipboard

- hotkey-triggered
- captures clipboard + app/window metadata
- sends to fast model
- returns summary via alert and clipboard

### 2. Explain clipboard error/log

- hotkey-triggered
- prepends a fixed instruction for diagnosis
- uses coding model or fast model depending on size
- returns compact bullet explanation

### 3. Rewrite clipboard tersely

- hotkey-triggered
- useful for emails/notes/messages
- returns rewritten version to clipboard

### 4. Send to Open WebUI

- captures clipboard + metadata
- opens a browser URL for Open WebUI or writes a handoff file that can be loaded there
- intended as an escalation path for deeper multi-turn work

### 5. Menu bar status item

At minimum show:

- local model backend reachable / unreachable
- optional label such as `LM: up` or `LM: down`

Later expand to:

- current active model
- likely busy/idle
- queue depth if a queue layer exists later

---

## Open WebUI integration guidance

Open WebUI should be treated as the **deeper workspace**.

Suggested Hammerspoon integration patterns:

### Lightweight handoff

- open Open WebUI in the browser
- preload clipboard contents into a local handoff file
- optionally copy a templated prompt to clipboard and launch the UI

### Future richer handoff

If Open WebUI later supports a stable API/workflow for pre-seeding conversations in the user’s setup, add that later.

Do not block v1 on deep Open WebUI coupling.

---

## Notes/storage guidance

Because the notes system is not chosen, storage must stay generic.

### Required behavior

Support saving to a configurable directory as markdown/text.

### Suggested first storage modes

- save to `~/notes-inbox/` if configured
- otherwise save to a configurable fallback folder
- optionally write to a shared handoff folder such as:
  - a user-configurable handoff directory
  - a shared local workspace directory

### Design rule

The storage layer should expose an interface like:

- `saveMarkdown(title, body, metadata)`
- `appendInbox(body)`

Do not hardcode a specific notes app.

---

## Error handling expectations

This system should fail clearly.

If something goes wrong, avoid silent no-ops.

Examples:

- backend unreachable -> show alert
- model request fails -> show alert and copy error summary if useful
- no clipboard text -> show alert
- unsupported app-specific capture -> gracefully fall back to clipboard-only mode

The system should be robust enough that a failed browser URL lookup does not break a clipboard summary action.

---

## Security / privacy considerations

- Assume all requests stay local to the machine unless explicitly routed elsewhere
- Keep secrets/config out of the main source if possible
- If an API key is needed for LM Studio, load it from config rather than hardcoding
- Be conservative with logging sensitive clipboard data
- Consider a config flag to disable saving raw captured context to disk

---

## Suggested incremental implementation plan

### Phase 1: basic action path

Implement:

- config loader
- local HTTP client
- clipboard summary action
- one hotkey
- one simple alert result

### Phase 2: better UX

Add:

- clipboard rewrite action
- error explanation action
- menu bar item showing backend up/down
- copy result back to clipboard

### Phase 3: richer context

Add:

- front app / window title capture
- browser URL capture where possible
- Finder selection capture where possible

### Phase 4: escalation and storage

Add:

- send to Open WebUI action
- save to markdown/inbox folder
- abstract storage backend for future notes integration

### Phase 5: advanced status

Only later:

- loaded model visibility if available
- current request/busy state
- queue status if a local queue layer exists later

---

## Advice on implementation style

- Keep the initial code small and debuggable
- Prefer a few boring functions over over-abstracted Lua
- Build a strong direct path from hotkey -> context -> request -> result
- Avoid trying to solve queueing, multi-client routing, or persistent memory in this Hammerspoon layer
- This is a **human-facing convenience harness**, not the final distributed control plane

---

## Success criteria

A successful v1 should let the user:

- press a hotkey
- instantly use a local model from the main user account
- avoid switching into the inference user
- get useful results for bounded tasks
- escalate deeper work into Open WebUI
- save outputs to files without being locked into a notes system yet

If that works reliably, the implementation is on the right track.
