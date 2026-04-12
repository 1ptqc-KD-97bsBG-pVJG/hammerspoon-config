local function showStartupError(message)
  print(string.format("[local-model-harness] %s", message))
  hs.alert.show(string.format("Local model harness failed: %s", message), nil, nil, 4)
end

local function shouldReload(changedFiles)
  for _, file in ipairs(changedFiles) do
    if file:sub(-4) == ".lua" then
      return true
    end
  end

  return false
end

local function configureReloader()
  if _G.localModelHarnessReloader then
    _G.localModelHarnessReloader:stop()
  end

  _G.localModelHarnessReloader = hs.pathwatcher
    .new(hs.configdir, function(changedFiles)
      if shouldReload(changedFiles) then
        hs.reload()
      end
    end)
    :start()
end

local ok, err = xpcall(function()
  local config = require("config")
  local valid, validationError = config.validate()
  if not valid then
    error(validationError)
  end

  local storage = require("llm.storage").new(config)
  local scripts = require("llm.scripts").new(config)
  local client = require("llm.client").new(config)
  local models = require("llm.models").new(config)
  local prompts = require("llm.prompts").new(config)
  local context = require("llm.context").new(config)
  local status = require("llm.status").new(config, client)

  local storageReady, storageError = storage.ensureDirectories()
  if not storageReady then
    error(storageError)
  end

  local actions = require("llm.actions").new({
    config = config,
    client = client,
    models = models,
    prompts = prompts,
    context = context,
    status = status,
    storage = storage,
    scripts = scripts,
  })

  local ui = require("llm.ui").new(config, actions, status)
  status.setChangeListener(function()
    ui.refreshMenu()
  end)

  ui.refreshMenu()
  ui.startStatusTimer()
  actions.refreshBackendStatus({ silent = true })
  configureReloader()

  _G.LocalModelHarness = {
    config = config,
    storage = storage,
    client = client,
    models = models,
    prompts = prompts,
    context = context,
    status = status,
    actions = actions,
    ui = ui,
    scripts = scripts,
  }
end, debug.traceback)

if not ok then
  showStartupError(err)
end
