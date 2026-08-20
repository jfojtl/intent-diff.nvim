local helpers = require("tests.helpers")
local forges = require("intentdiff.forges")
local config = require("intentdiff.config")

local restore

describe("forges.resolve", function()
  before_each(function() config.setup({}) end)
  after_each(function()
    if restore then
      restore()
      restore = nil
    end
    config.setup({})
  end)

  it("picks github for a github remote under auto", function()
    local mod, name = forges.resolve("git@github.com:o/r.git")
    assert.equals("github", name)
    -- Identity, not a probe for one function name: resolve's whole job is
    -- picking the right module, and whether that module implements `submit`
    -- is forge_github_submit_spec's business, not the registry's.
    assert.equals(require("intentdiff.forges.github"), mod)
  end)

  it("finds no forge for an unknown host", function()
    local mod, name = forges.resolve("git@bitbucket.org:o/r.git")
    assert.is_nil(mod)
    assert.is_nil(name)
  end)

  it("honours an explicit forge name regardless of the remote", function()
    config.setup({ forge = "github" })
    local _, name = forges.resolve("git@example.invalid:o/r.git")
    assert.equals("github", name)
  end)

  it("uses a table forge as given", function()
    local custom = { submit = function() end, detect = function() end,
      matches = function() return true end, capabilities = function() return {} end }
    config.setup({ forge = custom })
    local mod, name = forges.resolve("anything")
    assert.equals(custom, mod)
    assert.equals("custom", name)
  end)

  it("reports a disabled forge distinctly from an unmatched one", function()
    config.setup({ forge = false })
    local mod, name, err = forges.resolve("git@github.com:o/r.git")
    assert.is_nil(mod)
    assert.is_nil(name)
    assert.is_truthy(err:match("disabled"))
  end)

  it("errors on a forge name with no module", function()
    config.setup({ forge = "nosuchforge" })
    local mod, _, err = forges.resolve("x")
    assert.is_nil(mod)
    assert.is_truthy(err:match("nosuchforge"))
  end)
end)

