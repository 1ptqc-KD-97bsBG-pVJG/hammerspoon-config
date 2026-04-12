local M = {}

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

local function isBlank(value)
  return trim(value) == ""
end

local function previewText(value, maxLength)
  local flattened = trim((value or ""):gsub("%s+", " "))
  if flattened == "" then
    return ""
  end

  if #flattened <= maxLength then
    return flattened
  end

  return flattened:sub(1, maxLength - 3) .. "..."
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

  local self = {}

  local function showAlert(message, seconds)
    hs.alert.show(message, nil, nil, seconds or 2)
  end

  local function showNotReady(actionLabel)
    showAlert(string.format("%s is wired but not implemented yet.", actionLabel), 2)
  end

  local function showClipboardRequired(actionLabel)
    showAlert(string.format("%s needs clipboard text first.", actionLabel), 2)
  end

  local function showColdStartWarning(modelId, role)
    local roleLabel = role == "code" and "code" or role
    showAlert(string.format("Loading %s model: %s", roleLabel, modelId), 2.5)
  end

  local function copyResult(text)
    hs.pasteboard.setContents(text)
  end

  local function formatFailure(actionLabel, result)
    local message = actionLabel .. " failed."
    if result and result.error and result.error.message and result.error.message ~= "" then
      message = string.format("%s %s", message, result.error.message)
    else
      local snapshot = status.getStatusSnapshot()
      if snapshot.last_error and snapshot.last_error ~= "" then
        message = string.format("%s %s", message, snapshot.last_error)
      end
    end

    return message
  end

  local function errorText(result)
    if not result or not result.error then
      return ""
    end

    local message = tostring(result.error.message or "")
    local detail = tostring(result.error.detail or "")
    return (message .. " " .. detail):lower()
  end

  local function shouldRetryWithModelLoad(result)
    if not config.backend.enable_native_model_management then
      return false
    end

    local combined = errorText(result)
    if combined == "" then
      return false
    end

    return combined:find("model not loaded", 1, true)
      or combined:find("not currently loaded", 1, true)
      or combined:find("no model loaded", 1, true)
      or combined:find("load the model", 1, true)
      or combined:find("load a model", 1, true)
      or combined:find("model is not loaded", 1, true)
  end

  local function shouldFallbackToFast(result)
    local combined = errorText(result)
    if combined == "" then
      return false
    end

    return combined:find("insufficient system resources", 1, true)
      or combined:find("insufficient resources", 1, true)
      or combined:find("overload", 1, true)
      or combined:find("out of memory", 1, true)
      or combined:find("not enough memory", 1, true)
      or combined:find("cannot load model", 1, true)
  end

  local function buildInstantContext()
    return context.buildContext({
      include_browser = true,
      include_finder = true,
      allow_full_clipboard = false,
    })
  end

  local function seemsTriviallyShortForRewrite(inputText, outputText)
    local inputLength = #(trim(inputText or ""))
    local outputLength = #(trim(outputText or ""))

    if inputLength < 140 then
      return false
    end

    return outputLength > 0 and outputLength < math.max(24, math.floor(inputLength * 0.16))
  end

  local function looksLikePlaceholder(value)
    local text = trim(value or ""):lower()
    if text == "" then
      return true
    end

    return text:sub(-3) == "..."
      or text:find("^original")
      or text:find("^i am running")
      or text == "..."
  end

  local function looksCorrupted(value)
    local text = trim(value or "")
    if text == "" then
      return true
    end

    if punctuationDensity(text) > 0.35 then
      return true
    end

    if text:find("…") and punctuationDensity(text) > 0.2 then
      return true
    end

    return false
  end

  local function isBadStructuredOutput(spec, parsed, normalized, payloadContext)
    local text = trim(normalized or "")
    if text == "" then
      return true
    end

    if spec.action_name == "rewriteClipboardTersely" then
      return looksLikePlaceholder(parsed.text or text) or seemsTriviallyShortForRewrite(payloadContext.clipboard, text)
    end

    if spec.action_name == "explainClipboardError" then
      return looksCorrupted(parsed.root_cause or "")
        or looksCorrupted(parsed.immediate_fix or "")
        or looksCorrupted(parsed.next_checks or "")
    end

    return false
  end

  local function fastSelection(actionName, text)
    return {
      action = actionName,
      role = "fast",
      model = models.resolveModelForRole("fast"),
      is_code_like = models.looksLikeCodeOrLog(text),
      summary = string.format("%s -> %s (fast)", actionName, models.resolveModelForRole("fast")),
    }
  end

  local function choosePrimarySelection(spec, payloadContext)
    local desired = models.describeSelection(spec.action_name, payloadContext.clipboard)

    if desired.role == "fast" then
      return desired
    end

    if status.isModelLoaded(desired.model) then
      return desired
    end

    if config.backend.auto_load_non_fast_models then
      return desired
    end

    return fastSelection(spec.action_name, payloadContext.clipboard)
  end

  local function runTextAction(spec)
    local payloadContext = buildInstantContext()
    if isBlank(payloadContext.clipboard) then
      showClipboardRequired(spec.label)
      return
    end

    local primarySelection = choosePrimarySelection(spec, payloadContext)
    local prompt = spec.build_prompt(payloadContext)

    local function requestInference(modelSelection, done)
      client.requestStructuredChatResponse({
        model = modelSelection.model,
        system = prompt.system,
        user = prompt.user,
        max_tokens = spec.max_output_tokens,
        schema_name = spec.schema_name,
        schema = spec.schema,
        temperature = spec.temperature,
      }, done)
    end

    local function handleFinalResult(result, modelSelection)
      status.endBusy()

      if not result.ok then
        showAlert(formatFailure(spec.label, result), 3)
        return
      end

      local normalized = spec.normalize_result(result.data.parsed)
      if not normalized or trim(normalized) == "" then
        showAlert(spec.label .. " returned an empty response.", 2.5)
        return
      end

      if isBadStructuredOutput(spec, result.data.parsed, normalized, payloadContext) then
        showAlert(spec.label .. " returned degraded output.", 2.5)
        return
      end

      spec.handle_success(normalized, payloadContext, modelSelection, result.data.parsed)
    end

    local function runFastFallback()
      local fallbackSelection = fastSelection(spec.action_name, payloadContext.clipboard)
      requestInference(fallbackSelection, function(fallbackResult)
        handleFinalResult(fallbackResult, fallbackSelection)
      end)
    end

    status.beginBusy()
    local retriedForQuality = false

    local function processResult(result, modelSelection)
      if result.ok then
        local normalized = spec.normalize_result(result.data.parsed)
        if isBadStructuredOutput(spec, result.data.parsed, normalized, payloadContext) and not retriedForQuality then
          retriedForQuality = true
          requestInference(modelSelection, function(retryResult)
            processResult(retryResult, modelSelection)
          end)
          return
        end
      end

      handleFinalResult(result, modelSelection)
    end

    requestInference(primarySelection, function(initialResult)
      if initialResult.ok or not shouldRetryWithModelLoad(initialResult) then
        if not initialResult.ok and spec.allow_fast_fallback and shouldFallbackToFast(initialResult) then
          runFastFallback()
          return
        end

        processResult(initialResult, primarySelection)
        return
      end

      status.ensureModelReady(primarySelection.model, primarySelection.role, {
        onWarning = showColdStartWarning,
      }, function(ensureResult)
        if not ensureResult.ok then
          if spec.allow_fast_fallback and shouldFallbackToFast(ensureResult) then
            runFastFallback()
            return
          end

          handleFinalResult(ensureResult, primarySelection)
          return
        end

        requestInference(primarySelection, function(retriedResult)
          if not retriedResult.ok and spec.allow_fast_fallback and shouldFallbackToFast(retriedResult) then
            runFastFallback()
            return
          end

          processResult(retriedResult, primarySelection)
        end)
      end)
    end)
  end

  function self.summarizeClipboard()
    runTextAction({
      action_name = "summarizeClipboard",
      label = "Summarize Clipboard",
      max_output_tokens = 400,
      temperature = 0,
      schema_name = "clipboard_summary",
      schema = {
        type = "object",
        properties = {
          bullets = {
            type = "array",
            items = { type = "string" },
            minItems = 1,
            maxItems = 3,
          },
        },
        required = { "bullets" },
        additionalProperties = false,
      },
      build_prompt = prompts.buildSummaryPrompt,
      normalize_result = function(parsed)
        local bullets = {}
        for _, bullet in ipairs(parsed.bullets or {}) do
          local cleaned = trim(bullet)
          if cleaned ~= "" then
            table.insert(bullets, "- " .. cleaned)
          end
        end
        return table.concat(bullets, "\n")
      end,
      handle_success = function(text, payloadContext)
        copyResult(text)
        local message = "Summary copied to clipboard."
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end

        showAlert(message, 3)
      end,
    })
  end

  function self.rewriteClipboardTersely()
    runTextAction({
      action_name = "rewriteClipboardTersely",
      label = "Rewrite Clipboard Tersely",
      max_output_tokens = 900,
      temperature = 0,
      schema_name = "clipboard_rewrite",
      schema = {
        type = "object",
        properties = {
          text = { type = "string" },
        },
        required = { "text" },
        additionalProperties = false,
      },
      build_prompt = prompts.buildRewritePrompt,
      normalize_result = function(parsed)
        return trim(parsed.text or "")
      end,
      handle_success = function(text, payloadContext)
        copyResult(text)
        local message = "Rewritten text copied to clipboard."
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end

        showAlert(message, 3)
      end,
    })
  end

  function self.explainClipboardError()
    runTextAction({
      action_name = "explainClipboardError",
      label = "Explain Clipboard Error",
      max_output_tokens = 1100,
      temperature = 0,
      allow_fast_fallback = true,
      schema_name = "clipboard_error_explanation",
      schema = {
        type = "object",
        properties = {
          root_cause = { type = "string" },
          immediate_fix = { type = "string" },
          next_checks = { type = "string" },
        },
        required = { "root_cause", "immediate_fix", "next_checks" },
        additionalProperties = false,
      },
      build_prompt = prompts.buildErrorExplainPrompt,
      normalize_result = function(parsed)
        return table.concat({
          "Root cause",
          trim(parsed.root_cause or ""),
          "",
          "Immediate fix",
          trim(parsed.immediate_fix or ""),
          "",
          "What to check next",
          trim(parsed.next_checks or ""),
        }, "\n")
      end,
      handle_success = function(text, payloadContext, modelSelection)
        copyResult(text)
        local message = "Error explanation copied to clipboard."
        if modelSelection.role == "code" then
          message = message .. " Used code model."
        else
          message = message .. " Used fast fallback model."
        end
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 120)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end

        showAlert(message, 3.5)
      end,
    })
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
        showAlert("Backend status refreshed.", 1.5)
      else
        local message = result.error and result.error.message or "Backend refresh failed"
        showAlert(message, 2)
      end
    end)
  end

  return self
end

return M
