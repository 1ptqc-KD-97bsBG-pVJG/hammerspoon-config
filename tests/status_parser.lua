package.path = table.concat({
  "./?.lua",
  "./?/init.lua",
  package.path,
}, ";")

local statusModule = require("llm.status")

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

local function contains(list, target)
  for _, item in ipairs(list or {}) do
    if item == target then
      return true
    end
  end
  return false
end

local nativePayload = {
  models = {
    {
      type = "llm",
      publisher = "zai-org",
      key = "zai-org/glm-4.7-flash",
      display_name = "Glm 4.7 Flash",
      loaded_instances = {},
    },
    {
      type = "llm",
      publisher = "qwen",
      key = "qwen/qwen3-coder-next",
      display_name = "Qwen3 Coder Next",
      loaded_instances = {
        {
          id = "qwen/qwen3-coder-next",
          config = {
            context_length = 128000,
            parallel = 4,
          },
        },
      },
    },
  },
}

local parsedNative = statusModule._test.parseNativeModels(nativePayload)
assertTrue(contains(parsedNative.available_models, "zai-org/glm-4.7-flash"), "native parser should expose GLM as available")
assertTrue(contains(parsedNative.available_models, "qwen/qwen3-coder-next"), "native parser should expose Qwen as available")
assertEqual(#parsedNative.loaded_models, 1, "native parser should find one loaded model")
assertEqual(parsedNative.loaded_models[1], "qwen/qwen3-coder-next", "native parser should capture the loaded Qwen model")
assertEqual(#parsedNative.loaded_instances, 1, "native parser should capture one loaded instance")
assertEqual(parsedNative.loaded_instances[1].instance_id, "qwen/qwen3-coder-next", "native parser should capture the nested loaded instance id")
assertEqual(parsedNative.loaded_instances[1].model, "qwen/qwen3-coder-next", "native parser should associate nested loaded instance with parent key")

local duplicateInstancePayload = {
  models = {
    {
      key = "zai-org/glm-4.7-flash",
      display_name = "Glm 4.7 Flash",
      loaded_instances = {
        { id = "zai-org/glm-4.7-flash" },
        { id = "zai-org/glm-4.7-flash:2" },
      },
    },
  },
}

local parsedDuplicate = statusModule._test.parseNativeModels(duplicateInstancePayload)
assertEqual(#parsedDuplicate.loaded_models, 1, "duplicate instance payload should still produce one logical loaded model")
assertEqual(parsedDuplicate.loaded_models[1], "zai-org/glm-4.7-flash", "duplicate instance payload should normalize logical model id")
assertEqual(#parsedDuplicate.loaded_instances, 2, "duplicate instance payload should preserve two loaded instances")
assertEqual(parsedDuplicate.loaded_instances[1].model, "zai-org/glm-4.7-flash", "first duplicate instance should map to normalized model id")
assertEqual(parsedDuplicate.loaded_instances[2].model, "zai-org/glm-4.7-flash", "second duplicate instance should map to normalized model id")
assertEqual(parsedDuplicate.loaded_instances[2].instance_id, "zai-org/glm-4.7-flash:2", "second duplicate instance should keep its unique instance id")

print("status parser tests passed")
