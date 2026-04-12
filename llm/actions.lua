local M = {}

function M.new(deps)
  local status = deps.status

  local self = {}

  local function showNotReady(actionLabel)
    hs.alert.show(string.format("%s is wired but not implemented yet.", actionLabel), nil, nil, 2)
  end

  function self.summarizeClipboard()
    showNotReady("Summarize Clipboard")
  end

  function self.rewriteClipboardTersely()
    showNotReady("Rewrite Clipboard Tersely")
  end

  function self.explainClipboardError()
    showNotReady("Explain Clipboard Error")
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
        hs.alert.show("Backend status refreshed.", nil, nil, 1.5)
      else
        local message = result.error and result.error.message or "Backend refresh failed"
        hs.alert.show(message, nil, nil, 2)
      end
    end)
  end

  return self
end

return M
