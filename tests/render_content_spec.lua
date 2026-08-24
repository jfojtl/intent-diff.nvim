local helpers = require("tests.intentdiff_helpers")
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

  it('treats the "WORKING" sentinel as the working tree, not a revision', function()
    -- init.lua sets target_revision = "WORKING" for a plain `:IntentDiff`, so
    -- this is the MAINSTREAM path, not an edge case. `git show WORKING:path`
    -- always fails; taking that branch left every file rendering hunks-only.
    local repo = helpers.make_repo({ ["a.lua"] = "one\ntwo" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "one\nTWO\nthree")

    local sess = { git_root = repo, base_revision = base, target_revision = "WORKING" }
    local done = false
    content.ensure(sess, { { path = "a.lua", status = "M", binary = false } },
      function() done = true end)
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

describe("render.content negative cache", function()
  --- A status-M file that git AND the worktree both refuse: it is in neither
  --- the base revision nor the working tree. Every realistic trigger — a
  --- status-M file since deleted from the worktree, an unresolvable path, a
  --- permissions failure — lands in the same place: `fetch` leaves the side
  --- nil, which is byte-for-byte what "never fetched" looks like.
  local function unfetchable()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    return sess_for(repo, base), { { path = "ghost.lua", status = "M", binary = false } }
  end

  it("stops reporting a permanently-unfetchable file as missing", function()
    local sess, files = unfetchable()
    local done = false
    local ready, missing = content.ensure(sess, files, function() done = true end)
    assert.is_false(ready)
    assert.same({ "ghost.lua" }, missing)
    assert.truthy(helpers.wait_for(function() return done end, 5000))
    assert.is_nil(content.get(sess, "ghost.lua", "old"),
      "the fetch must really have failed, or this test proves nothing")

    -- The whole point: the second call resolves synchronously and reports
    -- NOTHING missing, so no worker is scheduled and the caller comes to rest
    -- on the hunk-body fallback instead of asking again forever.
    local ready2, missing2 = content.ensure(sess, files, function()
      error("on_ready must not fire for a file already known to have failed")
    end)
    assert.is_true(ready2)
    assert.same({}, missing2)
  end)

  it("never re-runs git show for a file whose fetch already failed", function()
    local sess, files = unfetchable()
    local real = vim.fn.systemlist
    local shows = 0
    vim.fn.systemlist = function(cmd, ...)
      if type(cmd) == "table" and vim.tbl_contains(cmd, "show") then
        shows = shows + 1
      end
      return real(cmd, ...)
    end
    local ok, err = pcall(function()
      local done = false
      content.ensure(sess, files, function() done = true end)
      assert.truthy(helpers.wait_for(function() return done end, 5000))
      assert.equals(1, shows, "the first ensure must fetch exactly once")

      -- Every debounced sidebar hover and every layout toggle calls ensure
      -- again for the same file list. Before the negative cache each of these
      -- scheduled another synchronous `git show`.
      for _ = 1, 5 do
        content.ensure(sess, files)
      end
      vim.wait(300, function() return false end, 20)
      assert.equals(1, shows, "a failed fetch must never be retried")
    end)
    vim.fn.systemlist = real
    assert.is_true(ok, tostring(err))
  end)

  it("notifies once per file, not once per repaint", function()
    local sess, files = unfetchable()
    local real = vim.notify
    local notices = {}
    vim.notify = function(msg, level, opts)
      if type(msg) == "string" and msg:find("ghost.lua", 1, true) then
        notices[#notices + 1] = msg
      end
      return real(msg, level, opts)
    end
    local ok, err = pcall(function()
      local done = false
      content.ensure(sess, files, function() done = true end)
      assert.truthy(helpers.wait_for(function() return done end, 5000))
      assert.equals(1, #notices, "a failed fetch must be reported to the user")
      assert.truthy(notices[1]:find("ghost.lua", 1, true))

      for _ = 1, 5 do
        content.ensure(sess, files)
      end
      vim.wait(300, function() return false end, 20)
      assert.equals(1, #notices, "the notice must not repeat on every repaint")
    end)
    vim.notify = real
    assert.is_true(ok, tostring(err))
  end)

  it("retries after invalidate, because the file changed on disk", function()
    -- invalidate() is the write-watcher's signal that this path's content
    -- moved underneath us — the one event that can turn an unreadable path
    -- into a readable one, so it clears the negative cache. The permanent
    -- failures the cache exists for raise no write event.
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    local sess = sess_for(repo, base)
    local files = { { path = "later.lua", status = "A", binary = false } }

    local done = false
    content.ensure(sess, files, function() done = true end)
    assert.truthy(helpers.wait_for(function() return done end, 5000))
    assert.is_nil(content.get(sess, "later.lua", "new"))
    assert.is_true(content.ensure(sess, files), "the failure must be remembered")

    helpers.write_file(repo, "later.lua", "now it exists")
    content.invalidate(sess, "later.lua")

    done = false
    local ready, missing = content.ensure(sess, files, function() done = true end)
    assert.is_false(ready)
    assert.same({ "later.lua" }, missing)
    assert.truthy(helpers.wait_for(function() return done end, 5000))
    assert.same({ "now it exists" }, content.get(sess, "later.lua", "new"))
  end)
end)
