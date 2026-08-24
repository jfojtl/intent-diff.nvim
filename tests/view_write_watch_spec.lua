-- Writing a file that is part of a live review must invalidate its cached
-- worktree content and repaint every review tab showing it — the gap task 11
-- (`gf` / M.open_real_file) made reachable: review -> gf -> fix -> back to the
-- review used to show whatever the worktree held when the review's content
-- cache first read the file, forever.
--
-- The other half under test is the honest degradation: the file's HUNKS were
-- parsed from `git diff` before the edit, so a repaint must never pair fresh
-- worktree content against those now-possibly-wrong ranges. It must fall back
-- to the hunks' own frozen text instead, and say why on the separator — see
-- view.lua's "stale-on-write" section and render/plan.lua's `file.stale`
-- branch.
local helpers = require("tests.intentdiff_helpers")
local view = require("intentdiff.view")
local content = require("intentdiff.render.content")

--- A repo, its base revision, and the parsed file entries/hunks of its diff —
--- the shape `view.show` takes. Mirrors view_spec.lua's fixture.
local function fixture(initial, edited)
  local repo = helpers.make_repo(initial)
  local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
  for path, body in pairs(edited or {}) do
    helpers.write_file(repo, path, body)
  end
  local hs, files = require("intentdiff.hunks").parse(helpers.git(repo, "diff"))
  for _, f in ipairs(files) do
    f.hunks = vim.tbl_filter(function(h) return h.file == f.path end, hs)
  end
  return repo, base, files, hs
end

local function all_visible(hs)
  local visible = {}
  for _, h in ipairs(hs) do
    visible[h.id] = true
  end
  return visible
end

--- Edit `path` (repo-relative) through a REAL Neovim buffer and `:write` it,
--- so BufWritePost actually fires. `helpers.write_file` writes straight to
--- disk with `vim.fn.writefile` and triggers no autocommand at all — it is
--- what every OTHER spec uses to stage a diff, which is exactly why none of
--- them can accidentally trip the watcher this file is testing.
---
--- Opens a NEW TAB rather than reusing the current window, matching what
--- M.open_real_file (`gf`) actually does — reusing a review pane's window
--- would clobber its scratch diff buffer instead of exercising the real
--- workflow.
local function edit_and_save(repo, path, lines)
  vim.cmd("tabedit " .. vim.fn.fnameescape(repo .. "/" .. path))
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.cmd("write")
  vim.cmd("tabclose")
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

--- Does any line of `pane` contain `needle`?
local function any_line_has(pane, needle)
  for _, l in ipairs(pane.lines) do
    if l:find(needle, 1, true) then
      return true
    end
  end
  return false
end

describe("view: stale-on-write", function()
  local real_notify, notices

  before_each(function()
    require("intentdiff.config").setup({})
    notices = {}
    real_notify = vim.notify
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    vim.notify = real_notify
  end)

  it("invalidates the cache and falls back to the hunks' own text once the file is written", function()
    local repo, base, files, hs = fixture(
      { ["a.lua"] = "one\ntwo\nthree\n" },
      { ["a.lua"] = "one\nTWO\nthree\n" })
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()

    local ready = false
    view.show(sess, files, all_visible(hs), { on_ready = function() ready = true end })
    assert.truthy(helpers.wait_for(function() return ready end, 5000))
    assert.is_false(view.current_plan(sess.tabpage).files[1].fallback,
      "the file must render whole-file before any write invalidates it")
    assert.is_false(content.is_stale(sess, "a.lua"))

    edit_and_save(repo, "a.lua", { "one", "TWO", "three", "FOUR" })

    assert.truthy(content.is_stale(sess, "a.lua"), "invalidate must mark the file stale")
    local plan = view.current_plan(sess.tabpage)
    assert.is_true(plan.files[1].fallback,
      "a stale file must render hunks-only, never paired against content newer than its hunks")
    assert.is_true(any_line_has(plan.modified, "changed on disk"),
      "the separator must say WHY it fell back, not just that it did")

    -- The hunk's own text is exactly what still renders — the diff shown is
    -- consistent with itself (describes the pre-edit change correctly), just
    -- not with the post-edit file. "TWO" (the pre-edit addition) is present;
    -- "FOUR" (the post-edit addition, never diffed) is not — proving this
    -- isn't a silent partial refresh that mixed old hunk pairing with new
    -- content.
    assert.is_true(any_line_has(plan.modified, "TWO"))
    assert.is_false(any_line_has(plan.modified, "FOUR"))

    assert.equals(1, #notices, "the write must surface a visible staleness notice")
    assert.truthy(notices[1].msg:find("a.lua", 1, true))
    assert.equals(vim.log.levels.WARN, notices[1].level)

    view.close_tab(sess)
  end)

  it("does nothing for a write to a file outside the review", function()
    local repo, base, files, hs = fixture(
      { ["a.lua"] = "one\n" },
      { ["a.lua"] = "ONE\n" })
    helpers.write_file(repo, "b.lua", "unrelated\n")

    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local ready = false
    view.show(sess, files, all_visible(hs), { on_ready = function() ready = true end })
    assert.truthy(helpers.wait_for(function() return ready end, 5000))
    local plan_before = view.current_plan(sess.tabpage)

    edit_and_save(repo, "b.lua", { "still unrelated" })

    assert.is_false(content.is_stale(sess, "b.lua"))
    assert.is_true(plan_before == view.current_plan(sess.tabpage),
      "a write to a file the review doesn't show must not repaint it")
    assert.equals(0, #notices, "an unrelated write must not notify either")

    view.close_tab(sess)
  end)

  it("refreshes every review tab showing the file, not just the current one", function()
    local repo, base, files, hs = fixture(
      { ["a.lua"] = "one\n" },
      { ["a.lua"] = "ONE\n" })

    local sess1 = { git_root = repo, base_revision = base, target_revision = nil }
    sess1.tabpage = view.open_tab()
    local ready1 = false
    view.show(sess1, files, all_visible(hs), { on_ready = function() ready1 = true end })
    assert.truthy(helpers.wait_for(function() return ready1 end, 5000))

    local sess2 = { git_root = repo, base_revision = base, target_revision = nil }
    sess2.tabpage = view.open_tab()
    local ready2 = false
    view.show(sess2, files, all_visible(hs), { on_ready = function() ready2 = true end })
    assert.truthy(helpers.wait_for(function() return ready2 end, 5000))

    edit_and_save(repo, "a.lua", { "ONE", "extra" })

    assert.is_true(view.current_plan(sess1.tabpage).files[1].fallback,
      "the first review tab must be refreshed too, even though it is not current")
    assert.is_true(view.current_plan(sess2.tabpage).files[1].fallback)

    view.close_tab(sess1)
    view.close_tab(sess2)
  end)

  it("does not accumulate BufWritePost autocommands across repeated review opens", function()
    local function count()
      return #vim.api.nvim_get_autocmds({ group = "IntentDiffWatch", event = "BufWritePost" })
    end
    local tabs = {}
    for _ = 1, 3 do
      tabs[#tabs + 1] = view.open_tab()
    end
    assert.equals(1, count(), "opening several review tabs must not stack more than one autocommand")
    for _, tab in ipairs(tabs) do
      view.close_tab({ tabpage = tab })
    end
    assert.equals(1, count(), "closing review tabs must not touch the (never per-tab) watcher either")
  end)
end)