describe("forges.collect", function()
  after_each(function()
    if restore then
      restore()
      restore = nil
    end
    config.setup({})
  end)

  it("reads branch, head and dirty files from a real repo", function()
    local repo = helpers.make_repo({ ["a.ts"] = "one\n", ["b.ts"] = "two\n" })
    helpers.git(repo, "checkout", "-q", "-b", "feat/x")
    -- The remote is what makes `assert.is_nil(state.target)` below mean
    -- something: without it resolve finds no forge, collect returns before
    -- detect is ever reached, and the assertion passes for the wrong reason.
    helpers.git(repo, "remote", "add", "origin", "git@github.com:o/r.git")
    helpers.write_file(repo, "a.ts", "changed\n")
    restore = helpers.fake_bin("gh", [[
echo "no pull requests found" >&2
exit 1
]])
    local state, done
    forges.collect(repo, { "a.ts" }, function(s)
      state, done = s, true
    end)
    helpers.wait_for(function() return done end)
    assert.equals("feat/x", state.branch)
    assert.is_truthy(state.head_sha:match("^%x+$"))
    assert.same({ "a.ts" }, state.dirty_files)
    assert.is_nil(state.target)
  end)

  it("feeds preflight a state that produces no_pr", function()
    local repo = helpers.make_repo({ ["a.ts"] = "one\n" })
    helpers.git(repo, "checkout", "-q", "-b", "feat/x")
    helpers.git(repo, "remote", "add", "origin", "git@github.com:o/r.git")
    restore = helpers.fake_bin("gh", [[
echo "no pull requests found" >&2
exit 1
]])
    local state, done
    forges.collect(repo, { "a.ts" }, function(s)
      state, done = s, true
    end)
    helpers.wait_for(function() return done end)
    assert.equals("github", state.forge_name)
    assert.equals("no_pr", forges.preflight(state).mode)
  end)

  -- `forge = false` is documented as stopping before any fact is gathered.
  -- The four git subprocesses (two rev-parses, origin/HEAD, status) sat above
  -- the disabled check, so turning the feature off still paid for all of them.
  it("gathers no repository facts when the forge is disabled", function()
    config.setup({ forge = false })
    local repo = helpers.make_repo({ ["a.ts"] = "one\n" })
    helpers.write_file(repo, "a.ts", "changed\n")
    local state, err, done
    forges.collect(repo, { "a.ts" }, function(s, e)
      state, err, done = s, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_truthy(err:match("disabled"))
    assert.is_nil(state.branch)
    assert.is_nil(state.head_sha)
    assert.is_nil(state.default_branch)
    assert.same({}, state.dirty_files)
  end)

  -- An unborn branch: `git init` with no commit, so `rev-parse --abbrev-ref
  -- HEAD` fails and `branch` is nil. github.detect would then build
  -- { cmd, "pr", "view", nil, "--json", … } — a hole at index 4 that leaves
  -- `#argv` undefined and the argv malformed.
  it("never asks the forge about a nil branch", function()
    local repo = vim.fn.tempname()
    vim.fn.mkdir(repo, "p")
    helpers.git(repo, "init", "-q")
    helpers.git(repo, "remote", "add", "origin", "git@github.com:o/r.git")
    local detected = false
    config.setup({ forge = {
      matches = function() return true end,
      capabilities = function() return {} end,
      submit = function() end,
      detect = function() detected = true end,
    } })
    local state, err, done
    forges.collect(repo, { "a.ts" }, function(s, e)
      state, err, done = s, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_false(detected, "detect must never be called without a branch")
    assert.is_nil(state.branch)
    assert.is_truthy(err:match("[Bb]ranch"))
  end)
end)

describe("forges.dirty_files", function()
  it("reports the new path of a rename, not the old", function()
    local repo = helpers.make_repo({ ["a.ts"] = "one\n", ["keep.ts"] = "k\n" })
    helpers.git(repo, "mv", "a.ts", "b.ts")
    assert.same({ "b.ts" }, forges.dirty_files(repo))
  end)

  it("handles a rename whose new path contains the rename arrow", function()
    local repo = helpers.make_repo({ ["a.ts"] = "one\n" })
    helpers.git(repo, "mv", "a.ts", "b -> c.ts")
    -- Default porcelain renders this `R  a.ts -> "b -> c.ts"`, which no pattern
    -- can split unambiguously; -z makes it two unquoted NUL records.
    assert.same({ "b -> c.ts" }, forges.dirty_files(repo))
  end)

  it("reports modified and untracked files", function()
    local repo = helpers.make_repo({ ["a.ts"] = "one\n" })
    helpers.write_file(repo, "a.ts", "changed\n")
    helpers.write_file(repo, "new.ts", "new\n")
    local dirty = forges.dirty_files(repo)
    table.sort(dirty)
    assert.same({ "a.ts", "new.ts" }, dirty)
  end)
end)

describe("forges.base_drift", function()
  --- A repo on `main` with a remote-tracking ref pinned at the initial commit.
  --- `update-ref` fabricates origin/main directly: no bare repo, no fetch, no
  --- network.
  local function repo_with_origin_main()
    local repo = helpers.make_repo({ ["a.ts"] = "one\n" })
    helpers.git(repo, "branch", "-M", "main")
    helpers.git(repo, "update-ref", "refs/remotes/origin/main",
      vim.trim(helpers.git(repo, "rev-parse", "HEAD")))
    return repo
  end

  it("reports how far the local base branch is ahead of its remote", function()
    local repo = repo_with_origin_main()
    helpers.write_file(repo, "a.ts", "two\n")
    helpers.git(repo, "commit", "-qam", "unpushed work on main")
    assert.same({ ref = "main", ahead = 1 }, forges.base_drift(repo, "main"))
  end)

  it("answers nil when the base branch matches its remote", function()
    assert.is_nil(forges.base_drift(repo_with_origin_main(), "main"))
  end)

  it("answers nil when there is no remote-tracking ref to compare against", function()
    -- rev-list against a ref that does not exist fails; an unknowable drift is
    -- not a drift of zero, but it is equally not something to report.
    local repo = helpers.make_repo({ ["a.ts"] = "one\n" })
    helpers.git(repo, "branch", "-M", "main")
    assert.is_nil(forges.base_drift(repo, "main"))
  end)

  it("answers nil when the PR names no base branch", function()
    assert.is_nil(forges.base_drift(repo_with_origin_main(), nil))
  end)
end)
