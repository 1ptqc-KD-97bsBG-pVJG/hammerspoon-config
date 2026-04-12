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
    string.format("Last check: %s", snapshot.last_checked_at or "never"),
  }

  if type(snapshot.loaded_models) == "table" and #snapshot.loaded_models > 0 then
    table.insert(lines, "Loaded models: " .. table.concat(snapshot.loaded_models, ", "))
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
    local items = {
      { title = "Summarize Clipboard", fn = actions.summarizeClipboard },
      { title = "Explain Clipboard Error", fn = actions.explainClipboardError },
      { title = "Rewrite Clipboard Tersely", fn = actions.rewriteClipboardTersely },
      { title = "Draft Utility Script", fn = actions.draftUtilityScript },
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
      { title = "Reload Config", fn = hs.reload },
    }

    return items
  end

  registerHotkey(config.ui.hotkeys.summarize, actions.summarizeClipboard)
  registerHotkey(config.ui.hotkeys.explain_error, actions.explainClipboardError)
  registerHotkey(config.ui.hotkeys.rewrite_terse, actions.rewriteClipboardTersely)
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
