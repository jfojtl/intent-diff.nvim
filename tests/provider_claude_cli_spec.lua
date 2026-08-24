local claude_cli = require("intentdiff.providers.claude_cli")
local helpers = require("tests.intentdiff_helpers")
local log = require("intentdiff.log")
local config = require("intentdiff.config")

local REQUEST = {
  diff_text = "diff --git a/a.lua b/a.lua\n@@ -1,1 +1,1 @@\n-x\n+y\n",
  hunks = { { id = "a.lua:1", n = 1, file = "a.lua", summary_lines = { "@@ -1,1 +1,1 @@", "-x", "+y" } } },
}

local REQUEST_WITH_REPO = vim.tbl_extend("force", REQUEST, {
  repo = { git_root = "/tmp/some-repo", base_revision = "abc1234", target_revision = "WORKING" },
})

describe("claude_cli.build_prompt", function()
  it("includes a compact numbered entry (number, file, hunk header), the ids output contract, and the diff", function()
    local prompt = claude_cli.build_prompt(REQUEST)
    -- The compact numbered entry: "- <n>  <file>  <header>" per the contract.
    assert.truthy(prompt:find("- 1  a.lua  @@ -1,1 +1,1 @@", 1, true))
    assert.truthy(prompt:find('"ids"', 1, true))
    assert.truthy(prompt:find('"groups"', 1, true))
    assert.truthy(prompt:find("Full diff:", 1, true))
  end)

  it("omits diff body when diff_text is nil (summary mode)", function()
    local prompt = claude_cli.build_prompt({ diff_text = nil, hunks = REQUEST.hunks })
    assert.is_nil(prompt:find("Full diff:", 1, true))
  end)

  it("includes the agentic-lookup instruction, naming the revision range, when request.repo is set and agentic isn't disabled", function()
    local prompt = claude_cli.build_prompt(REQUEST_WITH_REPO)
    assert.truthy(prompt:find("read%-only"))
    assert.truthy(prompt:find("abc1234", 1, true))
    assert.truthy(prompt:find("WORKING", 1, true))
  end)

  it("omits the agentic-lookup instruction when opts.agentic is false", function()
    local prompt = claude_cli.build_prompt(REQUEST_WITH_REPO, { agentic = false })
    assert.is_nil(prompt:find("read%-only"))
  end)

  it("omits the agentic-lookup instruction when request carries no repo info, even with agentic enabled", function()
    local prompt = claude_cli.build_prompt(REQUEST, { agentic = true })
    assert.is_nil(prompt:find("read%-only"))
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

  it("captures stderr and logs it on a failing invocation", function()
    local log_file = vim.fn.tempname()
    config.setup({ log_file = log_file })
    local restore = helpers.fake_bin("claude", [[
cat > /dev/null
echo 'boom: something went wrong' 1>&2
exit 7]])
    local err
    claude_cli.new({ timeout_ms = 5000 })(REQUEST, function(_, e) err = e end)
    helpers.wait_for(function() return err end)
    restore()
    assert.truthy(err:find("exited"))

    local lines = log.read()
    assert.is_true(#lines > 0, "expected a provider_invocation entry")
    local entry = lines[#lines]
    assert.truthy(entry:find("provider_invocation", 1, true))
    assert.truthy(entry:find("exit_code=7", 1, true))
    assert.truthy(entry:find("boom: something went wrong", 1, true),
      "stderr not captured in log entry: " .. entry)
  end)

  it("logs elapsed time, prompt size, hunk count, and exit code on success", function()
    local log_file = vim.fn.tempname()
    config.setup({ log_file = log_file })
    local restore = helpers.fake_bin("claude", [[
cat > /dev/null
echo '{"groups":[{"title":"Fake","hunk_ids":["a.lua:1"]}]}']])
    local result, err
    claude_cli.new({ timeout_ms = 5000 })(REQUEST, function(r, e) result, err = r, e end)
    helpers.wait_for(function() return result or err end)
    restore()
    assert.is_nil(err)

    local lines = log.read()
    assert.is_true(#lines > 0, "expected a provider_invocation entry")
    local entry = lines[#lines]
    assert.truthy(entry:find("provider_invocation", 1, true))
    assert.truthy(entry:find("exit_code=0", 1, true))
    assert.truthy(entry:find("hunk_count=1", 1, true))
    assert.truthy(entry:find(("prompt_bytes=%d"):format(#claude_cli.build_prompt(REQUEST)), 1, true))
    assert.truthy(entry:find("elapsed_ms=", 1, true))
    assert.truthy(entry:find("parse_outcome=ok", 1, true))
  end)

  --- Count how many `provider_invocation` lines are in the log — the bug
  --- these two regression tests guard against is on_exit landing AFTER the
  --- timeout/cancel path already recorded (or, for cancel, decided not to
  --- record) an entry, logging a second, contradictory one.
  local function invocation_entry_count()
    local n = 0
    for _, line in ipairs(log.read()) do
      if line:find("provider_invocation", 1, true) then
        n = n + 1
      end
    end
    return n
  end

  it("logs exactly one entry when on_exit lands late, after the timeout already fired", function()
    local log_file = vim.fn.tempname()
    config.setup({ log_file = log_file })
    -- Ignores SIGTERM so jobstop() (sent when the timeout fires) can't kill
    -- it immediately: on_exit only lands once nvim escalates to SIGKILL,
    -- well after finish()/record() already ran for the timeout.
    local restore = helpers.fake_bin("claude", [[
cat > /dev/null
trap '' TERM
sleep 5]])
    local err
    claude_cli.new({ timeout_ms = 300 })(REQUEST, function(_, e) err = e end)
    helpers.wait_for(function() return err end, 5000)
    assert.truthy(err and err:find("timed out"))

    -- Give the late on_exit (post SIGKILL-escalation) a chance to fire and,
    -- if the bug regressed, log its own second entry.
    vim.wait(4000, function() return false end, 100)
    restore()

    local lines = log.read()
    assert.equals(1, invocation_entry_count(),
      "expected exactly one provider_invocation entry, got:\n" .. table.concat(lines, "\n"))
    assert.truthy(lines[#lines]:find("parse_outcome=timeout", 1, true),
      "the surviving entry must be the diagnostically useful timeout one: " .. lines[#lines])
  end)

  it("cancel() logs no provider_invocation entry, even once the process dies", function()
    -- Design decision: a cancelled invocation (session closed / superseded
    -- mid-classification) never produced a provider outcome worth
    -- diagnosing, so cancel() logs nothing — zero entries, not a
    -- "cancelled" one.
    local log_file = vim.fn.tempname()
    config.setup({ log_file = log_file })
    local restore = helpers.fake_bin("claude", [[
cat > /dev/null
trap '' TERM
sleep 5]])
    local called = false
    local handle = claude_cli.new({ timeout_ms = 10000 })(REQUEST, function() called = true end)
    vim.wait(200, function() return false end, 50) -- let the process actually start
    handle.cancel()

    -- Give the late on_exit (post SIGKILL-escalation) a chance to fire and,
    -- if the bug regressed, log a stray entry.
    vim.wait(4000, function() return false end, 100)
    restore()

    assert.is_false(called)
    local lines = log.read()
    assert.equals(0, invocation_entry_count(),
      "cancel() must not log a provider_invocation entry, got:\n" .. table.concat(lines, "\n"))
  end)
end)

describe("claude_cli provider: tool allowlist argv", function()
  --- Fake `claude` that captures its own argv (via "$@") to `argv_file` before
  --- replying with an empty grouping.
  local function fake_bin_capturing_argv(argv_file)
    return helpers.fake_bin("claude", ([[
cat > /dev/null
echo "$@" > %s
echo '{"groups":[]}']]):format(argv_file))
  end

  it("passes --allowedTools and --disallowedTools with the configured defaults", function()
    local argv_file = vim.fn.tempname()
    local restore = fake_bin_capturing_argv(argv_file)
    local result
    claude_cli.new({
      timeout_ms = 5000,
      allowed_tools = { "Bash(git diff:*)", "Bash(git log:*)", "Read", "Grep", "Glob" },
      disallowed_tools = { "Edit", "Write", "NotebookEdit" },
    })(REQUEST, function(r) result = r end)
    helpers.wait_for(function() return result end)
    restore()

    local argv = table.concat(vim.fn.readfile(argv_file), " ")
    assert.truthy(argv:find("--allowedTools Bash(git diff:*),Bash(git log:*),Read,Grep,Glob", 1, true),
      "argv missing --allowedTools: " .. argv)
    assert.truthy(argv:find("--disallowedTools Edit,Write,NotebookEdit", 1, true),
      "argv missing --disallowedTools: " .. argv)
  end)

  it("omits --allowedTools and --disallowedTools entirely when configured empty", function()
    local argv_file = vim.fn.tempname()
    local restore = fake_bin_capturing_argv(argv_file)
    local result
    claude_cli.new({ timeout_ms = 5000, allowed_tools = {}, disallowed_tools = {} })(REQUEST,
      function(r) result = r end)
    helpers.wait_for(function() return result end)
    restore()

    local argv = table.concat(vim.fn.readfile(argv_file), " ")
    assert.is_nil(argv:find("--allowedTools", 1, true), "expected no --allowedTools flag: " .. argv)
    assert.is_nil(argv:find("--disallowedTools", 1, true), "expected no --disallowedTools flag: " .. argv)
  end)

  it("omits --allowedTools and --disallowedTools when unset (nil, not just empty)", function()
    local argv_file = vim.fn.tempname()
    local restore = fake_bin_capturing_argv(argv_file)
    local result
    claude_cli.new({ timeout_ms = 5000 })(REQUEST, function(r) result = r end)
    helpers.wait_for(function() return result end)
    restore()

    local argv = table.concat(vim.fn.readfile(argv_file), " ")
    assert.is_nil(argv:find("--allowedTools", 1, true), "expected no --allowedTools flag: " .. argv)
    assert.is_nil(argv:find("--disallowedTools", 1, true), "expected no --disallowedTools flag: " .. argv)
  end)

  it("the config.lua defaults round-trip into argv via M.new(config.options.provider_opts)", function()
    -- Prove the wiring end to end: the actual defaults shipped in
    -- config.lua's provider_opts, unmodified, produce the expected flags.
    local defaults = require("intentdiff.config").defaults.provider_opts
    local argv_file = vim.fn.tempname()
    local restore = fake_bin_capturing_argv(argv_file)
    local result
    claude_cli.new(vim.tbl_extend("force", vim.deepcopy(defaults), { timeout_ms = 5000 }))(REQUEST,
      function(r) result = r end)
    helpers.wait_for(function() return result end)
    restore()

    local argv = table.concat(vim.fn.readfile(argv_file), " ")
    assert.truthy(argv:find("--allowedTools " .. table.concat(defaults.allowed_tools, ","), 1, true), argv)
    assert.truthy(argv:find("--disallowedTools " .. table.concat(defaults.disallowed_tools, ","), 1, true), argv)
  end)
end)

describe("claude_cli provider: agentic lookup channel cwd", function()
  it("sets the job's cwd to request.repo.git_root", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local pwd_file = vim.fn.tempname()
    local restore = helpers.fake_bin("claude", ([[
cat > /dev/null
pwd > %s
echo '{"groups":[]}']]):format(pwd_file))
    local result
    claude_cli.new({ timeout_ms = 5000 })(vim.tbl_extend("force", REQUEST, {
      repo = { git_root = dir },
    }), function(r) result = r end)
    helpers.wait_for(function() return result end)
    restore()

    local captured = vim.trim(table.concat(vim.fn.readfile(pwd_file), "\n"))
    -- Resolve both sides: /tmp is a symlink to /private/tmp on macOS, and
    -- `pwd` reports the physical (resolved) path.
    assert.equals(vim.uv.fs_realpath(dir), vim.uv.fs_realpath(captured))
  end)

  it("leaves cwd unset (today's behavior) when the request carries no repo", function()
    local pwd_file = vim.fn.tempname()
    local restore = helpers.fake_bin("claude", ([[
cat > /dev/null
pwd > %s
echo '{"groups":[]}']]):format(pwd_file))
    local result
    claude_cli.new({ timeout_ms = 5000 })(REQUEST, function(r) result = r end)
    helpers.wait_for(function() return result end)
    restore()

    local captured = vim.trim(table.concat(vim.fn.readfile(pwd_file), "\n"))
    -- Whatever nvim's own cwd was — just prove it's non-empty and did not
    -- error, i.e. jobstart happily ran with cwd omitted.
    assert.truthy(#captured > 0)
    assert.equals(vim.uv.fs_realpath(vim.fn.getcwd()), vim.uv.fs_realpath(captured))
  end)
end)
