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

  --- Untracked file, status "??" — codediff's show_untracked_file collapses
  --- this to a SINGLE window (session.original_win = nil, session.modified_win
  --- = the kept window), even though M.show_file requests side-by-side
  --- layout. That's the exact shape that broke clear_folds's
  --- `ipairs({ session.original_win, session.modified_win })`: with the first
  --- element nil, ipairs stopped before ever looking at the second.
  local function untracked_fixture()
    local repo = helpers.make_repo({ ["existing.txt"] = "keep\n" })
    local lines = {}
    for i = 1, 20 do lines[i] = "new line " .. i end
    helpers.write_file(repo, "new.lua", table.concat(lines, "\n"))

    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)

    local base
    require("codediff.core.git").resolve_revision("HEAD", repo, function(_, h) base = h end)
    helpers.wait_for(function() return base end)

    local sess = { tabpage = view.open_tab(), git_root = repo, base_revision = base,
      target_revision = "WORKING" }
    local file_entry = { path = "new.lua", status = "??", hunks = inv.hunks }
    local group = { title = "All", hunks = inv.hunks, files = { file_entry } }
    return sess, file_entry, group
  end

  local function show(sess, file_entry)
    local ready = false
    view.show_file(sess, file_entry, { on_ready = function() ready = true end })
    assert.truthy(helpers.wait_for(function() return ready end, 10000), "show_file timed out")
  end

  --- Every line of `win`'s buffer is actually visible — no fold (stale or
  --- otherwise) is hiding it.
  local function assert_unfolded(win)
    local last = vim.api.nvim_win_call(win, function() return vim.fn.line("$") end)
    for lnum = 1, last do
      assert.equals(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(lnum) end),
        ("line %d of win %s is folded closed"):format(lnum, win))
    end
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

  -- The author's report: pressing the comment key in the intent view did
  -- nothing at all. The keys were simply never installed there.
  it("installs the comment keys on the preview buffers, with a live row map", function()
    -- Literal lhs values: the defaults use <localleader>, which is expanded at
    -- map time and comes back from nvim_buf_get_keymap as "\cc".
    require("intentdiff.config").setup({
      keymaps = { comments = { add_comment = "gc", add_note = "gn", edit_comment = "ge" } },
    })
    local sess, file_entry, group = fixture()
    show(sess, file_entry)
    assert.is_true(view.show_preview(sess, group))

    local session = view.get_session(sess.tabpage)
    local function mapped(buf, mode)
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        out[m.lhs] = true
      end
      return out
    end
    for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
      local normal = mapped(buf, "n")
      assert.is_truthy(normal.gc, "no add_comment mapping on preview buffer " .. buf)
      assert.is_truthy(normal.ge, "no edit_comment mapping on preview buffer " .. buf)
      -- The visual-mode variants too: a range comment is the other half of
      -- requirement 1.
      assert.is_truthy(mapped(buf, "x").gn,
        "no visual add_note mapping on preview buffer " .. buf)
    end

    -- And the map those keys resolve through is registered for both panes.
    local panes = view.preview_panes(sess.tabpage)
    assert.equals(2, #panes)
    local addressed = 0
    for _, entry in ipairs(panes) do
      assert.truthy(view.preview_pane_for_buf(sess.tabpage, entry.bufnr))
      for row = 1, #entry.pane.lines do
        local target = require("intentdiff.preview").target_at(entry.pane, row)
        if target then
          assert.equals("big.lua", target.file)
          addressed = addressed + 1
        end
      end
    end
    assert.is_true(addressed > 0, "no preview row addresses a real file line")
  end)

  it("does not leave group folds applied to the preview buffers", function()
    local sess, file_entry, group = fixture()
    show(sess, { path = "big.lua", status = "M", hunks = { file_entry.hunks[1] } })
    view.show_preview(sess, group)
    local session = view.get_session(sess.tabpage)
    -- foldmethod alone is a weak check — it passes for literally any value
    -- other than "expr", including a wrong one, and says nothing about
    -- whether a STALE fold (foldmethod already "manual" but a fold left over
    -- from before) is still closed over content. Assert the actual visible
    -- state of every line instead.
    assert.not_equals("expr", vim.wo[session.modified_win].foldmethod)
    assert_unfolded(session.modified_win)
    assert_unfolded(session.original_win)
    assert.is_nil(view._active_folds[sess.tabpage])
  end)

  it("renders an untracked-file (single-pane) preview fully unfolded", function()
    local sess, file_entry, group = untracked_fixture()
    show(sess, file_entry)
    local shown_session = view.get_session(sess.tabpage)
    -- Confirms the fixture actually reproduces the single-pane shape:
    -- codediff's show_untracked_file collapsed to one window with
    -- original_win == nil, exactly what broke clear_folds's ipairs loop.
    assert.is_true(shown_session.single_pane)
    assert.is_nil(shown_session.original_win)
    local before = #vim.api.nvim_tabpage_list_wins(sess.tabpage)

    assert.is_true(view.show_preview(sess, group))
    assert.equals(before, #vim.api.nvim_tabpage_list_wins(sess.tabpage))
    local session = view.get_session(sess.tabpage)
    assert_unfolded(session.modified_win)

    assert.is_true(view.restore(sess))
    assert.truthy(helpers.wait_for(function()
      local s = view.get_session(sess.tabpage)
      return s and s.modified_win and vim.api.nvim_win_is_valid(s.modified_win) or nil
    end, 10000))
  end)

  it("restoring a preview with nothing shown yet leaves the tab and its windows intact", function()
    local sess, _, group = fixture()
    -- No M.show_file call: bootstrap the codediff session directly, so
    -- M._last_shown[tabpage] stays nil — the ordinary state of a tab right
    -- after :IntentDiff opens, before the user has selected any file, which
    -- is exactly when the next task's sidebar-cursor preview can fire.
    assert.truthy(view.bootstrap(sess))
    assert.is_true(view.show_preview(sess, group))
    local wins_before = vim.api.nvim_tabpage_list_wins(sess.tabpage)
    assert.truthy(#wins_before > 0)

    assert.is_false(view.restore(sess))
    -- Any buffer deletion here happens on a scheduled tick (retire_preview_bufs
    -- is deliberately deferred, see its comment), not synchronously inside
    -- restore() — so the crash this guards against wouldn't show up in an
    -- assertion made immediately afterward. Yield to the event loop first.
    vim.wait(200, function() return false end)

    assert.is_true(vim.api.nvim_tabpage_is_valid(sess.tabpage))
    assert.truthy(#vim.api.nvim_list_tabpages() >= 1)
    for _, w in ipairs(wins_before) do
      assert.is_true(vim.api.nvim_win_is_valid(w), "window " .. w .. " was closed")
    end
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

  it("restoring onto an untracked file keeps the session's inline layout", function()
    -- M.restore now fires on ordinary sidebar cursor movement (a file row),
    -- so M.show_file's whole-file branch hardcoding "side-by-side" silently
    -- reverted a user working in inline layout just by scrolling the sidebar
    -- past an untracked/added/deleted file.
    local sess, file_entry, group = untracked_fixture()
    show(sess, file_entry)
    local function session() return view.get_session(sess.tabpage) end
    assert.equals("side-by-side", session().layout)

    local toggled = false
    view.toggle_layout(sess.tabpage, { on_done = function() toggled = true end })
    assert.truthy(helpers.wait_for(function() return toggled end, 10000))
    assert.equals("inline", session().layout)
    local wins_before = #vim.api.nvim_tabpage_list_wins(sess.tabpage)

    assert.is_true(view.show_preview(sess, group))
    assert.is_true(view.restore(sess))
    assert.truthy(helpers.wait_for(function()
      local s = session()
      return s and s.modified_win and vim.api.nvim_win_is_valid(s.modified_win) or nil
    end, 10000))
    vim.wait(300, function() return false end, 20)

    assert.equals("inline", session().layout,
      "leaving a preview must not change the layout the user chose")
    assert.equals(wins_before, #vim.api.nvim_tabpage_list_wins(sess.tabpage))
  end)

  it("falls back to a single-pane preview when the session owns one pane window", function()
    -- Deliberate, documented limitation: show_preview derives its layout from
    -- session.layout, but a "??"/"A"/"D" anchor file has already collapsed the
    -- session to ONE pane window, and a preview may never create a window to
    -- get the second one back. So the preview renders inline even though the
    -- session still calls itself side-by-side.
    local sess, file_entry, group = untracked_fixture()
    show(sess, file_entry)
    assert.equals("side-by-side", view.get_session(sess.tabpage).layout)
    assert.is_nil(view.get_session(sess.tabpage).original_win)
    local wins_before = #vim.api.nvim_tabpage_list_wins(sess.tabpage)

    assert.is_true(view.show_preview(sess, group))
    assert.equals(1, #view._preview_bufs[sess.tabpage],
      "a one-window session must get a one-buffer (inline) preview")
    assert.equals(wins_before, #vim.api.nvim_tabpage_list_wins(sess.tabpage))
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
