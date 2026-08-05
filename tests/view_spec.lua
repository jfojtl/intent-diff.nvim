local helpers = require("tests.helpers")

--- A repo, its base revision, and the parsed file entries of its diff — the
--- shape `view.show` takes.
--- @return string repo, string base, table[] files, table hunks
local function fixture(initial, edited)
  local repo = helpers.make_repo(initial)
  local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
  for path, content in pairs(edited) do
    helpers.write_file(repo, path, content)
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

describe("view adapter", function()
  local view

  before_each(function()
    package.loaded["intentdiff.view"] = nil
    view = require("intentdiff.view")
    require("intentdiff.config").setup({})
  end)

  it("loads the codediff internals it still needs", function()
    assert.is_true(view.load())
    assert.is_true(view.available)
  end)

  it("opens a tab with both pane windows of its own", function()
    local tab = view.open_tab()
    assert.equals(tab, vim.api.nvim_get_current_tabpage())
    local wins = view.pane_wins(tab)
    assert.truthy(wins.original)
    assert.truthy(wins.modified)
    assert.are_not.equal(wins.original, wins.modified)
    -- diff_wins stays an ARRAY: three call sites iterate it.
    assert.equals(2, #view.diff_wins(tab))
    view.close_tab({ tabpage = tab })
  end)
end)

describe("view.show renders both surfaces through one path", function()
  local view

  before_each(function()
    require("intentdiff.config").setup({})
    view = require("intentdiff.view")
  end)

  it("renders a single file as a plan over one file", function()
    local repo, base, files, hs = fixture({ ["a.lua"] = "one\ntwo\n" }, { ["a.lua"] = "one\nTWO\n" })
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()

    local shown = false
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local plan = view.current_plan(sess.tabpage)
    assert.truthy(plan)
    assert.equals(1, #plan.files)
    assert.equals("a.lua", plan.files[1].path)
    -- Whole file, not just the hunk body: the renderer has the real content.
    assert.is_false(plan.files[1].fallback)
    view.close_tab(sess)
  end)

  it("renders an intent as a plan over several files, same call", function()
    local repo, base, files, hs = fixture(
      { ["a.lua"] = "one\n", ["b.lua"] = "x\n" },
      { ["a.lua"] = "ONE\n", ["b.lua"] = "X\n" })
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()

    local shown = false
    view.show(sess, files, all_visible(hs), { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local plan = view.current_plan(sess.tabpage)
    assert.equals(2, #plan.files)
    -- One buffer holds both files: the map proves it.
    local paths = {}
    for row = 1, #plan.modified.lines do
      local t = plan.modified.map[row]
      if t then paths[t.file] = true end
    end
    assert.is_true(paths["a.lua"])
    assert.is_true(paths["b.lua"])
    view.close_tab(sess)
  end)

  it("puts the plan into the pane windows and answers pane_for_buf", function()
    local repo, base, files, hs = fixture({ ["a.lua"] = "one\ntwo\n" }, { ["a.lua"] = "one\nTWO\n" })
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local shown = false
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local plan = view.current_plan(sess.tabpage)
    local wins = view.pane_wins(sess.tabpage)
    local mod_buf = vim.api.nvim_win_get_buf(wins.modified)
    local orig_buf = vim.api.nvim_win_get_buf(wins.original)
    assert.equals(plan.modified, view.pane_for_buf(sess.tabpage, mod_buf))
    assert.equals(plan.original, view.pane_for_buf(sess.tabpage, orig_buf))
    assert.is_nil(view.pane_for_buf(sess.tabpage, vim.api.nvim_create_buf(false, true)))
    assert.same(plan.modified.lines, vim.api.nvim_buf_get_lines(mod_buf, 0, -1, false))
    view.close_tab(sess)
  end)

  it("folds away a hunk that is not in the visible set", function()
    local lines = {}
    for i = 1, 60 do lines[i] = "line " .. i end
    local before = table.concat(lines, "\n") .. "\n"
    lines[5] = "CHANGED 5"
    lines[55] = "CHANGED 55"
    local repo, base, files, hs = fixture({ ["big.lua"] = before },
      { ["big.lua"] = table.concat(lines, "\n") .. "\n" })
    assert.equals(2, #hs)

    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local shown = false
    -- ONLY the first hunk is in this intent.
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local plan = view.current_plan(sess.tabpage)
    local win = view.pane_wins(sess.tabpage).modified
    local function row_of(line)
      for row = 1, #plan.modified.lines do
        local t = plan.modified.map[row]
        if t and t.side == "new" and t.line == line then return row end
      end
    end
    local open_row, folded_row = row_of(5), row_of(55)
    assert.truthy(open_row)
    assert.truthy(folded_row)
    assert.equals(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(open_row) end))
    assert.is_true(vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(folded_row) end) > 0)
    view.close_tab(sess)
  end)

  it("toggles to inline layout, collapsing to one window", function()
    local repo, base, files, hs = fixture({ ["a.lua"] = "one\ntwo\n" }, { ["a.lua"] = "one\nTWO\n" })
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local shown = false
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))
    assert.equals("side-by-side", view.current_plan(sess.tabpage).layout)

    local toggled = false
    assert.is_true(view.toggle_layout(sess.tabpage, { on_done = function() toggled = true end }))
    assert.truthy(helpers.wait_for(function() return toggled end, 5000))

    local plan = view.current_plan(sess.tabpage)
    assert.equals("inline", plan.layout)
    assert.is_nil(plan.original)
    assert.is_nil(view.pane_wins(sess.tabpage).original)
    assert.equals(1, #view.diff_wins(sess.tabpage))
    view.close_tab(sess)
  end)

  it("renders hunks-only, and says so, when the content cannot be fetched", function()
    -- A base revision that does not exist: `git show <rev>:<path>` fails for
    -- every file, so both sides stay nil and the plan falls back to the hunk
    -- bodies. The point is that this SETTLES — content.ensure fires its
    -- callback even when nothing arrived, and repainting from there
    -- unconditionally would loop forever.
    local repo, _, files, hs = fixture({ ["a.lua"] = "one\ntwo\n" }, { ["a.lua"] = "one\nTWO\n" })
    local sess = { git_root = repo, base_revision = "0000000000000000000000000000000000000000",
      target_revision = "0000000000000000000000000000000000000000" }
    sess.tabpage = view.open_tab()

    local ready_count = 0
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function()
      ready_count = ready_count + 1
    end })
    assert.truthy(helpers.wait_for(function() return ready_count > 0 end, 5000))

    local plan = view.current_plan(sess.tabpage)
    assert.is_true(plan.files[1].fallback, "the file must render hunks-only")
    assert.is_truthy(plan.modified.lines[1]:match("content unavailable"),
      "the separator must say why: " .. tostring(plan.modified.lines[1]))

    -- Give the failing fetch's callback every chance to re-enter and loop.
    vim.wait(400)
    assert.equals(1, ready_count, "on_ready must fire exactly once")
    assert.equals(plan, view.current_plan(sess.tabpage), "a failed fetch must not repaint")
    view.close_tab(sess)
  end)

  it("has no preview-mode state left", function()
    local view_mod = require("intentdiff.view")
    assert.is_nil(view_mod._preview_active)
    assert.is_nil(view_mod._preview_maps)
    assert.is_nil(view_mod._preview_bufs)
    assert.is_nil(view_mod._preview_sess)
    assert.is_nil(view_mod._last_shown)
    assert.is_nil(view_mod.show_preview)
    assert.is_nil(view_mod.show_file)
    assert.is_nil(view_mod.bootstrap)
  end)

  it("never creates a codediff session", function()
    local repo, base, files, hs = fixture({ ["a.lua"] = "one\n" }, { ["a.lua"] = "ONE\n" })
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local shown = false
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
    if ok then
      assert.is_nil(lifecycle.get_session(sess.tabpage),
        "intent-diff must no longer register a codediff session")
    end
    view.close_tab(sess)
  end)
end)
