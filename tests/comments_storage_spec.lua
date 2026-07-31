local storage = require("intentdiff.comments.storage")
local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")

describe("comments.storage", function()
  local cache
  --- One store per test: attaching is now a per-review act, so every attach
  --- test needs its own store rather than resetting a shared one.
  local s

  before_each(function()
    cache = vim.fn.tempname()
    config.setup({ cache_dir = cache })
    s = store.new()
  end)

  it("keys a working-tree review by repo and branch", function()
    local k = storage.key("/repo/a", nil, nil, "feature/x")
    assert.is_truthy(k:match("feature_x$"))
  end)

  it("keys a revision-range review by both revisions", function()
    local k = storage.key("/repo/a", "abc1234567", "def7654321", "main")
    assert.is_truthy(k:match("abc12345_def76543$"))
  end)

  it("gives different repos different keys for the same branch", function()
    assert.are_not.equals(storage.key("/repo/a", nil, nil, "main"),
      storage.key("/repo/b", nil, nil, "main"))
  end)

  it("strips a trailing caret from a revision", function()
    local k = storage.key("/repo/a", "abc1234^", "abc1234", "main")
    assert.is_truthy(k:match("abc1234_abc1234$"))
  end)

  it("round-trips comments through disk", function()
    local given = { { file = "a.lua", line = 3, side = "new", type = "issue", text = "x", created_at = 1 } }
    assert.is_true(storage.save("k1", given))
    assert.same(given, storage.load("k1"))
  end)

  it("returns an empty list for an unknown key", function()
    assert.same({}, storage.load("nope"))
  end)

  it("treats a corrupt file as empty", function()
    storage.save("k2", { { file = "a.lua", line = 1, type = "note", text = "x", created_at = 1 } })
    local f = io.open(storage.path("k2"), "w")
    f:write("{ not json")
    f:close()
    assert.same({}, storage.load("k2"))
  end)

  it("clears a stored review", function()
    storage.save("k3", { { file = "a.lua", line = 1, type = "note", text = "x", created_at = 1 } })
    storage.clear("k3")
    assert.same({}, storage.load("k3"))
  end)

  it("sweeps files older than expire_days and keeps fresh ones", function()
    storage.save("old", { { file = "a.lua", line = 1, type = "note", text = "x", created_at = 1 } })
    storage.save("new", { { file = "b.lua", line = 1, type = "note", text = "y", created_at = 1 } })
    local stale = os.time() - (8 * 24 * 60 * 60)
    vim.loop.fs_utime(storage.path("old"), stale, stale)
    storage.sweep({ force = true })
    assert.same({}, storage.load("old"))
    assert.equals(1, #storage.load("new"))
  end)

  it("does not sweep when expire_days is false", function()
    storage.save("old", { { file = "a.lua", line = 1, type = "note", text = "x", created_at = 1 } })
    local stale = os.time() - (400 * 24 * 60 * 60)
    vim.loop.fs_utime(storage.path("old"), stale, stale)
    config.setup({ cache_dir = cache, comments = { expire_days = false } })
    storage.sweep({ force = true })
    assert.equals(1, #storage.load("old"))
  end)

  it("survives an unwritable cache directory", function()
    -- On macOS, /proc doesn't exist. Instead, create a temp file and use a path under it as the cache_dir.
    -- This way, mkdir will fail because it's trying to create a directory under a file.
    local temp_file = vim.fn.tempname()
    -- Create an actual file at that path
    local f = io.open(temp_file, "w")
    f:write("placeholder")
    f:close()
    config.setup({ cache_dir = temp_file .. "/intentdiff-comments" })
    assert.is_false(storage.save("k4", { { file = "a.lua", line = 1, type = "note", text = "x", created_at = 1 } }))
    assert.same({}, storage.load("k4"))
    os.remove(temp_file)
  end)

  it("attach loads existing comments into the store", function()
    storage.save("k5", { { file = "a.lua", line = 7, side = "new", type = "note", text = "hi", created_at = 1 } })
    s.attach("k5")
    assert.equals(1, s.count())
    assert.equals(7, s.get_all()[1].line)
  end)

  it("attach persists every later change", function()
    s.attach("k6")
    s.add({ file = "a.lua", line = 2, side = "new", type = "issue", text = "z" })
    assert.equals(1, #storage.load("k6"))
    s.clear()
    assert.equals(0, #storage.load("k6"))
  end)

  it("detach stops persisting", function()
    s.attach("k7")
    s.add({ file = "a.lua", line = 2, side = "new", type = "issue", text = "z" })
    s.detach()
    s.clear()
    assert.equals(1, #storage.load("k7"))
  end)

  it("re-attaching does not stack persistence listeners", function()
    -- The old module-level store guarded its single listener with a `hooked`
    -- flag; a per-instance listener registered in attach() instead would
    -- accumulate one per attach and write the same file N times. Re-attaching
    -- to key A after key B must leave exactly A's file holding the comment,
    -- and B's untouched.
    s.attach("k8a")
    s.attach("k8b")
    s.attach("k8a")
    s.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "only a" })
    assert.equals(1, #storage.load("k8a"))
    assert.equals(0, #storage.load("k8b"))
  end)
end)
