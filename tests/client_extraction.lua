package.path = table.concat({
  "./?.lua",
  "./?/init.lua",
  package.path,
}, ";")

local clientModule = require("llm.client")

local function assertEqual(actual, expected, message)
  if actual ~= expected then
    error(string.format("%s\nexpected: %s\nactual: %s", message, tostring(expected), tostring(actual)))
  end
end

local function assertTrue(value, message)
  if not value then
    error(message)
  end
end

local plainPayload = {
  choices = {
    {
      finish_reason = "stop",
      message = {
        role = "assistant",
        content = "Plain text output",
      },
    },
  },
}

local text, finishReason, meta = clientModule._test.extractTextFromChatCompletions(plainPayload)
assertEqual(text, "Plain text output", "chat completion extractor should read string content")
assertEqual(finishReason, "stop", "chat completion extractor should preserve finish_reason")
assertTrue(type(meta) == "table", "chat completion extractor should return metadata")

local contentArrayPayload = {
  choices = {
    {
      finish_reason = "stop",
      message = {
        role = "assistant",
        content = {
          { type = "output_text", text = "First line" },
          { type = "output_text", text = "Second line" },
        },
      },
    },
  },
}

local arrayText = clientModule._test.extractTextFromChatCompletions(contentArrayPayload)
assertEqual(arrayText, "First line\nSecond line", "chat completion extractor should flatten content arrays")

local reasoningOnlyPayload = {
  choices = {
    {
      finish_reason = "length",
      message = {
        role = "assistant",
        content = "",
        reasoning_content = "1. Analyze the request",
      },
    },
  },
}

local emptyText, reasoningFinishReason, reasoningMeta = clientModule._test.extractTextFromChatCompletions(reasoningOnlyPayload)
assertEqual(emptyText, nil, "reasoning-only payload should not be treated as final text")
assertEqual(reasoningFinishReason, "length", "reasoning-only payload should preserve finish_reason")
assertEqual(reasoningMeta.reasoning_content, "1. Analyze the request", "reasoning-only payload should expose reasoning_content metadata")

local nativeChatPayload = {
  output = {
    { type = "reasoning", content = "internal reasoning" },
    { type = "message", content = "Final plain text" },
  },
}

local nativeText, nativeMeta = clientModule._test.extractTextFromNativeChat(nativeChatPayload)
assertEqual(nativeText, "Final plain text", "native chat extractor should pull message output")
assertEqual(nativeMeta.reasoning_content, "internal reasoning", "native chat extractor should preserve reasoning metadata")

local nativeReasoningOnlyPayload = {
  output = {
    { type = "reasoning", content = "still thinking" },
  },
}

local nativeEmptyText, nativeReasoningOnlyMeta = clientModule._test.extractTextFromNativeChat(nativeReasoningOnlyPayload)
assertEqual(nativeEmptyText, nil, "native reasoning-only payload should not be treated as final text")
assertEqual(nativeReasoningOnlyMeta.reasoning_content, "still thinking", "native reasoning-only payload should preserve reasoning metadata")

print("client extraction tests passed")
