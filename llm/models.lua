local M = {}

local CODE_PATTERNS = {
  "Traceback",
  "Exception",
  "SyntaxError",
  "ReferenceError",
  "TypeError",
  "stack trace",
  "stderr",
  "stdout",
  "line %d+",
  ":%d+:%d+",
  " at [%w_%.]+%(",
  "WARN",
  "ERROR",
  "INFO",
  "{",
  "}",
  ";",
}

local CLIPBOARD_ACTIONS = {
  summarizeClipboard = true,
  rewriteClipboardTersely = true,
  explainClipboardError = true,
}

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

function M.new(config)
  local self = {}

  function self.looksLikeCodeOrLog(text)
    local sample = trim(text)
    if sample == "" then
      return false
    end

    if sample:find("\n") and (sample:find("{") or sample:find("function") or sample:find("def ")) then
      return true
    end

    for _, pattern in ipairs(CODE_PATTERNS) do
      if sample:find(pattern) then
        return true
      end
    end

    return false
  end

  function self.isClipboardAction(actionName)
    return CLIPBOARD_ACTIONS[actionName] == true
  end

  function self.listClipboardProfiles()
    local profiles = {}
    for name, profile in pairs(config.clipboard.profiles) do
      table.insert(profiles, {
        name = name,
        label = profile.label,
        model = profile.model,
        api = profile.api,
        requires_thinking_disabled = profile.requires_thinking_disabled == true,
      })
    end

    table.sort(profiles, function(a, b)
      return a.name < b.name
    end)

    return profiles
  end

  function self.getClipboardProfile(profileName)
    local name = profileName or config.clipboard.active_profile
    local profile = config.clipboard.profiles[name]
    if not profile then
      return nil
    end

    return {
      name = name,
      label = profile.label,
      model = profile.model,
      api = profile.api,
      reasoning = profile.reasoning,
      requires_thinking_disabled = profile.requires_thinking_disabled == true,
    }
  end

  function self.getClipboardProfileNames()
    local names = {}
    for name in pairs(config.clipboard.profiles) do
      table.insert(names, name)
    end
    table.sort(names)
    return names
  end

  function self.describeClipboardProfile(profileName)
    local profile = self.getClipboardProfile(profileName)
    if not profile then
      return nil
    end

    profile.summary = string.format(
      "%s -> %s via %s",
      profile.name,
      profile.model,
      profile.api
    )
    return profile
  end

  function self.resolveRoleForAction(actionName)
    if self.isClipboardAction(actionName) then
      return "clipboard"
    end

    if actionName == "draftUtilityScript" then
      return "code"
    end

    if actionName == "sendToOpenWebUI" or actionName == "saveClipboardSummary" then
      return "fast"
    end

    return "fast"
  end

  function self.resolveModelForRole(role, profileName)
    if role == "clipboard" then
      local profile = self.getClipboardProfile(profileName)
      return profile and profile.model or nil
    end

    if role == "reason" then
      return config.models.reason
    end

    if role == "code" then
      return config.models.code
    end

    if role == "vision" then
      return config.models.vision
    end

    return config.models.fast
  end

  function self.describeSelection(actionName, text, profileName)
    local role = self.resolveRoleForAction(actionName, text)
    if role == "clipboard" then
      local profile = self.describeClipboardProfile(profileName)
      return {
        action = actionName,
        role = role,
        model = profile.model,
        api = profile.api,
        profile = profile.name,
        profile_label = profile.label,
        is_code_like = self.looksLikeCodeOrLog(text),
        summary = string.format("%s -> %s (%s)", actionName, profile.model, profile.name),
      }
    end

    local model = self.resolveModelForRole(role)
    return {
      action = actionName,
      role = role,
      model = model,
      is_code_like = self.looksLikeCodeOrLog(text),
      summary = string.format("%s -> %s (%s)", actionName, model, role),
    }
  end

  return self
end

return M
