local helpers = require("tests.helpers")

describe(":IntentDiff end-to-end", function()
  local repo

  local function fake_provider(groups)
    return function(_, cb)
      vim.schedule(function() cb({ groups = groups }) end)
      return { cancel = function() end }
    end
  end

  before_each(function()
    repo = helpers.make_repo({
      ["a.lua"] = table.concat(vim.fn.range(1, 40), "\n"),
      ["b.lua"] = "x",
    })
    helpers.write_file(repo, "a.lua",
      "CHANGED\n" .. table.concat(vim.fn.range(2, 39), "\n") .. "\nCHANGED")
    helpers.write_file(repo, "b.lua", "y")
    vim.cmd("cd " .. repo)
  end)

  after_each(function()
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
      if #vim.api.nvim_list_tabpages() > 1 then
        pcall(vim.cmd, "tabclose $")
      end
    end
  end)

  it("opens, classifies, groups the sidebar, and shows partial diffs", function()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({
        { title = "First edit", hunk_ids = { "a.lua:1", "b.lua:1" } },
        -- a.lua:2 intentionally missed → must land in Ungrouped
      }),
    })
    require("intentdiff").open("")

    local intentdiff = require("intentdiff")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = intentdiff._session(tab)
      return s and s.model.state == "ready" and s or nil
    end, 10000)

    assert.equals(2, #session.model.groups)
    assert.equals("First edit", session.model.groups[1].title)
    assert.equals("Ungrouped", session.model.groups[2].title)
    assert.equals(3, session.model.total_hunks)

    local lines = vim.api.nvim_buf_get_lines(session.sidebar.bufnr, 0, -1, false)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("First edit", 1, true))
    assert.truthy(text:find("Ungrouped", 1, true))
    assert.truthy(text:find("3/3 hunks", 1, true))
  end)

  it("provider failure degrades to flat list with a message", function()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = function(_, cb)
        vim.schedule(function() cb(nil, "boom") end)
        return { cancel = function() end }
      end,
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model.message and s or nil
    end, 10000)
    assert.truthy(session.model.message:find("boom", 1, true))
    -- flat fallback: single group containing every hunk
    assert.equals(1, #session.model.groups)
    assert.equals(3, #session.model.groups[1].hunks)
    -- ...and the footer must not read like the failure dropped the diff:
    -- every hunk is reachable from the sidebar, and there is no provider label
    -- to print (no provider produced this grouping).
    local text = table.concat(vim.api.nvim_buf_get_lines(session.sidebar.bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("3/3 hunks", 1, true), "footer misreports hunk coverage: " .. text)
    assert.is_nil(text:find("0/3", 1, true))
    assert.is_nil(text:find("?", 1, true), "footer prints a bogus provider label: " .. text)
  end)

  -- ------------------------------------------------------------------------
  -- Selecting files: the flow that was completely untested (and completely
  -- broken: the first <CR> closed the placeholder tab the sidebar lived in).
  -- ------------------------------------------------------------------------

  --- 60 lines of distinct content. a.lua and b.lua must NOT be identical:
  --- cache.rematch keys the previous classification by hunk content hash
  --- alone, so byte-identical hunks in two files are indistinguishable to it.
  local function sixty(prefix)
    local l = {}
    for i = 1, 60 do l[i] = prefix .. " line " .. i end
    return l
  end

  --- Repo with a.lua (hunks at 5 and 55) + b.lua (hunk at 5), grouped so that
  --- group 1 = a.lua:1 only, group 2 = a.lua:2 + b.lua:1. Each group therefore
  --- has an "other group's hunk" in a.lua that must stay folded.
  local function make_two_group_repo()
    local a, b = sixty("alpha"), sixty("beta")
    local r = helpers.make_repo({ ["a.lua"] = table.concat(a, "\n"), ["b.lua"] = table.concat(b, "\n") })
    a[5], a[55] = "CHANGED 5", "CHANGED 55"
    b[5] = "CHANGED 5"
    helpers.write_file(r, "a.lua", table.concat(a, "\n"))
    helpers.write_file(r, "b.lua", table.concat(b, "\n"))
    vim.cmd("cd " .. r)
    return r
  end

  local function press(win, key)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
  end

  --- Sidebar buffer line whose metadata matches, so tests drive the real
  --- <CR> keymap at the real cursor position instead of calling callbacks.
  local function sidebar_line(sidebar, kind, group_i, file_i)
    for l = 1, vim.api.nvim_buf_line_count(sidebar.bufnr) do
      local m = sidebar.meta_at(l)
      if m and m.kind == kind and m.group_i == group_i
          and (file_i == nil or m.file_i == file_i) then
        return l
      end
    end
  end

  local function fold_state(win, lnum)
    return vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(lnum) end)
  end

  --- True once OUR buffer-local override of codediff's layout-toggle key is
  --- the one installed on `buf`. codediff reinstalls its own version at the end
  --- of every render, so this is the only reliable "intent-diff has finished
  --- reacting to this render" signal — polling window/fold state alone can
  --- observe a window that merely kept its options from the previous render.
  local function ours_bound(buf)
    local key = require("codediff.config").options.keymaps.view.toggle_layout
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == key and (m.desc or ""):find("intent-diff", 1, true) then
        return true
      end
    end
    return false
  end

  --- Move the cursor to `line` in the sidebar (the <CR> keymap reads it).
  local function focus_row(session, line)
    assert.truthy(line, "no such sidebar row")
    vim.api.nvim_set_current_win(session.sidebar.winid)
    vim.api.nvim_win_set_cursor(session.sidebar.winid, { line, 0 })
  end

  --- Select group/file from the sidebar via <CR> and wait until the pane shows
  --- `path` with our group foldexpr in force and `visible`/`folded` in the
  --- expected fold state. Waiting on the fold state (not just on the foldexpr)
  --- matters when the selection re-renders the SAME file under a different
  --- group: the previous selection already left our foldexpr installed, so
  --- anything weaker returns before the new group's folds are applied.
  --- Returns the modified window.
  local function select_and_wait(session, group_i, file_i, path, visible, folded)
    local line = sidebar_line(session.sidebar, "file", group_i, file_i)
    assert.truthy(line, ("no sidebar row for group %d file %d"):format(group_i, file_i))
    focus_row(session, line)
    press(session.sidebar.winid, "<CR>")
    local view = require("intentdiff.view")
    local tab = session.sess.tabpage
    local win = helpers.wait_for(function()
      local cd_session = view.get_session(tab)
      local w = cd_session and cd_session.modified_win
      if not (w and vim.api.nvim_win_is_valid(w)) then
        return nil
      end
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
      if not name:find(path, 1, true)
          or vim.wo[w].foldexpr ~= "v:lua.require'intentdiff.view'.foldexpr()" then
        return nil
      end
      if not ours_bound(cd_session.modified_bufnr) then
        return nil
      end
      if visible and fold_state(w, visible) ~= -1 then
        return nil
      end
      if folded and not (fold_state(w, folded) > 0) then
        return nil
      end
      return w
    end, 10000)
    assert.truthy(win, ("pane never rendered %s with the group's folds"):format(path))
    return win
  end

  local function open_two_groups()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({
        { title = "Group one", hunk_ids = { "a.lua:1" } },
        { title = "Group two", hunk_ids = { "a.lua:2", "b.lua:1" } },
      }),
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model.state == "ready" and #s.model.groups == 2 and s or nil
    end, 10000)
    assert.truthy(session, "session never reached ready with 2 groups")
    assert.equals(tab, session.sess.tabpage)
    return session, tab
  end

  it("keeps the sidebar alive across file selections and folds to each group", function()
    make_two_group_repo()
    local session, tab = open_two_groups()

    -- The codediff session and the sidebar share ONE tab.
    local cd_session = require("intentdiff.view").get_session(tab)
    assert.truthy(cd_session, "codediff session missing from the review tab")
    assert.equals(tab, vim.api.nvim_win_get_tabpage(session.sidebar.winid))
    assert.equals(tab, vim.api.nvim_win_get_tabpage(cd_session.modified_win))
    -- Sidebar is left of the diff panes.
    assert.is_true(vim.api.nvim_win_get_position(session.sidebar.winid)[2]
      < vim.api.nvim_win_get_position(cd_session.modified_win)[2])

    -- 1) group 1 / a.lua: hunk at 5 visible, group 2's hunk at 55 folded.
    local win = select_and_wait(session, 1, 1, "a.lua", 5, 55)
    assert.equals("expr", vim.wo[win].foldmethod)
    assert.equals(-1, fold_state(win, 5))
    assert.is_true(fold_state(win, 55) > 0)

    -- The sidebar survived the selection and still lists both groups.
    assert.is_true(vim.api.nvim_win_is_valid(session.sidebar.winid))
    assert.is_true(vim.api.nvim_buf_is_valid(session.sidebar.bufnr))
    local text = table.concat(vim.api.nvim_buf_get_lines(session.sidebar.bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("Group one", 1, true))
    assert.truthy(text:find("Group two", 1, true))

    -- 2) ANOTHER group, same file: the fold filter inverts.
    win = select_and_wait(session, 2, 1, "a.lua", 55, 5)
    assert.equals(-1, fold_state(win, 55))
    assert.is_true(fold_state(win, 5) > 0)

    -- 3) ANOTHER group, another file: still driven from the same sidebar.
    win = select_and_wait(session, 2, 2, "b.lua", 5)
    assert.equals(-1, fold_state(win, 5))
    assert.is_true(vim.api.nvim_win_is_valid(session.sidebar.winid))
    assert.truthy(require("intentdiff")._session(tab), "session lost after 3 selections")

    -- Group headers still toggle, i.e. sidebar keymaps still reach the session.
    local header = sidebar_line(session.sidebar, "group", 1)
    focus_row(session, header)
    press(session.sidebar.winid, "<CR>")
    assert.is_true(require("intentdiff")._session(tab).model.groups[1].collapsed)
  end)

  it("codediff's layout toggle key re-renders and re-applies the group folds", function()
    make_two_group_repo()
    local session, tab = open_two_groups()
    local view = require("intentdiff.view")

    local win = select_and_wait(session, 1, 1, "a.lua", 5, 55)
    local layout_of = function() return view.get_session(tab).layout end
    local start_layout = layout_of()

    -- Whether the pane actually holds a rendered INLINE diff, rather than the
    -- plain file codediff's own (explorer-only) re-render path left behind:
    -- inline rendering is entirely extmark-based (codediff.ui.inline).
    local function inline_marks(cd_session)
      local ns = require("codediff.ui.inline").ns_inline
      return #vim.api.nvim_buf_get_extmarks(cd_session.modified_bufnr, ns, 0, -1, {})
    end

    local function toggle_and_assert(expected_layout)
      -- Press codediff's own toggle key in the diff pane: the whole point of
      -- the fix is that codediff's buffer-local `t` now reaches our toggle.
      press(win, require("codediff.config").options.keymaps.view.toggle_layout)
      local ok = helpers.wait_for(function()
        local cd_session = view.get_session(tab)
        local w = cd_session and cd_session.modified_win
        if not (w and vim.api.nvim_win_is_valid(w)) or cd_session.layout ~= expected_layout then
          return nil
        end
        -- A real re-render happened in the new layout: inline ⇒ one pane with
        -- inline extmarks; side-by-side ⇒ two live panes and no inline marks.
        if expected_layout == "inline" then
          if cd_session.original_win ~= w or inline_marks(cd_session) == 0 then
            return nil
          end
        else
          local o = cd_session.original_win
          if not (o and o ~= w and vim.api.nvim_win_is_valid(o)) or inline_marks(cd_session) > 0 then
            return nil
          end
        end
        return ours_bound(cd_session.modified_bufnr)
          and vim.wo[w].foldexpr == "v:lua.require'intentdiff.view'.foldexpr()"
          and fold_state(w, 5) == -1 and fold_state(w, 55) > 0 and w or nil
      end, 10000)
      assert.truthy(ok, "no re-rendered diff with group folds after toggling to " .. expected_layout)
      win = ok
      local cd_session = view.get_session(tab)
      assert.equals(expected_layout, layout_of())
      assert.equals("expr", vim.wo[win].foldmethod)
      assert.equals(-1, fold_state(win, 5))
      assert.is_true(fold_state(win, 55) > 0, "other group's hunk not folded in " .. expected_layout)
      -- The file is still the file we selected, not a plain buffer.
      assert.truthy(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find("a.lua", 1, true))
      if expected_layout == "inline" then
        assert.is_true(inline_marks(cd_session) > 0, "inline diff not rendered")
      else
        assert.equals(0, inline_marks(cd_session))
        assert.is_true(cd_session.original_win ~= win
          and vim.api.nvim_win_is_valid(cd_session.original_win),
          "original pane lost when toggling back to side-by-side")
        assert.equals(tab, vim.api.nvim_win_get_tabpage(cd_session.original_win))
      end
    end

    local other = start_layout == "inline" and "side-by-side" or "inline"
    toggle_and_assert(other)
    toggle_and_assert(start_layout)
    toggle_and_assert(other)
    assert.is_true(vim.api.nvim_win_is_valid(session.sidebar.winid), "sidebar lost across toggles")
  end)

  it("keeps ]c group-scoped after leaving and re-entering the review tab", function()
    make_two_group_repo()
    local session, tab = open_two_groups()
    local win = select_and_wait(session, 1, 1, "a.lua", 5, 55)
    local buf = vim.api.nvim_win_get_buf(win)

    local function mapping_desc(key)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == key then
          return m.desc or ""
        end
      end
      return nil
    end
    assert.truthy((mapping_desc("]c") or ""):find("intent-diff", 1, true))

    -- codediff deletes its keymaps.view lhs's — ours included — from the pane
    -- buffers on TabLeave and reinstalls its own all-hunks versions on
    -- TabEnter, so ]c silently stopped being group-scoped after any tab switch.
    vim.cmd("tabnew")
    local scratch = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_tabpage(tab)
    local reattached = helpers.wait_for(function()
      return (mapping_desc("]c") or ""):find("intent-diff", 1, true) and true or nil
    end, 10000)
    assert.truthy(reattached, "]c was not re-attached after TabEnter: "
      .. tostring(mapping_desc("]c")))

    -- Functional proof it is OUR ]c: sitting on group 1's only hunk in this
    -- file, group-scoped navigation has nowhere to go (group 2's hunk at 55 is
    -- not ours), whereas codediff's all-hunks ]c would jump to line 55.
    win = require("intentdiff.view").get_session(tab).modified_win
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    press(win, "]c")
    assert.equals(5, vim.api.nvim_win_get_cursor(win)[1])

    if vim.api.nvim_tabpage_is_valid(scratch) then
      vim.api.nvim_set_current_tabpage(scratch)
      vim.cmd("tabclose")
    end
  end)

  it("re-matches a changed diff against the previous classification", function()
    local repo = make_two_group_repo()
    local cache_dir = vim.fn.tempname()
    local calls = 0
    local function counting_provider(groups)
      return function(_, cb)
        calls = calls + 1
        vim.schedule(function() cb({ groups = groups }) end)
        return { cancel = function() end }
      end
    end

    require("intentdiff").setup({
      cache_dir = cache_dir,
      provider = counting_provider({
        { title = "Group one", hunk_ids = { "a.lua:1" } },
        { title = "Group two", hunk_ids = { "a.lua:2", "b.lua:1" } },
      }),
    })
    require("intentdiff").open("")
    local first_tab = vim.api.nvim_get_current_tabpage()
    helpers.wait_for(function()
      local s = require("intentdiff")._session(first_tab)
      return s and s.model.state == "ready" and #s.model.groups == 2 or nil
    end, 10000)
    assert.equals(1, calls)
    require("intentdiff").close(first_tab)

    -- Add a brand-new hunk: the diff hash changes, so the cache misses, but
    -- the last-hash index points at the previous classification for re-match.
    local c = sixty("alpha")
    c[5], c[55], c[30] = "CHANGED 5", "CHANGED 55", "BRAND NEW 30"
    helpers.write_file(repo, "a.lua", table.concat(c, "\n"))

    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model.state == "ready" and s.model.stale_count and s or nil
    end, 10000)
    assert.truthy(session, "second open never produced a re-matched model")
    assert.equals(1, calls, "provider ran again instead of re-matching")
    assert.equals(1, session.model.stale_count)
    -- Known hunks kept their groups; the new one shows up as Ungrouped.
    assert.equals("Group one", session.model.groups[1].title)
    assert.equals("Ungrouped", session.model.groups[#session.model.groups].title)
    local text = table.concat(vim.api.nvim_buf_get_lines(session.sidebar.bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("stale — 1 unclassified", 1, true), "stale footer unreachable: " .. text)
  end)

  it("forgets a session whose tab is closed externally", function()
    make_two_group_repo()
    local session, tab = open_two_groups()
    select_and_wait(session, 1, 1, "a.lua", 5, 55)

    vim.cmd("tabnew") -- never close the last tab
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose")

    assert.is_nil(require("intentdiff")._session(tab))
    assert.is_nil(require("intentdiff.view")._active_folds[tab])
    assert.is_nil(require("intentdiff.view")._last_shown[tab])
  end)

  it("closes the opened tab and session when the merge-base cannot be resolved", function()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({}),
    })
    local tabs_before = #vim.api.nvim_list_tabpages()
    require("intentdiff").open("definitely-no-such-branch...")

    local closed = helpers.wait_for(function()
      return #vim.api.nvim_list_tabpages() == tabs_before or nil
    end, 10000)

    assert.truthy(closed, "expected the opened tab to be closed after merge-base failure")
    assert.equals(tabs_before, #vim.api.nvim_list_tabpages())
    local tab = vim.api.nvim_get_current_tabpage()
    assert.is_nil(require("intentdiff")._session(tab))
  end)
end)
