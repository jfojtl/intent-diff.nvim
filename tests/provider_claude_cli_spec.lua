local claude_cli = require("intentdiff.providers.claude_cli")
local helpers = require("tests.helpers")

local REQUEST = {
  diff_text = "diff --git a/a.lua b/a.lua\n@@ -1,1 +1,1 @@\n-x\n+y\n",
  hunks = { { id = "a.lua:1", file = "a.lua", summary_lines = { "@@ -1,1 +1,1 @@", "-x", "+y" } } },
}

describe("claude_cli.build_prompt", function()
  it("includes ids, the JSON contract, and the diff", function()
    local prompt = claude_cli.build_prompt(REQUEST)
    assert.truthy(prompt:find("a.lua:1", 1, true))
    assert.truthy(prompt:find('"groups"', 1, true))
    assert.truthy(prompt:find("Full diff:", 1, true))
  end)

  it("omits diff body when diff_text is nil (summary mode)", function()
    local prompt = claude_cli.build_prompt({ diff_text = nil, hunks = REQUEST.hunks })
    assert.is_nil(prompt:find("Full diff:", 1, true))
  end)
end)

describe("claude_cli.parse_response", function()
  it("parses clean JSON", function()
    local r = claude_cli.parse_response('{"groups":[{"title":"T","hunk_ids":["a.lua:1"]}]}')
    assert.equals("T", r.groups[1].title)
  end)

  it("repairs fenced/prosed output", function()
    local r = claude_cli.parse_response('Sure!\n```json\n{"groups":[{"title":"T","hunk_ids":[]}]}\n```\n')
    assert.equals("T", r.groups[1].title)
  end)

  it("rejects garbage with an error", function()
    local r, err = claude_cli.parse_response("no json here")
    assert.is_nil(r)
    assert.truthy(err)
  end)

  it("handles trailing prose containing braces", function()
    local r = claude_cli.parse_response('{"groups":[{"title":"T","hunk_ids":[]}]}\nNote: format is {id: string}')
    assert.equals("T", r.groups[1].title)
  end)

  it("handles leading and trailing prose with braces around valid object", function()
    local r = claude_cli.parse_response('Example config {x: 1}\n{"groups":[{"title":"Fix","hunk_ids":["h1"]}]}\nNote: {done}')
    assert.equals("Fix", r.groups[1].title)
    assert.equals("h1", r.groups[1].hunk_ids[1])
  end)

  it("completes in <500ms with ~600 syntactically invalid braces", function()
    -- Pathological case: many invalid brace structures with valid JSON embedded
    -- Build a string with ~600 braces but JSON reachable within candidate limit
    local prose = ""
    -- Create 15 invalid structures before JSON, accumulating ~300 braces
    for i = 1, 15 do
      prose = prose .. "{invalid_" .. i .. ":" .. string.rep("{nested", 10) .. "value" .. string.rep("}", 10) .. "} "
    end
    prose = prose .. '{"groups":[{"title":"Perf","hunk_ids":["h1","h2","h3"]}]}'
    -- Create 15 more invalid structures after JSON, adding ~300 more braces
    for i = 1, 15 do
      prose = prose .. " {extra_" .. i .. ":" .. string.rep("{inner", 10) .. "data" .. string.rep("}", 10) .. "}"
    end

    local start = vim.uv.hrtime()
    local r = claude_cli.parse_response(prose)
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6

    assert.is_not_nil(r)
    assert.equals("Perf", r.groups[1].title)
    assert.is_true(elapsed_ms < 500, ("Expected <500ms, got %.1fms"):format(elapsed_ms))
  end)
end)

describe("claude_cli provider", function()
  it("runs the CLI and returns parsed groups", function()
    local restore = helpers.fake_bin("claude", [[
cat > /dev/null
echo '{"groups":[{"title":"Fake","hunk_ids":["a.lua:1"]}]}']])
    local result, err
    claude_cli.new({ timeout_ms = 5000 })(REQUEST, function(r, e) result, err = r, e end)
    helpers.wait_for(function() return result or err end)
    restore()
    assert.is_nil(err)
    assert.equals("Fake", result.groups[1].title)
  end)

  it("reports non-zero exit as an error", function()
    local restore = helpers.fake_bin("claude", "cat > /dev/null\nexit 3")
    local err
    claude_cli.new({ timeout_ms = 5000 })(REQUEST, function(_, e) err = e end)
    helpers.wait_for(function() return err end)
    restore()
    assert.truthy(err:find("exited"))
  end)

  it("times out slow providers", function()
    local restore = helpers.fake_bin("claude", "sleep 30")
    local err
    claude_cli.new({ timeout_ms = 300 })(REQUEST, function(_, e) err = e end)
    helpers.wait_for(function() return err end, 5000)
    restore()
    assert.truthy(err:find("timed out"))
  end)

  it("cancel suppresses the callback", function()
    local restore = helpers.fake_bin("claude", "sleep 5\necho '{}'")
    local called = false
    local handle = claude_cli.new({ timeout_ms = 10000 })(REQUEST, function() called = true end)
    handle.cancel()
    vim.wait(500, function() return false end, 50)
    restore()
    assert.is_false(called)
  end)
end)
