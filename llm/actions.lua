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
  local policies = deps.policies
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

  local function showFinderRequired(actionLabel)
    showAlert(string.format("%s needs a Finder selection first.", actionLabel), 2)
  end

  local function showTaskDescriptionRequired(actionLabel)
    showAlert(string.format("%s needs a task description first.", actionLabel), 2)
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
    local overrides = developerModeEnabled() and status.getContextOverrides() or {}
    return overrides
  end

  local function buildActionContext(actionName, profile)
    local contextOptions = policies.resolveContextOptions(actionName, buildInstantContext())
    if not contextOptions then
      return nil, nil
    end

    local payloadContext = context.buildContext(contextOptions)
    if contextOptions.include_profile_metadata then
      payloadContext.profile_metadata = {
        name = profile.name,
        label = profile.label,
        model = profile.model,
        api = profile.api,
      }
    end

    payloadContext.context_flags = policies.describeEnabledContext(contextOptions)
    return payloadContext, contextOptions
  end

  local function promptForTaskDescription(title)
    local button, text = hs.dialog.textPrompt(
      title,
      "Describe the script or helper you want to generate.",
      "",
      "Generate",
      "Cancel"
    )

    if button ~= "Generate" then
      return nil
    end

    local taskDescription = trim(text)
    if taskDescription == "" then
      return ""
    end

    return taskDescription
  end

  local function metadataFromContext(actionName, payloadContext, profile)
    local metadata = {
      { label = "Action", value = actionName },
      { label = "Captured At", value = payloadContext.captured_at },
      { label = "App", value = payloadContext.app },
      { label = "Window", value = payloadContext.window_title },
      { label = "URL", value = payloadContext.url },
      { label = "Page Title", value = payloadContext.page_title },
      { label = "Profile", value = profile and profile.label or nil },
      { label = "Model", value = profile and profile.model or nil },
      { label = "API", value = profile and profile.api or nil },
    }

    return metadata
  end

  local function renderContextSummaryMarkdown(payloadContext)
    local lines = {
      "## Captured Context",
      "",
    }

    if payloadContext.app and payloadContext.app ~= "" then
      table.insert(lines, "- App: " .. payloadContext.app)
    end
    if payloadContext.window_title and payloadContext.window_title ~= "" then
      table.insert(lines, "- Window: " .. payloadContext.window_title)
    end
    if payloadContext.url and payloadContext.url ~= "" then
      table.insert(lines, "- URL: " .. payloadContext.url)
    end
    if payloadContext.page_title and payloadContext.page_title ~= "" then
      table.insert(lines, "- Page Title: " .. payloadContext.page_title)
    end
    if payloadContext.profile_metadata and payloadContext.profile_metadata.label then
      table.insert(lines, "- Clipboard Profile: " .. payloadContext.profile_metadata.label)
    end
    if payloadContext.profile_metadata and payloadContext.profile_metadata.model then
      table.insert(lines, "- Model: " .. payloadContext.profile_metadata.model)
    end
    if payloadContext.profile_metadata and payloadContext.profile_metadata.api then
      table.insert(lines, "- API: " .. payloadContext.profile_metadata.api)
    end

    if type(payloadContext.finder_selection) == "table" and #payloadContext.finder_selection > 0 then
      table.insert(lines, "")
      table.insert(lines, "## Finder Selection")
      table.insert(lines, "")
      for _, item in ipairs(payloadContext.finder_selection) do
        table.insert(lines, "- " .. item)
      end
    end

    if payloadContext.clipboard and payloadContext.clipboard ~= "" then
      table.insert(lines, "")
      table.insert(lines, "## Clipboard")
      table.insert(lines, "")
      table.insert(lines, "```")
      table.insert(lines, payloadContext.clipboard)
      table.insert(lines, "```")
    end

    return table.concat(lines, "\n")
  end

  local function openUrlInPrimaryBrowser(url)
    if not url or url == "" then
      return false
    end

    if config.ui.primary_browser_bundle_id and config.ui.primary_browser_bundle_id ~= "" then
      hs.urlevent.openURLWithBundle(url, config.ui.primary_browser_bundle_id)
      return true
    end

    if config.ui.primary_browser_app and config.ui.primary_browser_app ~= "" then
      local task = hs.task.new("/usr/bin/open", nil, {
        "-a",
        config.ui.primary_browser_app,
        url,
      })
      if task then
        task:start()
        return true
      end
    end

    hs.urlevent.openURL(url)
    return true
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

  local function collectMeaningfulLines(text)
    local lines = {}
    for line in tostring(text or ""):gmatch("[^\n]+") do
      local cleaned = trim(line)
      if cleaned ~= "" then
        table.insert(lines, cleaned)
      end
    end
    return lines
  end

  local function normalizeBulletList(text, minimum, maximum)
    local lines = {}
    for _, line in ipairs(collectMeaningfulLines(text)) do
      local cleaned = line
        :gsub("^[-*•]%s*", "")
        :gsub("^%d+[.)]%s*", "")
      if cleaned ~= "" then
        table.insert(lines, "- " .. cleaned)
      end
    end

    if #lines < minimum or #lines > maximum then
      return nil
    end

    return table.concat(lines, "\n")
  end

  local function looksLikeParagraph(text)
    local lines = collectMeaningfulLines(text)
    return #lines <= 2 and collapseWhitespace(text):find("%.%s+") ~= nil
  end

  local function normalizeActionItems(text)
    local normalized = normalizeBulletList(text, 2, 7)
    if not normalized then
      return nil
    end

    local disallowedStarts = {
      ["is "] = true,
      ["are "] = true,
      ["was "] = true,
      ["were "] = true,
      ["there is "] = true,
      ["there are "] = true,
    }

    for line in normalized:gmatch("[^\n]+") do
      local body = trim((line:gsub("^%- %s*", ""))):lower()
      for prefix in pairs(disallowedStarts) do
        if body:find("^" .. prefix) then
          return nil
        end
      end
    end

    return normalized
  end

  local function normalizeCleanUpDraft(text)
    local output = sanitizeModelText(text)
    if output == "" then
      return nil
    end
    if startsLikeJson(output) or looksLikeReasoningLeak(output) then
      return nil
    end
    if output:match("^Title options:") then
      return nil
    end
    if normalizeBulletList(output, 2, 12) and not looksLikeParagraph(output) then
      return nil
    end
    return output
  end

  local function normalizeReplyDraft(text)
    local output = sanitizeModelText(text)
    if output == "" then
      return nil
    end
    if startsLikeJson(output) or looksLikeReasoningLeak(output) then
      return nil
    end
    if output:lower():find("^subject:", 1, true) then
      return nil
    end
    if normalizeBulletList(output, 2, 12) and not looksLikeParagraph(output) then
      return nil
    end
    return output
  end

  local function normalizeTitlePack(text)
    local output = sanitizeModelText(text)
    if output == "" then
      return nil
    end
    if startsLikeJson(output) or looksLikeReasoningLeak(output) then
      return nil
    end

    local lines = collectMeaningfulLines(output)
    if #lines < 6 then
      return nil
    end

    if lines[1] ~= "Title options:" then
      return nil
    end

    local bullets = {}
    local subjectLine = nil
    local slugLine = nil

    for i = 2, #lines do
      local line = lines[i]
      if #bullets < 3 then
        if not line:find("^%- ", 1, true) then
          return nil
        end
        table.insert(bullets, line)
      elseif not subjectLine then
        if not line:find("^Subject:%s*.+") then
          return nil
        end
        subjectLine = line
      elseif not slugLine then
        if not line:find("^Slug:%s*[%w%-]+$") then
          return nil
        end
        slugLine = line
      else
        return nil
      end
    end

    if #bullets ~= 3 or not subjectLine or not slugLine then
      return nil
    end

    return table.concat({
      "Title options:",
      bullets[1],
      bullets[2],
      bullets[3],
      subjectLine,
      slugLine,
    }, "\n")
  end

  local function normalizeRenamePlan(text)
    local output = sanitizeModelText(text)
    if output == "" or startsLikeJson(output) or looksLikeReasoningLeak(output) then
      return nil
    end

    local previewLines = {}
    local inPreview = false
    for _, line in ipairs(collectMeaningfulLines(output)) do
      if line == "Preview:" then
        inPreview = true
      elseif line == "Script:" then
        break
      elseif inPreview then
        table.insert(previewLines, line)
      end
    end

    if #previewLines == 0 then
      return nil
    end

    local normalizedPreview = {}
    for _, line in ipairs(previewLines) do
      if not line:find(" -> ", 1, true) then
        return nil
      end
      table.insert(normalizedPreview, line)
    end

    local lines = {
      "Preview:",
    }
    for _, line in ipairs(normalizedPreview) do
      table.insert(lines, line)
    end

    local codeBlock = output:match("(Script:%s*\n```.-```)")
    if codeBlock then
      table.insert(lines, codeBlock)
    end

    return table.concat(lines, "\n")
  end

  local function normalizeProcessPlan(text)
    local output = sanitizeModelText(text)
    if output == "" or startsLikeJson(output) or looksLikeReasoningLeak(output) then
      return nil
    end

    local planLines = {}
    local inPlan = false
    for _, line in ipairs(collectMeaningfulLines(output)) do
      if line == "Plan:" then
        inPlan = true
      elseif line == "Script:" then
        break
      elseif inPlan then
        table.insert(planLines, line)
      end
    end

    local normalizedPlan = normalizeBulletList(table.concat(planLines, "\n"), 2, 7)
    if not normalizedPlan then
      return nil
    end

    local lines = { "Plan:" }
    for line in normalizedPlan:gmatch("[^\n]+") do
      table.insert(lines, line)
    end

    local codeBlock = output:match("(Script:%s*\n```.-```)")
    if codeBlock then
      table.insert(lines, codeBlock)
    end

    return table.concat(lines, "\n")
  end

  local function normalizeFolderExplain(text)
    local output = sanitizeModelText(text)
    if output == "" or startsLikeJson(output) or looksLikeReasoningLeak(output) then
      return nil
    end

    local lowered = output:lower()
    if not lowered:find("what it looks like", 1, true) or not lowered:find("suggested next actions", 1, true) then
      return nil
    end

    return output
  end

  local function normalizeCommandBlock(text)
    local output = sanitizeModelText(text)
    if output == "" or startsLikeJson(output) or looksLikeReasoningLeak(output) then
      return nil
    end

    if not output:find("^Command:%s*", 1) then
      return nil
    end
    if not output:find("```", 1, true) then
      return nil
    end
    if not output:find("Explanation:%s*.+") then
      return nil
    end

    return output
  end

  local function maybeSavePlanScript(actionName, actionLabel, taskDescription, payloadContext, profile, responseText, preferredLanguage)
    if not tostring(responseText or ""):find("```", 1, true) then
      return nil
    end

    local extracted = scripts.extractCodeBlock(responseText, preferredLanguage)
    if not extracted or not extracted.code or extracted.code == "" then
      return nil
    end

    local language = extracted.language or preferredLanguage or scripts.guessLanguage(taskDescription or "")
    local note = scripts.renderRequestNote({
      generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
      language = language,
      task_description = taskDescription,
      context = payloadContext,
      note = extracted.explanation ~= "" and (actionLabel .. " helper script extracted from the model response.\n\n" .. extracted.explanation)
        or (actionLabel .. " helper script extracted from the model response."),
      include_raw_context = config.storage.include_raw_context == true,
    })

    local saved = storage.saveScriptDraft(
      taskDescription,
      extracted.code,
      note,
      scripts.extensionForLanguage(language)
    )

    if not saved.ok then
      return {
        ok = false,
        message = formatFailure(actionLabel, saved, profile),
        failure_reason = saved.error and saved.error.code or (actionName .. "_script_save_failed"),
      }
    end

    return {
      ok = true,
      code_path = saved.data.code_path,
      note_path = saved.data.note_path,
    }
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

  local function validateOutput(validatorName, inputText, text)
    local output = sanitizeModelText(text)

    if validatorName == "summary" then
      local normalized = normalizeSummaryText(output)
      if not normalized then
        return nil, "invalid_summary"
      end
      return normalized, nil
    end

    if validatorName == "rewrite" then
      local bad, reason = isBadRewrite(inputText or "", output)
      if bad then
        return nil, reason
      end
      return output, nil
    end

    if validatorName == "error_explain" then
      local bad, reason = isBadErrorExplain(output)
      if bad then
        return nil, reason
      end
      return normalizeErrorExplainText(output), nil
    end

    if validatorName == "cleanup_draft" then
      local normalized = normalizeCleanUpDraft(output)
      if not normalized then
        return nil, "invalid_cleanup_draft"
      end
      return normalized, nil
    end

    if validatorName == "bullets" then
      local normalized = normalizeBulletList(output, 3, 7)
      if not normalized then
        return nil, "invalid_bullets"
      end
      return normalized, nil
    end

    if validatorName == "action_items" then
      local normalized = normalizeActionItems(output)
      if not normalized then
        return nil, "invalid_action_items"
      end
      return normalized, nil
    end

    if validatorName == "reply_draft" then
      local normalized = normalizeReplyDraft(output)
      if not normalized then
        return nil, "invalid_reply_draft"
      end
      return normalized, nil
    end

    if validatorName == "title_pack" then
      local normalized = normalizeTitlePack(output)
      if not normalized then
        return nil, "invalid_title_pack"
      end
      return normalized, nil
    end

    if validatorName == "rename_plan" then
      local normalized = normalizeRenamePlan(output)
      if not normalized then
        return nil, "invalid_rename_plan"
      end
      return normalized, nil
    end

    if validatorName == "process_plan" then
      local normalized = normalizeProcessPlan(output)
      if not normalized then
        return nil, "invalid_process_plan"
      end
      return normalized, nil
    end

    if validatorName == "folder_explain" then
      local normalized = normalizeFolderExplain(output)
      if not normalized then
        return nil, "invalid_folder_explain"
      end
      return normalized, nil
    end

    if validatorName == "command_block" then
      local normalized = normalizeCommandBlock(output)
      if not normalized then
        return nil, "invalid_command_block"
      end
      return normalized, nil
    end

    return output, nil
  end

  local function normalizeSuccessResult(result, fallbackText)
    if type(result) == "table" then
      if result.ok == false then
        return result
      end

      return {
        ok = true,
        message = result.message or "",
        clipboard_text = result.clipboard_text or fallbackText,
      }
    end

    return {
      ok = true,
      message = tostring(result or ""),
      clipboard_text = fallbackText,
    }
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
    local policy = policies.getActionPolicy(spec.action_name)
    if not policy then
      showAlert("Action policy is invalid.", 2.5)
      return
    end

    local profile = getActiveClipboardProfile()
    if not profile then
      showAlert("Active clipboard profile is invalid.", 2.5)
      return
    end

    local payloadContext, contextOptions = buildActionContext(spec.action_name, profile)
    if not payloadContext then
      showAlert("Action context policy is invalid.", 2.5)
      return
    end

    local requiresClipboard = spec.requires_clipboard
    if requiresClipboard == nil then
      requiresClipboard = policy.requires_clipboard ~= false
    end

    local requiresFinder = spec.requires_finder
    if requiresFinder == nil then
      requiresFinder = policy.requires_finder == true
    end

    if requiresClipboard and isBlank(payloadContext.clipboard) then
      showClipboardRequired(spec.label)
      return
    end

    if requiresFinder and (type(payloadContext.finder_selection) ~= "table" or #payloadContext.finder_selection == 0) then
      showFinderRequired(spec.label)
      return
    end

    local startedAt = hs.timer.absoluteTime()
    local buildPrompt = spec.build_prompt
      or (type(policy.prompt_builder) == "string" and prompts[policy.prompt_builder])
    if type(buildPrompt) ~= "function" then
      showAlert("Action prompt builder is invalid.", 2.5)
      return
    end

    local prompt = buildPrompt(payloadContext)

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
        context_flags = payloadContext.context_flags,
        allow_full_clipboard = contextOptions and contextOptions.allow_full_clipboard or false,
      })
    end

    local validatorName = spec.validator or policy.validator

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

      local normalized, invalidReason = validateOutput(validatorName, payloadContext.clipboard, result.data.text)
      local buildRetryPrompt = spec.build_retry_prompt
        or (type(policy.retry_prompt_builder) == "string" and prompts[policy.retry_prompt_builder])

      if not normalized and not retried and type(buildRetryPrompt) == "function" then
        retried = true
        local retryPrompt = buildRetryPrompt(payloadContext)
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

      local successResult = normalizeSuccessResult(
        spec.handle_success(normalized, payloadContext, profile),
        normalized
      )
      if not successResult.ok then
        finishDiagnostics({
          success = false,
          failure_reason = successResult.failure_reason or "postprocess_failed",
          preview = previewText(successResult.message or "", 120),
        })
        showAlert(successResult.message or (spec.label .. " failed."), 3)
        return
      end

      local clipboardText = successResult.clipboard_text or normalized
      finishDiagnostics({
        success = true,
        preview = previewText(clipboardText, 120),
      })
      if not developerModeEnabled() or (config.debug and config.debug.copy_alerts_to_clipboard == false) then
        copyResult(clipboardText)
      end
      showAlert(successResult.message, spec.success_seconds, clipboardText)
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
        return {
          ok = true,
          message = message,
          clipboard_text = text,
        }
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
        return {
          ok = true,
          message = message,
          clipboard_text = text,
        }
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
        return {
          ok = true,
          message = message,
          clipboard_text = text,
        }
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

  function self.toggleContextOverride(key)
    local enabled = status.toggleContextOverride(key)
    if enabled == nil then
      showAlert("Unknown context toggle: " .. tostring(key), 2.5)
      return
    end

    local labelMap = {
      include_clipboard = "Clipboard context",
      include_browser = "Browser context",
      include_finder = "Finder context",
      include_profile_metadata = "Profile metadata",
      use_full_clipboard = "Full clipboard",
    }

    local message = string.format("%s %s.", labelMap[key] or key, enabled and "enabled" or "disabled")
    showAlert(message, 2.5)
  end

  function self.draftUtilityScript()
    local profile = getActiveClipboardProfile()
    if not profile then
      showAlert("Active clipboard profile is invalid.", 2.5)
      return
    end

    local taskDescription = promptForTaskDescription("Draft Utility Script")
    if taskDescription == nil then
      showAlert("Draft Utility Script cancelled.", 2)
      return
    end

    if taskDescription == "" then
      showTaskDescriptionRequired("Draft Utility Script")
      return
    end

    local payloadContext, contextOptions = buildActionContext("draftUtilityScript", profile)
    if not payloadContext then
      showAlert("Action context policy is invalid.", 2.5)
      return
    end

    local prompt = prompts.buildScriptDraftPrompt(
      taskDescription,
      payloadContext,
      scripts.guessLanguage(taskDescription)
    )

    status.beginBusy()
    ensureClipboardProfileReady(profile, function(ensureResult)
      if not ensureResult.ok then
        status.endBusy()
        showAlert(formatFailure("Draft Utility Script", ensureResult, profile), 3)
        return
      end

      requestPlainText(profile, prompt, 1400, function(result)
        status.endBusy()

        if not result.ok then
          showAlert(formatFailure("Draft Utility Script", result, profile), 3.5)
          return
        end

        local guessedLanguage = scripts.guessLanguage(taskDescription)
        local extracted = scripts.extractCodeBlock(result.data.text, guessedLanguage)
        if not extracted or not extracted.code or extracted.code == "" then
          local rawSave = storage.saveMarkdown(
            "Utility Script Raw Draft",
            result.data.text,
            metadataFromContext("draftUtilityScript", payloadContext, profile),
            {
              directory = config.storage.script_drafts_dir,
              prefix = "script-raw",
            }
          )

          if rawSave.ok then
            copyResult(rawSave.data.path)
            showAlert("Draft Utility Script could not extract a code block. Raw response saved and path copied to the clipboard.", 4, rawSave.data.path)
          else
            showAlert("Draft Utility Script could not extract a code block or save the raw response.", 4)
          end
          return
        end

        local language = extracted.language or guessedLanguage
        local note = scripts.renderRequestNote({
          generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          language = language,
          task_description = taskDescription,
          context = payloadContext,
          note = extracted.explanation,
          include_raw_context = config.storage.include_raw_context == true,
        })

        local saved = storage.saveScriptDraft(
          taskDescription,
          extracted.code,
          note,
          scripts.extensionForLanguage(language)
        )

        if not saved.ok then
          showAlert(formatFailure("Draft Utility Script", saved, profile), 3.5)
          return
        end

        copyResult(saved.data.code_path)
        if config.scripts.open_after_generate then
          hs.open(saved.data.code_path)
        end

        local message = table.concat({
          string.format("Draft Utility Script saved using %s.", profile.label),
          "Script: " .. saved.data.code_path,
          "Note: " .. saved.data.note_path,
        }, "\n")
        showAlert(message, 4, saved.data.code_path)

        recordBakeoff({
          recorded_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          action = "draftUtilityScript",
          profile = profile.name,
          model = profile.model,
          api = profile.api,
          success = true,
          preview = previewText(taskDescription, 120),
          context_flags = payloadContext.context_flags,
          allow_full_clipboard = contextOptions and contextOptions.allow_full_clipboard or false,
        })
      end)
    end)
  end

  function self.sendToOpenWebUI()
    local profile = getActiveClipboardProfile()
    if not profile then
      showAlert("Active clipboard profile is invalid.", 2.5)
      return
    end

    local payloadContext = buildActionContext("sendToOpenWebUI", profile)
    if not payloadContext then
      showAlert("Action context policy is invalid.", 2.5)
      return
    end

    local seedPrompt = prompts.buildOpenWebUISeedPrompt(payloadContext)
    local handoffBody = table.concat({
      "Use this file as the full local handoff context.",
      "",
      renderContextSummaryMarkdown(payloadContext),
      "",
      "## Seed Prompt",
      "",
      seedPrompt,
    }, "\n")

    local saved = storage.saveMarkdown(
      "Open WebUI Handoff",
      handoffBody,
      metadataFromContext("sendToOpenWebUI", payloadContext, profile),
      {
        directory = config.storage.handoff_dir,
        prefix = "handoff",
      }
    )

    if not saved.ok then
      showAlert(formatFailure("Send To Open WebUI", saved, profile), 3.5)
      return
    end

    copyResult(seedPrompt)
    openUrlInPrimaryBrowser(config.ui.open_webui_url)

    local message = table.concat({
      "Open WebUI handoff saved.",
      "Seed prompt copied to the clipboard.",
      "Handoff: " .. saved.data.path,
    }, "\n")
    showAlert(message, 4, seedPrompt)
  end

  function self.saveClipboardSummary()
    runClipboardAction({
      action_name = "saveClipboardSummary",
      label = "Save Clipboard Summary",
      max_tokens = 240,
      retry_max_tokens = 320,
      success_seconds = 3.5,
      handle_success = function(text, payloadContext, profile)
        local body = table.concat({
          text,
          "",
          renderContextSummaryMarkdown(payloadContext),
        }, "\n")

        local saved = storage.saveMarkdown(
          "Clipboard Summary",
          body,
          metadataFromContext("saveClipboardSummary", payloadContext, profile),
          {
            directory = config.storage.output_dir,
            prefix = "summary",
          }
        )

        if not saved.ok then
          return {
            ok = false,
            message = formatFailure("Save Clipboard Summary", saved, profile),
            failure_reason = saved.error and saved.error.code or "summary_save_failed",
          }
        end

        if config.storage.append_saved_summaries_to_inbox then
          local appended = storage.appendInbox(string.format("- [%s](%s)", os.date("%Y-%m-%d %H:%M"), saved.data.path))
          if not appended.ok then
            return {
              ok = false,
              message = formatFailure("Save Clipboard Summary", appended, profile),
              failure_reason = appended.error and appended.error.code or "summary_inbox_append_failed",
            }
          end
        end

        return {
          ok = true,
          message = table.concat({
            string.format("Summary saved using %s.", profile.label),
            "Path: " .. saved.data.path,
          }, "\n"),
          clipboard_text = text,
        }
      end,
    })
  end

  function self.cleanUpDraft()
    runClipboardAction({
      action_name = "cleanUpDraft",
      label = "Clean Up Draft",
      max_tokens = 700,
      success_seconds = 3,
      handle_success = function(text, payloadContext, profile)
        local message = string.format("Cleaned-up draft copied to clipboard using %s.", profile.label)
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end

        return {
          ok = true,
          message = message,
          clipboard_text = text,
        }
      end,
    })
  end

  function self.turnIntoBullets()
    runClipboardAction({
      action_name = "turnIntoBullets",
      label = "Turn Into Bullets",
      max_tokens = 320,
      success_seconds = 3,
      handle_success = function(text, payloadContext, profile)
        local message = string.format("Bullet list copied to clipboard using %s.", profile.label)
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end

        return {
          ok = true,
          message = message,
          clipboard_text = text,
        }
      end,
    })
  end

  function self.turnIntoActionItems()
    runClipboardAction({
      action_name = "turnIntoActionItems",
      label = "Turn Into Action Items",
      max_tokens = 360,
      success_seconds = 3,
      handle_success = function(text, payloadContext, profile)
        local message = string.format("Action items copied to clipboard using %s.", profile.label)
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end

        return {
          ok = true,
          message = message,
          clipboard_text = text,
        }
      end,
    })
  end

  function self.replyDraft()
    runClipboardAction({
      action_name = "replyDraft",
      label = "Reply Draft",
      max_tokens = 420,
      success_seconds = 3,
      handle_success = function(text, payloadContext, profile)
        local message = string.format("Reply draft copied to clipboard using %s.", profile.label)
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end

        return {
          ok = true,
          message = message,
          clipboard_text = text,
        }
      end,
    })
  end

  function self.titlePack()
    runClipboardAction({
      action_name = "titlePack",
      label = "Title Pack",
      max_tokens = 280,
      success_seconds = 3,
      handle_success = function(text, payloadContext, profile)
        local message = string.format("Title pack copied to clipboard using %s.", profile.label)
        if payloadContext.truncated then
          message = message .. " Input was truncated."
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end

        return {
          ok = true,
          message = message,
          clipboard_text = text,
        }
      end,
    })
  end

  function self.renameFilesPlan()
    runClipboardAction({
      action_name = "renameFilesPlan",
      label = "Rename Files Plan",
      max_tokens = 850,
      success_seconds = 3.5,
      handle_success = function(text, payloadContext, profile)
        local taskDescription = payloadContext.clipboard ~= ""
          and ("Rename selected files based on these instructions: " .. payloadContext.clipboard)
          or "Rename the selected files safely."
        local savedScript = maybeSavePlanScript(
          "renameFilesPlan",
          "Rename Files Plan",
          taskDescription,
          payloadContext,
          profile,
          text,
          "bash"
        )

        if savedScript and not savedScript.ok then
          return savedScript
        end

        local lines = {
          string.format("Rename plan copied to clipboard using %s.", profile.label),
        }
        if savedScript and savedScript.ok then
          table.insert(lines, "Script: " .. savedScript.code_path)
          table.insert(lines, "Note: " .. savedScript.note_path)
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          table.insert(lines, preview)
        end

        return {
          ok = true,
          message = table.concat(lines, "\n"),
          clipboard_text = text,
        }
      end,
    })
  end

  function self.processFilesPlan()
    runClipboardAction({
      action_name = "processFilesPlan",
      label = "Process Files Plan",
      max_tokens = 950,
      success_seconds = 3.5,
      handle_success = function(text, payloadContext, profile)
        local taskDescription = payloadContext.clipboard ~= ""
          and ("Process the selected files based on these instructions: " .. payloadContext.clipboard)
          or "Process the selected files safely."
        local savedScript = maybeSavePlanScript(
          "processFilesPlan",
          "Process Files Plan",
          taskDescription,
          payloadContext,
          profile,
          text,
          "python"
        )

        if savedScript and not savedScript.ok then
          return savedScript
        end

        local lines = {
          string.format("Process-files plan copied to clipboard using %s.", profile.label),
        }
        if savedScript and savedScript.ok then
          table.insert(lines, "Script: " .. savedScript.code_path)
          table.insert(lines, "Note: " .. savedScript.note_path)
        end

        local preview = previewText(text, 110)
        if preview ~= "" then
          table.insert(lines, preview)
        end

        return {
          ok = true,
          message = table.concat(lines, "\n"),
          clipboard_text = text,
        }
      end,
    })
  end

  function self.explainThisFolder()
    runClipboardAction({
      action_name = "explainThisFolder",
      label = "Explain This Folder",
      max_tokens = 520,
      success_seconds = 3,
      handle_success = function(text, payloadContext, profile)
        local message = string.format("Folder explanation copied to clipboard using %s.", profile.label)
        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end

        return {
          ok = true,
          message = message,
          clipboard_text = text,
        }
      end,
    })
  end

  function self.generateCommand()
    runClipboardAction({
      action_name = "generateCommand",
      label = "Generate Command",
      max_tokens = 520,
      success_seconds = 3,
      handle_success = function(text, payloadContext, profile)
        local message = string.format("Command copied to clipboard using %s.", profile.label)
        local preview = previewText(text, 110)
        if preview ~= "" then
          message = message .. "\n" .. preview
        end

        return {
          ok = true,
          message = message,
          clipboard_text = text,
        }
      end,
    })
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
