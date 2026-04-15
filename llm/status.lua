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
        if type(nestedValue) == "table" then
          local nestedCopy = {}
          for k, v in pairs(nestedValue) do
            nestedCopy[k] = v
          end
          nested[nestedKey] = nestedCopy
        else
          nested[nestedKey] = nestedValue
        end
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

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

local function normalizeModelId(value)
  local text = trim(value)
  if text == "" then
    return nil
  end

  return (text:gsub(":%d+$", ""))
end

local function extractModelIdentifier(item)
  if type(item) ~= "table" then
    return nil
  end

  return normalizeModelId(item.key)
    or normalizeModelId(item.model)
    or normalizeModelId(item.model_key)
    or normalizeModelId(item.identifier)
    or normalizeModelId(item.id)
    or normalizeModelId(item.path)
end

local function extractInstanceId(item)
  if type(item) ~= "table" then
    return nil
  end

  return item.instance_id or item.instanceId or item.id
end

local function isLoadedItem(item)
  if type(item) ~= "table" then
    return false
  end

  if item.loaded == true
    or item.is_loaded == true
    or item.state == "loaded"
    or item.status == "loaded"
    or item.active == true
    or item.current == true
  then
    return true
  end

  if extractInstanceId(item) and item.loaded == nil and item.is_loaded == nil and item.state == nil and item.status == nil then
    return true
  end

  return false
end

local function parseNativeModels(payload)
  local availableModels = {}
  local loadedModels = {}
  local loadedInstances = {}

  local function addAvailable(modelId)
    if modelId and not contains(availableModels, modelId) then
      table.insert(availableModels, modelId)
    end
  end

  local function addLoadedInstance(modelId, instanceId, label)
    if modelId and not contains(loadedModels, modelId) then
      table.insert(loadedModels, modelId)
    end

    local duplicate = false
    for _, item in ipairs(loadedInstances) do
      if item.instance_id == instanceId and item.model == modelId then
        duplicate = true
        break
      end
    end

    if not duplicate then
      table.insert(loadedInstances, {
        instance_id = instanceId,
        model = modelId,
        label = label,
      })
    end
  end

  local visited = {}
  local function walk(node, parentModelId, parentLabel)
    if type(node) ~= "table" or visited[node] then
      return
    end
    visited[node] = true

    local modelId = extractModelIdentifier(node) or parentModelId
    local label = trim(node.display_name or node.name or node.identifier or parentLabel or modelId or "Unknown")
    addAvailable(modelId)

    local nestedLoaded = node.loaded_instances
    if type(nestedLoaded) == "table" then
      for _, loaded in ipairs(nestedLoaded) do
        local loadedModelId = modelId or extractModelIdentifier(loaded)
        local instanceId = extractInstanceId(loaded)
        addAvailable(loadedModelId)
        if loadedModelId and instanceId and trim(instanceId) ~= "" then
          addLoadedInstance(loadedModelId, instanceId, label)
        end
      end
    end

    if isLoadedItem(node) and modelId then
      addLoadedInstance(modelId, extractInstanceId(node), label)
    end

    for key, child in pairs(node) do
      if key ~= "loaded_instances" then
        if type(child) == "table" then
          walk(child, modelId, label)
        elseif type(child) == "string" then
          local normalized = normalizeModelId(child)
          if normalized and normalized:find("/", 1, true) then
            addAvailable(normalized)
          end
        end
      end
    end
  end

  walk(payload and (payload.data or payload.models or payload) or {}, nil, nil)

  return {
    available_models = availableModels,
    loaded_models = loadedModels,
    loaded_instances = loadedInstances,
  }
end

local function parseOpenAIModels(payload)
  local source = payload and (payload.data or payload.models or payload) or {}
  local availableModels = {}

  if type(source) ~= "table" then
    return availableModels
  end

  for _, item in ipairs(source) do
    if type(item) == "table" then
      local modelId = extractModelIdentifier(item)
      if modelId and not contains(availableModels, modelId) then
        table.insert(availableModels, modelId)
      end
    elseif type(item) == "string" then
      if not contains(availableModels, item) then
        table.insert(availableModels, item)
      end
    end
  end

  return availableModels
end

M._test = {
  parseNativeModels = parseNativeModels,
  parseOpenAIModels = parseOpenAIModels,
}

