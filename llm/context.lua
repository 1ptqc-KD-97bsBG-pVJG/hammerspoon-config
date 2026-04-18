local M = {}
local BROWSER_SEPARATOR = "\n|||HS|||\n"

local BROWSER_ADAPTERS = {
  {
    app = "Zen",
    script = [[
      tell application "Zen"
        if (count of windows) is 0 then return ""
        set tabTitle to ""
        set tabURL to ""
        try
          set tabTitle to name of front window
        end try
        try
          set tabURL to URL of active tab of front window
        end try
        return tabURL & linefeed & "|||HS|||" & linefeed & tabTitle
      end tell
    ]],
  },
  {
    app = "Safari",
    script = [[
      tell application "Safari"
        if (count of windows) is 0 then return ""
        set currentTab to current tab of front window
        set tabURL to URL of currentTab
        set tabTitle to name of currentTab
        return tabURL & linefeed & "|||HS|||" & linefeed & tabTitle
      end tell
    ]],
  },
  {
    app = "Google Chrome",
    script = [[
      tell application "Google Chrome"
        if (count of windows) is 0 then return ""
        set currentTab to active tab of front window
        set tabURL to URL of currentTab
        set tabTitle to title of currentTab
        return tabURL & linefeed & "|||HS|||" & linefeed & tabTitle
      end tell
    ]],
  },
  {
    app = "Arc",
    script = [[
      tell application "Arc"
        if (count of windows) is 0 then return ""
        set currentTab to active tab of front window
        set tabURL to URL of currentTab
        set tabTitle to title of currentTab
        return tabURL & linefeed & "|||HS|||" & linefeed & tabTitle
      end tell
    ]],
  },
}

local function isoNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

local function splitBrowserPayload(payload)
  local url, title = payload:match("^(.-)" .. BROWSER_SEPARATOR .. "(.*)$")
  return trim(url), trim(title)
end

local function runAppleScript(script)
  local ok, result = hs.osascript.applescript(script)
  if not ok then
    return nil
  end

  if type(result) ~= "string" or result == "" then
    return nil
  end

  return result
end

local function orderedBrowserAdapters(config)
  local ordered = {}
  local primaryApp = config.ui.primary_browser_app

  if primaryApp and primaryApp ~= "" then
    for _, adapter in ipairs(BROWSER_ADAPTERS) do
      if adapter.app == primaryApp then
        table.insert(ordered, adapter)
      end
    end
  end

  for _, adapter in ipairs(BROWSER_ADAPTERS) do
    if adapter.app ~= primaryApp then
      table.insert(ordered, adapter)
    end
  end

  return ordered
end

local function findBrowserAdapter(config, appName)
  for _, adapter in ipairs(orderedBrowserAdapters(config)) do
    if adapter.app == appName then
      return adapter
    end
  end

  return nil
end

local function truncateClipboard(text, limit, allowFullClipboard)
  if allowFullClipboard or #text <= limit then
    return text, false
  end

  return text:sub(1, limit), true
end

function M.new(config)
  local self = {}

  function self.getClipboardText()
    return hs.pasteboard.getContents() or ""
  end

  function self.getFrontmostAppName()
    local frontmost = hs.application.frontmostApplication()
    return frontmost and frontmost:name() or ""
  end

  function self.getFrontWindowTitle()
    local frontWindow = hs.window.frontmostWindow()
    return frontWindow and (frontWindow:title() or "") or ""
  end

  function self.isSupportedBrowser(appName)
    return findBrowserAdapter(config, appName) ~= nil
  end

  function self.supportedBrowserApps()
    local apps = {}
    for _, adapter in ipairs(orderedBrowserAdapters(config)) do
      table.insert(apps, adapter.app)
    end
    return apps
  end

  function self.getBrowserContext(appName)
    if not config.features.browser_context then
      return nil
    end

    local targetApp = appName or self.getFrontmostAppName()
    local adapter = findBrowserAdapter(config, targetApp)
    if not adapter then
      return nil
    end

    local payload = runAppleScript(adapter.script)
    if not payload then
      return nil
    end

    local url, title = splitBrowserPayload(payload)
    if url == "" and title == "" then
      return nil
    end

    return {
      url = url ~= "" and url or nil,
      page_title = title ~= "" and title or nil,
      browser_app = adapter.app,
    }
  end

  function self.getFinderSelection()
    if not config.features.finder_context then
      return {}
    end

    local result = runAppleScript([[
      tell application "Finder"
        if selection is {} then return ""
        set selectedItems to selection
        set pathList to {}
        repeat with selectedItem in selectedItems
          set end of pathList to POSIX path of (selectedItem as alias)
        end repeat
        set AppleScript's text item delimiters to linefeed
        set outputText to pathList as string
        set AppleScript's text item delimiters to ""
        return outputText
      end tell
    ]])

    if not result or result == "" then
      return {}
    end

    local items = {}
    for path in result:gmatch("[^\r\n]+") do
      local trimmed = trim(path)
      if trimmed ~= "" then
        table.insert(items, trimmed)
      end
    end

    return items
  end

  function self.buildContext(opts)
    opts = opts or {}

    local observedAppName = self.getFrontmostAppName()
    local includeClipboard = opts.include_clipboard ~= false
    local includeApp = opts.include_app ~= false
    local includeWindow = opts.include_window ~= false
    local clipboard = ""
    local truncated = false

    if includeClipboard then
      clipboard, truncated = truncateClipboard(
        self.getClipboardText(),
        config.limits.instant_clipboard_chars,
        opts.allow_full_clipboard
      )
    end

    local context = {
      source = opts.source or (includeClipboard and "clipboard" or "context"),
      app = includeApp and observedAppName or "",
      window_title = includeWindow and self.getFrontWindowTitle() or "",
      url = nil,
      page_title = nil,
      finder_selection = {},
      clipboard = clipboard,
      truncated = truncated,
      captured_at = isoNow(),
    }

    if opts.include_browser and self.isSupportedBrowser(observedAppName) then
      local browserContext = self.getBrowserContext(observedAppName)
      if browserContext then
        context.url = browserContext.url
        context.page_title = browserContext.page_title
      end
    end

    if opts.include_finder then
      local shouldQueryFinder = opts.force_finder or observedAppName == "Finder"
      if shouldQueryFinder then
        context.finder_selection = self.getFinderSelection()
      end
    end

    return context
  end

  return self
end

return M
