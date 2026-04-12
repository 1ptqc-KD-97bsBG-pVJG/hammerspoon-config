local M = {}

local function nonEmpty(value)
  return type(value) == "string" and value ~= ""
end

local function renderContext(context)
  local lines = {
    string.format("App: %s", context.app ~= "" and context.app or "Unknown"),
    string.format("Window: %s", context.window_title ~= "" and context.window_title or "Unknown"),
    string.format("Captured At: %s", context.captured_at or "Unknown"),
  }

  if nonEmpty(context.url) then
    table.insert(lines, string.format("URL: %s", context.url))
  end

  if nonEmpty(context.page_title) then
    table.insert(lines, string.format("Page Title: %s", context.page_title))
  end

  if type(context.finder_selection) == "table" and #context.finder_selection > 0 then
    table.insert(lines, "Finder Selection:")
    for _, item in ipairs(context.finder_selection) do
      table.insert(lines, "- " .. item)
    end
  end

  if context.truncated then
    table.insert(lines, "Clipboard: Truncated to instant-action limit")
  end

  return table.concat(lines, "\n")
end

local function renderClipboardBlock(context)
  return table.concat({
    "<clipboard>",
    context.clipboard or "",
    "</clipboard>",
  }, "\n")
end

function M.new(config)
  local self = {}

  function self.buildSummaryPrompt(context)
    return {
      system = table.concat({
        "You are a concise local assistant.",
        "Return only the final answer.",
        "Do not describe your reasoning.",
        "Do not mention the metadata block unless it is directly relevant.",
        "Summarize only the clipboard content in at most 3 short bullets.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nSummarize only the clipboard content between the tags below.\n\n%s",
        renderContext(context),
        renderClipboardBlock(context)
      ),
    }
  end

  function self.buildRewritePrompt(context)
    return {
      system = table.concat({
        "Rewrite the clipboard text tersely.",
        "Preserve meaning and remove fluff.",
        "Return plain text only.",
        "Return only the rewritten clipboard text.",
        "Do not include analysis, steps, bullets, labels, or commentary.",
        "Do not rewrite the metadata block.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nRewrite only the clipboard content between the tags below.\n\n%s",
        renderContext(context),
        renderClipboardBlock(context)
      ),
    }
  end

  function self.buildErrorExplainPrompt(context)
    return {
      system = table.concat({
        "You are diagnosing an error, log, or code issue.",
        "Focus on the clipboard content only.",
        "Return only the final answer in plain text with these three sections:",
        "1. Root cause",
        "2. Immediate fix",
        "3. What to check next",
        "Do not include your reasoning process.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nAnalyze only the clipboard content between the tags below.\n\n%s",
        renderContext(context),
        renderClipboardBlock(context)
      ),
    }
  end

  function self.buildScriptDraftPrompt(taskDescription, context, language)
    return {
      system = table.concat({
        "Write one runnable script for the described task.",
        string.format("Default language: %s.", language),
        "Prefer the standard library first.",
        "Only use third-party packages when necessary, and mention them clearly.",
        "If the script changes files, favor a safe or preview mode when feasible.",
        "Return the script in a fenced code block followed by a brief usage note.",
      }, "\n"),
      user = string.format(
        "%s\n\nTask:\n%s\n\nClipboard:\n%s",
        renderContext(context),
        taskDescription,
        context.clipboard
      ),
    }
  end

  function self.buildOpenWebUISeedPrompt(context)
    local lines = {
      "Use the saved handoff file as the full context for this task.",
      "Start by summarizing the clipboard content and any relevant browser or Finder context.",
    }

    if context.truncated then
      table.insert(lines, "Prefer the handoff file over the clipboard because the instant-action clipboard was truncated.")
    end

    return table.concat(lines, "\n")
  end

  return self
end

return M
