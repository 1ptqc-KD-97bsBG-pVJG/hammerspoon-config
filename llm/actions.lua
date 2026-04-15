local M = {}

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

local function isBlank(value)
  return trim(value) == ""
end

local function collapseWhitespace(value)
  return trim((value or ""):gsub("[%s\194\160]+", " "))
end

local function lineCount(value)
  local text = trim(value or "")
  if text == "" then
    return 0
  end

  local count = 1
  for _ in text:gmatch("\n") do
    count = count + 1
  end
  return count
end

local function previewText(value, maxLength)
  local flattened = collapseWhitespace(value)
  if flattened == "" then
    return ""
  end

  if #flattened <= maxLength then
    return flattened
  end

  return flattened:sub(1, maxLength - 3) .. "..."
end

local function sanitizeModelText(value)
  local text = tostring(value or "")

  local markers = {
    "<|start|>",
    "<|channel|>",
    "<|message|>",
    "<|end|>",
  }

  for _, marker in ipairs(markers) do
    local startPos = text:find(marker, 1, true)
    if startPos then
      text = text:sub(1, startPos - 1)
    end
  end

  return trim(text)
end

local function startsLikeJson(value)
  local text = trim(value or "")
  return text:sub(1, 1) == "{" or text:sub(1, 1) == "["
end

local function punctuationDensity(value)
  local total = 0
  local punct = 0

  for i = 1, #value do
    local ch = value:sub(i, i)
    total = total + 1
    if ch:match("[%p]") then
      punct = punct + 1
    end
  end

  if total == 0 then
    return 0
  end

  return punct / total
end

