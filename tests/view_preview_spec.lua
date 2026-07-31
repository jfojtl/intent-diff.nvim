local helpers = require("tests.helpers")

describe("view: intent preview", function()
  local view

  before_each(function()
    package.loaded["intentdiff.view"] = nil
    view = require("intentdiff.view")
    assert.is_true(view.load())
    require("intentdiff.config").setup({})
  end)

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      pcall(vim.cmd, "tabclose $")
    end
  end)

  --- 60-line file with two distant edits → two hunks.
  local function fixture()
    local lines = {}
    for i = 1, 60 do lines[i] = "line " .. i end
    local repo = helpers.make_repo({ ["big.lua"] = table.concat(lines, "\n") })
    lines[5] = "CHANGED 5"
    lines[55] = "CHANGED 55"
    helpers.write_file(repo, "big.lua", table.concat(lines, "\n"))

    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)

    local base
    require("codediff.core.git").resolve_revision("HEAD", repo, function(_, h) base = h end)
    helpers.wait_for(function() return base end)

    local sess = { tabpage = view.open_tab(), git_root = repo, base_revision = base,
      target_revision = "WORKING" }
    local file_entry = { path = "big.lua", status = "M", hunks = inv.hunks }
    local group = { title = "All", hunks = inv.hunks, files = { file_entry } }
    return sess, file_entry, group
  end

  local function show(sess, file_entry)
    local ready = false
    view.show_file(sess, file_entry, { on_ready = function() ready = true end })
    assert.truthy(helpers.wait_for(function() return ready end, 10000), "show_file timed out")
  end

  it("injects two panes without creating or closing a window", function()
    local sess, file_entry, group = fixture()
    show(sess, file_entry)
    local before = #vim.api.nvim_tabpage_list_wins(sess.tabpage)

    assert.is_true(view.show_preview(sess, group))
    assert.equals(before, #vim.api.nvim_tabpage_list_wins(sess.tabpage))

    local session = view.get_session(sess.tabpage)
    local modified = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    assert.truthy(table.concat(modified, "\n"):find("big.lua", 1, true))
    assert.equals(vim.api.nvim_buf_line_count(session.original_bufnr),
      vim.api.nvim_buf_line_count(session.modified_bufnr))
  end)

  it("does not leave group folds applied to the preview buffers", function()
    local sess, file_entry, group = fixture()
    show(sess, { path = "big.lua", status = "M", hunks = { file_entry.hunks[1] } })
    view.show_preview(sess, group)
    local session = view.get_session(sess.tabpage)
    assert.not_equals("expr", vim.wo[session.modified_win].foldmethod)
    assert.is_nil(view._active_folds[sess.tabpage])
  end)

  it("restores the last shown file with its folds", function()
    local sess, file_entry, group = fixture()
    local partial = { path = "big.lua", status = "M", hunks = { file_entry.hunks[1] } }
    show(sess, partial)
    view.show_preview(sess, group)
    assert.is_true(view.restore(sess))
    -- The restored buffer's content lands synchronously (real file, read off
    -- disk); apply_group_folds only runs once codediff's own diff computation
    -- settles a few ticks later (session.stored_diff_result), so wait for
    -- both rather than just the line count.
    assert.truthy(helpers.wait_for(function()
      local s = view.get_session(sess.tabpage)
      return s and vim.api.nvim_buf_line_count(s.modified_bufnr) == 60
        and vim.wo[s.modified_win].foldmethod == "expr" or nil
    end, 10000))
    local session = view.get_session(sess.tabpage)
    assert.equals("expr", vim.wo[session.modified_win].foldmethod)
    assert.is_nil(view._preview_active[sess.tabpage])
  end)

  it("survives the probe-3 round trip across both layouts", function()
    local sess, file_entry, group = fixture()
    show(sess, file_entry)
    local function wins() return #vim.api.nvim_tabpage_list_wins(sess.tabpage) end
    local function session() return view.get_session(sess.tabpage) end

    assert.is_true(view.show_preview(sess, group))
    assert.equals(2, wins())
    assert.is_nil(session().single_pane)

    view.restore(sess)
    assert.truthy(helpers.wait_for(function()
      return vim.api.nvim_buf_line_count(session().modified_bufnr) == 60 or nil
    end, 10000))

    local toggled = false
    view.toggle_layout(sess.tabpage, { on_done = function() toggled = true end })
    assert.truthy(helpers.wait_for(function() return toggled end, 10000))
    assert.equals("inline", session().layout)
    assert.equals(1, wins())

    assert.is_true(view.show_preview(sess, group))
    assert.equals(1, wins())
    assert.equals("inline", session().layout)

    view.restore(sess)
    assert.truthy(helpers.wait_for(function()
      return vim.api.nvim_buf_line_count(session().modified_bufnr) == 60 or nil
    end, 10000))
    assert.equals("inline", session().layout)
  end)

  it("toggles layout from inside a preview and comes back previewing", function()
    local sess, file_entry, group = fixture()
    show(sess, file_entry)
    view.show_preview(sess, group)
    local before = view.get_session(sess.tabpage).layout

    view.toggle_preview_layout(sess.tabpage)
    assert.truthy(helpers.wait_for(function()
      local s = view.get_session(sess.tabpage)
      return (s.layout ~= before and view._preview_active[sess.tabpage]) and true or nil
    end, 15000), "layout must flip and the preview must return")

    local session = view.get_session(sess.tabpage)
    local lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    assert.truthy(table.concat(lines, "\n"):find("big.lua", 1, true))
  end)
end)
