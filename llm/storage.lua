local M = {}

local function isoNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function stamp()
  return os.date("%Y%m%d-%H%M%S")
end

local function slugify(value, fallback)
  local slug = (value or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    return fallback or "item"
  end
  return slug
end

local function dirname(path)
  return path:match("^(.*)/[^/]+$") or "."
end

local function ensureDir(path)
  local current = ""
  if path:sub(1, 1) == "/" then
    current = "/"
  end

  for part in path:gmatch("[^/]+") do
    if current == "/" then
      current = current .. part
    elseif current == "" then
      current = part
    else
      current = current .. "/" .. part
    end

    if not hs.fs.attributes(current) then
      local ok, message = hs.fs.mkdir(current)
      if not ok then
        return false, message or ("Failed to create directory: " .. current)
      end
    end
  end

  return true
end

local function writeFile(path, content, mode)
  local file, openError = io.open(path, mode or "w")
  if not file then
    return false, openError
  end

  local ok, writeError = file:write(content)
  file:close()
  if not ok then
    return false, writeError
  end

  return true
end

local function renderMetadataLines(metadata)
  local lines = {}
  for _, item in ipairs(metadata or {}) do
    if item.value ~= nil and item.value ~= "" then
      table.insert(lines, string.format("- %s: %s", item.label, item.value))
    end
  end
  return table.concat(lines, "\n")
end

function M.new(config)
  local self = {}

  function self.ensureDirectories()
    local directories = {
      config.storage.output_dir,
      config.storage.handoff_dir,
      config.storage.script_drafts_dir,
      config.storage.diagnostics_dir,
      dirname(config.storage.inbox_file),
    }

    for _, path in ipairs(directories) do
      local ok, message = ensureDir(path)
      if not ok then
        return false, message
      end
    end

    return true
  end

  function self.saveMarkdown(title, body, metadata, opts)
    opts = opts or {}
    local directory = opts.directory or config.storage.output_dir
    local prefix = opts.prefix or "note"
    local filename = string.format("%s-%s-%s.md", stamp(), prefix, slugify(title, "note"))
    local path = directory .. "/" .. filename

    local contentParts = {
      "# " .. title,
      "",
      renderMetadataLines(metadata),
      "",
      body,
      "",
    }

    local ok, errorMessage = writeFile(path, table.concat(contentParts, "\n"), "w")
    if not ok then
      return {
        ok = false,
        error = {
          code = "write_failed",
          message = "Failed to write markdown file",
          detail = errorMessage,
        },
      }
    end

    return {
      ok = true,
      data = {
        path = path,
        generated_at = isoNow(),
      },
    }
  end

  function self.appendInbox(body)
    local ok, errorMessage = writeFile(config.storage.inbox_file, body .. "\n", "a")
    if not ok then
      return {
        ok = false,
        error = {
          code = "append_failed",
          message = "Failed to append inbox file",
          detail = errorMessage,
        },
      }
    end

    return {
      ok = true,
      data = {
        path = config.storage.inbox_file,
      },
    }
  end

  function self.saveScriptDraft(name, code, note, extension)
    local ext = extension or "txt"
    local baseName = string.format("%s-%s", stamp(), slugify(name, "script"))
    local codePath = string.format("%s/%s.%s", config.storage.script_drafts_dir, baseName, ext)
    local notePath = string.format("%s/%s.md", config.storage.script_drafts_dir, baseName)

    local ok, codeError = writeFile(codePath, code, "w")
    if not ok then
      return {
        ok = false,
        error = {
          code = "script_write_failed",
          message = "Failed to write script draft",
          detail = codeError,
        },
      }
    end

    local noteOk, noteError = writeFile(notePath, note, "w")
    if not noteOk then
      return {
        ok = false,
        error = {
          code = "note_write_failed",
          message = "Failed to write script note",
          detail = noteError,
        },
      }
    end

    return {
      ok = true,
      data = {
        code_path = codePath,
        note_path = notePath,
      },
    }
  end

  function self.appendDiagnosticRecord(record)
    local filename = string.format("%s-bakeoff.jsonl", os.date("%Y%m%d"))
    local path = string.format("%s/%s", config.storage.diagnostics_dir, filename)
    local ok, encoded = pcall(hs.json.encode, record)
    if not ok then
      return {
        ok = false,
        error = {
          code = "diagnostic_encode_failed",
          message = "Failed to encode diagnostic record",
          detail = encoded,
        },
      }
    end

    local writeOk, writeError = writeFile(path, encoded .. "\n", "a")
    if not writeOk then
      return {
        ok = false,
        error = {
          code = "diagnostic_write_failed",
          message = "Failed to write diagnostic record",
          detail = writeError,
        },
      }
    end

    return {
      ok = true,
      data = {
        path = path,
      },
    }
  end

  return self
end

return M
