local M = {}

local function isoNow()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function shallowCopy(value)
  local copy = {}
  for key, item in pairs(value) do
    if type(item) == "table" then
      local nested = {}
      for nestedKey, nestedValue in pairs(item) do
        nested[nestedKey] = nestedValue
      end
      copy[key] = nested
    else
      copy[key] = item
    end
  end
  return copy
end

local function contains(list, target)
  for _, item in ipairs(list or {}) do
    if item == target then
      return true
    end
  end

  return false
end

local function listModelIds(payload)
  if type(payload) ~= "table" then
    return {}
  end

  local source = payload.data or payload.models or payload
  local ids = {}
  if type(source) ~= "table" then
    return ids
  end

  for _, item in ipairs(source) do
    if type(item) == "table" then
      local identifier = item.id or item.model or item.identifier
      if identifier then
        table.insert(ids, identifier)
      end
    elseif type(item) == "string" then
      table.insert(ids, item)
    end
  end

  return ids
end

local function listLoadedNativeModels(payload)
  if type(payload) ~= "table" then
    return {}
  end

  local source = payload.data or payload.models or payload
  local ids = {}
  if type(source) ~= "table" then
    return ids
  end

  for _, item in ipairs(source) do
    if type(item) == "table" then
      local loaded = item.loaded == true
        or item.is_loaded == true
        or item.state == "loaded"
        or item.status == "loaded"
      if loaded then
        local identifier = item.id or item.model or item.identifier
        if identifier then
          table.insert(ids, identifier)
        end
      end
    end
  end

  return ids
end

function M.new(config, client)
  local changeListener = nil
  local busyCount = 0
  local state = {
    reachable = false,
    native_available = false,
    last_checked_at = nil,
    loaded_models = {},
    available_models = {},
    busy = false,
    last_error = nil,
    last_status_source = nil,
  }

  local function notify()
    if changeListener then
      changeListener(shallowCopy(state))
    end
  end

  local function applySnapshot(changes)
    for key, value in pairs(changes) do
      state[key] = value
    end
    notify()
  end

  local self = {}

  function self.setChangeListener(listener)
    changeListener = listener
  end

  function self.getStatusSnapshot()
    return shallowCopy(state)
  end

  function self.setBusy(isBusy)
    busyCount = isBusy and 1 or 0
    applySnapshot({ busy = isBusy })
  end

  function self.beginBusy()
    busyCount = busyCount + 1
    applySnapshot({ busy = true })
  end

  function self.endBusy()
    busyCount = math.max(0, busyCount - 1)
    applySnapshot({ busy = busyCount > 0 })
  end

  function self.isModelLoaded(modelId)
    return contains(state.loaded_models, modelId)
  end

  function self.isModelKnown(modelId)
    return contains(state.available_models, modelId)
  end

  function self.refreshStatus(callback)
    client.listNativeModels(function(nativeResult)
      if nativeResult.ok then
        applySnapshot({
          reachable = true,
          native_available = true,
          available_models = listModelIds(nativeResult.data),
          loaded_models = listLoadedNativeModels(nativeResult.data),
          last_checked_at = isoNow(),
          last_error = nil,
          last_status_source = "native",
        })

        if callback then
          callback({ ok = true, data = self.getStatusSnapshot() })
        end
        return
      end

      client.listModels(function(openAIResult)
        if openAIResult.ok then
          applySnapshot({
            reachable = true,
            native_available = false,
            available_models = listModelIds(openAIResult.data),
            loaded_models = {},
            last_checked_at = isoNow(),
            last_error = nil,
            last_status_source = "openai",
          })

          if callback then
            callback({ ok = true, data = self.getStatusSnapshot() })
          end
          return
        end

        local failureMessage = openAIResult.error and openAIResult.error.message or "Backend is unreachable"
        applySnapshot({
          reachable = false,
          native_available = false,
          available_models = {},
          loaded_models = {},
          last_checked_at = isoNow(),
          last_error = failureMessage,
          last_status_source = nil,
        })

        if callback then
          callback(openAIResult)
        end
      end)
    end)
  end

  local function continueEnsureModelReady(modelId, role, opts, callback)
    if not config.backend.enable_native_model_management then
      callback({
        ok = true,
        data = {
          model = modelId,
          loaded = false,
          skipped = true,
          reason = "native_management_disabled",
        },
      })
      return
    end

    if not state.native_available then
      callback({
        ok = true,
        data = {
          model = modelId,
          loaded = false,
          skipped = true,
          reason = "native_management_unavailable",
        },
      })
      return
    end

    if self.isModelLoaded(modelId) then
      callback({ ok = true, data = { model = modelId, loaded = true, already_loaded = true } })
      return
    end

    if opts.onWarning and role ~= "fast" then
      opts.onWarning(modelId, role)
    end

    client.loadModel(modelId, function(loadResult)
      if not loadResult.ok then
        callback(loadResult)
        return
      end

      self.refreshStatus(function(refreshResult)
        if refreshResult and refreshResult.ok then
          callback({ ok = true, data = { model = modelId, loaded = true, refreshed = true } })
          return
        end

        callback({ ok = true, data = { model = modelId, loaded = true, refresh_failed = true } })
      end)
    end)
  end

  function self.ensureModelReady(modelId, role, opts, callback)
    opts = opts or {}
    local shouldRefreshFirst = opts.force_refresh == true or state.last_checked_at == nil

    if shouldRefreshFirst then
      self.refreshStatus(function(refreshResult)
        if refreshResult and not refreshResult.ok and config.backend.enable_native_model_management then
          callback(refreshResult)
          return
        end

        continueEnsureModelReady(modelId, role, opts, callback)
      end)
      return
    end

    continueEnsureModelReady(modelId, role, opts, callback)
  end

  function self.withModelReady(modelSelection, opts, requestFn, callback)
    self.beginBusy()
    self.ensureModelReady(modelSelection.model, modelSelection.role, opts, function(ensureResult)
      if not ensureResult.ok then
        self.endBusy()
        callback(ensureResult)
        return
      end

      requestFn(function(result)
        self.endBusy()
        callback(result)
      end)
    end)
  end

  return self
end

return M
