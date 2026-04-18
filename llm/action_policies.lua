local M = {}

local CONTEXT_OVERRIDE_DEFS = {
  include_clipboard = {
    key = "include_clipboard",
    label = "Include Clipboard",
    description = "Add clipboard text when an action does not include it by default.",
  },
  include_browser = {
    key = "include_browser",
    label = "Include Browser Context",
    description = "Add active browser URL/title when available.",
  },
  include_finder = {
    key = "include_finder",
    label = "Include Finder Context",
    description = "Add Finder selection even when Finder is not frontmost.",
  },
  include_profile_metadata = {
    key = "include_profile_metadata",
    label = "Include Profile Metadata",
    description = "Add active clipboard profile, model, and API metadata.",
  },
  use_full_clipboard = {
    key = "use_full_clipboard",
    label = "Use Full Clipboard",
    description = "Allow full clipboard capture for actions that support it.",
  },
}

local ACTION_POLICIES = {
  summarizeClipboard = {
    action = "summarizeClipboard",
    label = "Summarize Clipboard",
    prompt_builder = "buildSummaryPrompt",
    validator = "summary",
    profile_behavior = "active_clipboard_profile",
    requires_clipboard = true,
    menu_only = false,
    hotkey_enabled = true,
    default_context = {
      clipboard = true,
      app = true,
      window = true,
    },
    optional_context = {
      browser = true,
      finder = true,
      profile_metadata = true,
      full_clipboard = true,
    },
    allow_full_clipboard = false,
  },
  rewriteClipboardTersely = {
    action = "rewriteClipboardTersely",
    label = "Rewrite Clipboard Tersely",
    prompt_builder = "buildRewritePrompt",
    retry_prompt_builder = "buildRewriteRetryPrompt",
    validator = "rewrite",
    profile_behavior = "active_clipboard_profile",
    requires_clipboard = true,
    menu_only = false,
    hotkey_enabled = true,
    default_context = {
      clipboard = true,
      app = true,
      window = true,
    },
    optional_context = {
      browser = true,
      finder = true,
      profile_metadata = true,
      full_clipboard = true,
    },
    allow_full_clipboard = false,
  },
  explainClipboardError = {
    action = "explainClipboardError",
    label = "Explain Clipboard Error",
    prompt_builder = "buildErrorExplainPrompt",
    retry_prompt_builder = "buildErrorExplainRetryPrompt",
    validator = "error_explain",
    profile_behavior = "active_clipboard_profile",
    requires_clipboard = true,
    menu_only = false,
    hotkey_enabled = true,
    default_context = {
      clipboard = true,
      app = true,
      window = true,
    },
    optional_context = {
      browser = true,
      finder = true,
      profile_metadata = true,
      full_clipboard = true,
    },
    allow_full_clipboard = false,
  },
  draftUtilityScript = {
    action = "draftUtilityScript",
    label = "Draft Utility Script",
    prompt_builder = "buildScriptDraftPrompt",
    validator = "script_draft",
    profile_behavior = "active_clipboard_profile",
    requires_clipboard = false,
    menu_only = false,
    hotkey_enabled = true,
    default_context = {
      clipboard = true,
      app = true,
      window = true,
      finder = true,
    },
    optional_context = {
      browser = true,
      profile_metadata = true,
      full_clipboard = true,
    },
    allow_full_clipboard = true,
  },
  sendToOpenWebUI = {
    action = "sendToOpenWebUI",
    label = "Send To Open WebUI",
    prompt_builder = "buildOpenWebUISeedPrompt",
    validator = "handoff",
    profile_behavior = "active_clipboard_profile",
    requires_clipboard = false,
    menu_only = false,
    hotkey_enabled = true,
    default_context = {
      clipboard = true,
      app = true,
      window = true,
      browser = true,
      finder = true,
      profile_metadata = true,
      full_clipboard = true,
    },
    optional_context = {},
    allow_full_clipboard = true,
  },
  saveClipboardSummary = {
    action = "saveClipboardSummary",
    label = "Save Clipboard Summary",
    prompt_builder = "buildSummaryPrompt",
    validator = "summary",
    profile_behavior = "active_clipboard_profile",
    requires_clipboard = true,
    menu_only = false,
    hotkey_enabled = true,
    default_context = {
      clipboard = true,
      app = true,
      window = true,
    },
    optional_context = {
      browser = true,
      finder = true,
      profile_metadata = true,
      full_clipboard = true,
    },
    allow_full_clipboard = false,
  },
}

