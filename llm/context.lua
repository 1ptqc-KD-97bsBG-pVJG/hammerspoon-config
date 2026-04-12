local M = {}

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
        return tabURL & "
|||HS|||
" & tabTitle
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
        return tabURL & "
|||HS|||
" & tabTitle
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
        return tabURL & "
|||HS|||
" & tabTitle
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
        return tabURL & "
|||HS|||
" & tabTitle
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
  local separator = "\n|||HS|||\n"
  local url, title = payload:match("^(.-)" .. separator .. "(.*)$")
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

  function self.getBrowserContext(appName)
    if not config.features.browser_context then
      return nil
    end

    local targetApp = appName or self.getFrontmostAppName()
    for _, adapter in ipairs(BROWSER_ADAPTERS) do
      if adapter.app == targetApp then
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
        }
      end
    end

    return nil
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
        return pathList as string
      end tell
    ]])

    if not result or result == "" then
      return {}
    end

    local items = {}
    for path in result:gmatch("[^\r\n,]+") do
      local trimmed = trim(path)
      if trimmed ~= "" then
        table.insert(items, trimmed)
      end
    end

    return items
  end

  function self.buildContext(opts)
    opts = opts or {}

    local appName = self.getFrontmostAppName()
    local clipboard = self.getClipboardText()
    local truncated = false

    if not opts.allow_full_clipboard and #clipboard > config.limits.instant_clipboard_chars then
      clipboard = clipboard:sub(1, config.limits.instant_clipboard_chars)
      truncated = true
    end

    local context = {
      source = "clipboard",
      app = appName,
      window_title = self.getFrontWindowTitle(),
      url = nil,
      page_title = nil,
      finder_selection = {},
      clipboard = clipboard,
      truncated = truncated,
      captured_at = isoNow(),
    }

    if opts.include_browser then
      local browserContext = self.getBrowserContext(appName)
      if browserContext then
        context.url = browserContext.url
        context.page_title = browserContext.page_title
      end
    end

    if opts.include_finder then
      local shouldQueryFinder = opts.force_finder or appName == "Finder"
      if shouldQueryFinder then
        context.finder_selection = self.getFinderSelection()
      end
    end

    return context
  end

  return self
end

return M
