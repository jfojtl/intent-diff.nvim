local forges = require("intentdiff.forges")

local function target(over)
  return vim.tbl_extend("force", {
    service = "github", id = "123", url = "https://github.com/o/r/pull/123",
    title = "T", head_sha = "aaaa", base_ref = "main",
  }, over or {})
end

local function state(over)
  return vim.tbl_extend("force", {
    branch = "feat/x", default_branch = "main", target = target(),
    head_sha = "aaaa", dirty_files = {}, commented_files = { "a.ts" },
    forge_name = "github", remote_url = "git@github.com:o/r.git",
  }, over or {})
end

describe("forges.preflight", function()
  it("submits inline when HEAD matches the PR head and nothing is dirty", function()
    local r = forges.preflight(state())
    assert.equals("inline", r.mode)
  end)

  it("refuses when no forge serves the remote", function()
    local r = forges.preflight(state({ forge_name = nil }))
    assert.equals("no_forge", r.mode)
    assert.is_truthy(r.reason:match("no supported forge"))
  end)

  it("names the default branch before asking about a PR", function()
    -- target is nil here too: the default-branch message must win, not "no_pr".
    local r = forges.preflight(state({ branch = "main", target = nil }))
    assert.equals("default_branch", r.mode)
    assert.is_truthy(r.reason:match("main"))
  end)

  it("skips the default-branch check when the default branch is unknown", function()
    local r = forges.preflight(state({ default_branch = nil }))
    assert.equals("inline", r.mode)
  end)

  it("asks for a PR to be created when the branch has none", function()
    local r = forges.preflight(state({ target = nil }))
    assert.equals("no_pr", r.mode)
    assert.is_truthy(r.reason:match("gh pr create"))
  end)

  it("degrades to general when local HEAD is not the PR head", function()
    local r = forges.preflight(state({ head_sha = "bbbb" }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("bbbb"))
    assert.is_truthy(r.reason:match("aaaa"))
  end)

  it("degrades to general when a commented file is dirty", function()
    local r = forges.preflight(state({
      dirty_files = { "a.ts" }, commented_files = { "a.ts", "b.ts" },
    }))
    assert.equals("general", r.mode)
    assert.same({ "a.ts" }, r.dirty)
    assert.is_truthy(r.reason:match("1 of 2"))
  end)

  it("ignores a dirty file that carries no comment", function()
    local r = forges.preflight(state({
      dirty_files = { "unrelated.ts" }, commented_files = { "a.ts" },
    }))
    assert.equals("inline", r.mode)
  end)

  it("states both reasons when HEAD is stale and a file is dirty", function()
    local r = forges.preflight(state({ head_sha = "bbbb", dirty_files = { "a.ts" } }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("ahead"))
    assert.is_truthy(r.reason:match("uncommitted"))
  end)
end)