local function shallowCopy(source)
  local copy = {}
  for key, value in pairs(source or {}) do
    if type(value) == "table" then
      local nested = {}
      for nestedKey, nestedValue in pairs(value) do
        nested[nestedKey] = nestedValue
      end
      copy[key] = nested
    else
      copy[key] = value
    end
  end
  return copy
end

local function isEnabled(map, key)
  return type(map) == "table" and map[key] == true
end

M._test = {
  policies = ACTION_POLICIES,
  context_override_defs = CONTEXT_OVERRIDE_DEFS,
}

function M.new()
  local self = {}

  function self.getActionPolicy(actionName)
    local policy = ACTION_POLICIES[actionName]
    if not policy then
      return nil
    end

    return shallowCopy(policy)
  end

  function self.listActionPolicies()
    local items = {}
    for _, policy in pairs(ACTION_POLICIES) do
      table.insert(items, shallowCopy(policy))
    end

    table.sort(items, function(a, b)
      return a.action < b.action
    end)

    return items
  end

  function self.listContextOverrideDefs()
    local items = {}
    for _, def in pairs(CONTEXT_OVERRIDE_DEFS) do
      table.insert(items, shallowCopy(def))
    end

    table.sort(items, function(a, b)
      return a.key < b.key
    end)

    return items
  end

  function self.isKnownContextOverride(key)
    return CONTEXT_OVERRIDE_DEFS[key] ~= nil
  end

  function self.resolveContextOptions(actionName, overrides)
    local policy = ACTION_POLICIES[actionName]
    if not policy then
      return nil
    end

    local defaultContext = policy.default_context or {}
    local optionalContext = policy.optional_context or {}
    local fullClipboardEnabled = policy.allow_full_clipboard and (defaultContext.full_clipboard == true or isEnabled(overrides, "use_full_clipboard"))

    return {
      source = defaultContext.clipboard and "clipboard" or "context",
      include_clipboard = defaultContext.clipboard == true or isEnabled(overrides, "include_clipboard"),
      include_app = defaultContext.app ~= false,
      include_window = defaultContext.window ~= false,
      include_browser = defaultContext.browser == true or (optionalContext.browser == true and isEnabled(overrides, "include_browser")),
      include_finder = defaultContext.finder == true or (optionalContext.finder == true and isEnabled(overrides, "include_finder")),
      force_finder = defaultContext.finder == true or isEnabled(overrides, "include_finder"),
      include_profile_metadata = defaultContext.profile_metadata == true or (optionalContext.profile_metadata == true and isEnabled(overrides, "include_profile_metadata")),
      allow_full_clipboard = fullClipboardEnabled,
      context_flags = {
        clipboard = defaultContext.clipboard == true or isEnabled(overrides, "include_clipboard"),
        app = defaultContext.app ~= false,
        window = defaultContext.window ~= false,
        browser = defaultContext.browser == true or (optionalContext.browser == true and isEnabled(overrides, "include_browser")),
        finder = defaultContext.finder == true or (optionalContext.finder == true and isEnabled(overrides, "include_finder")),
        profile_metadata = defaultContext.profile_metadata == true or (optionalContext.profile_metadata == true and isEnabled(overrides, "include_profile_metadata")),
        full_clipboard = fullClipboardEnabled,
      },
    }
  end

  function self.describeEnabledContext(contextOptions)
    local enabled = {}
    local flags = contextOptions and contextOptions.context_flags or {}

    if flags.clipboard then
      table.insert(enabled, "clipboard")
    end
    if flags.app then
      table.insert(enabled, "app")
    end
    if flags.window then
      table.insert(enabled, "window")
    end
    if flags.browser then
      table.insert(enabled, "browser")
    end
    if flags.finder then
      table.insert(enabled, "finder")
    end
    if flags.profile_metadata then
      table.insert(enabled, "profile_metadata")
    end
    if flags.full_clipboard then
      table.insert(enabled, "full_clipboard")
    end

    return enabled
  end

  return self
end

return M
