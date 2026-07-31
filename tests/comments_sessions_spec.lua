-- Two review tabs at once. Every test here fails against the module-level
-- singleton the store used to be: attaching a second review re-keyed and
-- re-loaded the ONE shared list, so a comment added afterwards in the first tab
-- was written under the second review's key, and closing either tab blanked the
-- other's comments and cleared comment extmarks in every buffer in the editor.
local comments = require("intentdiff.comments")
local storage = require("intentdiff.comments.storage")
local marks = require("intentdiff.comments.marks")
local config = require("intentdiff.config")
local helpers = require("tests.helpers")

--- A session entry shaped like the plugin's own, attached to a review of
--- `repo` pinned to an explicit revision pair (so its key is deterministic and
--- needs no git plumbing beyond the repo root).
local function attach(repo, base, target)
  local entry = { sess = { git_root = repo, base_revision = base, target_revision = target } }
  comments.attach_session(entry)
  return entry
end

local function key_of(repo, base, target)
  return storage.key(repo, base, target, nil)
end

local function scratch(nlines)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, nlines do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("comments across concurrent review sessions", function()
  local repo

  before_each(function()
    config.setup({ cache_dir = vim.fn.tempname() })
    repo = helpers.make_repo({ ["a.lua"] = "x" })
  end)

  -- 1. Isolation.
  it("gives two attached sessions independent comments", function()
    local a = attach(repo, "aaa", "bbb")
    local b = attach(repo, "ccc", "ddd")

    -- Different lines, so both adds succeed even when the two stores are (as
    -- they must not be) the same one: this test has to fail on the CONTENT
    -- being shared, not on `collides` refusing the second add.
    a.comment_store.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "in A" })
    b.comment_store.add({ file = "a.lua", line = 7, side = "new", type = "issue", text = "in B" })

    assert.equals(1, a.comment_store.count())
    assert.equals(1, b.comment_store.count())
    assert.equals("in A", a.comment_store.get_all()[1].text)
    assert.equals("in B", b.comment_store.get_all()[1].text)
    for _, c in ipairs(a.comment_store.get_all()) do
      assert.are_not.equals("in B", c.text, "A's store must never hold B's comment")
    end
    for _, c in ipairs(b.comment_store.get_all()) do
      assert.are_not.equals("in A", c.text, "B's store must never hold A's comment")
    end
    -- And the per-file view each pane renders from is separated too.
    assert.equals("in A", a.comment_store.get_for_file("a.lua", "new")[1].text)
    assert.equals(1, #a.comment_store.get_for_file("a.lua", "new"))
    assert.are_not.equals(a.comment_store, b.comment_store)
  end)

  -- 2. No cross-key writes. The on-disk corruption case: with one shared
  -- store, attaching B re-pointed the ONE persistence key, so this comment —
  -- added through A, after B opened — landed in B's file.
  it("writes a comment added in the first session under the FIRST session's key", function()
    local a = attach(repo, "aaa", "bbb")
    local b = attach(repo, "ccc", "ddd")
    local key_a, key_b = key_of(repo, "aaa", "bbb"), key_of(repo, "ccc", "ddd")
    assert.are_not.equals(key_a, key_b, "the two keys must differ for this to mean anything")

    a.comment_store.add({ file = "a.lua", line = 4, side = "new", type = "issue", text = "belongs to A" })

    local on_disk_a = storage.load(key_a)
    assert.equals(1, #on_disk_a)
    assert.equals("belongs to A", on_disk_a[1].text)

    local on_disk_b = storage.load(key_b)
    assert.equals(0, #on_disk_b, "A's comment must not be written under B's key")
    -- B's own store is untouched in memory as well.
    assert.equals(0, b.comment_store.count())
  end)

  -- 3. Teardown isolation.
  it("leaves the other session's comments intact when one detaches", function()
    local a = attach(repo, "aaa", "bbb")
    local b = attach(repo, "ccc", "ddd")
    a.comment_store.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "in A" })
    local b_store = b.comment_store
    b_store.add({ file = "a.lua", line = 2, side = "new", type = "note", text = "in B" })

    comments.detach_session(a)

    assert.is_nil(a.comment_store, "the detached session must drop its store")
    assert.equals(b_store, b.comment_store, "the other session keeps its store")
    assert.equals(1, b.comment_store.count())
    assert.equals("in B", b.comment_store.get_all()[1].text)
    -- B is still persisting under its own key.
    b.comment_store.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "later" })
    assert.equals(2, #storage.load(key_of(repo, "ccc", "ddd")))
  end)

  -- 4. Extmark teardown isolation. `marks.clear_all()` walked every buffer in
  -- the editor, so closing either tab wiped both.
  it("clears only the torn-down review's extmarks, not the other review's", function()
    local a = attach(repo, "aaa", "bbb")
    local b = attach(repo, "ccc", "ddd")
    local buf_a, buf_b = scratch(10), scratch(10)

    a.comment_store.add({ file = "a.lua", line = 3, side = "new", type = "issue", text = "in A" })
    b.comment_store.add({ file = "a.lua", line = 3, side = "new", type = "issue", text = "in B" })
    marks.render_buffer(a.comment_store, buf_a, "a.lua", "new")
    marks.render_buffer(b.comment_store, buf_b, "a.lua", "new")
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(buf_a, marks.ns, 0, -1, {}))
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(buf_b, marks.ns, 0, -1, {}))

    comments.detach_session(a)

    assert.equals(0, #vim.api.nvim_buf_get_extmarks(buf_a, marks.ns, 0, -1, {}),
      "the torn-down review must clean up after itself")
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(buf_b, marks.ns, 0, -1, {}),
      "the surviving review's boxes must still be on screen")

    vim.api.nvim_buf_delete(buf_a, { force = true })
    vim.api.nvim_buf_delete(buf_b, { force = true })
  end)

  it("clears the padding extmarks the torn-down review drew, and only those", function()
    local a = attach(repo, "aaa", "bbb")
    local b = attach(repo, "ccc", "ddd")
    local old_a, new_a, old_b, new_b = scratch(10), scratch(10), scratch(10), scratch(10)

    for _, pair in ipairs({ { a, old_a, new_a }, { b, old_b, new_b } }) do
      local entry, old_buf, new_buf = pair[1], pair[2], pair[3]
      entry.comment_store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "one\ntwo" })
      marks.render_buffer(entry.comment_store, old_buf, "a.lua", "old")
      marks.render_buffer(entry.comment_store, new_buf, "a.lua", "new")
      marks.align(entry.comment_store, old_buf, new_buf, "a.lua")
    end
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(old_a, marks.ns_padding, 0, -1, {}))
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(old_b, marks.ns_padding, 0, -1, {}))

    comments.detach_session(a)

    assert.equals(0, #vim.api.nvim_buf_get_extmarks(old_a, marks.ns_padding, 0, -1, {}))
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(old_b, marks.ns_padding, 0, -1, {}),
      "the surviving review's alignment padding must survive")

    for _, buf in ipairs({ old_a, new_a, old_b, new_b }) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  it("keeps the surviving review renderable after the other tears down", function()
    -- Not just "the marks are still there": B must still be able to re-render,
    -- which is what a scroll or a pane rebuild does moments later.
    local a = attach(repo, "aaa", "bbb")
    local b = attach(repo, "ccc", "ddd")
    local buf_b = scratch(10)
    b.comment_store.add({ file = "a.lua", line = 5, side = "new", type = "praise", text = "in B" })

    comments.detach_session(a)
    marks.render_buffer(b.comment_store, buf_b, "a.lua", "new")

    assert.equals(1, #vim.api.nvim_buf_get_extmarks(buf_b, marks.ns, 0, -1, {}))
    vim.api.nvim_buf_delete(buf_b, { force = true })
  end)

  -- 5's single-review half, at the level this file is about: one review alone
  -- behaves exactly as before — attach loads, changes persist, teardown clears.
  it("behaves unchanged for a single review", function()
    local entry = attach(repo, "aaa", "bbb")
    local buf = scratch(10)
    entry.comment_store.add({ file = "a.lua", line = 2, side = "new", type = "note", text = "solo" })
    marks.render_buffer(entry.comment_store, buf, "a.lua", "new")
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(buf, marks.ns, 0, -1, {}))
    assert.equals(1, #storage.load(key_of(repo, "aaa", "bbb")))

    comments.detach_session(entry)
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(buf, marks.ns, 0, -1, {}))
    -- Detached, so nothing more is written; the file keeps what was saved.
    assert.equals(1, #storage.load(key_of(repo, "aaa", "bbb")))

    -- Re-opening the same review loads it back.
    local again = attach(repo, "aaa", "bbb")
    assert.equals(1, again.comment_store.count())
    assert.equals("solo", again.comment_store.get_all()[1].text)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- 6. Round-trip compatibility: a file written in the pre-change on-disk
  -- format (a bare JSON array of comment records) must still load.
  it("loads a comments file written before the store was scoped per session", function()
    local key = key_of(repo, "aaa", "bbb")
    vim.fn.mkdir(config.options.cache_dir .. "/comments", "p")
    local file = assert(io.open(storage.path(key), "w"))
    file:write('[{"file":"a.lua","line":3,"line_end":5,"side":"old","type":"suggestion",'
      .. '"text":"legacy comment","created_at":1700000000},'
      .. '{"intent_title":"An intent","type":"praise","text":"legacy intent comment",'
      .. '"created_at":1700000001}]')
    file:close()

    local entry = attach(repo, "aaa", "bbb")
    local got = entry.comment_store.get_all()
    assert.equals(2, #got)
    assert.equals("legacy comment", got[1].text)
    assert.equals(3, got[1].line)
    assert.equals(5, got[1].line_end)
    assert.equals("old", got[1].side)
    assert.equals("legacy intent comment", got[2].text)
    assert.equals("An intent", got[2].intent_title)
    -- And it round-trips: a later change rewrites the same key without losing
    -- what was already there.
    entry.comment_store.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "new one" })
    assert.equals(3, #storage.load(key))
  end)

  it("resolves the store for a tabpage through the session registry", function()
    local a = attach(repo, "aaa", "bbb")
    local b = attach(repo, "ccc", "ddd")
    a.sess.tabpage, b.sess.tabpage = 900101, 900102
    local restore_a = helpers.fake_session(900101, a)
    local restore_b = helpers.fake_session(900102, b)

    assert.equals(a.comment_store, comments.store_for(900101))
    assert.equals(b.comment_store, comments.store_for(900102))
    assert.are_not.equals(comments.store_for(900101), comments.store_for(900102),
      "two review tabs must resolve to two different stores")

    comments.detach_session(a)
    assert.is_nil(comments.store_for(900101))
    assert.equals(b.comment_store, comments.store_for(900102))

    restore_b()
    restore_a()
  end)
end)
