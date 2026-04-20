package.path = table.concat({
  "./?.lua",
  "./?/init.lua",
  package.path,
}, ";")

local config = require("config")
local prompts = require("llm.prompts").new(config)

local function assertTrue(value, message)
  if not value then
    error(message)
  end
end

local sampleContext = {
  app = "Codex",
  window_title = "Notes",
  captured_at = "2026-04-18T12:00:00Z",
  clipboard = "Need to clean this draft up and send it later.",
}

local cleanUpPrompt = prompts.buildCleanUpDraftPrompt(sampleContext)
assertTrue(cleanUpPrompt.system:find("Polish the clipboard text for clarity and flow.", 1, true) ~= nil, "clean-up prompt should mention polishing")

local bulletsPrompt = prompts.buildTurnIntoBulletsPrompt(sampleContext)
assertTrue(bulletsPrompt.system:find("Return only 3 to 7 bullet lines.", 1, true) ~= nil, "bullets prompt should require bullet lines")

local actionItemsPrompt = prompts.buildTurnIntoActionItemsPrompt(sampleContext)
assertTrue(actionItemsPrompt.system:find("Each line must begin with '- '.", 1, true) ~= nil, "action-items prompt should require dash bullets")

local replyPrompt = prompts.buildReplyDraftPrompt(sampleContext)
assertTrue(replyPrompt.system:find("Draft a concise reply", 1, true) ~= nil, "reply prompt should request a reply draft")

local titlePackPrompt = prompts.buildTitlePackPrompt(sampleContext)
assertTrue(titlePackPrompt.system:find("Title options:", 1, true) ~= nil, "title-pack prompt should require title options heading")
assertTrue(titlePackPrompt.system:find("Slug: one-line-kebab-case", 1, true) ~= nil, "title-pack prompt should require a slug line")

print("work copilot prompt tests passed")
