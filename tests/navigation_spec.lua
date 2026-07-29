local navigation = require("intentdiff.navigation")

local function mk_hunk(line, orig_line)
  return { modified = { start_line = line, end_line = line + 1 },
           original = { start_line = orig_line or line, end_line = (orig_line or line) + 1 } }
end

describe("navigation.plan_move", function()
  -- plan_move(file_entries, file_i, cursor_line, dir, side) -> { line = n } | { file_i = n, jump = "first"|"last" } | nil
  local files = {
    { path = "a.lua", hunks = { mk_hunk(5), mk_hunk(50) } },
    { path = "b.lua", hunks = { mk_hunk(10) } },
  }

  it("moves to the next hunk within the file", function()
    assert.same({ line = 50 }, navigation.plan_move(files, 1, 5, 1))
  end)

  it("rolls over to the next file after the last hunk", function()
    assert.same({ file_i = 2, jump = "first" }, navigation.plan_move(files, 1, 50, 1))
  end)

  it("moves back within the file", function()
    assert.same({ line = 5 }, navigation.plan_move(files, 1, 50, -1))
  end)

  it("rolls back to the previous file before the first hunk", function()
    assert.same({ file_i = 1, jump = "last" }, navigation.plan_move(files, 2, 10, -1))
  end)

  it("returns nil at the group's boundaries", function()
    assert.is_nil(navigation.plan_move(files, 2, 10, 1))
    assert.is_nil(navigation.plan_move(files, 1, 5, -1))
  end)

  it("defaults to the modified side when no side is given", function()
    local side_files = {
      { path = "a.lua", hunks = { mk_hunk(5, 500), mk_hunk(50, 5000) } },
    }
    -- cursor_line=5 is only < modified.start_line=50 for hunk 2, not original 5000
    assert.same({ line = 50 }, navigation.plan_move(side_files, 1, 5, 1))
  end)

  it("compares against the original side's line numbers when side='original'", function()
    local side_files = {
      { path = "a.lua", hunks = { mk_hunk(5, 500), mk_hunk(50, 5000) } },
    }
    assert.same({ line = 5000 }, navigation.plan_move(side_files, 1, 500, 1, "original"))
    assert.same({ line = 500 }, navigation.plan_move(side_files, 1, 5000, -1, "original"))
  end)
end)

describe("navigation integration (move/attach/detach/set_position)", function()
  local view_stub, saved_view
  local tabpage, win1, win2, buf1, buf2
  local ctx

  local function mk_files()
    return {
      { path = "a.lua", hunks = {
          mk_hunk(5, 105),
          mk_hunk(50, 150),
        } },
      { path = "b.lua", hunks = { mk_hunk(10, 110) } },
    }
  end

  before_each(function()
    -- Real tabpage with two split windows + scratch buffers standing in for
    -- the original/modified diff panes.
    vim.cmd("tabnew")
    tabpage = vim.api.nvim_get_current_tabpage()
    win1 = vim.api.nvim_get_current_win()
    buf1 = vim.api.nvim_win_get_buf(win1)
    vim.api.nvim_buf_set_lines(buf1, 0, -1, false, (function()
      local l = {}
      for i = 1, 200 do l[i] = "orig " .. i end
      return l
    end)())

    vim.cmd("vsplit")
    win2 = vim.api.nvim_get_current_win()
    buf2 = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win2, buf2)
    vim.api.nvim_buf_set_lines(buf2, 0, -1, false, (function()
      local l = {}
      for i = 1, 200 do l[i] = "mod " .. i end
      return l
    end)())

    saved_view = package.loaded["intentdiff.view"]
    view_stub = {
      diff_wins = function() return { win1, win2 } end,
      get_session = function() return { original_win = win1, modified_win = win2 } end,
    }
    package.loaded["intentdiff.view"] = view_stub

    package.loaded["intentdiff.navigation"] = nil
    navigation = require("intentdiff.navigation")

    ctx = {
      model = { groups = { { files = mk_files() } } },
      group_i = 1,
      file_i = 1,
      select_file = function() end,
    }
  end)

  after_each(function()
    navigation.detach(tabpage)
    package.loaded["intentdiff.view"] = saved_view
    package.loaded["intentdiff.navigation"] = nil
    navigation = require("intentdiff.navigation")
    if vim.api.nvim_tabpage_is_valid(tabpage) then
      vim.api.nvim_set_current_tabpage(tabpage)
      vim.cmd("tabclose")
    end
  end)

  it("attach installs ]c/[c buffer-local maps on both buffers", function()
    navigation.attach(tabpage, ctx)
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

  it("next_hunk from the modified pane moves cursor in the modified win using modified-side lines", function()
    navigation.attach(tabpage, ctx)
    vim.api.nvim_set_current_win(win2)
    vim.api.nvim_win_set_cursor(win2, { 1, 0 })
    navigation.next_hunk(tabpage)
    assert.equals(win2, vim.api.nvim_get_current_win())
    assert.equals(5, vim.api.nvim_win_get_cursor(win2)[1])
  end)

  it("next_hunk from the original pane uses original-side lines and keeps focus in the original win", function()
    navigation.attach(tabpage, ctx)
    vim.api.nvim_set_current_win(win1)
    vim.api.nvim_win_set_cursor(win1, { 1, 0 })
    navigation.next_hunk(tabpage)
    assert.equals(win1, vim.api.nvim_get_current_win())
    assert.equals(105, vim.api.nvim_win_get_cursor(win1)[1])
  end)

  it("rolls over past the last hunk by calling ctx.select_file and updating ctx.file_i", function()
    navigation.attach(tabpage, ctx)
    local called
    ctx.select_file = function(group_i, file_i, opts) called = { group_i, file_i, opts } end
    vim.api.nvim_set_current_win(win2)
    vim.api.nvim_win_set_cursor(win2, { 50, 0 }) -- at last hunk of file 1
    navigation.next_hunk(tabpage)
    assert.same({ 1, 2, { jump = "first" } }, called)
    assert.equals(2, ctx.file_i)
  end)

  it("move() with nil session is a no-op and does not error", function()
    navigation.attach(tabpage, ctx)
    view_stub.get_session = function() return nil end
    vim.api.nvim_set_current_win(win2)
    vim.api.nvim_win_set_cursor(win2, { 1, 0 })
    assert.has_no.errors(function() navigation.next_hunk(tabpage) end)
    assert.equals(1, vim.api.nvim_win_get_cursor(win2)[1])
  end)

  it("detach clears state so next_hunk is a no-op afterwards", function()
    navigation.attach(tabpage, ctx)
    navigation.detach(tabpage)
    vim.api.nvim_set_current_win(win2)
    vim.api.nvim_win_set_cursor(win2, { 1, 0 })
    assert.has_no.errors(function() navigation.next_hunk(tabpage) end)
    assert.equals(1, vim.api.nvim_win_get_cursor(win2)[1])
  end)
end)
