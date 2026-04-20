local M = {}

local function nonEmpty(value)
  return type(value) == "string" and value ~= ""
end

local function renderContext(context)
  local lines = {}

  if nonEmpty(context.app) then
    table.insert(lines, string.format("App: %s", context.app))
  end

  if nonEmpty(context.window_title) then
    table.insert(lines, string.format("Window: %s", context.window_title))
  end

  if nonEmpty(context.captured_at) then
    table.insert(lines, string.format("Captured At: %s", context.captured_at))
  end

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

  if type(context.profile_metadata) == "table" then
    if nonEmpty(context.profile_metadata.label) then
      table.insert(lines, string.format("Clipboard Profile: %s", context.profile_metadata.label))
    end
    if nonEmpty(context.profile_metadata.model) then
      table.insert(lines, string.format("Model: %s", context.profile_metadata.model))
    end
    if nonEmpty(context.profile_metadata.api) then
      table.insert(lines, string.format("API: %s", context.profile_metadata.api))
    end
  end

  if context.truncated then
    table.insert(lines, "Clipboard: Truncated to instant-action limit")
  end

  return #lines > 0 and table.concat(lines, "\n") or "Captured At: " .. (context.captured_at or "Unknown")
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
        "Do not return JSON.",
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
        "This is a rewrite, not a summary.",
        "Preserve meaning, keep every material point, and remove fluff.",
        "Return plain text only.",
        "Return only the rewritten clipboard text.",
        "Do not return JSON.",
        "Do not include analysis, steps, bullets, labels, or commentary.",
        "Do not use ellipses, placeholders, or short fragment stubs.",
        "Do not rewrite the metadata block.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nRewrite only the clipboard content between the tags below.\n\n%s",
        renderContext(context),
        renderClipboardBlock(context)
      ),
    }
  end

  function self.buildRewriteRetryPrompt(context)
    return {
      system = table.concat({
        "Rewrite the clipboard text tersely.",
        "This is a rewrite, not a summary.",
        "Keep every material claim, but express it more tightly.",
        "Return plain text only.",
        "Return only the rewritten clipboard text.",
        "Do not return JSON.",
        "Do not include analysis, labels, bullets, commentary, placeholders, or ellipses.",
        "Do not shorten the answer to a heading or opening fragment.",
        "Do not rewrite the metadata block.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nYour previous attempt was too short or incomplete. Rewrite the full clipboard content between the tags below, keeping all important points.\n\n%s",
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
        "Return only the final answer in plain text.",
        "Use these exact headings:",
        "Root cause",
        "Immediate fix",
        "What to check next",
        "Each section must contain at least one complete sentence.",
        "Do not return JSON.",
        "Do not use ellipses, placeholders, or fragments.",
        "Do not include your reasoning process.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nAnalyze only the clipboard content between the tags below.\n\n%s",
        renderContext(context),
        renderClipboardBlock(context)
      ),
    }
  end

  function self.buildErrorExplainRetryPrompt(context)
    return {
      system = table.concat({
        "You are diagnosing an error, log, or code issue.",
        "Focus on the clipboard content only.",
        "Return only the final answer in plain text.",
        "Use these exact headings:",
        "Root cause",
        "Immediate fix",
        "What to check next",
        "Each section must contain one to three complete sentences.",
        "Do not return JSON.",
        "Do not use ellipses, placeholders, or fragments.",
        "Do not include your reasoning process.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nYour previous attempt was incomplete. Analyze only the clipboard content between the tags below and provide a complete answer for all three sections.\n\n%s",
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

  function self.buildCleanUpDraftPrompt(context)
    return {
      system = table.concat({
        "Polish the clipboard text for clarity and flow.",
        "Preserve the original intent and material points.",
        "Return only the cleaned-up draft in plain text.",
        "Do not return JSON.",
        "Do not include notes, commentary, bullets, labels, or headings unless they are already necessary in the draft.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nClean up only the clipboard content between the tags below.\n\n%s",
        renderContext(context),
        renderClipboardBlock(context)
      ),
    }
  end

  function self.buildTurnIntoBulletsPrompt(context)
    return {
      system = table.concat({
        "Turn the clipboard text into crisp bullets.",
        "Return only 3 to 7 bullet lines.",
        "Each line must begin with '- '.",
        "Keep the important points and remove fluff.",
        "Do not return JSON or any commentary.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nConvert only the clipboard content between the tags below into concise bullets.\n\n%s",
        renderContext(context),
        renderClipboardBlock(context)
      ),
    }
  end

  function self.buildTurnIntoActionItemsPrompt(context)
    return {
      system = table.concat({
        "Turn the clipboard text into concrete next steps.",
        "Return only 2 to 7 action-item lines.",
        "Each line must begin with '- '.",
        "Write each item as a clear imperative action.",
        "Do not return JSON or any commentary.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nTurn only the clipboard content between the tags below into action items.\n\n%s",
        renderContext(context),
        renderClipboardBlock(context)
      ),
    }
  end

  function self.buildReplyDraftPrompt(context)
    return {
      system = table.concat({
        "Draft a concise reply based on the clipboard text.",
        "Return only the reply in plain text.",
        "Make it sendable and natural.",
        "Do not return JSON.",
        "Do not include notes, labels, subject lines, or commentary unless they are explicitly needed in the reply.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nDraft a reply using only the clipboard content between the tags below.\n\n%s",
        renderContext(context),
        renderClipboardBlock(context)
      ),
    }
  end

  function self.buildTitlePackPrompt(context)
    return {
      system = table.concat({
        "Generate a compact title pack from the clipboard text.",
        "Return plain text only.",
        "Use this exact format:",
        "Title options:",
        "- option 1",
        "- option 2",
        "- option 3",
        "Subject: one line",
        "Slug: one-line-kebab-case",
        "Do not return JSON.",
        "Do not add any extra sections or commentary.",
      }, "\n"),
      user = string.format(
        "Context metadata:\n%s\n\nGenerate the title pack using only the clipboard content between the tags below.\n\n%s",
        renderContext(context),
        renderClipboardBlock(context)
      ),
    }
  end

  return self
end

return M
