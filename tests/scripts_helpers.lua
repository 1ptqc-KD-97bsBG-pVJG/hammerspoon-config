package.path = table.concat({
  "./?.lua",
  "./?/init.lua",
  package.path,
}, ";")

local scriptsModule = require("llm.scripts").new({
  scripts = {
    default_language = "python",
  },
})

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s\nexpected: %s\nactual: %s", message, tostring(expected), tostring(actual)))
  end
end

local fenced = scriptsModule.extractCodeBlock("```python\nprint('hi')\n```\n\nUse python.", "python")
assertEqual(fenced.code, "print('hi')", "fenced extraction should return code")
assertEqual(fenced.language, "python", "fenced extraction should preserve language")

local raw = scriptsModule.extractCodeBlock("echo hello", "bash")
assertEqual(raw.code, "echo hello", "raw fallback should return unfenced body")
assertEqual(raw.language, "bash", "raw fallback should preserve preferred language")

assertEqual(scriptsModule.extensionForLanguage("python"), "py", "python extension should be py")
assertEqual(scriptsModule.guessLanguage("write a bash script"), "bash", "language guessing should detect bash")

print("scripts helper tests passed")
