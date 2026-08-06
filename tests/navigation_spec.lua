local helpers = require("tests.helpers")

describe("navigation.next_hunk / navigation.prev_hunk read plan.hunk_rows", function()
  -- Unit-level: stub view.current_plan with a bare `{ hunk_rows = ... }` so
  -- the jump logic is pinned in isolation from plan.build and view.show. The
  -- end-to-end behaviour (the plan actually painted, the off-by-separator-row
  -- bug, group-scoping across files) is covered further down against the real
  -- renderer.
  local navigation, saved_view
  local tabpage, win, buf

  before_each(function()
    vim.cmd("tabnew")
    tabpage = vim.api.nvim_get_current_tabpage()
    win = vim.api.nvim_get_current_win()
    buf = vim.api.nvim_win_get_buf(win)
    local lines = {}
    for i = 1, 200 do lines[i] = "row " .. i end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    saved_view = package.loaded["intentdiff.view"]
    package.loaded["intentdiff.navigation"] = nil
    navigation = require("intentdiff.navigation")
  end)

  after_each(function()
    package.loaded["intentdiff.view"] = saved_view
    package.loaded["intentdiff.navigation"] = nil
    navigation = require("intentdiff.navigation")
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      vim.api.nvim_set_current_tabpage(tabpage)
      vim.cmd("tabclose")
    end
  end)

  local function stub_plan(hunk_rows)
    package.loaded["intentdiff.view"] = {
      current_plan = function() return { hunk_rows = hunk_rows } end,
    }
  end

  it("moves forward to the first row of the next range", function()
    stub_plan({ { 5, 5 }, { 20, 22 }, { 40, 40 } })
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    assert.is_true(navigation.next_hunk(tabpage))
    assert.equals(20, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("moves backward to the first row of the previous range", function()
    stub_plan({ { 5, 5 }, { 20, 22 }, { 40, 40 } })
    vim.api.nvim_win_set_cursor(win, { 40, 0 })
    assert.is_true(navigation.prev_hunk(tabpage))
    assert.equals(20, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("does not move past the last range", function()
    stub_plan({ { 5, 5 }, { 20, 22 } })
    vim.api.nvim_win_set_cursor(win, { 20, 0 })
    assert.is_false(navigation.next_hunk(tabpage))
    assert.equals(20, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("does not move before the first range", function()
    stub_plan({ { 5, 5 }, { 20, 22 } })
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    assert.is_false(navigation.prev_hunk(tabpage))
    assert.equals(5, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("is a no-op, not an error, when there is no painted plan", function()
    package.loaded["intentdiff.view"] = { current_plan = function() return nil end }
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    assert.has_no.errors(function()
      assert.is_false(navigation.next_hunk(tabpage))
    end)
    assert.equals(5, vim.api.nvim_win_get_cursor(win)[1])
  end)

  it("is a no-op when the plan has no visible hunks", function()
    stub_plan({})
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    assert.is_false(navigation.next_hunk(tabpage))
    assert.equals(5, vim.api.nvim_win_get_cursor(win)[1])
  end)
end)

describe("navigation.reattach_keymaps", function()
  -- All this module still owns. The per-tabpage ctx it used to keep
  -- (attach/detach/set_position/update_model) is gone: nothing read it — `jump`
  -- above plans against the painted plan — so it could only ever disagree with
  -- the screen.
  local view_stub, saved_view
  local tabpage, win1, win2, buf1, buf2
  local navigation

  before_each(function()
    vim.cmd("tabnew")
    tabpage = vim.api.nvim_get_current_tabpage()
    win1 = vim.api.nvim_get_current_win()
    buf1 = vim.api.nvim_win_get_buf(win1)

    vim.cmd("vsplit")
    win2 = vim.api.nvim_get_current_win()
    buf2 = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win2, buf2)

    saved_view = package.loaded["intentdiff.view"]
    view_stub = {
      diff_wins = function() return { win1, win2 } end,
      pane_wins = function() return { original = win1, modified = win2 } end,
      current_plan = function() return nil end,
    }
    package.loaded["intentdiff.view"] = view_stub

    package.loaded["intentdiff.navigation"] = nil
    navigation = require("intentdiff.navigation")
  end)

  after_each(function()
    package.loaded["intentdiff.view"] = saved_view
    package.loaded["intentdiff.navigation"] = nil
    navigation = require("intentdiff.navigation")
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      vim.api.nvim_set_current_tabpage(tabpage)
      vim.cmd("tabclose")
    end
  end)

  it("installs ]c/[c buffer-local maps on both diff pane buffers", function()
    navigation.reattach_keymaps(tabpage)
    for _, buf in ipairs({ buf1, buf2 }) do
      local found_next, found_prev = false, false
      for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if keymap.lhs == "]c" then found_next = true end
        if keymap.lhs == "[c" then found_prev = true end
      end
      assert.is_true(found_next, "]c not mapped on buffer " .. buf)
      assert.is_true(found_prev, "[c not mapped on buffer " .. buf)
    end
  end)

  it("needs no prior call and no per-tab state", function()
    -- Fixes the bug where a whole-intent view (which never called the old
    -- M.attach at all) left ]c/[c completely unbound. There is no longer any
    -- state that could gate this — view.install_keymaps calls it after every
    -- render, on whatever buffers the panes now hold.
    navigation.reattach_keymaps(tabpage)
    local found_next = false
    for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(buf2, "n")) do
      if keymap.lhs == "]c" then found_next = true end
    end
    assert.is_true(found_next, "]c not mapped")
  end)

  it("no longer exposes the write-only ctx store", function()
    -- Deleted, not deprecated: init.lua wrote this on every selection and
    -- nothing ever read it back, so it could only ever drift from the screen.
    for _, name in ipairs({ "attach", "detach", "set_position", "update_model" }) do
      assert.is_nil(navigation[name], "navigation." .. name .. " should be gone")
    end
  end)
end)

describe("the edit escape hatch", function()
  it("opens the real file at the row's coordinate", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\ntwo\nthree\n" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "one\nTWO\nthree\n")

    local view = require("intentdiff.view")
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local hunks = require("intentdiff.hunks")
    local hs, files = hunks.parse(helpers.git(repo, "diff"))
    files[1].hunks = hs
    local shown = false
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local wins = view.pane_wins(sess.tabpage)
    local plan = view.current_plan(sess.tabpage)
    -- Find the row showing modified line 2.
    local target_row
    for row = 1, #plan.modified.lines do
      local t = plan.modified.map[row]
      if t and t.line == 2 and t.side == "new" then target_row = row end
    end
    assert.truthy(target_row)
    vim.api.nvim_win_set_cursor(wins.modified, { target_row, 0 })
    view.open_real_file(sess.tabpage)

    local buf = vim.api.nvim_get_current_buf()
    -- vim.fn.resolve, not a raw string compare: `repo` comes from
    -- vim.fn.tempname(), and on macOS $TMPDIR sits under a /var that is
    -- itself a symlink to /private/var, which nvim_buf_get_name resolves and
    -- a plain concatenation of `repo` does not.
    assert.equals(vim.fn.resolve(repo .. "/a.lua"), vim.fn.resolve(vim.api.nvim_buf_get_name(buf)))
    assert.equals(2, vim.api.nvim_win_get_cursor(0)[1])
    assert.is_true(vim.bo[buf].modifiable, "the real file must be editable")
    -- open_real_file's tabedit left a SECOND tab open (that is its whole
    -- point — the review tab survives intact); close it too, or it leaks
    -- into whatever spec runs next in this same nvim instance.
    vim.cmd("tabclose")
    view.close_tab(sess)
  end)

  it("does nothing on a row that addresses no line", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\n" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "ONE\n")

    local view = require("intentdiff.view")
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local hunks = require("intentdiff.hunks")
    local hs, files = hunks.parse(helpers.git(repo, "diff"))
    files[1].hunks = hs
    local shown = false
    view.show(sess, files, { [hs[1].id] = true }, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local wins = view.pane_wins(sess.tabpage)
    vim.api.nvim_win_set_cursor(wins.modified, { 1, 0 })  -- the separator row
    local before = vim.api.nvim_get_current_buf()
    view.open_real_file(sess.tabpage)
    assert.equals(before, vim.api.nvim_get_current_buf())
    view.close_tab(sess)
  end)
end)

describe("navigation reads hunk ranges from the plan", function()
  it("jumps between the visible hunks only", function()
    local orig, mod = {}, {}
    for i = 1, 30 do orig[i] = "line" .. i; mod[i] = "line" .. i end
    mod[5] = "A"; mod[15] = "B"; mod[25] = "C"
    local repo = helpers.make_repo({ ["a.lua"] = table.concat(orig, "\n") .. "\n" })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", table.concat(mod, "\n") .. "\n")

    local view = require("intentdiff.view")
    local nav = require("intentdiff.navigation")
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local hunks = require("intentdiff.hunks")
    local hs, files = hunks.parse(helpers.git(repo, "diff"))
    files[1].hunks = hs
    assert.equals(3, #hs)

    -- Only the first and third hunks are in this intent.
    local visible = { [hs[1].id] = true, [hs[3].id] = true }
    local shown = false
    view.show(sess, files, visible, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local wins = view.pane_wins(sess.tabpage)
    vim.api.nvim_win_set_cursor(wins.modified, { 1, 0 })
    nav.next_hunk(sess.tabpage)
    local first = vim.api.nvim_win_get_cursor(wins.modified)[1]
    nav.next_hunk(sess.tabpage)
    local second = vim.api.nvim_win_get_cursor(wins.modified)[1]
    nav.next_hunk(sess.tabpage)
    local third = vim.api.nvim_win_get_cursor(wins.modified)[1]

    assert.is_true(second > first)
    assert.equals(second, third, "must not jump to the unowned middle hunk")
    view.close_tab(sess)
  end)

  it("]c across a multi-file intent lands on the row that actually displays "
      .. "the second file's hunk (the off-by-separator-row bug)", function()
    -- The bug Task 10 left behind compared a PANE row against FILE line
    -- numbers, so it was off by the separator row and by every preceding row
    -- of every preceding file. Asserted here through plan.target_at, not a
    -- hardcoded row number, so a regression to that comparison (which would
    -- still land on SOME row, just the wrong one) cannot pass silently.
    local repo = helpers.make_repo({
      ["a.lua"] = "one\ntwo\nthree\n",
      ["b.lua"] = "x\ny\nz\n",
    })
    local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
    helpers.write_file(repo, "a.lua", "one\nTWO\nthree\n")
    helpers.write_file(repo, "b.lua", "x\nY\nz\n")

    local view = require("intentdiff.view")
    local nav = require("intentdiff.navigation")
    local plan_mod = require("intentdiff.render.plan")
    local sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    local hunks = require("intentdiff.hunks")
    local hs, files = hunks.parse(helpers.git(repo, "diff"))
    for _, f in ipairs(files) do
      f.hunks = vim.tbl_filter(function(h) return h.file == f.path end, hs)
    end
    local visible = {}
    for _, h in ipairs(hs) do visible[h.id] = true end

    local shown = false
    view.show(sess, files, visible, { on_ready = function() shown = true end })
    assert.truthy(helpers.wait_for(function() return shown end, 5000))

    local wins = view.pane_wins(sess.tabpage)
    vim.api.nvim_win_set_cursor(wins.modified, { 1, 0 })
    assert.is_true(nav.next_hunk(sess.tabpage), "expected a first hunk (a.lua)")
    local at_a = plan_mod.target_at(view.current_plan(sess.tabpage).modified,
      vim.api.nvim_win_get_cursor(wins.modified)[1])
    assert.equals("a.lua", at_a.file)

    assert.is_true(nav.next_hunk(sess.tabpage), "expected a second hunk (b.lua)")
    local row = vim.api.nvim_win_get_cursor(wins.modified)[1]
    local plan = view.current_plan(sess.tabpage)
    local at_b = plan_mod.target_at(plan.modified, row)
    assert.truthy(at_b, "the row ]c landed on must address a real (file, line)")
    assert.equals("b.lua", at_b.file)
    assert.equals("new", at_b.side)
    -- Not a hardcoded row/line: the expected line is read off the SAME
    -- parsed hunk the render was built from, so this pins "]c lands where
    -- b.lua's own hunk actually starts" without guessing git's context width.
    local b_hunk
    for _, h in ipairs(hs) do
      if h.file == "b.lua" then b_hunk = h end
    end
    assert.truthy(b_hunk, "no parsed hunk for b.lua")
    assert.equals(b_hunk.modified.start_line, at_b.line)

    view.close_tab(sess)
  end)
end)
