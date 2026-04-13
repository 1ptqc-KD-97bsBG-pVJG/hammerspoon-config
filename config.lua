local home = os.getenv("HOME") or "~"

local M = {
  backend = {
    kind = "lmstudio",
    base_url = "http://localhost:1234",
    openai_base = "http://localhost:1234/v1",
    native_base = "http://localhost:1234/api/v1",
    api_token_env = "LM_STUDIO_API_TOKEN",
    request_timeout_ms = 45000,
    status_timeout_ms = 1500,
    enable_native_model_management = true,
    auto_load_fast_model = true,
    auto_load_non_fast_models = false,
    unload_other_models_before_load = true,
  },
  models = {
    fast = "openai/gpt-oss-20b",
    reason = "qwen3.5-122b-a10b",
    code = "qwen/qwen3-coder-next",
    vision = "qwen/qwen3-vl-8b",
    background = "zai-org/glm-4.7-flash",
  },
  ui = {
    modifier = { "cmd", "alt", "ctrl" },
    hotkeys = {
      summarize = "S",
      explain_error = "E",
      rewrite_terse = "R",
      draft_script = "G",
      open_webui = "O",
      save_summary = "W",
    },
    primary_browser_app = "Zen",
    primary_browser_bundle_id = nil,
    open_webui_url = "http://localhost:3000",
  },
  storage = {
    output_dir = home .. "/Documents/hammerspoon-lm/output",
    inbox_file = home .. "/Documents/hammerspoon-lm/inbox.md",
    handoff_dir = home .. "/Documents/hammerspoon-lm/handoff",
    script_drafts_dir = home .. "/Documents/hammerspoon-lm/scripts",
    include_raw_context = false,
  },
  features = {
    browser_context = true,
    finder_context = true,
    script_drafting = true,
  },
  scripts = {
    default_language = "python",
    open_after_generate = true,
  },
  limits = {
    instant_clipboard_chars = 12000,
  },
  status = {
    refresh_interval_s = 30,
  },
}

local function deepMerge(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" and type(target[key]) == "table" then
      deepMerge(target[key], value)
    else
      target[key] = value
    end
  end
end

local function expandPath(path)
  if type(path) ~= "string" then
    return path
  end

  if path == "~" then
    return home
  end

  if path:sub(1, 2) == "~/" then
    return home .. path:sub(2)
  end

  return path
end

local function normalizeUrl(url)
  if type(url) ~= "string" then
    return url
  end

  return (url:gsub("/+$", ""))
end

local function normalizeConfig()
  M.backend.base_url = normalizeUrl(M.backend.base_url)
  M.backend.openai_base = normalizeUrl(M.backend.openai_base)
  M.backend.native_base = normalizeUrl(M.backend.native_base)

  M.storage.output_dir = expandPath(M.storage.output_dir)
  M.storage.inbox_file = expandPath(M.storage.inbox_file)
  M.storage.handoff_dir = expandPath(M.storage.handoff_dir)
  M.storage.script_drafts_dir = expandPath(M.storage.script_drafts_dir)
end

local function isNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

local localOverridesLoaded, localOverrides = pcall(require, "config.local")
if localOverridesLoaded and type(localOverrides) == "table" then
  deepMerge(M, localOverrides)
end

function M.validate()
  normalizeConfig()

  local requiredStrings = {
    { value = M.backend.kind, label = "backend.kind" },
    { value = M.backend.base_url, label = "backend.base_url" },
    { value = M.backend.openai_base, label = "backend.openai_base" },
    { value = M.backend.native_base, label = "backend.native_base" },
    { value = M.models.fast, label = "models.fast" },
    { value = M.models.reason, label = "models.reason" },
    { value = M.models.code, label = "models.code" },
    { value = M.models.vision, label = "models.vision" },
    { value = M.ui.primary_browser_app, label = "ui.primary_browser_app" },
    { value = M.ui.open_webui_url, label = "ui.open_webui_url" },
    { value = M.storage.output_dir, label = "storage.output_dir" },
    { value = M.storage.inbox_file, label = "storage.inbox_file" },
    { value = M.storage.handoff_dir, label = "storage.handoff_dir" },
    { value = M.storage.script_drafts_dir, label = "storage.script_drafts_dir" },
    { value = M.scripts.default_language, label = "scripts.default_language" },
  }

  for _, entry in ipairs(requiredStrings) do
    if not isNonEmptyString(entry.value) then
      return false, string.format("Missing required config: %s", entry.label)
    end
  end

  if type(M.ui.modifier) ~= "table" or #M.ui.modifier == 0 then
    return false, "ui.modifier must be a non-empty table"
  end

  if type(M.ui.hotkeys) ~= "table" then
    return false, "ui.hotkeys must be a table"
  end

  if type(M.backend.request_timeout_ms) ~= "number" or M.backend.request_timeout_ms <= 0 then
    return false, "backend.request_timeout_ms must be a positive number"
  end

  if type(M.backend.status_timeout_ms) ~= "number" or M.backend.status_timeout_ms <= 0 then
    return false, "backend.status_timeout_ms must be a positive number"
  end

  if type(M.backend.auto_load_fast_model) ~= "boolean" then
    return false, "backend.auto_load_fast_model must be a boolean"
  end

  if type(M.backend.auto_load_non_fast_models) ~= "boolean" then
    return false, "backend.auto_load_non_fast_models must be a boolean"
  end

  if type(M.backend.unload_other_models_before_load) ~= "boolean" then
    return false, "backend.unload_other_models_before_load must be a boolean"
  end

  if type(M.limits.instant_clipboard_chars) ~= "number" or M.limits.instant_clipboard_chars <= 0 then
    return false, "limits.instant_clipboard_chars must be a positive number"
  end

  if type(M.status.refresh_interval_s) ~= "number" or M.status.refresh_interval_s <= 0 then
    return false, "status.refresh_interval_s must be a positive number"
  end

  return true
end

return M
