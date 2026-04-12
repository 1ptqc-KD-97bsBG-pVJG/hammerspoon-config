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
  local state = {
    reachable = false,
    native_available = false,
    last_checked_at = nil,
    loaded_models = {},
    available_models = {},
    busy = false,
    last_error = nil,
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
    applySnapshot({ busy = isBusy })
  end

  function self.isModelLoaded(modelId)
    for _, loadedId in ipairs(state.loaded_models) do
      if loadedId == modelId then
        return true
      end
    end

    return false
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
        })

        if callback then
          callback(openAIResult)
        end
      end)
    end)
  end

  function self.ensureModelReady(modelId, role, opts, callback)
    opts = opts or {}

    if not config.backend.enable_native_model_management then
      callback({ ok = true, data = { model = modelId, loaded = false, skipped = true } })
      return
    end

    if not state.native_available then
      callback({ ok = true, data = { model = modelId, loaded = false, skipped = true } })
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
          callback({ ok = true, data = { model = modelId, loaded = true } })
          return
        end

        callback({ ok = true, data = { model = modelId, loaded = true, refresh_failed = true } })
      end)
    end)
  end

  return self
end

return M
