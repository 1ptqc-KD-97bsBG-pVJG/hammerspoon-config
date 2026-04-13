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

local function normalizeFailure(code, message, detail)
  return {
    ok = false,
    error = {
      code = code,
      message = message,
      detail = detail,
    },
  }
end

local function extractTextFromResponse(decoded)
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
    local textParts = {}
    for _, outputItem in ipairs(decoded.output) do
      if type(outputItem) == "table" and type(outputItem.content) == "table" then
        for _, contentItem in ipairs(outputItem.content) do
          if type(contentItem) == "table" then
            if type(contentItem.text) == "string" and contentItem.text ~= "" then
              table.insert(textParts, contentItem.text)
            elseif contentItem.type == "output_text" and type(contentItem.text) == "string" then
              table.insert(textParts, contentItem.text)
            end
          end
        end
      end
    end

    if #textParts > 0 then
      return table.concat(textParts, "\n")
    end
  end

  if type(decoded.choices) == "table" then
    local firstChoice = decoded.choices[1]
    if type(firstChoice) == "table" then
      if type(firstChoice.text) == "string" and firstChoice.text ~= "" then
        return firstChoice.text
      end

      if type(firstChoice.message) == "table" and type(firstChoice.message.content) == "string" then
        return firstChoice.message.content
      end

      if type(firstChoice.message) == "table" and type(firstChoice.message.content) == "table" then
        local parts = {}
        for _, contentItem in ipairs(firstChoice.message.content) do
          if type(contentItem) == "table" and type(contentItem.text) == "string" then
            table.insert(parts, contentItem.text)
          end
        end

        if #parts > 0 then
          return table.concat(parts, "\n")
        end
      end
    end
  end

  return nil
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

function M.new(config)
  local headers = buildHeaders(config)

  local function jsonRequest(url, method, payload, timeoutMs, callback)
    local completed = false
    local timeout = hs.timer.doAfter(timeoutMs / 1000, function()
      if completed then
        return
      end

      completed = true
      callback(normalizeFailure("timeout", string.format("%s request timed out", method), url))
    end)

    local body = nil
    if payload ~= nil then
      local ok, encoded = pcall(hs.json.encode, payload)
      if not ok then
        timeout:stop()
        callback(normalizeFailure("json_encode_failed", "Failed to encode request payload", encoded))
        return
      end
      body = encoded
    end

    hs.http.doAsyncRequest(url, method, body, headers, function(statusCode, responseBody, responseHeaders)
      if completed then
        return
      end

      completed = true
      timeout:stop()

      if type(statusCode) ~= "number" then
        callback(normalizeFailure("request_failed", "HTTP request failed", statusCode))
        return
      end

      local ok, decoded = decodeJson(responseBody)
      if statusCode < 200 or statusCode >= 300 then
        local message = ok and extractErrorMessage(decoded, "Backend request failed") or "Backend request failed"
        callback(normalizeFailure(string.format("http_%d", statusCode), message, responseBody))
        return
      end

      if not ok then
        callback(normalizeFailure("json_decode_failed", "Failed to decode response payload", decoded))
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

  function self.loadModel(modelId, callback)
    local payloads = {
      { model = modelId },
      { id = modelId },
      { identifier = modelId },
    }

    local function tryPayload(index)
      local payload = payloads[index]
      if not payload then
        callback(normalizeFailure(
          "model_load_failed",
          "Failed to load model with available payload formats",
          modelId
        ))
        return
      end

      self.requestJson({
        url = config.backend.native_base .. "/models/load",
        method = "POST",
        payload = payload,
        timeout_ms = config.backend.request_timeout_ms,
      }, function(result)
        if result.ok then
          callback(result)
          return
        end

        local detail = tostring(result.error and result.error.detail or "")
        local message = tostring(result.error and result.error.message or "")
        local combined = (message .. " " .. detail):lower()
        local schemaMismatch = combined:find("unknown key") or combined:find("unknown field") or combined:find("invalid type")

        if schemaMismatch then
          tryPayload(index + 1)
          return
        end

        callback(result)
      end)
    end

    tryPayload(1)
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

      local text = extractTextFromResponse(result.data)
      if not text or text == "" then
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

      local choices = result.data and result.data.choices
      local firstChoice = type(choices) == "table" and choices[1] or nil
      local message = firstChoice and firstChoice.message or nil
      local content = message and message.content or nil
      local finishReason = firstChoice and firstChoice.finish_reason or nil

      if type(content) ~= "string" or trim(content) == "" then
        callback(normalizeFailure("empty_output", "The model response did not include structured content", result.data))
        return
      end

      local ok, parsed = pcall(hs.json.decode, content)
      if not ok or type(parsed) ~= "table" then
        callback(normalizeFailure("json_decode_failed", "The model returned invalid JSON for structured output", content))
        return
      end

      callback({
        ok = true,
        data = {
          parsed = parsed,
          raw_text = content,
          finish_reason = finishReason,
          raw = result.data,
        },
      })
    end)
  end

  return self
end

return M
