local M = {}

local function buildHeaders(config)
  local headers = {
    ["Content-Type"] = "application/json",
  }

  local envName = config.backend.api_token_env
  if envName and envName ~= "" then
    local token = os.getenv(envName)
    if token and token ~= "" then
      headers.Authorization = "Bearer " .. token
    end
  end

  return headers
end

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

local function collapseWhitespace(value)
  return trim(tostring(value or ""):gsub("[%s\194\160]+", " "))
end

local function previewText(value, maxLength)
  local flattened = collapseWhitespace(value)
  if flattened == "" then
    return ""
  end

  if #flattened <= maxLength then
    return flattened
  end

  return flattened:sub(1, maxLength - 3) .. "..."
end

local function decodeJson(body)
  if body == nil or body == "" then
    return true, {}
  end

  local ok, decoded = pcall(hs.json.decode, body)
  if not ok then
    return false, decoded
  end

  return true, decoded
end

local function extractErrorMessage(decoded, fallback)
  if type(decoded) ~= "table" then
    return fallback
  end

  if type(decoded.error) == "string" then
    return decoded.error
  end

  if type(decoded.error) == "table" then
    return decoded.error.message or decoded.error.code or fallback
  end

  return decoded.message or fallback
end

local function normalizeFailure(code, message, detail, status)
  return {
    ok = false,
    error = {
      code = code,
      message = message,
      detail = detail,
      status = status,
    },
  }
end

local function buildInputBlocks(systemPrompt, userPrompt)
  local items = {}

  if systemPrompt and systemPrompt ~= "" then
    table.insert(items, {
      role = "system",
      content = {
        {
          type = "input_text",
          text = systemPrompt,
        },
      },
    })
  end

  if userPrompt and userPrompt ~= "" then
    table.insert(items, {
      role = "user",
      content = {
        {
          type = "input_text",
          text = userPrompt,
        },
      },
    })
  end

  return items
end

local function flattenContentArray(content)
  local parts = {}
  for _, item in ipairs(content or {}) do
    if type(item) == "string" then
      local text = trim(item)
      if text ~= "" then
        table.insert(parts, text)
      end
    elseif type(item) == "table" then
      if type(item.text) == "string" and item.text ~= "" then
        table.insert(parts, item.text)
      elseif item.type == "output_text" and type(item.text) == "string" then
        table.insert(parts, item.text)
      elseif type(item.content) == "string" and item.content ~= "" then
        table.insert(parts, item.content)
      end
    end
  end

  if #parts == 0 then
    return nil
  end

  return table.concat(parts, "\n")
end

local function extractTextFromResponses(decoded)
  if type(decoded) ~= "table" then
    return nil
  end

  if type(decoded.output_text) == "string" and decoded.output_text ~= "" then
    return decoded.output_text
  end

  if type(decoded.response) == "string" and decoded.response ~= "" then
    return decoded.response
  end

  if type(decoded.output) == "table" then
    local parts = {}
    for _, outputItem in ipairs(decoded.output) do
      if type(outputItem) == "table" then
        if type(outputItem.content) == "table" then
          local flattened = flattenContentArray(outputItem.content)
          if flattened and flattened ~= "" then
            table.insert(parts, flattened)
          end
        elseif outputItem.type == "message" and type(outputItem.text) == "string" then
          table.insert(parts, outputItem.text)
        end
      end
    end

    if #parts > 0 then
      return table.concat(parts, "\n")
    end
  end

  return nil
end

