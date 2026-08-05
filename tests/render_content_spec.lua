local helpers = require("tests.helpers")
local content = require("intentdiff.render.content")

local function sess_for(repo, base)
  return { git_root = repo, base_revision = base, target_revision = nil }
end

describe("render.content", function()
  it("reads the base revision for the old side and the worktree for the new", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\ntwo" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "one\nTWO\nthree")

    local sess = sess_for(repo, base)
    local files = { { path = "a.lua", status = "M", binary = false } }
    local done = false
    content.ensure(sess, files, function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))

    assert.same({ "one", "two" }, content.get(sess, "a.lua", "old"))
    assert.same({ "one", "TWO", "three" }, content.get(sess, "a.lua", "new"))
  end)

  it("gives an added file an empty old side", function()
    local repo = helpers.make_repo({ ["a.lua"] = "x" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "new.lua", "fresh")

    local sess = sess_for(repo, base)
    local done = false
    content.ensure(sess, { { path = "new.lua", status = "??", binary = false } },
      function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))

    assert.same({}, content.get(sess, "new.lua", "old"))
    assert.same({ "fresh" }, content.get(sess, "new.lua", "new"))
  end)

  it("gives a deleted file an empty new side", function()
    local repo = helpers.make_repo({ ["gone.lua"] = "bye" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    os.remove(repo .. "/gone.lua")

    local sess = sess_for(repo, base)
    local done = false
    content.ensure(sess, { { path = "gone.lua", status = "D", binary = false } },
      function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))

    assert.same({ "bye" }, content.get(sess, "gone.lua", "old"))
    assert.same({}, content.get(sess, "gone.lua", "new"))
  end)

  it("gives a binary file both sides empty and never shells out", function()
    local repo = helpers.make_repo({ ["a.lua"] = "x" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))

    local sess = sess_for(repo, base)
    local ready = content.ensure(sess, { { path = "b.png", status = "M", binary = true } })
    -- Resolved synchronously: nothing to fetch.
    assert.is_true(ready)
    assert.same({}, content.get(sess, "b.png", "old"))
    assert.same({}, content.get(sess, "b.png", "new"))
  end)

  it("reports not-ready and lists what is missing before content lands", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))

    local sess = sess_for(repo, base)
    local ready, missing = content.ensure(sess, { { path = "a.lua", status = "M", binary = false } })
    assert.is_false(ready)
    assert.same({ "a.lua" }, missing)
  end)

  it("serves a second request from cache without refetching", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))

    local sess = sess_for(repo, base)
    local files = { { path = "a.lua", status = "M", binary = false } }
    local done = false
    content.ensure(sess, files, function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))

    -- Now resolved synchronously.
    assert.is_true(content.ensure(sess, files))
  end)

  it("re-reads the worktree side after invalidate but keeps the base side", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "two")

    local sess = sess_for(repo, base)
    local files = { { path = "a.lua", status = "M", binary = false } }
    local done = false
    content.ensure(sess, files, function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))
    assert.same({ "two" }, content.get(sess, "a.lua", "new"))

    helpers.write_file(repo, "a.lua", "three")
    content.invalidate(sess, "a.lua")
    assert.is_nil(content.get(sess, "a.lua", "new"))
    assert.same({ "one" }, content.get(sess, "a.lua", "old"), "base side survives invalidate")

    done = false
    content.ensure(sess, files, function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))
    assert.same({ "three" }, content.get(sess, "a.lua", "new"))
  end)
end)
