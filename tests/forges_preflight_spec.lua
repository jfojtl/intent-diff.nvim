local forges = require("intentdiff.forges")

local function target(over)
  return vim.tbl_extend("force", {
    service = "github", id = "123", url = "https://github.com/o/r/pull/123",
    title = "T", head_sha = "aaaa", base_ref = "main",
  }, over or {})
end

--- A key set to `NONE` is REMOVED from the returned state.
---
--- Necessary because `state({ target = nil })` cannot express "no target":
--- Lua drops `key = nil` from a table constructor, so vim.tbl_extend never sees
--- it and the default survives — the test then passes for the wrong reason.
local NONE = {}

local function state(over)
  over = over or {}
  local out = vim.tbl_extend("force", {
    branch = "feat/x", default_branch = "main", target = target(),
    head_sha = "aaaa", dirty_files = {}, commented_files = { "a.ts" },
    forge_name = "github", remote_url = "git@github.com:o/r.git",
    -- The review's OWN revisions, and the PR's merge base to compare the
    -- base against. The default pair is the only one that can post inline:
    -- the working tree, based exactly where the PR diverged.
    target_revision = "WORKING", base_revision = "mb00mb00", merge_base = "mb00mb00",
  }, over)
  for key, value in pairs(over) do
    if value == NONE then
      out[key] = nil
    end
  end
  return out
end

describe("forges.preflight", function()
  it("submits inline when HEAD matches the PR head and nothing is dirty", function()
    local r = forges.preflight(state())
    assert.equals("inline", r.mode)
  end)

  it("refuses when no forge serves the remote", function()
    local r = forges.preflight(state({ forge_name = NONE }))
    assert.equals("no_forge", r.mode)
    assert.is_truthy(r.reason:match("no supported forge"))
  end)

  it("names the default branch before asking about a PR", function()
    -- target is nil here too: the default-branch message must win, not "no_pr".
    local r = forges.preflight(state({ branch = "main", target = NONE }))
    assert.equals("default_branch", r.mode)
    assert.is_truthy(r.reason:match("main"))
  end)

  it("skips the default-branch check when the default branch is unknown", function()
    local r = forges.preflight(state({ default_branch = NONE }))
    assert.equals("inline", r.mode)
  end)

  it("asks for a PR to be created when the branch has none", function()
    local r = forges.preflight(state({ target = NONE }))
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

  -- The line numbers in a review pinned to `v1.1` describe the files AS OF
  -- v1.1. HEAD can still equal the PR head and no commented file need be dirty
  -- — the working tree is simply not what was read — so neither the head_sha
  -- check nor the dirty check catches this, and without its own check the
  -- comments post onto lines of the PR that nobody looked at.
  it("degrades to general when the review is pinned to a revision", function()
    local r = forges.preflight(state({ target_revision = "v1.1" }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("pinned to v1%.1"))
  end)

  it("degrades to general when target_revision is missing entirely", function()
    local r = forges.preflight(state({ target_revision = NONE }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("pinned"))
  end)

  -- `:IntentDiff main` bases the review on main's TIP; GitHub's LEFT side is
  -- the merge base. Every old-side line number is off by whatever main has
  -- gained since the branch diverged.
  it("degrades to general when the review's base is not the PR's merge base", function()
    local r = forges.preflight(state({ base_revision = "deadbeefdeadbeef" }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("merge base"))
    assert.is_truthy(r.reason:match("deadbeef"))
  end)

  it("degrades to general when the merge base could not be resolved", function()
    local r = forges.preflight(state({ merge_base = NONE }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("merge base"))
  end)

  -- Two hashes are a fact, not a diagnosis. The overwhelmingly likely cause of
  -- a base that is not the merge base is a local base branch the remote has
  -- never seen, and the user has no reason to suspect it: `git status` on the
  -- FEATURE branch says up to date, because the stale branch is the other one.
  it("names the stale local base branch and the remedy when one is known", function()
    local r = forges.preflight(state({
      base_revision = "deadbeefdeadbeef",
      base_drift = { ref = "main", ahead = 1 },
    }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("merge base"))
    assert.is_truthy(r.reason:match("local main"))
    assert.is_truthy(r.reason:match("1 commit"))
    assert.is_truthy(r.reason:match("origin/main%.%.%."))
  end)

  it("says nothing about drift when the base branch is in sync", function()
    local r = forges.preflight(state({ base_revision = "deadbeefdeadbeef" }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("merge base"))
    -- No drift fact: the bases differ for some other reason, and inventing a
    -- cause would send the user chasing a branch that is perfectly fine.
    assert.is_nil(r.reason:match("origin/main%.%.%."))
  end)

  it("states both reasons when HEAD is stale and a file is dirty", function()
    local r = forges.preflight(state({ head_sha = "bbbb", dirty_files = { "a.ts" } }))
    assert.equals("general", r.mode)
    assert.is_truthy(r.reason:match("ahead"))
    assert.is_truthy(r.reason:match("uncommitted"))
  end)
end)