local function extractTextFromNativeChat(decoded)
  if type(decoded) ~= "table" then
    return nil, {}
  end

  local output = type(decoded.output) == "table" and decoded.output or {}
  local messageParts = {}
  local reasoningParts = {}

  for _, item in ipairs(output) do
    if type(item) == "table" then
      if item.type == "message" and type(item.content) == "string" and trim(item.content) ~= "" then
        table.insert(messageParts, item.content)
      elseif item.type == "reasoning" and type(item.content) == "string" and trim(item.content) ~= "" then
        table.insert(reasoningParts, item.content)
      end
    end
  end

  local text = nil
  if #messageParts > 0 then
    text = table.concat(messageParts, "\n")
  end

  local reasoningContent = nil
  if #reasoningParts > 0 then
    reasoningContent = table.concat(reasoningParts, "\n")
  end

  return text, {
    reasoning_content = reasoningContent,
    stats = decoded.stats,
  }
end

local function extractTextFromChatCompletions(decoded)
  if type(decoded) ~= "table" then
    return nil, nil, {}
  end

  local firstChoice = type(decoded.choices) == "table" and decoded.choices[1] or nil
  if type(firstChoice) ~= "table" then
    return nil, nil, {}
  end

  local finishReason = firstChoice.finish_reason
  local message = type(firstChoice.message) == "table" and firstChoice.message or nil

  if type(firstChoice.text) == "string" and firstChoice.text ~= "" then
    return firstChoice.text, finishReason, { raw_choice = firstChoice }
  end

  if message then
    local content = message.content
    if type(content) == "string" and content ~= "" then
      return content, finishReason, { raw_choice = firstChoice }
    end

    if type(content) == "table" then
      return flattenContentArray(content), finishReason, { raw_choice = firstChoice }
    end
  end

  local reasoningContent = nil
  if message and type(message.reasoning_content) == "string" and trim(message.reasoning_content) ~= "" then
    reasoningContent = message.reasoning_content
  elseif type(firstChoice.reasoning_content) == "string" and trim(firstChoice.reasoning_content) ~= "" then
    reasoningContent = firstChoice.reasoning_content
  end

  return nil, finishReason, {
    raw_choice = firstChoice,
    reasoning_content = reasoningContent,
  }
end

M._test = {
  extractTextFromResponses = extractTextFromResponses,
  extractTextFromChatCompletions = extractTextFromChatCompletions,
  extractTextFromNativeChat = extractTextFromNativeChat,
  flattenContentArray = flattenContentArray,
}

