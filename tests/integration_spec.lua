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
  --- the one installed on `buf`.
  local function ours_bound(buf)
    local key = require("codediff.config").options.keymaps.view.toggle_layout
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == key and (m.desc or ""):find("intent-diff", 1, true) then
        return true
      end
    end
    return false
  end

  --- The row of `tab`'s painted plan showing new-side `line` of `path`.
  ---
  --- A pane row is NOT a file line any more: the panes hold a render plan,
  --- which pairs both sides and can concatenate several files. Every assertion
  --- about "is this line folded" has to go through the plan's map.
  local function plan_row(tab, path, line)
    local plan = require("intentdiff.view").current_plan(tab)
    if not plan then
      return nil
    end
    for row = 1, #plan.modified.lines do
      local t = plan.modified.map[row]
      if t and t.file == path and t.side == "new" and t.line == line then
        return row
      end
    end
    return nil
  end

  --- `path` is the ONLY file the panes show, with the file's line `visible`
  --- open and its line `folded` closed. Returns the modified window, or nil.
  local function shows(tab, path, visible, folded)
    local view = require("intentdiff.view")
    local plan = view.current_plan(tab)
    if not (plan and #plan.files == 1 and plan.files[1].path == path) then
      return nil
    end
    local win = view.pane_wins(tab).modified
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return nil
    end
    if visible then
      local row = plan_row(tab, path, visible)
      if not row or fold_state(win, row) ~= -1 then
        return nil
      end
    end
    if folded then
      local row = plan_row(tab, path, folded)
      if not row or not (fold_state(win, row) > 0) then
        return nil
      end
    end
    return win
  end

  --- Move the cursor to `line` in the sidebar (the <CR> keymap reads it).
  local function focus_row(session, line)
    assert.truthy(line, "no such sidebar row")
    vim.api.nvim_set_current_win(session.sidebar.winid)
    vim.api.nvim_win_set_cursor(session.sidebar.winid, { line, 0 })
  end

  --- Select group/file from the sidebar via <CR> and wait until the panes hold
  --- a plan over `path` with `visible`/`folded` in the expected fold state.
  --- Waiting on the fold state (not just on the render) matters when the
  --- selection re-renders the SAME file under a different group.
  --- Returns the modified window.
  local function select_and_wait(session, group_i, file_i, path, visible, folded)
    local line = sidebar_line(session.sidebar, "file", group_i, file_i)
    assert.truthy(line, ("no sidebar row for group %d file %d"):format(group_i, file_i))
    focus_row(session, line)
    press(session.sidebar.winid, "<CR>")
    local tab = session.sess.tabpage
    local win = helpers.wait_for(function()
      return shows(tab, path, visible, folded)
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

    -- The diff panes and the sidebar share ONE tab.
    local wins = require("intentdiff.view").pane_wins(tab)
    assert.truthy(wins.modified, "no diff pane in the review tab")
    assert.equals(tab, vim.api.nvim_win_get_tabpage(session.sidebar.winid))
    assert.equals(tab, vim.api.nvim_win_get_tabpage(wins.modified))
    -- Sidebar is left of the diff panes.
    assert.is_true(vim.api.nvim_win_get_position(session.sidebar.winid)[2]
      < vim.api.nvim_win_get_position(wins.modified)[2])

    -- 1) group 1 / a.lua: hunk at 5 visible, group 2's hunk at 55 folded.
    local win = select_and_wait(session, 1, 1, "a.lua", 5, 55)
    assert.equals("expr", vim.wo[win].foldmethod)

    -- The sidebar survived the selection and still lists both groups.
    assert.is_true(vim.api.nvim_win_is_valid(session.sidebar.winid))
    assert.is_true(vim.api.nvim_buf_is_valid(session.sidebar.bufnr))
    local text = table.concat(vim.api.nvim_buf_get_lines(session.sidebar.bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("Group one", 1, true))
    assert.truthy(text:find("Group two", 1, true))

    -- 2) ANOTHER group, same file: the fold filter inverts.
    win = select_and_wait(session, 2, 1, "a.lua", 55, 5)

    -- 3) ANOTHER group, another file: still driven from the same sidebar.
    win = select_and_wait(session, 2, 2, "b.lua", 5)
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

  it("the layout toggle re-renders and keeps the group folds", function()
    make_two_group_repo()
    local session, tab = open_two_groups()
    local view = require("intentdiff.view")

    local win = select_and_wait(session, 1, 1, "a.lua", 5, 55)
    assert.equals("side-by-side", view.current_plan(tab).layout)

    local function toggle_and_assert(expected_layout)
      -- Press codediff's own toggle key in the pane: it is bound to OUR
      -- toggle, which re-renders the current plan in the other layout.
      press(win, require("codediff.config").options.keymaps.view.toggle_layout)
      local ok = helpers.wait_for(function()
        local plan = view.current_plan(tab)
        if not (plan and plan.layout == expected_layout) then
          return nil
        end
        if expected_layout == "inline" then
          if plan.original ~= nil or view.pane_wins(tab).original ~= nil then
            return nil
          end
        elseif plan.original == nil or view.pane_wins(tab).original == nil then
          return nil
        end
        return shows(tab, "a.lua", 5, 55)
      end, 10000)
      assert.truthy(ok, "no re-render with the group folds after toggling to " .. expected_layout)
      win = ok
      assert.equals("expr", vim.wo[win].foldmethod)
      assert.is_true(ours_bound(vim.api.nvim_win_get_buf(win)),
        "our keys must be reinstalled on the freshly painted buffer")
      assert.equals(1, #view.current_plan(tab).files,
        "the toggle must re-render the SAME plan, not something else")
    end

    toggle_and_assert("inline")
    toggle_and_assert("side-by-side")
    toggle_and_assert("inline")
    assert.is_true(vim.api.nvim_win_is_valid(session.sidebar.winid), "sidebar lost across toggles")
  end)

  -- Whole-file statuses ("??"/"A"/"D") used to need three separate tests, one
  -- per codediff single-file entry point, because toggling layout on them
  -- corrupted the pane in three different ways. There is one render path now
  -- and these statuses are ordinary plans whose old (or new) side is empty, so
  -- one test over the awkward one is enough: a deleted file, whose content
  -- lives only on the original side.
  it("toggling layout on a whole-file (D) pane keeps its content", function()
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

    local view = require("intentdiff.view")
    local function shows_content()
      local plan = view.current_plan(tab)
      if not plan then
        return nil
      end
      local pane = plan.original or plan.modified
      return table.concat(pane.lines, "\n"):find("GONE LINE ONE", 1, true) ~= nil or nil
    end
    assert.truthy(helpers.wait_for(shows_content, 10000), "the deleted file never rendered")

    local baseline_wins = #vim.api.nvim_tabpage_list_wins(tab)
    for i = 1, 3 do
      local before = view.current_plan(tab).layout
      assert.is_true(view.toggle_layout(tab), ("press %d: toggle refused"):format(i))
      assert.truthy(helpers.wait_for(function()
        return view.current_plan(tab).layout ~= before and shows_content() or nil
      end, 10000), ("press %d: the deleted file lost its content"):format(i))
      assert.is_true(#vim.api.nvim_tabpage_list_wins(tab) <= baseline_wins,
        ("press %d: tab window count grew (phantom window)"):format(i))
      assert.is_true(vim.api.nvim_win_is_valid(session.sidebar.winid),
        ("press %d: sidebar window lost"):format(i))
    end
  end)

  --- Repo with two files, each owned entirely by a different group, at
  --- clearly different line numbers — so a jump target unambiguously reveals
  --- WHICH file the panes are planning against. Unlike make_two_group_repo,
  --- whose two files both change at line 5: with that fixture a ]c landing on
  --- line 5 could mean either file.
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
  -- (`entry.shown.file_entry == file_entry`). Previously this was
  -- exercised only incidentally, as a side effect of the "keeps ]c
  -- group-scoped" test's setup above. Positive case: a <CR> that lands on the
  -- SAME file a still-in-flight auto-open is rendering must still end up with
  -- OUR navigation attached, not codediff's default.
  it("installs OUR ]c/[c when a same-file <CR> races a still-pending auto-open", function()
    -- open_two_groups() only waits for model.state == "ready";
    -- classify_and_render's own auto_open_first (group1/file1 = a.lua) is
    -- kicked off synchronously in that SAME completion callback, but its
    -- render only settles later — so the <CR> below reliably (though not
    -- necessarily) lands inside that gap. Either way the assertions must
    -- hold: settled-before-<CR> takes select_file's plain open_file() path,
    -- in-flight takes the same_as_shown short-circuit — and both end with
    -- OUR ]c installed, because view.install_keymaps re-installs it after
    -- every render regardless of which path got there.
    make_two_group_repo()
    local session, tab = open_two_groups()
    local win = select_and_wait(session, 1, 1, "a.lua", 5, 55)
    local buf = vim.api.nvim_win_get_buf(win)
    local desc
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
      if m.lhs == "]c" then desc = m.desc end
    end
    assert.truthy((desc or ""):find("intent-diff", 1, true),
      "]c must be group-scoped (intentdiff's own binding)")
    -- Functional proof, not just the desc string: group 1's only hunk in this
    -- file has nowhere to go, so a group-scoped ]c leaves the cursor alone.
    local row = plan_row(tab, "a.lua", 5)
    assert.truthy(row)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    press(win, "]c")
    assert.equals(row, vim.api.nvim_win_get_cursor(win)[1])
  end)

  -- End-to-end backstop for the same race, through the REAL renderer: a newer
  -- selection on a DIFFERENT file wins the panes outright, and a still-pending
  -- auto-open landing afterwards cannot claw them back.
  --
  -- This used to spy on navigation.attach and assert which group_i/file_i the
  -- auto-open's on_ready computed. That ctx had no consumer — ]c/[c plan
  -- against the painted plan — so the assertion described a value that could
  -- not affect anything. It now asserts what a user can see: which file the
  -- panes render, and where ]c takes the cursor. The deterministic proof of
  -- open_file's IDENTITY gate itself lives in hover_spec, at the one call site
  -- with an observable content effect (M.open_path's on_shown); this test is
  -- the integration-level backstop, so it is deliberately about the outcome
  -- rather than about which branch produced it.
  --
  -- view.show is wrapped, not replaced: the real render still runs (so there
  -- IS a painted plan to assert on), but its on_ready is held back so the
  -- auto-open's can be fired late on demand. Real timing cannot produce "an
  -- older render lands after a newer one took the panes" — once y.lua's render
  -- has run, x.lua's own readiness signal never arrives at all.
  it("keeps the panes on the newer selection when a stale auto-open lands afterwards", function()
    make_two_file_two_group_repo()
    local view = require("intentdiff.view")
    local plan_mod = require("intentdiff.render.plan")
    local real_show = view.show
    local pending = {} -- captured renders, in call order
    view.show = function(sess, files, visible, opts)
      opts = opts or {}
      local record = { files = files, on_ready = opts.on_ready }
      pending[#pending + 1] = record
      return real_show(sess, files, visible,
        vim.tbl_extend("force", opts, { on_ready = function() end }))
    end
    local ok, err = pcall(function()
      local session, tab = open_two_file_groups()
      assert.equals(1, #pending, "auto-open must have captured exactly one render")
      local x_call = pending[1]
      assert.equals("x.lua", x_call.files[1].path)

      -- Newer selection on a DIFFERENT file: y.lua, group 2. Goes through the
      -- full open_file() path (not same_as_shown, since the path differs).
      local y_line = sidebar_line(session.sidebar, "file", 2, 1)
      assert.truthy(y_line, "no sidebar row for y.lua")
      focus_row(session, y_line)
      press(session.sidebar.winid, "<CR>")
      assert.equals(2, #pending, "selecting y.lua must have rendered again")
      assert.equals("y.lua", pending[2].files[1].path)

      -- Fire x.lua's STALE on_ready now, simulating it arriving late — after
      -- the newer selection has already moved entry.shown on to y.lua.
      assert.truthy(x_call.on_ready, "auto-open's render had no on_ready")
      x_call.on_ready()

      -- The panes still render y.lua, and only y.lua — not one row of x.lua
      -- anywhere in the map. (Numeric loop, not ipairs: `map` is sparse.)
      local plan = view.current_plan(tab)
      assert.truthy(plan, "nothing is painted")
      assert.equals(1, #plan.files)
      assert.equals("y.lua", plan.files[1].path)
      for row = 1, #plan.modified.lines do
        local t = plan.modified.map[row]
        assert.is_true(t == nil or t.file == "y.lua",
          ("pane row %d shows %s, not y.lua"):format(row, t and t.file or "?"))
      end

      -- And ]c, driven from the pane, plans against what is painted: it moves,
      -- and it lands on a row that addresses y.lua. (Its target is the first
      -- PANE row of the hunk's span, which includes git's leading context
      -- lines, so the file — not a line number — is what this pins.)
      local win = view.pane_wins(tab).modified
      assert.truthy(win and vim.api.nvim_win_is_valid(win))
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      assert.is_true(require("intentdiff.navigation").next_hunk(tab),
        "]c did not move")
      local at = plan_mod.target_at(plan.modified,
        vim.api.nvim_win_get_cursor(win)[1])
      assert.truthy(at, "]c landed on a row that addresses no line")
      assert.equals("y.lua", at.file)
    end)
    view.show = real_show
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
    assert.is_nil(require("intentdiff.view")._painted[tab])
    assert.is_nil(require("intentdiff.view")._wins[tab])
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

  --- Wait for the panes to hold a plan over `path` and, if given, the fold
  --- state at the file's `visible`/`folded` lines. Returns the window.
  local function wait_auto_opened(tab, path, visible, folded)
    return helpers.wait_for(function()
      return shows(tab, path, visible, folded)
    end, 10000)
  end

  --- Wait for the panes to hold ANY render with real content, regardless of
  --- which file. Used while classification is still loading, before groups
  --- (and thus a specific expected path) exist.
  local function wait_content_pane(tab)
    local view = require("intentdiff.view")
    return helpers.wait_for(function()
      local plan = view.current_plan(tab)
      if not (plan and #plan.modified.lines > 1) then
        return nil
      end
      local win = view.pane_wins(tab).modified
      if not (win and vim.api.nvim_win_is_valid(win)) then
        return nil
      end
      return win
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

    local wins = require("intentdiff.view").pane_wins(tab)
    local mbuf = vim.api.nvim_win_get_buf(wins.modified)
    local obuf = vim.api.nvim_win_get_buf(wins.original)
    assert.is_true(vim.api.nvim_buf_line_count(mbuf) > 1, "modified pane still empty")
    assert.is_true(vim.api.nvim_buf_line_count(obuf) > 1, "original pane still empty")
    assert.equals("expr", vim.wo[win].foldmethod)

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
    -- de-dupe guard exists for. Without it, view.show() would fire
    -- twice for this file (a wasted second cd.view.update()/diff recompute).
    local repo = helpers.make_repo({ ["only.lua"] = table.concat(vim.fn.range(1, 20), "\n") })
    local lines = vim.fn.range(1, 20)
    lines[10] = "CHANGED"
    helpers.write_file(repo, "only.lua", table.concat(lines, "\n"))
    vim.cmd("cd " .. repo)

    local view = require("intentdiff.view")
    local orig_show = view.show
    local call_count = 0
    view.show = function(...)
      call_count = call_count + 1
      return orig_show(...)
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
      return shows(tab, "only.lua")
    end, 10000)
    view.show = orig_show -- restore before any assertion can fail
    assert.truthy(rendered, "only.lua never auto-opened with content")

    assert.equals(1, call_count,
      "expected exactly one render when loading-phase and ready-phase targets coincide, got "
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
    -- rather than a race against the auto-open's own async render.
    assert.truthy(wait_content_pane(tab), "no auto-opened content before manual selection")

    -- Manually select b.lua (file_i=2 in the flat "All changes" group; a.lua
    -- is file_i=1 and is what auto-open just showed) via the real <CR>
    -- keymap.
    local line = sidebar_line(session.sidebar, "file", 1, 2)
    focus_row(session, line)
    press(session.sidebar.winid, "<CR>")

    local view = require("intentdiff.view")
    local win = helpers.wait_for(function() return shows(tab, "b.lua") end, 10000)
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
    local final_plan = view.current_plan(tab)
    assert.equals(1, #final_plan.files)
    assert.equals("b.lua", final_plan.files[1].path,
      "auto-open stole the user's manual selection")
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
    local win = helpers.wait_for(function() return shows(tab, "added.lua") end, 10000)
    assert.truthy(win, "manual selection of added.lua never rendered")
    -- Sanity: nothing folded yet — the flat group owns every sub-hunk.
    -- Ten lines INTO the last sub-hunk, past the context the renderer keeps
    -- around the previous one.
    local last_line = added_hunks[#added_hunks].modified.start_line + 10
    assert.equals(-1, fold_state(win, plan_row(tab, "added.lua", added_hunks[1].modified.start_line)))
    assert.equals(-1, fold_state(win, plan_row(tab, "added.lua", last_line)))

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
    assert.truthy(helpers.wait_for(function()
      local row = plan_row(tab, "added.lua", last_line)
      return row and fold_state(view.pane_wins(tab).modified, row) > 0 or nil
    end, 10000), "the other sub-hunks were never folded away")
    win = view.pane_wins(tab).modified
    assert.equals(-1, fold_state(win, plan_row(tab, "added.lua", added_hunks[1].modified.start_line)))
    assert.is_true(fold_state(win, plan_row(tab, "added.lua", last_line)) > 0)
    local final_plan = view.current_plan(tab)
    assert.equals(1, #final_plan.files)
    assert.equals("added.lua", final_plan.files[1].path)
  end)

  it("auto_open = false leaves the panes empty until a manual selection", function()
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

    -- Give any (wrongly-firing) auto-open a moment, then assert nothing was
    -- painted at all.
    vim.wait(300)
    local view = require("intentdiff.view")
    assert.is_nil(view.current_plan(tab), "auto_open = false must render nothing")
    assert.truthy(view.pane_wins(tab).modified, "the pane windows must still exist")

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

  after_each(function()
    require("intentdiff.config").setup({})
  end)

  it("registers the comment commands", function()
    local cmds = vim.api.nvim_get_commands({})
    assert.is_truthy(cmds.IntentDiffCommentsYank)
    assert.is_truthy(cmds.IntentDiffCommentsWrite)
    assert.is_truthy(cmds.IntentDiffCommentsList)
    assert.is_truthy(cmds.IntentDiffCommentsClear)
    assert.is_truthy(cmds.IntentDiffCommentsSubmit)
    assert.is_truthy(cmds.IntentDiffCommentsFetch)
  end)

  -- The commands are registered UNCONDITIONALLY (plugin/intentdiff.lua runs
  -- long before setup() decides anything), so `comments.enabled = false` is a
  -- real contract only because each one refuses up front. Asserting the
  -- commands merely EXIST never executes that refusal — so run one, with the
  -- feature off, and check both halves of what refusing means: the user is
  -- told, and the clipboard is left exactly as it was.
  it("refuses every comment command while comments are disabled", function()
    require("intentdiff.config").setup({ comments = { enabled = false } })
    local real_notify = vim.notify
    local messages = {}
    vim.notify = function(msg) messages[#messages + 1] = msg end

    vim.fn.setreg("+", "SENTINEL")
    local out_path = vim.fn.tempname() .. "/refused.md"
    local ok, err = pcall(function()
      for _, cmd in ipairs({ "IntentDiffCommentsYank", "IntentDiffCommentsList",
        "IntentDiffCommentsClear", "IntentDiffCommentsWrite " .. out_path }) do
        vim.cmd(cmd)
      end
    end)
    vim.notify = real_notify
    assert.is_true(ok, "a disabled command must refuse, not error: " .. tostring(err))

    assert.equals("SENTINEL", vim.fn.getreg("+"),
      "a refused :IntentDiffCommentsYank must not touch the clipboard")
    assert.equals(0, vim.fn.filereadable(out_path),
      "a refused :IntentDiffCommentsWrite must not create a file")
    local refusals = 0
    for _, msg in ipairs(messages) do
      if tostring(msg):find("review comments are disabled", 1, true) then
        refusals = refusals + 1
      end
    end
    assert.equals(4, refusals,
      "every comment command must say why it did nothing, got: " .. vim.inspect(messages))
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
    -- Distinctive keys, so the assertion cannot pass by coincidence: the
    -- defaults are <Tab>, <C-s> and q, and <Tab>/q are also bound elsewhere in
    -- the config (sidebar next_group, view quit) — a test written against the
    -- defaults would be asserting about someone else's key.
    require("intentdiff.config").setup({
      keymaps = { comments = {
        popup_cycle_type = "<F13>", popup_submit = "<F14>", popup_cancel = "<F15>",
      } },
    })
    local km = require("intentdiff.config").options.keymaps.comments
    local sections = require("intentdiff.keymap_help")._build_sections(
      require("intentdiff.config").options.keymaps)
    local found_comments = false
    for _, s in ipairs(sections) do
      if s.title == "COMMENTS" then
        found_comments = true
        for _, item in ipairs(s.items) do
          -- All three, read from config — not just popup_submit.
          for _, action in ipairs({ "popup_cycle_type", "popup_submit", "popup_cancel" }) do
            assert.are_not.equals(km[action], item[1],
              action .. " is popup-local and must not be listed tab-wide")
          end
        end
      end
    end
    assert.is_true(found_comments, "the COMMENTS section must exist for this to mean anything")
  end)

  it("omits a disabled comment action from the help", function()
    require("intentdiff.config").setup({ keymaps = { comments = { add_praise = false } } })
    local sections = require("intentdiff.keymap_help")._build_sections(
      require("intentdiff.config").options.keymaps)
    -- The flag its sibling above uses, for the same reason: with every
    -- assertion inside `if s.title == "COMMENTS"`, a mutation that emits no
    -- COMMENTS section at all executes ZERO assertions and passes.
    local found_comments = false
    for _, s in ipairs(sections) do
      if s.title == "COMMENTS" then
        found_comments = true
        for _, item in ipairs(s.items) do
          assert.are_not.equals("<localleader>cp", item[1])
        end
      end
    end
    assert.is_true(found_comments, "the COMMENTS section must exist for this to mean anything")
  end)

  -- Named for what it checks: the g? cheatsheet. What it does NOT check is
  -- keymap installation — that is the two tests below, on a scratch buffer and
  -- on a live review tab's real pane.
  it("omits the whole COMMENTS section from the help when comments are disabled", function()
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
  -- keys have to reach the buffer the pane DISPLAYS, the marks have to survive
  -- the rebuild, and closing the tab has to detach the store.
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
      local win = view.pane_wins(tab).modified
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

    -- This review owns a store of its own, attached to its key, so a comment
    -- persists and renders.
    local marks = require("intentdiff.comments.marks")
    local st = entry.comment_store
    assert.truthy(st, "the review never got a comment store")
    assert.truthy(entry.shown and entry.shown.file_entry, "no file was ever shown")
    local path = entry.shown.file_entry.path
    st.add({ file = path, line = 2, side = "new", type = "issue", text = "live comment" })
    marks.refresh(tab)
    assert.is_true(#vim.api.nvim_buf_get_extmarks(displayed, marks.ns, 0, -1, {}) > 0,
      "the comment left no extmark on the displayed pane buffer")

    -- `]n` against the REAL diff_wins. The navigation guard ("am I in a diff
    -- pane?") reads the painted panes, so this is what proves those agree with
    -- the window the user's cursor is actually in — a stub cannot.
    local modified = view.pane_wins(tab).modified
    local row = nil
    local plan = view.current_plan(tab)
    for r = 1, #plan.modified.lines do
      local t = plan.modified.map[r]
      if t and t.file == path and t.side == "new" and t.line == 2 then
        row = r
      end
    end
    assert.truthy(row, "the plan does not show line 2 of the shown file")
    vim.api.nvim_set_current_win(modified)
    vim.api.nvim_win_set_cursor(modified, { 1, 0 })
    require("intentdiff.comments").next(tab)
    assert.equals(row, vim.api.nvim_win_get_cursor(modified)[1],
      "]n did not reach the comment from inside a real diff pane")

    -- An intent comment signs the sidebar's group head row, and survives a
    -- re-render of the sidebar.
    st.add({ intent_title = entry.model.groups[1].title, type = "praise", text = "nice" })
    entry.sidebar.update(entry.model)
    assert.is_true(#vim.api.nvim_buf_get_extmarks(entry.sidebar.bufnr, marks.ns, 0, -1, {}) > 0,
      "the intent comment left no sign on the sidebar")

    -- Closing the review drops its store and wipes the marks it drew: the
    -- comments are on disk, not in memory, and nothing is left rendered.
    require("intentdiff").close(tab)
    assert.is_nil(entry.comment_store, "closing must drop the review's store")
    assert.is_nil(require("intentdiff.comments").store_for(tab))
    if vim.api.nvim_buf_is_valid(displayed) then
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(displayed, marks.ns, 0, -1, {}),
        "the review's comment extmarks outlived it")
    end
  end)

  -- The `comments.enabled = false` contract against a REAL review, which is
  -- the only place it means anything: the pane buffer the review displays and
  -- the sidebar both go through install_comment_keymaps, and neither may come
  -- out carrying a comment key. Deliberately identified by a VIEW key first —
  -- asserting "no comment keys" on a buffer whose keymaps were never installed
  -- at all would pass no matter what the flag does.
  it("installs no comment keys on a live review with comments disabled", function()
    local repo = helpers.make_repo({ ["a.lua"] = table.concat(vim.fn.range(1, 40), "\n") })
    helpers.write_file(repo, "a.lua", "CHANGED\n" .. table.concat(vim.fn.range(2, 40), "\n"))
    vim.cmd("cd " .. repo)
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      comments = { enabled = false },
      -- Distinctive, leader-free keys: nvim_buf_get_keymap reports the
      -- EXPANDED lhs, so the `<localleader>c*` defaults would come back as
      -- "\ci" and an assertion written against the config string would be
      -- comparing the wrong thing.
      keymaps = { comments = { add_issue = "gI", next_comment = "]N" } },
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
    -- Wait for the pane buffer to have OUR view keys on it: that is the moment
    -- install_comment_keymaps has run for it too.
    local displayed = helpers.wait_for(function()
      local win = view.pane_wins(tab).modified
      if not (win and vim.api.nvim_win_is_valid(win)) then
        return nil
      end
      local buf = vim.api.nvim_win_get_buf(win)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == "g?" then
          return buf
        end
      end
      return nil
    end, 10000)
    assert.truthy(displayed, "the review's own pane keys never landed on a buffer")

    --- Every lhs bound on `buf` in `mode`, and every desc.
    local function bound(buf, mode)
      local lhs, descs = {}, {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        lhs[m.lhs] = true
        if m.desc then
          descs[m.desc] = true
        end
      end
      return lhs, descs
    end

    local comment_descs = {}
    for _, desc in pairs(view.COMMENT_DESCS) do
      comment_descs[desc] = true
    end

    -- Asserted, not assumed: a nil second element would make this ipairs stop
    -- at index 1 and silently skip the sidebar — the nil-hole trap this
    -- codebase has paid for elsewhere.
    assert.truthy(entry.sidebar and entry.sidebar.bufnr, "the review has no sidebar buffer")
    for _, buf in ipairs({ displayed, entry.sidebar.bufnr }) do
      for _, mode in ipairs({ "n", "x" }) do
        local lhs, descs = bound(buf, mode)
        assert.is_nil(lhs["gI"], "an add key is bound with comments disabled (" .. mode .. ")")
        assert.is_nil(lhs["]N"], "a navigation key is bound with comments disabled (" .. mode .. ")")
        -- Nothing else from the comment set either, whatever it is bound to.
        for desc in pairs(descs) do
          assert.is_nil(comment_descs[desc], "comment action still bound: " .. desc)
        end
      end
    end

    -- ...and the review never took a store, so nothing could be recorded even
    -- if a key did somehow fire.
    assert.is_nil(entry.comment_store)

    require("intentdiff").close(tab)
  end)

  -- Two review tabs open at once, through the real `:IntentDiff` path — the
  -- scenario the singleton store corrupted. The second review used to re-key
  -- and re-load the ONE shared store, so a comment added AFTERWARDS in the
  -- first tab was written under the second review's key, and closing either tab
  -- blanked the other.
  it("keeps two concurrent review tabs' comments apart, on disk and on screen", function()
    local repo = helpers.make_repo({ ["a.lua"] = table.concat(vim.fn.range(1, 40), "\n") })
    helpers.write_file(repo, "a.lua", "SECOND\n" .. table.concat(vim.fn.range(2, 40), "\n"))
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-q", "-m", "second")
    helpers.write_file(repo, "a.lua", "THIRD\n" .. table.concat(vim.fn.range(2, 40), "\n"))
    vim.cmd("cd " .. repo)

    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = function(_, cb)
        vim.schedule(function()
          cb({ groups = { { title = "Only intent", hunk_ids = { "a.lua:1" } } } })
        end)
        return { cancel = function() end }
      end,
    })

    local opened = {}

    --- Open a review and wait until its comments have attached. The review's
    --- tab is found by looking for a tab that did not exist before rather than
    --- by reading the current one, so the lookup cannot be fooled by anything
    --- that moves the cursor between tabs.
    local function open(args)
      local before = {}
      for _, t in ipairs(vim.api.nvim_list_tabpages()) do
        before[t] = true
      end
      require("intentdiff").open(args)
      local found_tab, found_entry
      helpers.wait_for(function()
        for _, t in ipairs(vim.api.nvim_list_tabpages()) do
          if not before[t] then
            local s = require("intentdiff")._session(t)
            if s and s.comment_store then
              found_tab, found_entry = t, s
              return true
            end
          end
        end
        return false
      end, 10000)
      assert.truthy(found_entry, "the review never attached its comments: " .. args)
      opened[#opened + 1] = found_tab
      return found_tab, found_entry
    end

    -- Closing both reviews must happen even when an assertion below fails:
    -- a leaked review tab (and its session) breaks every later test in this
    -- file.
    local ok, err = pcall(function()

    -- A plain working-tree review (branch-keyed) and a HEAD~1-pinned one
    -- (revision-pair-keyed): two tabs, two keys.
    local tab_a, entry_a = open("")
    -- The second `:IntentDiff` is issued from an ordinary tab, as a user
    -- would, rather than from inside the first review's own pane.
    vim.cmd("tabnew")
    local scratch_tab = vim.api.nvim_get_current_tabpage()
    local tab_b, entry_b = open("HEAD~1")
    pcall(vim.api.nvim_win_close, vim.api.nvim_tabpage_list_wins(scratch_tab)[1], true)
    assert.are_not.equals(tab_a, tab_b, "the second review must open its own tab")
    assert.are_not.equals(entry_a.comment_store, entry_b.comment_store)

    local storage = require("intentdiff.comments.storage")
    local root = entry_a.sess.git_root
    local branch = vim.trim(helpers.git(root, "rev-parse", "--abbrev-ref", "HEAD"))
    local key_a = storage.key(root, nil, nil, branch)
    local key_b = storage.key(root, entry_b.sess.base_revision, entry_b.sess.target_revision, nil)
    assert.are_not.equals(key_a, key_b, "the two keys must differ for this to mean anything")

    -- The corruption case: a comment added in tab A *after* tab B opened.
    entry_a.comment_store.add({ file = "a.lua", line = 3, side = "new", type = "issue", text = "for A" })
    entry_b.comment_store.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "for B" })

    local on_disk_a, on_disk_b = storage.load(key_a), storage.load(key_b)
    assert.equals(1, #on_disk_a)
    assert.equals("for A", on_disk_a[1].text)
    assert.equals(1, #on_disk_b)
    assert.equals("for B", on_disk_b[1].text)

    assert.equals(1, entry_a.comment_store.count())
    assert.equals(1, entry_b.comment_store.count())

    -- Closing A leaves B's comments in memory, still persisting, and still
    -- rendered.
    local marks = require("intentdiff.comments.marks")
    local b_store = entry_b.comment_store
    marks.refresh(tab_b)
    require("intentdiff").close(tab_a)

    assert.is_nil(require("intentdiff.comments").store_for(tab_a))
    assert.equals(b_store, require("intentdiff.comments").store_for(tab_b),
      "closing one review must not detach the other")
    assert.equals(1, b_store.count())
    assert.equals("for B", b_store.get_all()[1].text)
    b_store.add({ file = "a.lua", line = 20, side = "new", type = "praise", text = "later in B" })
    assert.equals(2, #storage.load(key_b), "B must still be persisting under its own key")

    end) -- pcall
    for _, tab in ipairs(opened) do
      pcall(require("intentdiff").close, tab)
    end
    assert(ok, err)
  end)

  -- Correction B, pinned by its CONSEQUENCE rather than by where the call
  -- sits. attach_session chooses between branch keying and revision-pair
  -- keying by reading sess.base_revision/target_revision, which are only
  -- assigned late, inside the resolve_revision callback. Attach any earlier
  -- (e.g. where `sess` is first created) and it sees neither field, takes the
  -- working-tree branch for EVERY review, and a `:IntentDiff HEAD~1` review
  -- both loads and overwrites the working-tree review's comments. Here that
  -- would write the branch-keyed file and this test would fail.
  it("keys a revision-pinned review by its revisions, not by the branch", function()
    local repo = helpers.make_repo({ ["a.lua"] = table.concat(vim.fn.range(1, 40), "\n") })
    helpers.write_file(repo, "a.lua", "SECOND\n" .. table.concat(vim.fn.range(2, 40), "\n"))
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-q", "-m", "second")
    vim.cmd("cd " .. repo)

    local cache_dir = vim.fn.tempname()
    require("intentdiff").setup({
      cache_dir = cache_dir,
      provider = function(_, cb)
        vim.schedule(function() cb({ groups = {} }) end)
        return { cancel = function() end }
      end,
    })
    require("intentdiff").open("HEAD~1")
    local tab = vim.api.nvim_get_current_tabpage()
    -- The revisions and the attach land together, in one scheduled callback:
    -- once base_revision is observable from out here, attach_session has run.
    local entry = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.sess.base_revision and s or nil
    end, 10000)
    assert.truthy(entry, "the review never resolved its base revision")
    assert.equals("WORKING", entry.sess.target_revision)

    -- Adding a comment persists it under whatever key this review's store
    -- attached to.
    assert.truthy(entry.comment_store, "the review never got a comment store")
    entry.comment_store.add({ file = "a.lua", line = 2, side = "new", type = "note", text = "pinned" })

    local storage = require("intentdiff.comments.storage")
    local root = entry.sess.git_root -- codediff's resolved root, symlinks and all
    local branch = vim.trim(helpers.git(root, "rev-parse", "--abbrev-ref", "HEAD"))
    local branch_key = storage.key(root, nil, nil, branch)
    local pair_key = storage.key(root, entry.sess.base_revision, entry.sess.target_revision, nil)
    assert.are_not.equals(branch_key, pair_key, "the two keys must differ for this to mean anything")

    assert.equals(1, vim.fn.filereadable(storage.path(pair_key)),
      "a HEAD~1-pinned review must persist under its revision pair")
    assert.equals(0, vim.fn.filereadable(storage.path(branch_key)),
      "attaching before the revisions are known would key it by branch instead")

    require("intentdiff").close(tab)
  end)

  -- M.open_path is the file-opening path comments.list jumps through. Every
  -- other test stubs it, so this is the only place the real one — and the
  -- on_shown callbacks threaded into open_file and select_file — actually run.
  it("opens a file by path and reports back once it is on screen", function()
    local repo = helpers.make_repo({
      ["a.lua"] = table.concat(vim.fn.range(1, 40), "\n"),
      ["b.lua"] = "x",
    })
    helpers.write_file(repo, "a.lua", "CHANGED\n" .. table.concat(vim.fn.range(2, 40), "\n"))
    helpers.write_file(repo, "b.lua", "y")
    vim.cmd("cd " .. repo)
    require("intentdiff").setup({
      cache_dir = vim.fn.tempname(),
      provider = function(_, cb)
        vim.schedule(function()
          cb({ groups = { { title = "Both", hunk_ids = { "a.lua:1", "b.lua:1" } } } })
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

    local shown = helpers.wait_for(function()
      local s = entry.shown
      return s and s.file_entry and s.file_entry.path or nil
    end, 10000)
    assert.truthy(shown, "no file was ever auto-opened")

    -- Whichever file is NOT the one on screen.
    local other
    for _, f in ipairs(entry.model.groups[1].files) do
      if f.path ~= shown then
        other = f.path
      end
    end
    assert.truthy(other, "the fixture must group two files")

    local fired = false
    assert.is_true(require("intentdiff").open_path(tab, other, function() fired = true end))
    assert.truthy(helpers.wait_for(function() return fired or nil end, 10000),
      "on_shown never fired for a file that had to be rendered")
    assert.equals(other, entry.shown.file_entry.path)

    -- Asking again for the file now on screen takes select_file's
    -- same_as_shown short-circuit, which never calls open_file at all — its
    -- own on_shown call is the only thing that answers there.
    local again = false
    assert.is_true(require("intentdiff").open_path(tab, other, function() again = true end))
    assert.truthy(helpers.wait_for(function() return again or nil end, 10000),
      "on_shown never fired for a file that was already on screen")

    -- A path the model does not mention opens nothing and says so.
    local ghost = false
    assert.is_false(require("intentdiff").open_path(tab, "nope.lua", function() ghost = true end))
    assert.is_false(ghost)
    assert.equals(other, entry.shown.file_entry.path)

    require("intentdiff").close(tab)
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
    local st = store.new()
    st.add({ file = "a.lua", line = 2, side = "new", type = "issue", text = "x" })
    assert.is_truthy(export.generate(st.get_all(), before_model):match("## First pass"))
    assert.is_truthy(export.generate(st.get_all(), after_model):match("## Second pass"))
  end)
end)