function M.new(config, client)
  local changeListener = nil
  local busyCount = 0
  local state = {
    reachable = false,
    native_available = false,
    unload_available = nil,
    responses_available = nil,
    chat_available = nil,
    native_chat_available = nil,
    last_checked_at = nil,
    loaded_models = {},
    loaded_instances = {},
    available_models = {},
    busy = false,
    last_error = nil,
    last_status_source = nil,
    active_clipboard_profile = config.clipboard.active_profile,
    developer_mode = config.debug and config.debug.developer_mode == true or false,
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

  function self.getActiveClipboardProfile()
    return state.active_clipboard_profile
  end

  function self.setActiveClipboardProfile(profileName)
    if type(config.clipboard.profiles[profileName]) ~= "table" then
      return false
    end

    applySnapshot({ active_clipboard_profile = profileName })
    return true
  end

  function self.getDeveloperMode()
    return state.developer_mode == true
  end

  function self.setDeveloperMode(enabled)
    applySnapshot({ developer_mode = enabled == true })
    return state.developer_mode
  end

  function self.toggleDeveloperMode()
    return self.setDeveloperMode(not self.getDeveloperMode())
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

  function self.getLoadedInstances()
    local instances = {}
    for _, item in ipairs(state.loaded_instances or {}) do
      table.insert(instances, {
        instance_id = item.instance_id,
        model = item.model,
        label = item.label,
      })
    end
    return instances
  end

  function self.isClipboardProfilePrepared(profile)
    if not profile then
      return false
    end

    if #state.loaded_instances == 1 and state.loaded_instances[1].model == profile.model then
      return true
    end

    if #state.loaded_instances == 0 and #state.loaded_models == 1 and state.loaded_models[1] == profile.model then
      return true
    end

    return false
  end

  local function probeUnloadEndpoint(callback)
    client.requestJson({
      url = config.backend.native_base .. "/models/unload",
      method = "POST",
      payload = { instance_id = "__probe__" },
      timeout_ms = config.backend.status_timeout_ms,
    }, function(result)
      if result.ok then
        callback(true)
        return
      end

      local status = result.error and result.error.status or nil
      if status == 400 or status == 401 or status == 422 then
        callback(true)
        return
      end

      if status == 404 or status == 405 then
        callback(false)
        return
      end

      callback(nil)
    end)
  end

  function self.refreshStatus(callback)
    client.listNativeModels(function(nativeResult)
      local nativeParsed = nil

      if nativeResult.ok then
        nativeParsed = parseNativeModels(nativeResult.data)
      end

      client.listModels(function(openAIResult)
        local reachable = openAIResult.ok or nativeResult.ok
        local availableModels = {}
        local source = nil

        if nativeParsed then
          availableModels = nativeParsed.available_models
          source = "native"
        elseif openAIResult.ok then
          availableModels = parseOpenAIModels(openAIResult.data)
          source = "openai"
        end

        client.probePostEndpoint("/chat/completions", function(chatProbe)
          client.probePostEndpoint("/responses", function(responsesProbe)
            client.probeNativePostEndpoint("/chat", function(nativeChatProbe)
              local finalize = function(unloadAvailable)
              applySnapshot({
                reachable = reachable,
                native_available = nativeResult.ok,
                unload_available = unloadAvailable,
                responses_available = responsesProbe.ok and responsesProbe.data.available or false,
                chat_available = chatProbe.ok and chatProbe.data.available or false,
                native_chat_available = nativeChatProbe.ok and nativeChatProbe.data.available or false,
                available_models = availableModels,
                loaded_models = nativeParsed and nativeParsed.loaded_models or {},
                loaded_instances = nativeParsed and nativeParsed.loaded_instances or {},
                last_checked_at = isoNow(),
                last_error = reachable and nil or (openAIResult.error and openAIResult.error.message or nativeResult.error and nativeResult.error.message or "Backend is unreachable"),
                last_status_source = source,
              })

              if callback then
                callback(reachable and { ok = true, data = self.getStatusSnapshot() } or openAIResult.ok and { ok = true, data = self.getStatusSnapshot() } or nativeResult)
              end
            end

            if nativeResult.ok then
              probeUnloadEndpoint(finalize)
            else
              finalize(false)
            end
            end)
          end)
        end)
      end)
    end)
  end

  local function unloadInstances(instances, callback)
    if type(instances) ~= "table" or #instances == 0 then
      callback({ ok = true, data = { unloaded = {} } })
      return
    end

    if state.unload_available == false then
      callback({
        ok = false,
        error = {
          code = "native_unload_unavailable",
          message = "Native unload endpoint is unavailable",
          detail = "Unload loaded models manually in LM Studio before preparing the clipboard model.",
        },
      })
      return
    end

    local index = 1
    local unloaded = {}

    local function unloadNext()
      local instance = instances[index]
      if not instance then
        callback({ ok = true, data = { unloaded = unloaded } })
        return
      end

      if not instance.instance_id or trim(instance.instance_id) == "" then
        callback({
          ok = false,
          error = {
            code = "missing_instance_id",
            message = "A loaded model instance is missing instance_id",
            detail = instance.model or "unknown",
          },
        })
        return
      end

      client.unloadModelInstance(instance.instance_id, function(result)
        if not result.ok then
          callback(result)
          return
        end

        table.insert(unloaded, instance)
        index = index + 1
        unloadNext()
      end)
    end

    unloadNext()
  end

  function self.prepareClipboardModel(profile, callback)
    if not config.backend.enable_native_model_management then
      callback({
        ok = false,
        error = {
          code = "native_management_disabled",
          message = "Native model management is disabled",
          detail = "Enable backend.enable_native_model_management to prepare clipboard models.",
        },
      })
      return
    end

    self.refreshStatus(function(refreshResult)
      if not refreshResult.ok then
        callback(refreshResult)
        return
      end

      if not state.native_available then
        callback({
          ok = false,
          error = {
            code = "native_management_unavailable",
            message = "Native model management is unavailable",
            detail = "LM Studio native /api/v1/models endpoints were not reachable.",
          },
        })
        return
      end

      if #state.loaded_models > 1 and #state.loaded_instances == 0 then
        callback({
          ok = false,
          error = {
            code = "loaded_models_missing_instances",
            message = "Loaded models were detected, but instance IDs were not available",
            detail = "Unload models manually in LM Studio before preparing the clipboard model.",
          },
        })
        return
      end

      local alreadyPrepared = self.isClipboardProfilePrepared(profile)

      if alreadyPrepared then
        callback({
          ok = true,
          data = {
            prepared = true,
            already_prepared = true,
            profile = profile.name,
            model = profile.model,
            unloaded = {},
            loaded_instances = self.getLoadedInstances(),
          },
        })
        return
      end

      if #state.loaded_instances == 0 and #state.loaded_models == 1 and state.loaded_models[1] == profile.model then
        callback({
          ok = true,
          data = {
            prepared = true,
            already_prepared = true,
            profile = profile.name,
            model = profile.model,
            unloaded = {},
            loaded_instances = self.getLoadedInstances(),
          },
        })
        return
      end

      unloadInstances(self.getLoadedInstances(), function(unloadResult)
        if not unloadResult.ok then
          callback(unloadResult)
          return
        end

        client.loadModel(profile.model, config.backend.clipboard_ttl_s, function(loadResult)
          if not loadResult.ok then
            callback(loadResult)
            return
          end

          self.refreshStatus(function(postRefresh)
            if not postRefresh.ok then
              callback(postRefresh)
              return
            end

            callback({
              ok = true,
              data = {
                prepared = self.isModelLoaded(profile.model),
                profile = profile.name,
                model = profile.model,
                unloaded = unloadResult.data.unloaded,
                loaded_instances = self.getLoadedInstances(),
              },
            })
          end)
        end)
      end)
    end)
  end

  function self.ensureClipboardModel(profile, callback)
    self.refreshStatus(function(refreshResult)
      if not refreshResult.ok then
        callback(refreshResult)
        return
      end

      if self.isClipboardProfilePrepared(profile) then
        callback({
          ok = true,
          data = {
            prepared = true,
            model = profile.model,
            profile = profile.name,
          },
        })
        return
      end

      if self.isModelLoaded(profile.model) and (#state.loaded_instances > 1 or #state.loaded_models > 1) then
        callback({
          ok = false,
          error = {
            code = "multiple_models_loaded",
            message = "Multiple models are currently loaded",
            detail = "Run Prepare Clipboard Model so the clipboard profile is the only loaded model.",
          },
        })
        return
      end

      if not config.backend.manage_clipboard_model then
        callback({
          ok = false,
          error = {
            code = "clipboard_model_not_prepared",
            message = "Clipboard model is not prepared",
            detail = string.format("Run Prepare Clipboard Model for %s first.", profile.label),
          },
        })
        return
      end

      self.prepareClipboardModel(profile, callback)
    end)
  end

  return self
end

return M
