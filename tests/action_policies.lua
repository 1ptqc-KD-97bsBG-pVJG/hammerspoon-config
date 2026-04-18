package.path = table.concat({
  "./?.lua",
  "./?/init.lua",
  package.path,
}, ";")

local policyModule = require("llm.action_policies").new()

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

local rewritePolicy = policyModule.getActionPolicy("rewriteClipboardTersely")
assertEqual(rewritePolicy.label, "Rewrite Clipboard Tersely", "rewrite policy should be discoverable")
assertEqual(rewritePolicy.prompt_builder, "buildRewritePrompt", "rewrite policy should declare its prompt builder")
assertTrue(rewritePolicy.default_context.clipboard == true, "rewrite policy should include clipboard by default")
assertTrue(rewritePolicy.default_context.app == true, "rewrite policy should include app by default")
assertTrue(rewritePolicy.default_context.window == true, "rewrite policy should include window by default")
assertTrue(rewritePolicy.optional_context.browser == true, "rewrite policy should allow optional browser context")

local noOverrides = policyModule.resolveContextOptions("rewriteClipboardTersely", {})
assertTrue(noOverrides.include_clipboard == true, "rewrite should include clipboard without overrides")
assertTrue(noOverrides.include_browser == false, "rewrite should not include browser by default")
assertTrue(noOverrides.include_finder == false, "rewrite should not include finder by default")
assertTrue(noOverrides.include_profile_metadata == false, "rewrite should not include profile metadata by default")
assertTrue(noOverrides.allow_full_clipboard == false, "rewrite should not allow full clipboard in this slice")

local withOverrides = policyModule.resolveContextOptions("rewriteClipboardTersely", {
  include_browser = true,
  include_finder = true,
  include_profile_metadata = true,
  use_full_clipboard = true,
})
assertTrue(withOverrides.include_browser == true, "browser override should enable browser context")
assertTrue(withOverrides.include_finder == true, "finder override should enable finder context")
assertTrue(withOverrides.force_finder == true, "finder override should force finder querying")
assertTrue(withOverrides.include_profile_metadata == true, "profile metadata override should enable profile metadata")
assertTrue(withOverrides.allow_full_clipboard == false, "full clipboard override should still obey action policy")

local enabled = policyModule.describeEnabledContext(withOverrides)
assertTrue(#enabled >= 5, "enabled context description should include the active flags")
assertTrue(policyModule.isKnownContextOverride("include_browser"), "browser override should be a known toggle")
assertTrue(not policyModule.resolveContextOptions("unknownAction", {}), "unknown actions should not resolve context options")

local scriptDraftOptions = policyModule.resolveContextOptions("draftUtilityScript", {
  include_browser = true,
  include_profile_metadata = true,
  use_full_clipboard = true,
})
assertTrue(scriptDraftOptions.include_finder == true, "script drafting should include Finder context by default")
assertTrue(scriptDraftOptions.force_finder == true, "script drafting should force Finder selection lookup")
assertTrue(scriptDraftOptions.allow_full_clipboard == true, "script drafting should allow full clipboard capture")
assertTrue(scriptDraftOptions.include_browser == true, "script drafting should allow browser context in developer mode")

local webuiOptions = policyModule.resolveContextOptions("sendToOpenWebUI", {})
assertTrue(webuiOptions.include_browser == true, "WebUI handoff should include browser context by default")
assertTrue(webuiOptions.include_finder == true, "WebUI handoff should include Finder context by default")
assertTrue(webuiOptions.include_profile_metadata == true, "WebUI handoff should include profile metadata by default")
assertTrue(webuiOptions.allow_full_clipboard == true, "WebUI handoff should allow full clipboard by default")

print("action policy tests passed")