function M.new(deps)
  local config = deps.config
  local client = deps.client
  local models = deps.models
  local prompts = deps.prompts
  local context = deps.context
  local status = deps.status
  local storage = deps.storage

  local self = {}
  local activeNotifications = {}
  local activeOverlay = nil
  local activeOverlayTimer = nil

  local function developerModeEnabled()
    return status.getDeveloperMode and status.getDeveloperMode() == true
  end

  local function resolvedAlertSeconds(seconds)
    local base = developerModeEnabled()
      and ((config.debug and config.debug.developer_alert_seconds) or 20)
      or ((config.debug and config.debug.alert_seconds) or 12)

    if type(seconds) == "number" and seconds > 0 then
      return math.max(seconds, base)
    end

    return base
  end

  local function maybeCopyAlertToClipboard(message, outputText)
    if not developerModeEnabled() then
      return
    end

    if config.debug and config.debug.copy_alerts_to_clipboard == false then
      return
    end

    if type(outputText) == "string" and trim(outputText) ~= "" then
      hs.pasteboard.setContents(message)
      hs.timer.doAfter((config.debug and config.debug.clipboard_sequence_delay_s) or 0.2, function()
        hs.pasteboard.setContents(outputText)
      end)
      return
    end

    hs.pasteboard.setContents(message)
  end

  local function showNotification(message, seconds)
    local note = hs.notify.new({
      title = "Local Model Harness",
      informativeText = message,
      autoWithdraw = true,
    })

    note:withdrawAfter(0)
    note:send()
    table.insert(activeNotifications, note)

    if #activeNotifications > 20 then
      table.remove(activeNotifications, 1)
    end
  end

  local function dismissOverlay()
    if activeOverlayTimer then
      activeOverlayTimer:stop()
      activeOverlayTimer = nil
    end

    if activeOverlay then
      activeOverlay:delete()
      activeOverlay = nil
    end
  end

  local function estimateWrappedLineCount(message, width)
    local usableWidth = math.max(240, width - 96)
    local charsPerLine = math.max(24, math.floor(usableWidth / 13))
    local total = 0

    for rawLine in tostring(message or ""):gmatch("[^\n]+") do
      local line = collapseWhitespace(rawLine)
      if line == "" then
        total = total + 1
      else
        total = total + math.max(1, math.ceil(#line / charsPerLine))
      end
    end

    return math.max(total, 1)
  end

  local function showOverlay(message, seconds)
    dismissOverlay()

    local focusedWindow = hs.window.frontmostWindow()
    local screen = focusedWindow and focusedWindow:screen() or hs.screen.mainScreen()
    local frame = screen:fullFrame()
    local width = math.min(math.max(frame.w * 0.78, 720), 1500)
    local wrappedLines = estimateWrappedLineCount(message, width)
    local height = math.min(math.max(110, 56 + (wrappedLines * 34)), frame.h * 0.65)
    local top = frame.y + math.max(30, frame.h * 0.035)
    local left = frame.x + ((frame.w - width) / 2)

    activeOverlay = hs.canvas.new({
      x = left,
      y = top,
      w = width,
      h = height,
    })

    activeOverlay:level("overlay")
    activeOverlay:replaceElements(
      {
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = 24, yRadius = 24 },
        fillColor = { red = 0.06, green = 0.06, blue = 0.06, alpha = 0.96 },
        strokeColor = { white = 1.0, alpha = 0.18 },
        strokeWidth = 2,
        frame = { x = 0, y = 0, w = "100%", h = "100%" },
      },
      {
        type = "text",
        text = message,
        textSize = 28,
        textColor = { white = 1.0, alpha = 1.0 },
        textAlignment = "center",
        frame = { x = 34, y = 24, w = width - 68, h = height - 48 },
      }
    )
    activeOverlay:show()

    activeOverlayTimer = hs.timer.doAfter(seconds, function()
      dismissOverlay()
    end)
  end

  local function showAlert(message, seconds, outputText)
    local duration = resolvedAlertSeconds(seconds)
    showOverlay(message, duration)
    showNotification(message, duration)
    maybeCopyAlertToClipboard(message, outputText)
  end

  local function copyResult(text)
    hs.pasteboard.setContents(text)
  end

  local function showClipboardRequired(actionLabel)
    showAlert(string.format("%s needs clipboard text first.", actionLabel), 2)
  end

  local function showNotReady(actionLabel)
    showAlert(string.format("%s is wired but not implemented yet.", actionLabel), 2)
  end

  local function formatFailure(actionLabel, result, profile)
    local message = actionLabel .. " failed."
    local errorObject = result and result.error or {}

    if errorObject.code == "reasoning_only_output" then
      if profile and profile.requires_thinking_disabled then
        return string.format(
          "%s %s is still returning reasoning instead of final text. Disable thinking in LM Studio and retry.",
          message,
          profile.label
        )
      end

      return message .. " The model produced reasoning output but no final text."
    end

    if result and result.error and result.error.message and result.error.message ~= "" then
      message = string.format("%s %s", message, result.error.message)
    end

    if errorObject and type(errorObject.detail) == "string" and errorObject.detail ~= "" then
      local detail = errorObject.detail
      if #detail < 140 then
        message = string.format("%s %s", message, detail)
      end
    end

    return message
  end

  local function buildInstantContext()
    return context.buildContext({
      include_browser = true,
      include_finder = true,
      allow_full_clipboard = false,
    })
  end

  local function getActiveClipboardProfile()
    local profileName = status.getActiveClipboardProfile()
    return models.getClipboardProfile(profileName)
  end

  local function recordBakeoff(event)
    if not config.clipboard.bakeoff_mode then
      return
    end

    storage.appendDiagnosticRecord(event)
  end

  local function looksLikeReasoningLeak(text)
    local lowered = (text or ""):lower()
    return lowered:find("<|start|>", 1, true)
      or lowered:find("<|channel|>analysis", 1, true)
      or lowered:find("<|channel|>commentary", 1, true)
      or lowered:find("<|channel|>final", 1, true)
      or lowered:find("valid channels:", 1, true)
  end

  local function normalizeSummaryText(text)
    local lines = {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
      local cleaned = trim(line)
      if cleaned ~= "" then
        cleaned = cleaned:gsub("^[-*•]%s*", "")
        table.insert(lines, "- " .. cleaned)
      end
    end

    if #lines == 0 then
      return nil
    end

    if #lines > 3 then
      return nil
    end

    return table.concat(lines, "\n")
  end

  local function isBadRewrite(inputText, outputText)
    local output = sanitizeModelText(outputText)
    if output == "" then
      return true, "empty"
    end

    if startsLikeJson(output) then
      return true, "json_wrapper"
    end

    if looksLikeReasoningLeak(output) then
      return true, "reasoning_leak"
    end

    if output == "..." or output:find("…") then
      return true, "ellipsis_stub"
    end

    local inputLength = #collapseWhitespace(inputText)
    local outputLength = #collapseWhitespace(output)
    if inputLength >= 220 and outputLength < math.max(60, math.floor(inputLength * 0.18)) then
      return true, "too_short"
    end

    return false, nil
  end

  local function normalizeErrorExplainText(text)
    local output = sanitizeModelText(text)
    if output == "" then
      return nil
    end

    local lowered = output:lower()
    if lowered:find("root cause", 1, true)
      and lowered:find("immediate fix", 1, true)
      and lowered:find("what to check next", 1, true)
    then
      return output
    end

    return nil
  end

  local function isBadErrorExplain(text)
    local output = sanitizeModelText(text)
    if output == "" then
      return true, "empty"
    end

    if startsLikeJson(output) then
      return true, "json_wrapper"
    end

    if looksLikeReasoningLeak(output) then
      return true, "reasoning_leak"
    end

    if not normalizeErrorExplainText(output) then
      return true, "missing_sections"
    end

    if punctuationDensity(output) > 0.28 then
      return true, "garbled"
    end

    return false, nil
  end

  local function requestPlainText(profile, prompt, maxTokens, callback)
    if profile.api == "responses" then
      client.requestTextResponse({
        model = profile.model,
        system = prompt.system,
        user = prompt.user,
        max_output_tokens = maxTokens,
      }, callback)
      return
    end

    if profile.api == "native_chat" then
      client.requestNativeChat({
        model = profile.model,
        system = prompt.system,
        user = prompt.user,
        max_output_tokens = maxTokens,
        temperature = 0,
        reasoning = profile.reasoning,
      }, callback)
      return
    end

    client.requestPlainChatCompletion({
      model = profile.model,
      system = prompt.system,
      user = prompt.user,
      max_tokens = maxTokens,
      temperature = 0,
    }, callback)
  end

  local function ensureClipboardProfileReady(profile, callback)
    status.ensureClipboardModel(profile, callback)
  end

  local function runClipboardAction(spec)
    local payloadContext = buildInstantContext()
    if isBlank(payloadContext.clipboard) then
      showClipboardRequired(spec.label)
      return
    end

    local profile = getActiveClipboardProfile()
    if not profile then
      showAlert("Active clipboard profile is invalid.", 2.5)
      return
    end

    local startedAt = hs.timer.absoluteTime()
    local prompt = spec.build_prompt(payloadContext)

    local function finishDiagnostics(result)
      local elapsedMs = math.floor((hs.timer.absoluteTime() - startedAt) / 1000000)
      recordBakeoff({
        recorded_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        action = spec.action_name,
        profile = profile.name,
        model = profile.model,
        api = profile.api,
        success = result.success,
        latency_ms = elapsedMs,
        failure_reason = result.failure_reason,
        preview = result.preview,
      })
    end

    local function validate(text)
      local output = sanitizeModelText(text)
      if spec.action_name == "summarizeClipboard" then
        local normalized = normalizeSummaryText(output)
        if not normalized then
          return nil, "invalid_summary"
        end
        return normalized, nil
      end

      if spec.action_name == "rewriteClipboardTersely" then
        local bad, reason = isBadRewrite(payloadContext.clipboard, output)
        if bad then
          return nil, reason
        end
        return output, nil
      end

      local bad, reason = isBadErrorExplain(output)
      if bad then
        return nil, reason
      end
      return normalizeErrorExplainText(output), nil
    end

    local retried = false

    local function handleResult(result)
      if not result.ok then
        status.endBusy()
        finishDiagnostics({
          success = false,
          failure_reason = result.error and result.error.code or "request_failed",
          preview = result.error and result.error.message or "",
        })
        showAlert(formatFailure(spec.label, result, profile), 3)
        return
      end

      local normalized, invalidReason = validate(result.data.text)
      if not normalized and not retried and spec.build_retry_prompt then
        retried = true
        local retryPrompt = spec.build_retry_prompt(payloadContext)
        requestPlainText(profile, retryPrompt, spec.retry_max_tokens or spec.max_tokens, handleResult)
        return
      end

      status.endBusy()

      if not normalized then
        local degradedMessage = spec.label .. " returned degraded output."
        if invalidReason == "reasoning_leak" and profile.requires_thinking_disabled then
          degradedMessage = string.format(
            "%s failed. %s is still in thinking mode. Disable thinking in LM Studio and retry.",
            spec.label,
            profile.label
          )
        end

        finishDiagnostics({
          success = false,
          failure_reason = invalidReason or "invalid_output",
          preview = previewText(result.data.text or "", 120),
        })
        showAlert(degradedMessage, 2.5, result.data.text)
        return
      end

      finishDiagnostics({
        success = true,
        preview = previewText(normalized, 120),
      })
      local successMessage = spec.handle_success(normalized, payloadContext, profile)
      if not developerModeEnabled() or (config.debug and config.debug.copy_alerts_to_clipboard == false) then
        copyResult(normalized)
      end
      showAlert(successMessage, spec.success_seconds, normalized)
    end

    status.beginBusy()
    ensureClipboardProfileReady(profile, function(ensureResult)
      if not ensureResult.ok then
        status.endBusy()
        finishDiagnostics({
          success = false,
          failure_reason = ensureResult.error and ensureResult.error.code or "prepare_failed",
          preview = ensureResult.error and ensureResult.error.message or "",
        })
        showAlert(formatFailure(spec.label, ensureResult, profile), 3)
        return
      end

      requestPlainText(profile, prompt, spec.max_tokens, handleResult)
    end)
  end

  function self.summarizeClipboard()
    runClipboardAction({
      action_name = "summarizeClipboard",
      label = "Summarize Clipboard",
      max_tokens = 240,
      retry_max_tokens = 320,
      build_prompt = prompts.buildSummaryPrompt,
      success_seconds = 3,
      handle_success = function(text, payloadContext, profile)
        local message = string.format("Summary copied to clipboard using %s.", profile.label)
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end
        return message
      end,
    })
  end

  function self.rewriteClipboardTersely()
    runClipboardAction({
      action_name = "rewriteClipboardTersely",
      label = "Rewrite Clipboard Tersely",
      max_tokens = 650,
      retry_max_tokens = 900,
      build_prompt = prompts.buildRewritePrompt,
      build_retry_prompt = prompts.buildRewriteRetryPrompt,
      success_seconds = 3,
      handle_success = function(text, payloadContext, profile)
        local message = string.format("Rewritten text copied to clipboard using %s.", profile.label)
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end
        return message
      end,
    })
  end

  function self.explainClipboardError()
    runClipboardAction({
      action_name = "explainClipboardError",
      label = "Explain Clipboard Error",
      max_tokens = 520,
      retry_max_tokens = 720,
      build_prompt = prompts.buildErrorExplainPrompt,
      build_retry_prompt = prompts.buildErrorExplainRetryPrompt,
      success_seconds = 3.5,
      handle_success = function(text, payloadContext, profile)
        local message = string.format("Error explanation copied to clipboard using %s.", profile.label)
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 120)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end
        return message
      end,
    })
  end

  function self.prepareClipboardModel()
    local profile = getActiveClipboardProfile()
    if not profile then
      showAlert("Active clipboard profile is invalid.", 2.5)
      return
    end

    status.beginBusy()
    status.prepareClipboardModel(profile, function(result)
      status.endBusy()

      if not result.ok then
      showAlert(formatFailure("Prepare Clipboard Model", result, profile), 3.5)
        return
      end

      local unloaded = {}
      for _, item in ipairs(result.data.unloaded or {}) do
        if item.model then
          table.insert(unloaded, item.model)
        end
      end

      local message = result.data.already_prepared
        and string.format("%s was already loaded and is prepared.", profile.label)
        or string.format("Prepared %s.", profile.label)
      if #unloaded > 0 then
        message = message .. "\nUnloaded: " .. table.concat(unloaded, ", ")
      end

      local loadedNow = {}
      for _, item in ipairs(result.data.loaded_instances or {}) do
        if item.model then
          table.insert(loadedNow, item.model)
        end
      end

      if #loadedNow > 0 then
        message = message .. "\nLoaded: " .. table.concat(loadedNow, ", ")
      end

      if profile.requires_thinking_disabled then
        message = message .. "\nReminder: disable thinking for this profile in LM Studio."
      end

      showAlert(message, 4)
    end)
  end

  function self.useClipboardProfile(profileName)
    local ok = status.setActiveClipboardProfile(profileName)
    if not ok then
      showAlert("Unknown clipboard profile: " .. tostring(profileName), 2.5)
      return
    end

    local profile = getActiveClipboardProfile()
    local message = string.format("Active clipboard profile: %s", profile.label)
    if profile.requires_thinking_disabled then
      message = message .. "\nReminder: disable thinking in LM Studio."
    end
    showAlert(message, 2.5)
  end

  function self.toggleDeveloperMode()
    local enabled = status.toggleDeveloperMode()
    local message = enabled
      and "Developer Mode enabled.\nAlerts stay on screen longer and are copied to the clipboard."
      or "Developer Mode disabled."
    showAlert(message, 2.5)
  end

  function self.draftUtilityScript()
    showNotReady("Draft Utility Script")
  end

  function self.sendToOpenWebUI()
    showNotReady("Send To Open WebUI")
  end

  function self.saveClipboardSummary()
    showNotReady("Save Clipboard Summary")
  end

  function self.refreshBackendStatus(options)
    options = options or {}

    status.refreshStatus(function(result)
      if options.silent then
        return
      end

      if result.ok then
        local snapshot = status.getStatusSnapshot()
        local profile = getActiveClipboardProfile()
        local loaded = {}
        for _, item in ipairs(snapshot.loaded_instances or {}) do
          if item.model then
            table.insert(loaded, item.model)
          end
        end

        local lines = {
          "Backend status refreshed.",
          "Clipboard profile: " .. (profile and profile.label or "Unknown"),
          "Chat completions: " .. tostring(snapshot.chat_available),
          "Responses: " .. tostring(snapshot.responses_available),
          "Native unload: " .. tostring(snapshot.unload_available),
        }

        if #loaded > 0 then
          table.insert(lines, "Loaded: " .. table.concat(loaded, ", "))
        end

        showAlert(table.concat(lines, "\n"), 3.5)
      else
        local message = result.error and result.error.message or "Backend refresh failed"
        showAlert(message, 2)
      end
    end)
  end

  return self
end

return M
