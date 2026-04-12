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

local ACTION_ROLE_MAP = {
  summarizeClipboard = "fast",
  rewriteClipboardTersely = "fast",
  explainClipboardError = "fast",
  draftUtilityScript = "code",
  sendToOpenWebUI = "fast",
  saveClipboardSummary = "fast",
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

  function self.resolveRoleForAction(actionName, text)
    if actionName == "explainClipboardError" and self.looksLikeCodeOrLog(text) then
      return "code"
    end

    return ACTION_ROLE_MAP[actionName] or "fast"
  end

  function self.resolveModelForRole(role)
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

  function self.resolveModelForAction(actionName, text)
    local role = self.resolveRoleForAction(actionName, text)
    return {
      action = actionName,
      role = role,
      model = self.resolveModelForRole(role),
      is_code_like = self.looksLikeCodeOrLog(text),
    }
  end

  function self.requiresColdStartWarning(modelId, role)
    return role ~= "fast" and modelId ~= config.models.fast
  end

  function self.describeSelection(actionName, text)
    local resolved = self.resolveModelForAction(actionName, text)
    local summary = string.format("%s -> %s (%s)", actionName, resolved.model, resolved.role)
    if actionName == "explainClipboardError" and resolved.role == "code" then
      summary = summary .. " [code/log heuristic]"
    end

    resolved.summary = summary
    return resolved
  end

  function self.isFastModel(modelId)
    return modelId == config.models.fast
  end

  return self
end

return M