function M.new(config)
  local headers = buildHeaders(config)

  local function rawRequest(url, method, body, timeoutMs, callback)
    local completed = false
    local timeout = hs.timer.doAfter(timeoutMs / 1000, function()
      if completed then
        return
      end

      completed = true
      callback(nil, nil, nil, normalizeFailure("timeout", string.format("%s request timed out", method), url))
    end)

    hs.http.doAsyncRequest(url, method, body, headers, function(statusCode, responseBody, responseHeaders)
      if completed then
        return
      end

      completed = true
      timeout:stop()

      if type(statusCode) ~= "number" then
        callback(nil, nil, nil, normalizeFailure("request_failed", "HTTP request failed", statusCode))
        return
      end

      callback(statusCode, responseBody, responseHeaders, nil)
    end)
  end

  local function jsonRequest(url, method, payload, timeoutMs, callback)
    local body = nil
    if payload ~= nil then
      local ok, encoded = pcall(hs.json.encode, payload)
      if not ok then
        callback(normalizeFailure("json_encode_failed", "Failed to encode request payload", encoded))
        return
      end
      body = encoded
    end

    rawRequest(url, method, body, timeoutMs, function(statusCode, responseBody, responseHeaders, transportError)
      if transportError then
        callback(transportError)
        return
      end

      local ok, decoded = decodeJson(responseBody)
      if statusCode < 200 or statusCode >= 300 then
        local message = ok and extractErrorMessage(decoded, "Backend request failed") or "Backend request failed"
        callback(normalizeFailure(string.format("http_%d", statusCode), message, responseBody, statusCode))
        return
      end

      if not ok then
        callback(normalizeFailure("json_decode_failed", "Failed to decode response payload", decoded, statusCode))
        return
      end

      callback({
        ok = true,
        data = decoded,
        status = statusCode,
        headers = responseHeaders,
      })
    end)
  end

  local self = {}

  function self.normalizeFailure(code, message, detail)
    return normalizeFailure(code, message, detail)
  end

  function self.requestJson(args, callback)
    jsonRequest(args.url, args.method, args.payload, args.timeout_ms, callback)
  end

  function self.probePostEndpoint(path, callback)
    jsonRequest(config.backend.openai_base .. path, "POST", {}, config.backend.status_timeout_ms, function(result)
      if result.ok then
        callback({ ok = true, data = { available = true, status = result.status } })
        return
      end

      local status = result.error and result.error.status or nil
      if status == 400 or status == 401 or status == 422 then
        callback({ ok = true, data = { available = true, status = status } })
        return
      end

      if status == 404 or status == 405 then
        callback({ ok = true, data = { available = false, status = status } })
        return
      end

      callback(result)
    end)
  end

  function self.probeNativePostEndpoint(path, callback)
    jsonRequest(config.backend.native_base .. path, "POST", {}, config.backend.status_timeout_ms, function(result)
      if result.ok then
        callback({ ok = true, data = { available = true, status = result.status } })
        return
      end

      local status = result.error and result.error.status or nil
      if status == 400 or status == 401 or status == 422 then
        callback({ ok = true, data = { available = true, status = status } })
        return
      end

      if status == 404 or status == 405 then
        callback({ ok = true, data = { available = false, status = status } })
        return
      end

      callback(result)
    end)
  end

  function self.listModels(callback)
    self.requestJson({
      url = config.backend.openai_base .. "/models",
      method = "GET",
      timeout_ms = config.backend.status_timeout_ms,
    }, callback)
  end

  function self.listNativeModels(callback)
    self.requestJson({
      url = config.backend.native_base .. "/models",
      method = "GET",
      timeout_ms = config.backend.status_timeout_ms,
    }, callback)
  end

  function self.loadModel(modelId, ttlSeconds, callback)
    if type(ttlSeconds) == "function" then
      callback = ttlSeconds
      ttlSeconds = nil
    end

    local payload = { model = modelId }
    if type(ttlSeconds) == "number" and ttlSeconds > 0 then
      payload.ttl = ttlSeconds
    end

    self.requestJson({
      url = config.backend.native_base .. "/models/load",
      method = "POST",
      payload = payload,
      timeout_ms = config.backend.request_timeout_ms,
    }, callback)
  end

  function self.unloadModelInstance(instanceId, callback)
    self.requestJson({
      url = config.backend.native_base .. "/models/unload",
      method = "POST",
      payload = { instance_id = instanceId },
      timeout_ms = config.backend.request_timeout_ms,
    }, callback)
  end

  function self.responsesRequest(payload, callback)
    self.requestJson({
      url = config.backend.openai_base .. "/responses",
      method = "POST",
      payload = payload,
      timeout_ms = config.backend.request_timeout_ms,
    }, callback)
  end

  function self.chatCompletionsRequest(payload, callback)
    self.requestJson({
      url = config.backend.openai_base .. "/chat/completions",
      method = "POST",
      payload = payload,
      timeout_ms = config.backend.request_timeout_ms,
    }, callback)
  end

  function self.nativeChatRequest(payload, callback)
    self.requestJson({
      url = config.backend.native_base .. "/chat",
      method = "POST",
      payload = payload,
      timeout_ms = config.backend.request_timeout_ms,
    }, callback)
  end

  function self.requestTextResponse(request, callback)
    local payload = {
      model = request.model,
      input = buildInputBlocks(request.system, request.user),
    }

    if request.max_output_tokens then
      payload.max_output_tokens = request.max_output_tokens
    end

    self.responsesRequest(payload, function(result)
      if not result.ok then
        callback(result)
        return
      end

      local text = extractTextFromResponses(result.data)
      if not text or trim(text) == "" then
        callback(normalizeFailure("empty_output", "The model response did not include text output", result.data))
        return
      end

      callback({
        ok = true,
        data = {
          text = trim(text),
          raw = result.data,
        },
      })
    end)
  end

  function self.requestPlainChatCompletion(request, callback)
    local payload = {
      model = request.model,
      messages = {
        {
          role = "system",
          content = request.system,
        },
        {
          role = "user",
          content = request.user,
        },
      },
      temperature = request.temperature or 0,
      stream = false,
    }

    if request.max_tokens then
      payload.max_tokens = request.max_tokens
    end

    if type(request.stop) == "table" and #request.stop > 0 then
      payload.stop = request.stop
    end

    self.chatCompletionsRequest(payload, function(result)
      if not result.ok then
        callback(result)
        return
      end

      local text, finishReason, meta = extractTextFromChatCompletions(result.data)
      if not text or trim(text) == "" then
        if type(meta) == "table" and type(meta.reasoning_content) == "string" and trim(meta.reasoning_content) ~= "" then
          callback(normalizeFailure(
            "reasoning_only_output",
            "The model produced reasoning output but no final text",
            {
              finish_reason = finishReason,
              reasoning_preview = previewText(meta.reasoning_content, 180),
            }
          ))
          return
        end

        local detail = finishReason and ("finish_reason=" .. tostring(finishReason)) or nil
        callback(normalizeFailure("empty_output", "The model response did not include text output", detail))
        return
      end

      callback({
        ok = true,
        data = {
          text = trim(text),
          finish_reason = finishReason,
          raw = result.data,
        },
      })
    end)
  end

  function self.requestNativeChat(request, callback)
    local payload = {
      model = request.model,
      system_prompt = request.system,
      input = request.user,
      temperature = request.temperature or 0,
      store = false,
    }

    if request.max_output_tokens then
      payload.max_output_tokens = request.max_output_tokens
    end

    if request.reasoning then
      payload.reasoning = request.reasoning
    end

    self.nativeChatRequest(payload, function(result)
      if not result.ok then
        callback(result)
        return
      end

      local text, meta = extractTextFromNativeChat(result.data)
      if not text or trim(text) == "" then
        if type(meta) == "table" and type(meta.reasoning_content) == "string" and trim(meta.reasoning_content) ~= "" then
          callback(normalizeFailure(
            "reasoning_only_output",
            "The model produced reasoning output but no final text",
            {
              reasoning_preview = previewText(meta.reasoning_content, 180),
            }
          ))
          return
        end

        callback(normalizeFailure("empty_output", "The model response did not include text output", nil))
        return
      end

      callback({
        ok = true,
        data = {
          text = trim(text),
          raw = result.data,
        },
      })
    end)
  end

  function self.requestStructuredChatResponse(request, callback)
    local payload = {
      model = request.model,
      messages = {
        {
          role = "system",
          content = request.system,
        },
        {
          role = "user",
          content = request.user,
        },
      },
      response_format = {
        type = "json_schema",
        json_schema = {
          name = request.schema_name,
          strict = true,
          schema = request.schema,
        },
      },
      temperature = request.temperature or 0,
      stream = false,
    }

    if request.max_tokens then
      payload.max_tokens = request.max_tokens
    end

    self.chatCompletionsRequest(payload, function(result)
      if not result.ok then
        callback(result)
        return
      end

      local text, finishReason = extractTextFromChatCompletions(result.data)
      if not text or trim(text) == "" then
        callback(normalizeFailure("empty_output", "The model response did not include structured content", result.data))
        return
      end

      local ok, parsed = pcall(hs.json.decode, text)
      if not ok or type(parsed) ~= "table" then
        callback(normalizeFailure("json_decode_failed", "The model returned invalid JSON for structured output", text))
        return
      end

      callback({
        ok = true,
        data = {
          parsed = parsed,
          raw_text = text,
          finish_reason = finishReason,
          raw = result.data,
        },
      })
    end)
  end

  return self
end

return M
