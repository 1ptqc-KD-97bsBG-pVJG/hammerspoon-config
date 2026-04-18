local M = {}

local function snapshotTitle(snapshot)
  if snapshot.busy then
    return "LM: busy"
  end

  if snapshot.reachable then
    return "LM: up"
  end

  return "LM: down"
end

local function buildTooltip(snapshot)
  local lines = {
    string.format("Backend: %s", snapshot.reachable and "reachable" or "unreachable"),
    string.format("Native management: %s", snapshot.native_available and "available" or "unavailable"),
    string.format("Responses: %s", snapshot.responses_available == nil and "unknown" or tostring(snapshot.responses_available)),
    string.format("Chat completions: %s", snapshot.chat_available == nil and "unknown" or tostring(snapshot.chat_available)),
    string.format("Native chat: %s", snapshot.native_chat_available == nil and "unknown" or tostring(snapshot.native_chat_available)),
    string.format("Native unload: %s", snapshot.unload_available == nil and "unknown" or tostring(snapshot.unload_available)),
    string.format("Clipboard profile: %s", snapshot.active_clipboard_profile or "unknown"),
    string.format("Developer mode: %s", snapshot.developer_mode and "on" or "off"),
    string.format("Last check: %s", snapshot.last_checked_at or "never"),
  }

  local enabledContext = {}
  local contextOverrides = snapshot.context_overrides or {}
  if contextOverrides.include_clipboard then
    table.insert(enabledContext, "clipboard")
  end
  if contextOverrides.include_browser then
    table.insert(enabledContext, "browser")
  end
  if contextOverrides.include_finder then
    table.insert(enabledContext, "finder")
  end
  if contextOverrides.include_profile_metadata then
    table.insert(enabledContext, "profile_metadata")
  end
  if contextOverrides.use_full_clipboard then
    table.insert(enabledContext, "full_clipboard")
  end

  if #enabledContext > 0 then
    table.insert(lines, "Developer context extras: " .. table.concat(enabledContext, ", "))
  end

  if type(snapshot.loaded_instances) == "table" and #snapshot.loaded_instances > 0 then
    local loaded = {}
    for _, item in ipairs(snapshot.loaded_instances) do
      table.insert(loaded, item.model or item.label or "unknown")
    end
    table.insert(lines, "Loaded models: " .. table.concat(loaded, ", "))
  end

  if snapshot.last_error then
    table.insert(lines, "Last error: " .. snapshot.last_error)
  end

  return table.concat(lines, "\n")
end

function M.new(config, actions, status)
  local menubar = hs.menubar.new()
  local timer = nil
  local hotkeys = {}
  local self = {}

  local function openPath(path)
    hs.open(path)
  end

  local function registerHotkey(key, fn)
    if not key then
      return
    end

    table.insert(hotkeys, hs.hotkey.bind(config.ui.modifier, key, fn))
  end

  local function buildMenu()
    local snapshot = status.getStatusSnapshot()
    local items = {
      { title = "Prepare Clipboard Model", fn = actions.prepareClipboardModel },
      { title = "Developer Mode", checked = snapshot.developer_mode == true, fn = actions.toggleDeveloperMode },
    }

    if snapshot.developer_mode == true then
      table.insert(items, { title = "Include Clipboard", checked = snapshot.context_overrides and snapshot.context_overrides.include_clipboard == true, fn = function()
        actions.toggleContextOverride("include_clipboard")
      end })
      table.insert(items, { title = "Include Browser Context", checked = snapshot.context_overrides and snapshot.context_overrides.include_browser == true, fn = function()
        actions.toggleContextOverride("include_browser")
      end })
      table.insert(items, { title = "Include Finder Context", checked = snapshot.context_overrides and snapshot.context_overrides.include_finder == true, fn = function()
        actions.toggleContextOverride("include_finder")
      end })
      table.insert(items, { title = "Include Profile Metadata", checked = snapshot.context_overrides and snapshot.context_overrides.include_profile_metadata == true, fn = function()
        actions.toggleContextOverride("include_profile_metadata")
      end })
      table.insert(items, { title = "Use Full Clipboard", checked = snapshot.context_overrides and snapshot.context_overrides.use_full_clipboard == true, fn = function()
        actions.toggleContextOverride("use_full_clipboard")
      end })
    end

    table.insert(items, { title = "-" })
    local actionItems = {
      { title = "Summarize Clipboard", fn = actions.summarizeClipboard },
      { title = "Explain Clipboard Error", fn = actions.explainClipboardError },
      { title = "Rewrite Clipboard Tersely", fn = actions.rewriteClipboardTersely },
      { title = "Draft Utility Script", fn = actions.draftUtilityScript },
      { title = "-" },
      { title = "Use GLM Clipboard Profile", checked = snapshot.active_clipboard_profile == "glm", fn = function()
        actions.useClipboardProfile("glm")
      end },
      { title = "Use GPT OSS Clipboard Profile", checked = snapshot.active_clipboard_profile == "gpt_oss", fn = function()
        actions.useClipboardProfile("gpt_oss")
      end },
      { title = "-" },
      { title = "Send to Open WebUI", fn = actions.sendToOpenWebUI },
      { title = "Save Clipboard Summary", fn = actions.saveClipboardSummary },
      { title = "Refresh Backend Status", fn = function()
        actions.refreshBackendStatus({ silent = false })
      end },
      { title = "-" },
      { title = "Open Output Folder", fn = function()
        openPath(config.storage.output_dir)
      end },
      { title = "Open Script Drafts Folder", fn = function()
        openPath(config.storage.script_drafts_dir)
      end },
      { title = "Open Diagnostics Folder", fn = function()
        openPath(config.storage.diagnostics_dir)
      end },
      { title = "Reload Config", fn = hs.reload },
    }

    for _, item in ipairs(actionItems) do
      table.insert(items, item)
    end

    return items
  end

  registerHotkey(config.ui.hotkeys.summarize, actions.summarizeClipboard)
  registerHotkey(config.ui.hotkeys.explain_error, actions.explainClipboardError)
  registerHotkey(config.ui.hotkeys.rewrite_terse, actions.rewriteClipboardTersely)
  registerHotkey(config.ui.hotkeys.prepare_clipboard_model, actions.prepareClipboardModel)
  registerHotkey(config.ui.hotkeys.draft_script, actions.draftUtilityScript)
  registerHotkey(config.ui.hotkeys.open_webui, actions.sendToOpenWebUI)
  registerHotkey(config.ui.hotkeys.save_summary, actions.saveClipboardSummary)

  function self.refreshMenu()
    local snapshot = status.getStatusSnapshot()
    menubar:setTitle(snapshotTitle(snapshot))
    menubar:setTooltip(buildTooltip(snapshot))
    menubar:setMenu(buildMenu())
  end

  function self.startStatusTimer()
    if timer then
      timer:stop()
    end

    timer = hs.timer.doEvery(config.status.refresh_interval_s, function()
      actions.refreshBackendStatus({ silent = true })
    end)
  end

  function self.stop()
    if timer then
      timer:stop()
      timer = nil
    end

    for _, hotkey in ipairs(hotkeys) do
      hotkey:delete()
    end

    if menubar then
      menubar:delete()
    end
  end

  return self
end

return M
