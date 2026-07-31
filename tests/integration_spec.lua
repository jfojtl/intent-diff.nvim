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

  it("shows a live elapsed counter while classifying, and clears the timer after completion", function()
    local deferred_cb
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = function(_, cb)
        deferred_cb = cb
        return { cancel = function() end }
      end,
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()

    local session = helpers.wait_for(function()
      return require("intentdiff")._session(tab)
    end, 10000)
    assert.truthy(session, "session never created")

    -- The timer ticks roughly once per second; give it real wall-clock time.
    local ticked = helpers.wait_for(function()
      local text = table.concat(vim.api.nvim_buf_get_lines(session.sidebar.bufnr, 0, -1, false), "\n")
      return text:find("classifying… %d+s") and text or nil
    end, 5000)
    assert.truthy(ticked, "sidebar never showed an elapsed seconds count while classifying")

    assert.truthy(deferred_cb, "provider never invoked")
    deferred_cb({ groups = { { title = "Done", hunk_ids = { "a.lua:1" } } } })

    local done = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model.state == "ready" and s or nil
    end, 10000)
    assert.truthy(done, "classification never completed")
    assert.is_nil(require("intentdiff")._session(tab).elapsed_timer,
      "elapsed timer still armed after classification completed")
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

  it("<Tab> jumps straight to the next group's head line, even when the current "
      .. "group's title wraps across multiple sidebar lines", function()
    make_two_group_repo()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({
        -- Deliberately long enough to wrap past the default 40-col sidebar.
        { title = "This group title is deliberately long so that it must wrap "
            .. "across more than one line in the sidebar", hunk_ids = { "a.lua:1" } },
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

    -- Sanity check the fixture: group 1 must actually occupy more than a
    -- title line + a stats line, or this test would not exercise the bug
    -- (wrapped titles used to add extra "kind == group" lines that <Tab>
    -- mistook for additional groups).
    local group1_rows = 0
    for l = 1, vim.api.nvim_buf_line_count(session.sidebar.bufnr) do
      local m = session.sidebar.meta_at(l)
      if m and m.kind == "group" and m.group_i == 1 then
        group1_rows = group1_rows + 1
      end
    end
    assert.is_true(group1_rows >= 3,
      "fixture title did not wrap; test would not catch the regression")

    focus_row(session, 1)
    press(session.sidebar.winid, "<Tab>")

    local cur = vim.api.nvim_win_get_cursor(session.sidebar.winid)[1]
    local m = session.sidebar.meta_at(cur)
    assert.truthy(m, "cursor landed on a line with no metadata")
    assert.equals(2, m.group_i, "<Tab> did not land on group 2")
    assert.is_true(m.group_head, "<Tab> did not land on group 2's head line")
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

  -- ------------------------------------------------------------------------
  -- Whole-file statuses ("??"/"A"/"D") toggled with `t`: view.lua's
  -- M.toggle_layout used to unconditionally call codediff's own
  -- cd.view.toggle_layout, whose standalone rerender rebuilds a two-sided
  -- SessionConfig from session.original/session.modified — one of which is
  -- always path.empty() for these statuses (show_untracked_file /
  -- show_added_virtual_file / show_deleted_virtual_file only ever populate
  -- ONE side). codediff resolves that empty Path to Neovim's shared buffer
  -- #1, asynchronously for "A"/"D", so the 2nd press left the pane bound to
  -- buffer #1 with session.layout stuck, and the 3rd press left a permanent
  -- phantom window. Drive the real sidebar-select → toggle flow and assert
  -- after EVERY press that none of that happened.
  -- ------------------------------------------------------------------------

  --- The single window currently showing a whole-file pane's content,
  --- regardless of which session field codediff parked it on: modified_win
  --- for "??"/"A" and for anything in inline layout (inline always uses a
  --- single window aliased to both original_win/modified_win); original_win
  --- for "D" in side-by-side layout (show_deleted_virtual_file keeps only the
  --- original pane and leaves modified_win nil).
  local function whole_file_win(cd_session)
    local m, o = cd_session.modified_win, cd_session.original_win
    if m and vim.api.nvim_win_is_valid(m) then
      return m
    end
    if o and vim.api.nvim_win_is_valid(o) then
      return o
    end
  end

  --- Select a whole-file entry from the sidebar via the real <CR> keymap and
  --- wait until its pane shows real content (not buffer #1) containing
  --- `expect_text` AND our `t` override has actually landed (M.install_keymaps
  --- runs asynchronously — see M.show_file). Without waiting on ours_bound
  --- here, a synchronous next keypress can race codediff's own un-patched `t`
  --- (which still calls cd.view.toggle_layout directly), reproducing the very
  --- corruption this test exists to catch as a false failure. Returns the
  --- content window.
  local function select_whole_file_and_wait(session, tab, group_i, file_i, path, expect_text)
    local line = sidebar_line(session.sidebar, "file", group_i, file_i)
    assert.truthy(line, ("no sidebar row for group %d file %d"):format(group_i, file_i))
    focus_row(session, line)
    press(session.sidebar.winid, "<CR>")
    local view = require("intentdiff.view")
    local win = helpers.wait_for(function()
      local cd_session = view.get_session(tab)
      local w = cd_session and whole_file_win(cd_session)
      if not w then
        return nil
      end
      local buf = vim.api.nvim_win_get_buf(w)
      if buf == 1 then
        return nil
      end
      if not vim.api.nvim_buf_get_name(buf):find(path, 1, true) then
        return nil
      end
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      if not text:find(expect_text, 1, true) then
        return nil
      end
      if not ours_bound(buf) then
        return nil
      end
      return w
    end, 10000)
    assert.truthy(win, ("whole-file pane never rendered %s"):format(path))
    return win
  end

  --- Press codediff's layout-toggle key on a whole-file pane up to `times`
  --- times, asserting after EVERY press: the pane is not bound to buffer #1
  --- and still shows `expect_text`, the tab's window count never grows past
  --- what it was right after selection (no phantom windows), the sidebar
  --- window+buffer are still valid, and session.layout actually alternated.
  --- Each press waits for ours_bound on the new buffer before returning —
  --- same reasoning as select_whole_file_and_wait: the NEXT press must not
  --- race codediff's own un-patched `t`.
  local function toggle_whole_file_and_assert(session, tab, path, expect_text, times)
    local view = require("intentdiff.view")
    local toggle_key = require("codediff.config").options.keymaps.view.toggle_layout
    local cd_session = view.get_session(tab)
    local win = whole_file_win(cd_session)
    assert.truthy(win, "no whole-file pane before toggling")
    local baseline_wins = #vim.api.nvim_tabpage_list_wins(tab)
    local prev_layout = cd_session.layout

    for i = 1, times do
      press(win, toggle_key)
      local ok = helpers.wait_for(function()
        local s = view.get_session(tab)
        if not s or s.layout == prev_layout then
          return nil -- hasn't actually flipped (yet)
        end
        local w = whole_file_win(s)
        if not w then
          return nil
        end
        local buf = vim.api.nvim_win_get_buf(w)
        if buf == 1 then
          return nil
        end
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        if not text:find(expect_text, 1, true) then
          return nil
        end
        if not ours_bound(buf) then
          return nil
        end
        return w
      end, 10000)
      assert.truthy(ok, ("press %d: %s never re-rendered with real content after toggling layout"):format(i, path))
      win = ok

      local s = view.get_session(tab)
      assert.is_true(s.layout ~= prev_layout,
        ("press %d: session.layout did not alternate for %s"):format(i, path))
      assert.is_true(#vim.api.nvim_tabpage_list_wins(tab) <= baseline_wins,
        ("press %d: tab window count grew (phantom window) for %s"):format(i, path))
      assert.is_true(vim.api.nvim_win_is_valid(session.sidebar.winid),
        ("press %d: sidebar window lost for %s"):format(i, path))
      assert.is_true(vim.api.nvim_buf_is_valid(session.sidebar.bufnr),
        ("press %d: sidebar buffer lost for %s"):format(i, path))

      prev_layout = s.layout
    end
  end

  it("toggling layout on an untracked (??) whole-file pane never corrupts it", function()
    local repo = helpers.make_repo({ ["tracked.lua"] = "x" })
    helpers.write_file(repo, "new_file.txt", "UNTRACKED LINE ONE\nUNTRACKED LINE TWO")
    vim.cmd("cd " .. repo)

    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({
        { title = "New file", hunk_ids = { "new_file.txt:1" } },
      }),
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model.state == "ready" and s or nil
    end, 10000)
    assert.truthy(session, "session never reached ready")

    select_whole_file_and_wait(session, tab, 1, 1, "new_file.txt", "UNTRACKED LINE ONE")
    toggle_whole_file_and_assert(session, tab, "new_file.txt", "UNTRACKED LINE ONE", 3)
  end)

  it("toggling layout on an added (A) whole-file pane never corrupts it", function()
    local repo = helpers.make_repo({ ["base.lua"] = "x" })
    local git = require("codediff.core.git")
    local base_hash
    git.resolve_revision("HEAD", repo, function(_, hash) base_hash = hash end)
    helpers.wait_for(function() return base_hash end)

    helpers.write_file(repo, "added.txt", "ADDED LINE ONE\nADDED LINE TWO")
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-q", "-m", "add file")
    local target_hash
    git.resolve_revision("HEAD", repo, function(_, hash) target_hash = hash end)
    helpers.wait_for(function() return target_hash end)

    vim.cmd("cd " .. repo)
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({
        { title = "Add file", hunk_ids = { "added.txt:1" } },
      }),
    })
    require("intentdiff").open(base_hash .. " " .. target_hash)
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model.state == "ready" and s or nil
    end, 10000)
    assert.truthy(session, "session never reached ready")

    select_whole_file_and_wait(session, tab, 1, 1, "added.txt", "ADDED LINE ONE")
    toggle_whole_file_and_assert(session, tab, "added.txt", "ADDED LINE ONE", 3)
  end)

  it("toggling layout on a deleted (D) whole-file pane never corrupts it", function()
    local repo = helpers.make_repo({ ["gone.txt"] = "GONE LINE ONE\nGONE LINE TWO" })
    local git = require("codediff.core.git")
    local base_hash
    git.resolve_revision("HEAD", repo, function(_, hash) base_hash = hash end)
    helpers.wait_for(function() return base_hash end)

    helpers.git(repo, "rm", "-q", "gone.txt")
    helpers.git(repo, "commit", "-q", "-m", "remove file")
    local target_hash
    git.resolve_revision("HEAD", repo, function(_, hash) target_hash = hash end)
    helpers.wait_for(function() return target_hash end)

    vim.cmd("cd " .. repo)
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({
        { title = "Remove file", hunk_ids = { "gone.txt:1" } },
      }),
    })
    require("intentdiff").open(base_hash .. " " .. target_hash)
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model.state == "ready" and s or nil
    end, 10000)
    assert.truthy(session, "session never reached ready")

    select_whole_file_and_wait(session, tab, 1, 1, "gone.txt", "GONE LINE ONE")
    toggle_whole_file_and_assert(session, tab, "gone.txt", "GONE LINE ONE", 3)
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

  --- Repo with two files, each owned entirely by a different group, at
  --- clearly different line numbers — so ]c's jump target unambiguously
  --- reveals WHICH file's hunks navigation.attach actually bound. Unlike
  --- make_two_group_repo, whose two files both change at line 5: with that
  --- fixture a ]c jump landing on line 5 could mean either "correct ctx,
  --- y.lua's own hunk" or "stale ctx, x.lua's hunk" — no good for proving a
  --- ctx did NOT get clobbered by the wrong file.
  local function make_two_file_two_group_repo()
    local x, y = sixty("xxx"), sixty("yyy")
    local r = helpers.make_repo({ ["x.lua"] = table.concat(x, "\n"), ["y.lua"] = table.concat(y, "\n") })
    x[5] = "CHANGED 5"
    y[40] = "CHANGED 40"
    helpers.write_file(r, "x.lua", table.concat(x, "\n"))
    helpers.write_file(r, "y.lua", table.concat(y, "\n"))
    vim.cmd("cd " .. r)
    return r
  end

  local function open_two_file_groups()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({
        { title = "Group X", hunk_ids = { "x.lua:1" } },
        { title = "Group Y", hunk_ids = { "y.lua:1" } },
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

  -- Direct, isolated coverage for the IDENTITY gate in open_file's on_ready
  -- (`view._last_shown[tab].file_entry == file_entry`). Previously this was
  -- exercised only incidentally, as a side effect of the "keeps ]c
  -- group-scoped" test's setup above. Positive case: a <CR> that lands on the
  -- SAME file a still-in-flight auto-open is rendering must still end up with
  -- OUR navigation attached, not codediff's default.
  it("attaches OUR ]c/[c navigation when a same-file <CR> races a still-pending auto-open", function()
    -- open_two_groups() only waits for model.state == "ready";
    -- classify_and_render's own auto_open_first (group1/file1 = a.lua) is
    -- kicked off synchronously in that SAME completion callback, but its
    -- show_file()'s on_ready (where navigation.attach would normally run)
    -- only fires later, once when_diff_ready's poll succeeds — so the <CR>
    -- below reliably (though not necessarily) lands inside that gap. Either
    -- way the assertions below must hold: settled-before-<CR> takes
    -- select_file's plain open_file() path, in-flight takes the
    -- same_as_shown short-circuit and leaves the auto-open's own on_ready to
    -- pass the identity gate — both must end up with OUR ]c attached.
    make_two_group_repo()
    local session = open_two_groups()
    local win = select_and_wait(session, 1, 1, "a.lua", 5, 55)
    local buf = vim.api.nvim_win_get_buf(win)
    local desc
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "]c" then desc = m.desc end
    end
    assert.truthy((desc or ""):find("intent-diff", 1, true),
      "]c must be group-scoped (intentdiff's own attach), not codediff's default")
    -- Functional proof, not just the desc string: group 1's only hunk in this
    -- file has nowhere to go — codediff's own all-hunks ]c would jump to 55.
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 5, 0 })
    press(win, "]c")
    assert.equals(5, vim.api.nvim_win_get_cursor(win)[1])
  end)

  -- Negative-case counterpart: a newer selection that lands on a DIFFERENT
  -- file (not what the still-in-flight auto-open was rendering) must still
  -- bail out of attaching that stale ctx.
  --
  -- Two earlier versions of this test both turned out not to discriminate
  -- anything:
  --  1. A ]c-jump-based version inferred the outcome from where the cursor
  --     landed — but x.lua's superseded on_ready (when it fires at all)
  --     reliably arrives AFTER a ]c press has already been checked, so it
  --     passed with or without the `still_current` bail, even with an extra
  --     1.5s settle inserted first: a behavioral probe only sees whatever
  --     ctx is attached AT THE MOMENT it fires, not a record of what
  --     happened over time.
  --  2. A navigation.attach-spy version that instead waited on REAL timing
  --     for x.lua's on_ready to fire late *still* didn't discriminate:
  --     once y.lua's own show_file() runs cd.view.update, codediff's shared
  --     session only tracks ONE "current" diff target
  --     (session.modified.absolute) — x.lua's when_diff_ready poll can
  --     never again match its own path once y.lua has taken over, so it
  --     just gives up silently after ~3s. x.lua's on_ready never fires AT
  --     ALL once a different file has been selected; real timing never
  --     exercises the code path this test exists to guard, no matter how
  --     long it waits.
  --
  -- Stub view.show_file to CAPTURE on_ready instead of letting (as shown
  -- above, sometimes structurally unreachable) async rendering decide when
  -- it fires, and invoke the captured callbacks in a chosen order —
  -- deterministic, independent of codediff's internals or timing.
  it("does not attach a stale ctx when a newer selection lands on a different file "
      .. "while an auto-open is still in flight", function()
    make_two_file_two_group_repo()
    local view = require("intentdiff.view")
    local navigation = require("intentdiff.navigation")
    local real_show_file = view.show_file
    local real_attach = navigation.attach
    local pending = {} -- captured show_file() calls, in call order
    local attach_calls = {}
    view.show_file = function(sess, file_entry, opts)
      -- Mirror the one side effect same_as_shown/still_current depend on —
      -- set synchronously at the top of the real show_file (see view.lua) —
      -- without doing any real, asynchronous rendering.
      view._last_shown[sess.tabpage] = { sess = sess, file_entry = file_entry }
      pending[#pending + 1] = { file_entry = file_entry, on_ready = opts and opts.on_ready }
    end
    navigation.attach = function(tabpage, ctx)
      attach_calls[#attach_calls + 1] = { group_i = ctx.group_i, file_i = ctx.file_i }
      return real_attach(tabpage, ctx)
    end
    local ok, err = pcall(function()
      local session = open_two_file_groups()
      assert.equals(1, #pending, "auto-open must have captured exactly one show_file() call")
      local x_call = pending[1]
      assert.equals("x.lua", x_call.file_entry.path)

      -- Newer selection on a DIFFERENT file: y.lua, group 2. Goes through
      -- the full open_file() path (not same_as_shown, since the path
      -- differs), capturing its own show_file() call rather than x.lua's
      -- being re-used.
      local y_line = sidebar_line(session.sidebar, "file", 2, 1)
      assert.truthy(y_line, "no sidebar row for y.lua")
      focus_row(session, y_line)
      press(session.sidebar.winid, "<CR>")
      assert.equals(2, #pending, "selecting y.lua must have called show_file() again")
      assert.equals("y.lua", pending[2].file_entry.path)

      -- Fire x.lua's STALE on_ready now, simulating it arriving late — after
      -- the newer selection has already moved _last_shown on to y.lua —
      -- exactly what open_file's on_ready IDENTITY gate has to reject.
      assert.truthy(x_call.on_ready, "auto-open's show_file() call had no on_ready")
      x_call.on_ready()

      for i, c in ipairs(attach_calls) do
        assert.is_false(c.group_i == 1 and c.file_i == 1,
          ("navigation.attach call #%d was made with x.lua's stale ctx (group 1/file 1) "
            .. "after y.lua's own selection had already taken over the panes"):format(i))
      end
    end)
    view.show_file = real_show_file
    navigation.attach = real_attach
    assert.is_true(ok, tostring(err))
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

  -- ------------------------------------------------------------------------
  -- auto_open: the sidebar used to reach "ready" with two empty codediff
  -- placeholder panes and stay that way until the user pressed <CR> — nothing
  -- ever auto-opened. These tests drive :IntentDiff WITHOUT any simulated
  -- keypress and assert real content shows up on its own.
  -- ------------------------------------------------------------------------

  --- True once `buf`'s name is a real file path, not one of codediff's empty
  --- placeholder buffers ("CodeDiff N.N" — nvim resolves the relative name
  --- against cwd, so it may show up prefixed with the repo path).
  local function is_placeholder_name(name)
    return name:match("CodeDiff %d+%.%d+$") ~= nil
  end

  --- Wait for the modified pane to show `path` with real content (line count
  --- > 1) and, if given, the fold state at `visible`/`folded` lines. Returns
  --- the window.
  local function wait_auto_opened(tab, path, visible, folded)
    local view = require("intentdiff.view")
    return helpers.wait_for(function()
      local cd_session = view.get_session(tab)
      local w = cd_session and cd_session.modified_win
      if not (w and vim.api.nvim_win_is_valid(w)) then
        return nil
      end
      local buf = vim.api.nvim_win_get_buf(w)
      local name = vim.api.nvim_buf_get_name(buf)
      if not name:find(path, 1, true) then
        return nil
      end
      if vim.api.nvim_buf_line_count(buf) <= 1 then
        return nil
      end
      if vim.wo[w].foldmethod ~= "expr" then
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
  end

  --- Wait for the modified pane to show ANY real (non-placeholder) content,
  --- regardless of which file. Used while classification is still loading,
  --- before groups (and thus a specific expected path) exist.
  local function wait_content_pane(tab)
    local view = require("intentdiff.view")
    return helpers.wait_for(function()
      local cd_session = view.get_session(tab)
      local w = cd_session and cd_session.modified_win
      if not (w and vim.api.nvim_win_is_valid(w)) then
        return nil
      end
      local buf = vim.api.nvim_win_get_buf(w)
      local name = vim.api.nvim_buf_get_name(buf)
      if is_placeholder_name(name) then
        return nil
      end
      if vim.api.nvim_buf_line_count(buf) <= 1 then
        return nil
      end
      return w
    end, 10000)
  end

  it("auto-opens the first group's first file with content and correct folds, and returns focus to the sidebar", function()
    make_two_group_repo()
    local session, tab = open_two_groups()

    -- Group one = a.lua's hunk at line 5 only; group two owns a.lua's hunk
    -- at line 55. Both panes must hold real content, and the modified pane's
    -- folds must show group one's hunk while hiding group two's.
    local win = wait_auto_opened(tab, "a.lua", 5, 55)
    assert.truthy(win, "modified pane never auto-opened a.lua with group one's folds")

    local cd_session = require("intentdiff.view").get_session(tab)
    local mbuf = vim.api.nvim_win_get_buf(cd_session.modified_win)
    local obuf = vim.api.nvim_win_get_buf(cd_session.original_win)
    assert.is_true(vim.api.nvim_buf_line_count(mbuf) > 1, "modified pane still empty")
    assert.is_true(vim.api.nvim_buf_line_count(obuf) > 1, "original pane still empty")
    assert.is_false(is_placeholder_name(vim.api.nvim_buf_get_name(mbuf)))
    assert.is_false(is_placeholder_name(vim.api.nvim_buf_get_name(obuf)))
    assert.equals("expr", vim.wo[win].foldmethod)
    assert.equals(-1, fold_state(win, 5))
    assert.is_true(fold_state(win, 55) > 0)

    local focused = helpers.wait_for(function()
      return vim.api.nvim_get_current_win() == session.sidebar.winid or nil
    end, 10000)
    assert.truthy(focused, "focus did not return to the sidebar after auto-open")
  end)

  it("de-dupes the loading-phase and ready-phase auto-opens when they target the same file+hunks", function()
    -- Single file, single hunk: whatever the provider does with that one
    -- hunk, the flat "All changes" group's first file and the real first
    -- group's first file are necessarily the exact same file with the exact
    -- same (one-hunk) hunk set — the mainstream double-render case the
    -- de-dupe guard exists for. Without it, view.show_file() would fire
    -- twice for this file (a wasted second cd.view.update()/diff recompute).
    local repo = helpers.make_repo({ ["only.lua"] = table.concat(vim.fn.range(1, 20), "\n") })
    local lines = vim.fn.range(1, 20)
    lines[10] = "CHANGED"
    helpers.write_file(repo, "only.lua", table.concat(lines, "\n"))
    vim.cmd("cd " .. repo)

    local view = require("intentdiff.view")
    local orig_show_file = view.show_file
    local call_count = 0
    view.show_file = function(...)
      call_count = call_count + 1
      return orig_show_file(...)
    end

    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({
        { title = "Only group", hunk_ids = { "only.lua:1" } },
      }),
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model.state == "ready" and s or nil
    end, 10000)
    assert.truthy(session, "session never reached ready")

    local rendered = helpers.wait_for(function()
      local cd_session = view.get_session(tab)
      local w = cd_session and cd_session.modified_win
      if not (w and vim.api.nvim_win_is_valid(w)) then
        return nil
      end
      local buf = vim.api.nvim_win_get_buf(w)
      local name = vim.api.nvim_buf_get_name(buf)
      if not name:find("only.lua", 1, true) or vim.api.nvim_buf_line_count(buf) <= 1 then
        return nil
      end
      return w
    end, 10000)
    view.show_file = orig_show_file -- restore before any assertion can fail
    assert.truthy(rendered, "only.lua never auto-opened with content")

    assert.equals(1, call_count,
      "expected exactly one show_file() render when loading-phase and ready-phase targets coincide, got "
        .. call_count)
  end)

  it("auto-opens a file from the flat 'All changes' group while classification is still loading", function()
    make_two_group_repo()
    local deferred_cb
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = function(_, cb)
        deferred_cb = cb
        return { cancel = function() end }
      end,
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      return require("intentdiff")._session(tab)
    end, 10000)
    assert.truthy(session, "session never created")

    -- Still loading: a file from the flat "All changes" group must already
    -- be shown with real content, before the provider ever responds.
    local win = wait_content_pane(tab)
    assert.truthy(win, "no file auto-opened while classification was still loading")
    assert.equals("loading", require("intentdiff")._session(tab).model.state)

    assert.truthy(deferred_cb, "provider never invoked")
    deferred_cb({ groups = {
      { title = "Group one", hunk_ids = { "a.lua:1" } },
      { title = "Group two", hunk_ids = { "a.lua:2", "b.lua:1" } },
    } })
    local done = helpers.wait_for(function()
      local cur = require("intentdiff")._session(tab)
      return cur and cur.model.state == "ready" and cur or nil
    end, 10000)
    assert.truthy(done, "classification never completed")
  end)

  it("a manual selection made while classification is still loading survives the deferred callback", function()
    make_two_group_repo()
    local deferred_cb
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = function(_, cb)
        deferred_cb = cb
        return { cancel = function() end }
      end,
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      return require("intentdiff")._session(tab)
    end, 10000)
    assert.truthy(session, "session never created")

    -- Wait for the loading-phase auto-open to actually render something
    -- first, so the manual selection below is a clean, unambiguous override
    -- rather than a race against the auto-open's own async show_file().
    assert.truthy(wait_content_pane(tab), "no auto-opened content before manual selection")

    -- Manually select b.lua (file_i=2 in the flat "All changes" group; a.lua
    -- is file_i=1 and is what auto-open just showed) via the real <CR>
    -- keymap.
    local line = sidebar_line(session.sidebar, "file", 1, 2)
    focus_row(session, line)
    press(session.sidebar.winid, "<CR>")

    local view = require("intentdiff.view")
    local win = helpers.wait_for(function()
      local cd_session = view.get_session(tab)
      local w = cd_session and cd_session.modified_win
      if not (w and vim.api.nvim_win_is_valid(w)) then
        return nil
      end
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
      return name:find("b.lua", 1, true) and w or nil
    end, 10000)
    assert.truthy(win, "manual selection of b.lua never rendered")

    assert.truthy(deferred_cb, "provider never invoked")
    deferred_cb({ groups = {
      { title = "Group one", hunk_ids = { "a.lua:1" } },
      { title = "Group two", hunk_ids = { "a.lua:2", "b.lua:1" } },
    } })
    local done = helpers.wait_for(function()
      local cur = require("intentdiff")._session(tab)
      return cur and cur.model.state == "ready" and cur or nil
    end, 10000)
    assert.truthy(done, "classification never completed")

    -- Give any (incorrect) auto-open a moment to fire, then assert b.lua is
    -- STILL what's shown — auto-open must never steal a manual selection.
    vim.wait(300)
    local cd_session = view.get_session(tab)
    local final_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(cd_session.modified_win))
    assert.truthy(final_name:find("b.lua", 1, true),
      "auto-open stole the user's manual selection: " .. final_name)
  end)

  it("re-folds a manually-selected added file once classification narrows it to one sub-hunk", function()
    -- 3 blank-line-delimited 30-line blocks (90 lines total) is above
    -- added_file_split's default min_lines=60, so hunks.collect splits
    -- added.lua into >1 sub-hunk (see hunks.split_added / task 2).
    local r = helpers.make_repo({ ["base.lua"] = "x" })
    local src = {}
    for block = 1, 3 do
      for i = 1, 29 do src[#src + 1] = ("block%d line%d"):format(block, i) end
      src[#src + 1] = ""
    end
    helpers.write_file(r, "added.lua", table.concat(src, "\n"))
    vim.cmd("cd " .. r)

    local deferred_cb
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = function(_, cb)
        deferred_cb = cb
        return { cancel = function() end }
      end,
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local session = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.inventory and s or nil
    end, 10000)
    assert.truthy(session, "session never created")

    local added_hunks = vim.tbl_filter(
      function(h) return h.file == "added.lua" end, session.inventory.hunks)
    assert.is_true(#added_hunks > 1, "fixture did not split added.lua into sub-hunks")

    -- Manually select added.lua while classification is still "loading": the
    -- flat "All changes" group owns every sub-hunk, so the whole file is
    -- shown with nothing folded away yet.
    assert.truthy(wait_content_pane(tab), "no auto-opened content before manual selection")
    local line = sidebar_line(session.sidebar, "file", 1, nil)
    focus_row(session, line)
    press(session.sidebar.winid, "<CR>")

    local view = require("intentdiff.view")
    local win = helpers.wait_for(function()
      local cd_session = view.get_session(tab)
      local w = cd_session and cd_session.modified_win
      if not (w and vim.api.nvim_win_is_valid(w)) then
        return nil
      end
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(w))
      return name:find("added.lua", 1, true) and w or nil
    end, 10000)
    assert.truthy(win, "manual selection of added.lua never rendered")
    -- Sanity: nothing folded yet — the flat group owns both sub-hunks.
    assert.equals(-1, fold_state(win, added_hunks[1].modified.start_line))
    assert.equals(-1, fold_state(win, added_hunks[#added_hunks].modified.start_line))

    assert.truthy(deferred_cb, "provider never invoked")
    -- Real grouping: sub-hunk 1 in its own group, the rest elsewhere — the
    -- shown file (still added.lua, per the user's manual selection) now
    -- belongs to a group that owns only PART of it.
    local rest_ids = {}
    for i = 2, #added_hunks do
      rest_ids[#rest_ids + 1] = added_hunks[i].id
    end
    deferred_cb({ groups = {
      { title = "First chunk", hunk_ids = { added_hunks[1].id } },
      { title = "Rest", hunk_ids = rest_ids },
    } })
    local done = helpers.wait_for(function()
      local cur = require("intentdiff")._session(tab)
      return cur and cur.model.state == "ready" and cur or nil
    end, 10000)
    assert.truthy(done, "classification never completed")

    -- refold_shown_file must narrow the still-open added.lua pane to the
    -- group it now belongs to: sub-hunk 1 visible, the rest folded away —
    -- without moving the user off their manual selection.
    helpers.wait_for(function()
      return fold_state(win, added_hunks[#added_hunks].modified.start_line) > 0
    end, 10000)
    assert.equals(-1, fold_state(win, added_hunks[1].modified.start_line))
    assert.is_true(fold_state(win, added_hunks[#added_hunks].modified.start_line) > 0)
    local final_name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
    assert.truthy(final_name:find("added.lua", 1, true))
  end)

  it("auto_open = false leaves the placeholder panes until a manual selection", function()
    make_two_group_repo()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      auto_open = false,
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

    -- Give any (wrongly-firing) auto-open a moment, then assert the panes
    -- are still codediff's empty placeholders.
    vim.wait(300)
    local view = require("intentdiff.view")
    local cd_session = view.get_session(tab)
    local mbuf = vim.api.nvim_win_get_buf(cd_session.modified_win)
    local mname = vim.api.nvim_buf_get_name(mbuf)
    assert.truthy(is_placeholder_name(mname), "expected an empty placeholder pane, got " .. mname)
    assert.is_true(vim.api.nvim_buf_line_count(mbuf) <= 1)

    -- ...until a manual selection, which still works exactly as before.
    local win = select_and_wait(session, 1, 1, "a.lua", 5, 55)
    assert.truthy(win)
  end)

  it("an empty diff does not error and does not open anything", function()
    local repo = helpers.make_repo({ ["same.lua"] = "x\ny\nz" })
    vim.cmd("cd " .. repo)
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = fake_provider({}),
    })
    local tabs_before = #vim.api.nvim_list_tabpages()
    local ok, err = pcall(function() require("intentdiff").open("") end)
    assert.is_true(ok, "opening an empty diff errored: " .. tostring(err))

    local closed = helpers.wait_for(function()
      return #vim.api.nvim_list_tabpages() == tabs_before or nil
    end, 10000)
    assert.truthy(closed, "expected the opened tab to close for an empty diff")
    assert.equals(tabs_before, #vim.api.nvim_list_tabpages())
  end)

  it("toggles every intent collapsed and back, keeping directory state", function()
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      log_file = vim.fn.tempname() .. "/l.log",
      provider = fake_provider({
        { title = "First", ids = "1" },
        { title = "Second", ids = "2-99" },
      }),
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local entry = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model and s.model.state == "ready" and s or nil
    end, 15000)
    assert.truthy(entry)
    assert.is_true(#entry.model.groups >= 2)

    entry.model.groups[1].collapsed_dirs = { ["src"] = true }

    require("intentdiff").toggle_all(tab)
    for _, g in ipairs(entry.model.groups) do
      assert.is_true(g.collapsed, "every intent must collapse")
    end

    require("intentdiff").toggle_all(tab)
    for _, g in ipairs(entry.model.groups) do
      assert.is_falsy(g.collapsed, "every intent must expand again")
    end
    assert.is_true(entry.model.groups[1].collapsed_dirs["src"],
      "per-directory state must survive the round trip")
  end)

  --- Open a nested repo, then invoke the sidebar keymap `lhs` with the cursor
  --- parked on the first row of intent 1. Buffer-local keymaps are called
  --- through their callback rather than feedkeys so a hidden sidebar window
  --- cannot affect the result.
  local function fold_via_key(lhs)
    local nested = helpers.make_repo({
      ["src/http/a.lua"] = "x",
      ["src/db/b.lua"] = "x",
      ["top.lua"] = "x",
    })
    helpers.write_file(nested, "src/http/a.lua", "y")
    helpers.write_file(nested, "src/db/b.lua", "y")
    helpers.write_file(nested, "top.lua", "y")
    vim.cmd("cd " .. nested)
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      log_file = vim.fn.tempname() .. "/l.log",
      provider = fake_provider({ { title = "Everything", ids = "1-99" } }),
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local entry = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model and s.model.state == "ready" and s or nil
    end, 15000)
    assert.truthy(entry, "classification never became ready")

    local group_lnum
    for i, m in ipairs(entry.sidebar.meta) do
      if m.kind == "group" then
        group_lnum = i
        break
      end
    end
    assert.truthy(group_lnum, "no group row in the sidebar")
    vim.api.nvim_set_current_win(entry.sidebar.winid)
    vim.api.nvim_win_set_cursor(entry.sidebar.winid, { group_lnum, 0 })
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(entry.sidebar.bufnr, "n")) do
      if map.lhs == lhs and map.callback then
        map.callback()
        return entry
      end
    end
    error("no sidebar mapping for " .. lhs)
  end

  it("zA on an intent collapses its directories too, and zo re-opens just it", function()
    local entry = fold_via_key("zA")
    local g = entry.model.groups[1]
    assert.is_true(g.collapsed, "the intent itself must collapse")
    -- Recursive means the directories beneath the row, not only the row.
    assert.is_true(g.collapsed_dirs["src"], "src must collapse")
    assert.is_true(g.collapsed_dirs["src/http"], "src/http must collapse")
    assert.is_true(g.collapsed_dirs["src/db"], "src/db must collapse")
  end)

  it("zc on an intent leaves its directories alone", function()
    local entry = fold_via_key("zc")
    local g = entry.model.groups[1]
    assert.is_true(g.collapsed, "the intent itself must collapse")
    assert.same({}, g.collapsed_dirs or {},
      "the non-recursive key must not touch directory state")
  end)

  it("zR expands every intent without disturbing directory state", function()
    local entry = fold_via_key("zA") -- collapse intent + its dirs first
    local tab = entry.sess.tabpage
    require("intentdiff").fold_all(tab, "open")
    local g = entry.model.groups[1]
    assert.is_falsy(g.collapsed, "zR must expand the intent")
    assert.is_true(g.collapsed_dirs["src"],
      "zR is intent-level: the directories the user collapsed must stay collapsed")
  end)
end)

describe("comments in a review tab", function()
  local store = require("intentdiff.comments.store")

  before_each(function()
    store.detach()
    store.clear()
  end)

  after_each(function()
    require("intentdiff.config").setup({})
  end)

  it("registers the four comment commands", function()
    local cmds = vim.api.nvim_get_commands({})
    assert.is_truthy(cmds.IntentDiffCommentsYank)
    assert.is_truthy(cmds.IntentDiffCommentsWrite)
    assert.is_truthy(cmds.IntentDiffCommentsList)
    assert.is_truthy(cmds.IntentDiffCommentsClear)
  end)

  it("lists comment keys in the g? help", function()
    require("intentdiff.config").setup({})
    local sections = require("intentdiff.keymap_help")._build_sections(
      require("intentdiff.config").options.keymaps)
    local found
    for _, s in ipairs(sections) do
      if s.title == "COMMENTS" then
        found = s
      end
    end
    assert.is_truthy(found)
    local labels = {}
    for _, item in ipairs(found.items) do
      labels[item[1]] = item[2]
    end
    assert.is_truthy(labels["<localleader>ci"])
    assert.is_truthy(labels["<localleader>q"])
  end)

  -- The popup's own keys are buffer-local to the comment entry float, which
  -- shows its own footer; listing them in the tab-wide cheatsheet would
  -- advertise keys that do nothing on any of the surfaces it describes.
  it("omits the popup-local keys from the help", function()
    require("intentdiff.config").setup({})
    local sections = require("intentdiff.keymap_help")._build_sections(
      require("intentdiff.config").options.keymaps)
    for _, s in ipairs(sections) do
      if s.title == "COMMENTS" then
        for _, item in ipairs(s.items) do
          assert.are_not.equals("Cycle the comment type", item[2])
          assert.are_not.equals("<C-s>", item[1])
        end
      end
    end
  end)

  it("omits a disabled comment action from the help", function()
    require("intentdiff.config").setup({ keymaps = { comments = { add_praise = false } } })
    local sections = require("intentdiff.keymap_help")._build_sections(
      require("intentdiff.config").options.keymaps)
    for _, s in ipairs(sections) do
      if s.title == "COMMENTS" then
        for _, item in ipairs(s.items) do
          assert.are_not.equals("<localleader>cp", item[1])
        end
      end
    end
  end)

  it("installs no comment keys when comments are disabled", function()
    require("intentdiff.config").setup({ comments = { enabled = false } })
    local sections = require("intentdiff.keymap_help")._build_sections(
      require("intentdiff.config").options.keymaps)
    for _, s in ipairs(sections) do
      assert.are_not.equals("COMMENTS", s.title)
    end
  end)

  it("binds nothing on a buffer when comments are disabled", function()
    require("intentdiff.config").setup({ comments = { enabled = false } })
    local buf = vim.api.nvim_create_buf(false, true)
    require("intentdiff.view").install_comment_keymaps(buf, nil)
    assert.equals(0, #vim.api.nvim_buf_get_keymap(buf, "n"))
    assert.equals(0, #vim.api.nvim_buf_get_keymap(buf, "x"))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- Correction A: the visual-mode variants are driven by an ordered list of
  -- {action, type} records, not a table keyed by lhs. add_comment's type is
  -- nil BY DESIGN (the popup asks), which a value-keyed table cannot express —
  -- and a disabled action must be skipped by keymaps.each, never used as a
  -- table key.
  --- Literal lhs values, so the assertions compare against exactly what
  --- nvim_buf_get_keymap reports: the defaults use <localleader>, which is
  --- expanded at map time and would come back as "\cc".
  local PLAIN_KEYS = {
    add_comment = "gc",
    add_note = "gn",
    add_suggestion = "gs",
    add_issue = "gi",
    add_praise = "gp",
    export_and_close = "gq",
  }

  local function mapped(buf, mode)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
      out[m.lhs] = true
    end
    return out
  end

  it("installs a visual-mode variant for every add action, including add_comment", function()
    require("intentdiff.config").setup({ keymaps = { comments = PLAIN_KEYS } })
    local buf = vim.api.nvim_create_buf(false, true)
    require("intentdiff.view").install_comment_keymaps(buf, nil)
    local visual = mapped(buf, "x")
    -- add_comment's type is nil by design (the popup asks). A table keyed by
    -- lhs with the type as the VALUE simply drops it — this is the assertion
    -- that catches that.
    for _, action in ipairs({ "add_comment", "add_note", "add_suggestion", "add_issue", "add_praise" }) do
      assert.is_truthy(visual[PLAIN_KEYS[action]], "no visual mapping for " .. action)
    end
    -- Non-add actions stay normal-mode only.
    assert.is_nil(visual[PLAIN_KEYS.export_and_close])
    assert.is_truthy(mapped(buf, "n")[PLAIN_KEYS.export_and_close])
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("skips a disabled add action instead of erroring on a nil key", function()
    local keys = vim.tbl_extend("force", {}, PLAIN_KEYS)
    keys.add_comment = false
    require("intentdiff.config").setup({ keymaps = { comments = keys } })
    local buf = vim.api.nvim_create_buf(false, true)
    -- A disabled action must be skipped by keymaps.each, never used as a table
    -- key: `[nil] = ...` in a table constructor raises "table index is nil".
    assert.has_no.errors(function()
      require("intentdiff.view").install_comment_keymaps(buf, nil)
    end)
    local visual = mapped(buf, "x")
    assert.is_truthy(visual[PLAIN_KEYS.add_note], "the other add actions must still bind")
    assert.is_nil(visual[PLAIN_KEYS.add_comment], "the disabled action must bind nothing")
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it("binds every key of a list-valued comment action", function()
    require("intentdiff.config").setup({ keymaps = { comments = { add_issue = { "<leader>x", "<leader>y" } } } })
    local buf = vim.api.nvim_create_buf(false, true)
    require("intentdiff.view").install_comment_keymaps(buf, nil)
    local normal, visual = {}, {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      normal[m.lhs] = true
    end
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "x")) do
      visual[m.lhs] = true
    end
    local leader = vim.g.mapleader or "\\"
    for _, lhs in ipairs({ leader .. "x", leader .. "y" }) do
      assert.is_truthy(normal[lhs], "missing normal mapping " .. lhs)
      assert.is_truthy(visual[lhs], "missing visual mapping " .. lhs)
    end
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  -- The wiring this task is actually about, against a real review tab: the
  -- keys have to reach the buffer the pane DISPLAYS (codediff's
  -- session.*_bufnr fields lag behind a render by a scheduled callback, so
  -- installing from them alone can land the keys on a placeholder buffer
  -- nobody is looking at), the marks have to survive the rebuild, and closing
  -- the tab has to detach the store.
  it("wires comments into a live review tab", function()
    local repo = helpers.make_repo({ ["a.lua"] = table.concat(vim.fn.range(1, 40), "\n") })
    helpers.write_file(repo, "a.lua", "CHANGED\n" .. table.concat(vim.fn.range(2, 40), "\n"))
    vim.cmd("cd " .. repo)
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      keymaps = { comments = { add_issue = "gI" } },
      provider = function(_, cb)
        vim.schedule(function()
          cb({ groups = { { title = "Only intent", hunk_ids = { "a.lua:1" } } } })
        end)
        return { cancel = function() end }
      end,
    })
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local entry = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model.state == "ready" and s or nil
    end, 10000)
    assert.truthy(entry, "the review never became ready")

    local view = require("intentdiff.view")
    local displayed = helpers.wait_for(function()
      local session = view.get_session(tab)
      local win = session and session.modified_win
      if not (win and vim.api.nvim_win_is_valid(win)) then
        return nil
      end
      local buf = vim.api.nvim_win_get_buf(win)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == "gI" then
          return buf
        end
      end
      return nil
    end, 10000)
    assert.truthy(displayed,
      "the comment keys never reached the buffer the diff pane displays")

    -- The store is attached to this review, so a comment persists and renders.
    local marks = require("intentdiff.comments.marks")
    local shown = view._last_shown[tab]
    assert.truthy(shown and shown.file_entry, "no file was ever shown")
    store.add({ file = shown.file_entry.path, line = 2, side = "new",
      type = "issue", text = "live comment" })
    marks.refresh(tab)
    assert.is_true(#vim.api.nvim_buf_get_extmarks(displayed, marks.ns, 0, -1, {}) > 0,
      "the comment left no extmark on the displayed pane buffer")

    -- An intent comment signs the sidebar's group head row, and survives a
    -- re-render of the sidebar.
    store.add({ intent_title = entry.model.groups[1].title, type = "praise", text = "nice" })
    entry.sidebar.update(entry.model)
    assert.is_true(#vim.api.nvim_buf_get_extmarks(entry.sidebar.bufnr, marks.ns, 0, -1, {}) > 0,
      "the intent comment left no sign on the sidebar")

    -- Closing the review detaches the store: the comments are on disk, not in
    -- memory, so the next review does not inherit them.
    require("intentdiff").close(tab)
    assert.equals(0, store.count())
  end)

  it("re-files comments under new intents after re-classification", function()
    local export = require("intentdiff.comments.export")
    local before_model = {
      state = "ready",
      groups = { { title = "First pass", files = { { path = "a.lua" } },
        hunks = { { id = "a.lua:1", file = "a.lua",
          original = { start_line = 1, end_line = 5 },
          modified = { start_line = 1, end_line = 5 } } } } },
    }
    local after_model = {
      state = "ready",
      groups = { { title = "Second pass", files = { { path = "a.lua" } },
        hunks = { { id = "a.lua:1", file = "a.lua",
          original = { start_line = 1, end_line = 5 },
          modified = { start_line = 1, end_line = 5 } } } } },
    }
    store.add({ file = "a.lua", line = 2, side = "new", type = "issue", text = "x" })
    assert.is_truthy(export.generate(store.get_all(), before_model):match("## First pass"))
    assert.is_truthy(export.generate(store.get_all(), after_model):match("## Second pass"))
  end)
end)
