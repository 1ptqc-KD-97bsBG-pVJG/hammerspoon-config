local M = {}

local LANGUAGE_MAP = {
  python = "py",
  py = "py",
  bash = "sh",
  sh = "sh",
  zsh = "zsh",
  shell = "sh",
  javascript = "js",
  js = "js",
  typescript = "ts",
  ts = "ts",
  lua = "lua",
  applescript = "applescript",
}

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

local function normalizeLanguage(value)
  local language = trim((value or ""):lower())
  if language == "" then
    return nil
  end

  return language
end

function M.new(config)
  local self = {}

  function self.guessLanguage(taskDescription)
    local text = (taskDescription or ""):lower()
    if text:find("applescript") then
      return "applescript"
    end
    if text:find("typescript") then
      return "typescript"
    end
    if text:find("javascript") then
      return "javascript"
    end
    if text:find("bash") or text:find("shell") then
      return "bash"
    end
    if text:find("lua") then
      return "lua"
    end

    return normalizeLanguage(config.scripts.default_language) or "python"
  end

  function self.extensionForLanguage(language)
    return LANGUAGE_MAP[normalizeLanguage(language) or "python"] or "txt"
  end

  function self.slugify(value, fallback)
    local slug = (value or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
    if slug == "" then
      return fallback or "draft"
    end
    return slug
  end

  function self.extractCodeBlock(body, preferredLanguage)
    if type(body) ~= "string" or body == "" then
      return nil
    end

    local preferred = normalizeLanguage(preferredLanguage)
    local fallbackMatch = nil

    for fenceLanguage, code in body:gmatch("```([^\n]*)\n(.-)\n```") do
      local normalizedFence = normalizeLanguage(fenceLanguage)
      local match = {
        language = normalizedFence,
        code = trim(code),
      }

      if match.code ~= "" then
        if preferred and normalizedFence == preferred then
          local explanation = trim(body:gsub("```" .. fenceLanguage .. "\n" .. code .. "\n```", "", 1))
          return {
            code = match.code,
            language = normalizedFence or preferred,
            explanation = explanation,
          }
        end

        if not fallbackMatch then
          fallbackMatch = {
            code = match.code,
            language = normalizedFence or preferred,
            explanation = trim(body:gsub("```" .. fenceLanguage .. "\n" .. code .. "\n```", "", 1)),
          }
        end
      end
    end

    return fallbackMatch
  end

  function self.renderRequestNote(args)
    local metadataLines = {
      string.format("Generated: %s", args.generated_at or os.date("!%Y-%m-%dT%H:%M:%SZ")),
      string.format("Language: %s", args.language or "unknown"),
      string.format("App: %s", args.context.app or "Unknown"),
    }

    if args.context.window_title and args.context.window_title ~= "" then
      table.insert(metadataLines, string.format("Window: %s", args.context.window_title))
    end

    if args.context.url and args.context.url ~= "" then
      table.insert(metadataLines, string.format("URL: %s", args.context.url))
    end

    local lines = {
      "# Utility Script Draft",
      "",
    }

    for _, line in ipairs(metadataLines) do
      table.insert(lines, "- " .. line)
    end

    table.insert(lines, "")
    table.insert(lines, "## Request")
    table.insert(lines, "")
    table.insert(lines, args.task_description or "")
    table.insert(lines, "")

    if type(args.context.finder_selection) == "table" and #args.context.finder_selection > 0 then
      table.insert(lines, "## Finder Selection")
      table.insert(lines, "")
      for _, item in ipairs(args.context.finder_selection) do
        table.insert(lines, "- " .. item)
      end
      table.insert(lines, "")
    end

    if args.note and args.note ~= "" then
      table.insert(lines, "## Notes")
      table.insert(lines, "")
      table.insert(lines, args.note)
      table.insert(lines, "")
    end

    if args.include_raw_context then
      table.insert(lines, "## Clipboard")
      table.insert(lines, "")
      table.insert(lines, "```")
      table.insert(lines, args.context.clipboard or "")
      table.insert(lines, "```")
      table.insert(lines, "")
    end

    return table.concat(lines, "\n")
  end

  return self
end

return M
