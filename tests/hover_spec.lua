local helpers = require("tests.helpers")

describe("sidebar hover preview", function()
  local repo

  local function fake_provider(groups)
    return function(_, cb)
      vim.schedule(function() cb({ groups = groups }) end)
      return { cancel = function() end }
    end
  end

  before_each(function()
    repo = helpers.make_repo({
      ["src/a.lua"] = table.concat(vim.fn.range(1, 40), "\n"),
      ["b.lua"] = "x",
    })
    helpers.write_file(repo, "src/a.lua",
      "CHANGED\n" .. table.concat(vim.fn.range(2, 39), "\n") .. "\nCHANGED")
    helpers.write_file(repo, "b.lua", "y")
    vim.cmd("cd " .. repo)
  end)

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      pcall(vim.cmd, "tabclose $")
    end
  end)

  local function open_ready(opts)
    require("intentdiff").setup(vim.tbl_extend("force", {
      cache_dir = vim.fn.tempname(),
      log_file = vim.fn.tempname() .. "/l.log",
      provider = fake_provider({ { title = "Everything", ids = "1-99" } }),
    }, opts or {}))
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local entry = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model and s.model.state == "ready" and s or nil
    end, 15000)
    assert.truthy(entry, "session never became ready")
    return tab, entry
  end

  local function line_of(entry, kind)
    for l = 1, vim.api.nvim_buf_line_count(entry.sidebar.bufnr) do
      local m = entry.sidebar.meta_at(l)
      if m and m.kind == kind then
        return l
      end
    end
  end

  local function hover(entry, lnum)
    vim.api.nvim_set_current_win(entry.sidebar.winid)
    vim.api.nvim_win_set_cursor(entry.sidebar.winid, { lnum, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = entry.sidebar.bufnr })
  end

  it("previews the whole intent when the cursor rests on a group row", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
    hover(entry, line_of(entry, "group"))
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab]
    end, 5000), "preview never activated")

    local session = require("intentdiff.view").get_session(tab)
    local text = table.concat(
      vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("src/a.lua", 1, true))
    assert.truthy(text:find("b.lua", 1, true), "every file of the intent must appear")
  end)

  it("leaves the preview when the cursor moves to a file row", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
    hover(entry, line_of(entry, "group"))
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab]
    end, 5000))

    hover(entry, line_of(entry, "file"))
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab] == nil or nil
    end, 5000), "preview must close on a file row")
  end)

  it("previews only a directory's subtree", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
    local dir_line = line_of(entry, "dir")
    assert.truthy(dir_line, "expected a directory row for src/")
    hover(entry, dir_line)
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab]
    end, 5000))

    local session = require("intentdiff.view").get_session(tab)
    local text = table.concat(
      vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("src/a.lua", 1, true))
    assert.is_nil(text:find("b.lua", 1, true),
      "a directory preview must exclude files outside it")
  end)

  it("renders once for a burst of cursor movement", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 60 } })
    local calls = 0
    local view = require("intentdiff.view")
    local real = view.show_preview
    view.show_preview = function(...)
      calls = calls + 1
      return real(...)
    end

    local group_line = line_of(entry, "group")
    for _ = 1, 6 do
      hover(entry, group_line)
    end
    helpers.wait_for(function() return view._preview_active[tab] end, 5000)
    vim.wait(300, function() return false end, 50)
    view.show_preview = real
    assert.equals(1, calls)
  end)

  it("does nothing when the preview is disabled", function()
    local tab, entry = open_ready({ preview = { enabled = false, debounce_ms = 10 } })
    hover(entry, line_of(entry, "group"))
    vim.wait(300, function() return false end, 50)
    assert.is_nil(require("intentdiff.view")._preview_active[tab])
  end)

  --- A provider that parks its callback until the test releases it, so a hover
  --- preview can be put on screen while classification is still in flight —
  --- the default first-use path (auto-open hands focus back to the sidebar,
  --- the user presses `j`, the provider answers a moment later).
  ---
  --- `release(build)` decides the grouping at release time, after the test has
  --- seen what the flat loading model actually opened, which is what makes the
  --- de-dupe and non-de-dupe completion paths selectable deterministically
  --- rather than by guessing at the inventory's file order.
  local function gated_provider()
    local pending_cb, captured
    local provider = function(request, cb)
      captured, pending_cb = request, cb
      return { cancel = function() end }
    end
    local function release(build)
      assert.truthy(pending_cb, "the provider was never called")
      local cb, request = pending_cb, captured
      pending_cb = nil
      vim.schedule(function() cb({ groups = build(request) }) end)
    end
    return provider, release
  end

  --- Open a session and stop at the flat "All changes" loading model, with
  --- auto-open having already rendered its first file into the panes.
  local function open_loading(opts)
    require("intentdiff").setup(vim.tbl_extend("force", {
      cache_dir = vim.fn.tempname(),
      log_file = vim.fn.tempname() .. "/l.log",
    }, opts or {}))
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local entry = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model and s.model.state == "loading" and s.model.groups[1] and s or nil
    end, 15000)
    assert.truthy(entry, "session never reached the flat loading model")
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._last_shown[tab]
    end, 15000), "auto-open never rendered a file")
    return tab, entry
  end

  local function preview_up(tab)
    return helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab]
    end, 5000)
  end

  --- No diff pane is running our group foldexpr and no line of any pane is
  --- folded closed. Group folds are computed from a single file's line
  --- numbers; a preview buffer is a whole intent's render, so applying them
  --- hides arbitrary content.
  local function assert_preview_unfolded(tab)
    local wins = require("intentdiff.view").diff_wins(tab)
    assert.truthy(#wins > 0, "expected at least one diff pane window")
    for _, win in ipairs(wins) do
      assert.not_equals("expr", vim.wo[win].foldmethod)
      local last = vim.api.nvim_win_call(win, function() return vim.fn.line("$") end)
      for lnum = 1, last do
        assert.equals(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(lnum) end),
          ("preview line %d of win %s is folded closed"):format(lnum, win))
      end
    end
  end

  --- The panes are still showing this tab's tracked preview buffers — i.e.
  --- nothing silently swapped a real file in behind the preview's back,
  --- leaving _preview_bufs naming orphans.
  local function assert_panes_show_preview(tab)
    local view = require("intentdiff.view")
    local bufs = view._preview_bufs[tab]
    assert.truthy(bufs and #bufs > 0, "no preview buffers are recorded for the tab")
    local tracked = {}
    for _, b in ipairs(bufs) do tracked[b] = true end
    for _, win in ipairs(view.diff_wins(tab)) do
      assert.is_true(tracked[vim.api.nvim_win_get_buf(win)] or false,
        "a diff pane is not showing a tracked preview buffer")
    end
  end

  --- The intent the sidebar cursor names is the intent the panes show — every
  --- file of it, and no file that belongs only to another intent.
  local function assert_cursor_agrees_with_panes(tab, entry)
    local view = require("intentdiff.view")
    local lnum = vim.api.nvim_win_get_cursor(entry.sidebar.winid)[1]
    local m = entry.sidebar.meta_at(lnum)
    assert.equals("group", m and m.kind)
    local expected = entry.model.groups[m.group_i]
    assert.truthy(expected, "the cursor names a group the model does not have")
    assert.equals(expected.title, (view._preview_active[tab] or {}).title)

    local shown = {}
    for _, f in ipairs(expected.files) do shown[f.path] = true end
    local session = view.get_session(tab)
    local text = table.concat(
      vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false), "\n")
    for path in pairs(shown) do
      assert.truthy(text:find(path, 1, true),
        ("the panes must show %s, a file of the intent under the cursor"):format(path))
    end
    for _, g in ipairs(entry.model.groups) do
      for _, f in ipairs(g.files) do
        if not shown[f.path] then
          assert.is_nil(text:find(f.path, 1, true),
            ("%s belongs to another intent and must not be on screen"):format(f.path))
        end
      end
    end
  end

  --- Invoke a sidebar keymap by its callback, so a test never depends on
  --- feedkeys timing or on where the cursor happens to be.
  local function press(entry, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(entry.sidebar.bufnr, "n")) do
      if map.lhs == lhs and map.callback then
        return map.callback()
      end
    end
    error("no sidebar mapping for " .. lhs)
  end

  describe("classification completing while a preview is up", function()
    it("keeps the preview unfolded when the new grouping re-opens the same file", function()
      -- De-dupe path: the single classified group's first file IS the flat
      -- model's first file with the same hunks, so classify_and_render used to
      -- take the same_as_shown branch and apply group folds — to the PREVIEW's
      -- buffers, which were what the panes actually held.
      local provider, release = gated_provider()
      local tab, entry = open_loading({
        provider = provider,
        preview = { enabled = true, debounce_ms = 10 },
      })
      hover(entry, line_of(entry, "group"))
      assert.truthy(preview_up(tab), "preview never activated")

      release(function(request)
        local all = {}
        for _, h in ipairs(request.hunks) do all[#all + 1] = h.n end
        return { { title = "Everything", ids = table.concat(all, ",") } }
      end)
      assert.truthy(helpers.wait_for(function()
        return entry.model.state == "ready" or nil
      end, 15000), "classification never completed")
      vim.wait(300, function() return false end, 20)

      assert.truthy(require("intentdiff.view")._preview_active[tab],
        "the preview must survive classification")
      assert_preview_unfolded(tab)
      assert_panes_show_preview(tab)
      assert_cursor_agrees_with_panes(tab, entry)
    end)

    it("keeps the preview instead of auto-opening a file over it", function()
      -- Non-de-dupe path: the new first group deliberately excludes the file
      -- auto-open put on screen, so classify_and_render used to fall through
      -- to open_file → show_file, silently replacing the preview while
      -- _preview_active stayed truthy and the sidebar cursor still named a
      -- group row.
      local provider, release = gated_provider()
      local tab, entry = open_loading({
        provider = provider,
        preview = { enabled = true, debounce_ms = 10 },
      })
      local shown_path = require("intentdiff.view")._last_shown[tab].file_entry.path
      hover(entry, line_of(entry, "group"))
      assert.truthy(preview_up(tab), "preview never activated")

      release(function(request)
        local others, same = {}, {}
        for _, h in ipairs(request.hunks) do
          local into = h.file ~= shown_path and others or same
          into[#into + 1] = h.n
        end
        assert.truthy(#others > 0, "fixture must have a second file")
        return {
          { title = "Other file", ids = table.concat(others, ",") },
          { title = "Opened file", ids = table.concat(same, ",") },
        }
      end)
      assert.truthy(helpers.wait_for(function()
        return entry.model.state == "ready" or nil
      end, 15000), "classification never completed")
      vim.wait(300, function() return false end, 20)

      local view = require("intentdiff.view")
      assert.truthy(view._preview_active[tab], "the preview must not be replaced by a file")
      assert_panes_show_preview(tab)
      assert_preview_unfolded(tab)
      -- The point of the whole fix: the panes show the intent the cursor is
      -- on, re-derived from the NEW grouping, not the flat one it was
      -- rendered from a moment ago.
      assert_cursor_agrees_with_panes(tab, entry)
      assert.equals("Other file", view._preview_active[tab].title)
    end)

    it("re-points the deferred restore at the newly classified folds", function()
      -- The last-shown file is off screen while previewing, so its refold has
      -- to be deferred rather than applied to the preview's buffers.
      local provider, release = gated_provider()
      local tab, entry = open_loading({
        provider = provider,
        preview = { enabled = true, debounce_ms = 10 },
      })
      local view = require("intentdiff.view")
      local shown_path = view._last_shown[tab].file_entry.path
      local flat_entry = view._last_shown[tab].file_entry
      hover(entry, line_of(entry, "group"))
      assert.truthy(preview_up(tab), "preview never activated")

      -- One hunk of the opened file in its own group, so its classified hunk
      -- set is strictly smaller than the flat "All changes" one.
      release(function(request)
        local first, rest = nil, {}
        for _, h in ipairs(request.hunks) do
          if h.file == shown_path and not first then
            first = h.n
          else
            rest[#rest + 1] = h.n
          end
        end
        return {
          { title = "One hunk", ids = tostring(first) },
          { title = "The rest", ids = table.concat(rest, ",") },
        }
      end)
      assert.truthy(helpers.wait_for(function()
        return entry.model.state == "ready" or nil
      end, 15000))
      vim.wait(300, function() return false end, 20)

      -- The entry the first classified group holding this path now carries —
      -- refold_shown_file resolves the same way, first group wins.
      local classified
      for _, g in ipairs(entry.model.groups) do
        for _, f in ipairs(g.files) do
          if f.path == shown_path and not classified then
            classified = f
          end
        end
      end
      assert.truthy(classified, "reconcile must place the shown file in some group")

      local pending = view._last_shown[tab]
      assert.equals(shown_path, pending.file_entry.path)
      assert.equals(classified, pending.file_entry,
        "the deferred restore must carry the classified group's file entry, "
        .. "not the flat 'All changes' one it was opened with")
      assert.not_equals(flat_entry, pending.file_entry)
    end)

    it("survives a reclassify raised from a group row", function()
      -- `r` re-enters classify_and_render, which renders the flat loading
      -- model and calls auto_open_first again — with the preview still on
      -- screen. Both of that call's branches used to reach the preview's
      -- buffers.
      local provider, release = gated_provider()
      local tab, entry = open_loading({
        provider = provider,
        preview = { enabled = true, debounce_ms = 10 },
      })
      release(function(request)
        local all = {}
        for _, h in ipairs(request.hunks) do all[#all + 1] = h.n end
        return { { title = "First pass", ids = table.concat(all, ",") } }
      end)
      assert.truthy(helpers.wait_for(function()
        return entry.model.state == "ready" or nil
      end, 15000))

      hover(entry, line_of(entry, "group"))
      assert.truthy(preview_up(tab), "preview never activated")

      press(entry, require("intentdiff.config").options.keymaps.sidebar.reclassify)
      assert.truthy(helpers.wait_for(function()
        return entry.model.state == "loading" or nil
      end, 5000), "reclassify never re-entered the loading model")
      vim.wait(300, function() return false end, 20)
      assert.truthy(require("intentdiff.view")._preview_active[tab],
        "the preview must survive the loading phase of a reclassify")
      assert_preview_unfolded(tab)
      assert_panes_show_preview(tab)

      release(function(request)
        local all = {}
        for _, h in ipairs(request.hunks) do all[#all + 1] = h.n end
        return { { title = "Second pass", ids = table.concat(all, ",") } }
      end)
      assert.truthy(helpers.wait_for(function()
        return entry.model.state == "ready" or nil
      end, 15000))
      vim.wait(300, function() return false end, 20)

      assert_preview_unfolded(tab)
      assert_panes_show_preview(tab)
      assert_cursor_agrees_with_panes(tab, entry)
      assert.equals("Second pass", require("intentdiff.view")._preview_active[tab].title)
    end)
  end)

  describe("session teardown", function()
    it("tears down every timer and autocmd when the session ends", function()
      -- Named global constraint: nothing a session armed may outlive it.
      local provider = gated_provider() -- never released: classification stays in flight
      local tab, entry = open_loading({
        provider = provider,
        -- Long enough that the timer is still armed when the session closes,
        -- short enough that it would have fired inside the wait below.
        preview = { enabled = true, debounce_ms = 800 },
      })
      local view = require("intentdiff.view")
      local calls = 0
      local real = view.show_preview
      view.show_preview = function(...)
        calls = calls + 1
        return real(...)
      end
      local ok, err = pcall(function()
        local sidebar_buf = entry.sidebar.bufnr
        hover(entry, line_of(entry, "group")) -- arms the debounce timer
        assert.truthy(entry.hover_timer, "hover timer must be armed")
        assert.truthy(entry.elapsed_timer, "elapsed timer must run while classifying")
        local augroup = entry.hover_augroup
        assert.truthy(augroup, "hover augroup must be installed")
        assert.truthy(#vim.api.nvim_get_autocmds({ group = augroup }) > 0)

        require("intentdiff").close(tab)

        assert.is_nil(require("intentdiff")._session(tab))
        assert.is_nil(entry.hover_timer, "hover timer must be cleared")
        assert.is_nil(entry.elapsed_timer, "elapsed timer must be cleared")
        assert.is_false((pcall(vim.api.nvim_get_autocmds, { group = augroup })),
          "the hover augroup must be gone")
        if vim.api.nvim_buf_is_valid(sidebar_buf) then
          vim.api.nvim_exec_autocmds("CursorMoved", { buffer = sidebar_buf })
        end
        -- Past both the 800ms debounce and the 1s elapsed tick: neither may
        -- fire once the session is gone.
        vim.wait(1500, function() return false end, 50)
        assert.equals(0, calls, "no preview may render after the session closed")
      end)
      view.show_preview = real
      assert.is_true(ok, tostring(err))
    end)
  end)

  describe("cursor opens files", function()
    local function file_rows(entry)
      local rows = {}
      for l = 1, vim.api.nvim_buf_line_count(entry.sidebar.bufnr) do
        local m = entry.sidebar.meta_at(l)
        if m and m.kind == "file" then
          rows[#rows + 1] = { lnum = l, group_i = m.group_i, file_i = m.file_i }
        end
      end
      return rows
    end

    it("renders the hovered file's diff and keeps focus in the sidebar", function()
      local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
      local rows = file_rows(entry)
      assert.is_true(#rows >= 1)
      hover(entry, rows[1].lnum)

      local path = entry.model.groups[rows[1].group_i].files[rows[1].file_i].path
      assert.truthy(helpers.wait_for(function()
        local shown = require("intentdiff.view")._last_shown[tab]
        return shown and shown.file_entry.path == path or nil
      end, 10000), "hovered file was never rendered")
      assert.is_nil(require("intentdiff.view")._preview_active[tab])
      -- Focus returns to the sidebar asynchronously, in show_file's on_ready
      -- (see open_file's restore_focus handling) — strictly later than
      -- _last_shown above, which show_file sets synchronously at its top,
      -- before codediff's cd.view.update() has had a chance to steal focus
      -- onto a diff pane. Asserting the window immediately after the
      -- _last_shown wait is racy; wait on the focus condition itself, same
      -- pattern as the pre-existing auto-open focus-restore assertion in
      -- integration_spec.lua.
      assert.truthy(helpers.wait_for(function()
        return vim.api.nvim_get_current_win() == entry.sidebar.winid or nil
      end, 10000), "focus never returned to the sidebar")
    end)

    it("re-renders when the cursor moves to a different file row", function()
      local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
      local rows = file_rows(entry)
      assert.is_true(#rows >= 2, "fixture must have two file rows")
      local function path_of(r)
        return entry.model.groups[r.group_i].files[r.file_i].path
      end
      assert.not_equals(path_of(rows[1]), path_of(rows[2]))

      hover(entry, rows[1].lnum)
      assert.truthy(helpers.wait_for(function()
        local s = require("intentdiff.view")._last_shown[tab]
        return s and s.file_entry.path == path_of(rows[1]) or nil
      end, 10000))

      hover(entry, rows[2].lnum)
      assert.truthy(helpers.wait_for(function()
        local s = require("intentdiff.view")._last_shown[tab]
        return s and s.file_entry.path == path_of(rows[2]) or nil
      end, 10000), "moving between file rows must re-render (per-file de-dupe key)")
    end)

    it("leaves the preview when moving from a group row to a file row", function()
      local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
      hover(entry, line_of(entry, "group"))
      assert.truthy(helpers.wait_for(function()
        return require("intentdiff.view")._preview_active[tab]
      end, 10000))
      hover(entry, file_rows(entry)[1].lnum)
      assert.truthy(helpers.wait_for(function()
        return require("intentdiff.view")._preview_active[tab] == nil or nil
      end, 10000))
    end)

    it("restores instead of opening when hover_opens_files is false", function()
      local tab, entry = open_ready({
        preview = { enabled = true, debounce_ms = 10, hover_opens_files = false },
      })
      local before = require("intentdiff.view")._last_shown[tab]
      hover(entry, file_rows(entry)[1].lnum)
      vim.wait(400, function() return false end, 50)
      local after = require("intentdiff.view")._last_shown[tab]
      assert.equals(before and before.file_entry.path, after and after.file_entry.path)
    end)
  end)

  describe("<CR> jumps into the diff", function()
    local function first_file_row(entry)
      for l = 1, vim.api.nvim_buf_line_count(entry.sidebar.bufnr) do
        local m = entry.sidebar.meta_at(l)
        if m and m.kind == "file" then return l end
      end
    end

    local function press_cr(entry, lnum)
      vim.api.nvim_set_current_win(entry.sidebar.winid)
      vim.api.nvim_win_set_cursor(entry.sidebar.winid, { lnum, 0 })
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    end

    local function row_for(entry, group_i, file_i)
      for l = 1, vim.api.nvim_buf_line_count(entry.sidebar.bufnr) do
        local m = entry.sidebar.meta_at(l)
        if m and m.kind == "file" and m.group_i == group_i and m.file_i == file_i then
          return l
        end
      end
    end

    it("moves focus into the diff pane without re-rendering an already-shown file", function()
      local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
      local lnum = first_file_row(entry)
      local m = entry.sidebar.meta_at(lnum)
      local path = entry.model.groups[m.group_i].files[m.file_i].path
      hover(entry, lnum)
      -- Wait for THIS row's file specifically, not just "some" _last_shown:
      -- auto_open (on by default) already renders group 1/file 1 the instant
      -- the session goes ready, and in this fixture that is "b.lua" while
      -- first_file_row's row (nested under the "src" dir header) is
      -- "src/a.lua" — a bare `_last_shown[tab] ~= nil` check is already true
      -- from auto-open before the hover's own debounce timer ever fires, so
      -- it would let press_cr race ahead of hover's render instead of
      -- catching the already-shown short-circuit this test exists to verify.
      assert.truthy(helpers.wait_for(function()
        local shown = require("intentdiff.view")._last_shown[tab]
        return shown and shown.file_entry.path == path or nil
      end, 10000))
      -- _last_shown's path flips synchronously at the TOP of show_file, before
      -- codediff has actually swapped session.modified_bufnr onto the new
      -- file's diff buffer (that happens off a callback show_file's own
      -- on_ready — here, hover's restore_focus — only runs after). Also wait
      -- for focus to land back on the sidebar (hover's open_file call passes
      -- restore_focus = true) so "before" is captured once the render is
      -- actually settled, not mid-flight.
      assert.truthy(helpers.wait_for(function()
        return vim.api.nvim_get_current_win() == entry.sidebar.winid or nil
      end, 10000), "hover's render never settled (focus never returned to the sidebar)")

      -- Buffer-number equality cannot prove "did not re-render": codediff
      -- reuses the same bufnr for the same path, so comparing
      -- session.modified_bufnr before/after would pass even against code
      -- that unconditionally re-renders. Spy on view.show_file instead and
      -- require exactly zero calls.
      local view = require("intentdiff.view")
      local real_show_file = view.show_file
      local calls = 0
      view.show_file = function(...)
        calls = calls + 1
        return real_show_file(...)
      end
      local ok, err = pcall(function()
        press_cr(entry, lnum)
        vim.wait(500, function() return false end, 50)
        assert.equals(0, calls, "already-shown file must not re-render (show_file was called)")

        local session = require("intentdiff.view").get_session(tab)
        -- Focus-change timing depends on which path was taken: the
        -- short-circuit moves focus synchronously inside select_file, but if
        -- this assertion ever runs against a real render instead, on_ready's
        -- focus_diff_pane call is asynchronous — wait rather than assert
        -- bare-equals immediately.
        assert.truthy(helpers.wait_for(function()
          return session.modified_win == vim.api.nvim_get_current_win() or nil
        end, 10000))
      end)
      view.show_file = real_show_file
      assert.is_true(ok, tostring(err))
    end)

    it("renders and focuses a file that was not shown yet", function()
      local tab, entry = open_ready({
        preview = { enabled = true, debounce_ms = 10, hover_opens_files = false },
      })
      local lnum = first_file_row(entry)
      local m = entry.sidebar.meta_at(lnum)
      local path = entry.model.groups[m.group_i].files[m.file_i].path

      press_cr(entry, lnum)
      assert.truthy(helpers.wait_for(function()
        local s = require("intentdiff.view")._last_shown[tab]
        return s and s.file_entry.path == path or nil
      end, 10000))
      local session = require("intentdiff.view").get_session(tab)
      -- _last_shown is set synchronously at the top of show_file, strictly
      -- BEFORE show_file's on_ready moves focus (see open_file's opts.focus_diff
      -- handling) — asserting focus immediately after the wait above is racy.
      assert.truthy(helpers.wait_for(function()
        return session.modified_win == vim.api.nvim_get_current_win() or nil
      end, 10000))
    end)

    it("renders the file instead of leaving a hover preview on screen", function()
      -- Regression test: same_as_shown reads view._last_shown, which a hover
      -- PREVIEW never touches (show_preview swaps the pane buffers without
      -- updating it). With a preview up, _last_shown still names whatever
      -- file was rendered before the preview took over — auto_open (on by
      -- default) already rendered group1/file1 by the time open_ready
      -- returns — so without a _preview_active guard, pressing <CR> on that
      -- SAME row would take the pure-focus short-circuit and move focus INTO
      -- the preview buffer, never actually rendering the file. Reachable on
      -- defaults just by landing on a file row and pressing <CR> before its
      -- hover debounce fires.
      local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
      local shown = require("intentdiff.view")._last_shown[tab]
      assert.truthy(shown, "auto-open never rendered a file")

      hover(entry, line_of(entry, "group"))
      assert.truthy(helpers.wait_for(function()
        return require("intentdiff.view")._preview_active[tab]
      end, 10000), "preview never activated")
      local preview_bufs_before = vim.deepcopy(require("intentdiff.view")._preview_bufs[tab] or {})
      assert.truthy(#preview_bufs_before > 0, "expected preview buffers to be tracked")

      -- The SAME file/hunks the row names is what auto-open already rendered
      -- (group 1 / file 1) — exactly the same_as_shown match that must be
      -- suppressed while the preview owns the panes.
      local lnum = row_for(entry, 1, 1)
      assert.truthy(lnum, "no sidebar row for the auto-opened file")
      press_cr(entry, lnum)

      assert.truthy(helpers.wait_for(function()
        return require("intentdiff.view")._preview_active[tab] == nil or nil
      end, 10000), "preview must be cleared once the file actually renders")

      local session = require("intentdiff.view").get_session(tab)
      assert.truthy(helpers.wait_for(function()
        return session.modified_win == vim.api.nvim_get_current_win() or nil
      end, 10000))
      local cur_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
      for _, b in ipairs(preview_bufs_before) do
        assert.not_equals(b, cur_buf, "focus landed inside a preview buffer")
      end

      -- The pane must show the FILE's own diff (a real codediff buffer, named
      -- after the file), not a leftover preview scratch buffer's content —
      -- checked by name rather than by grepping the buffer text, since a real
      -- diff pane's content is the file's lines, which need not contain its
      -- own path anywhere.
      local buf_name = vim.api.nvim_buf_get_name(session.modified_bufnr)
      assert.truthy(buf_name:find(shown.file_entry.path, 1, true),
        ("modified pane must show %s, got buffer named %s"):format(
          shown.file_entry.path, buf_name))
      assert.truthy(helpers.wait_for(function()
        local s = require("intentdiff.view")._last_shown[tab]
        return s and s.file_entry.path == shown.file_entry.path or nil
      end, 10000), "_last_shown must reflect the actually-rendered file")
    end)

    describe("render_seq (deterministic)", function()
      --- Stub view.show_file to CAPTURE each call (file_entry + opts) instead
      --- of letting it actually render, mirroring the one synchronous side
      --- effect same_as_shown depends on (_last_shown). Gives full manual
      --- control over WHEN a render's on_ready fires — real timing can't
      --- reliably produce "hover's on_ready fires strictly AFTER a same-row
      --- <CR> already ran" on demand, and (see integration_spec.lua's
      --- "does not attach a stale ctx..." test) is sometimes structurally
      --- unable to produce a required ordering at all.
      local function stub_show_file()
        local view = require("intentdiff.view")
        local real_show_file = view.show_file
        local pending = {}
        view.show_file = function(sess, file_entry, opts)
          view._last_shown[sess.tabpage] = { sess = sess, file_entry = file_entry }
          pending[#pending + 1] = { file_entry = file_entry, opts = opts }
        end
        return pending, function() view.show_file = real_show_file end
      end

      it("a same-row <CR> wins over a still-pending hover render's own focus restore", function()
        local pending, restore = stub_show_file()
        local ok, err = pcall(function()
          local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
          -- auto_open_first's own open_file({auto=true}) call is captured
          -- here too (group 1/file 1); irrelevant to this test, just the
          -- first entry in `pending`.
          local lnum = first_file_row(entry)
          local m = entry.sidebar.meta_at(lnum)
          local path = entry.model.groups[m.group_i].files[m.file_i].path

          hover(entry, lnum)
          -- The hover's own open_file(..., {restore_focus = true}) call goes
          -- through the SAME stub — wait for it to have been captured (the
          -- real debounce timer still fires for real, just show_file itself
          -- no longer renders). show_file's own opts (captured here) only
          -- ever carries on_ready — opts.restore_focus lives on open_file's
          -- OWN parameter and is only reachable via the on_ready closure, so
          -- identify the hover's call by path instead.
          assert.truthy(helpers.wait_for(function()
            return pending[#pending] and pending[#pending].file_entry.path == path or nil
          end, 5000), "hover's open_file() call for this row was never captured")
          local hover_call = pending[#pending]

          -- <CR> on the SAME row: same_as_shown matches (view._last_shown was
          -- set by the stub above), so this takes the short-circuit —
          -- bumping entry.render_seq and moving focus into the diff pane
          -- synchronously, without a new show_file() call.
          local before_count = #pending
          press_cr(entry, lnum)
          assert.equals(before_count, #pending,
            "the short-circuit must not have called show_file() again")

          local session = require("intentdiff.view").get_session(tab)
          local win_after_cr = vim.api.nvim_get_current_win()
          assert.equals(session.modified_win, win_after_cr,
            "the <CR> short-circuit must have moved focus into the diff pane")

          -- NOW fire the hover's STALE on_ready — simulating it arriving
          -- late, after the <CR> already made its own, newer focus decision.
          assert.truthy(hover_call.opts.on_ready, "hover's open_file() call had no on_ready")
          hover_call.opts.on_ready()

          -- Focus must still be in the diff pane: is_latest must be false
          -- for this stale call, so it must not have restored focus to the
          -- sidebar.
          assert.equals(win_after_cr, vim.api.nvim_get_current_win(),
            "a stale hover on_ready must not yank focus back to the sidebar "
              .. "once a newer <CR> has already moved it into the diff pane")
        end)
        restore()
        assert.is_true(ok, tostring(err))
      end)

      it("a lone in-flight hover render with nothing newer still restores focus to the sidebar", function()
        local pending, restore = stub_show_file()
        local ok, err = pcall(function()
          local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
          local lnum = first_file_row(entry)
          local m = entry.sidebar.meta_at(lnum)
          local path = entry.model.groups[m.group_i].files[m.file_i].path

          hover(entry, lnum)
          assert.truthy(helpers.wait_for(function()
            return pending[#pending] and pending[#pending].file_entry.path == path or nil
          end, 5000), "hover's open_file() call for this row was never captured")
          local hover_call = pending[#pending]

          -- Nothing newer happens — no <CR>, no second selection. Move focus
          -- away from the sidebar first so firing on_ready is the only thing
          -- that could put it back, making the assertion below meaningful.
          local session = require("intentdiff.view").get_session(tab)
          vim.api.nvim_set_current_win(session.modified_win)
          assert.not_equals(entry.sidebar.winid, vim.api.nvim_get_current_win())

          assert.truthy(hover_call.opts.on_ready, "hover's open_file() call had no on_ready")
          hover_call.opts.on_ready()

          -- is_latest must be TRUE here (render_seq was never bumped by
          -- anything else) — the restore-to-sidebar tail must still run.
          -- This is the guard against render_seq gating too much: a fix that
          -- always skips the tail would also break this.
          assert.equals(entry.sidebar.winid, vim.api.nvim_get_current_win(),
            "a hover render with nothing newer must still restore focus to the sidebar")
        end)
        restore()
        assert.is_true(ok, tostring(err))
      end)
    end)
  end)

  --- Every file row of the sidebar, in buffer order, resolved against the
  --- CURRENT model (the loading model's rows and the classified model's rows
  --- are both valid inputs — meta_at is regenerated on every redraw).
  local function file_rows_with_paths(entry)
    local rows = {}
    for l = 1, vim.api.nvim_buf_line_count(entry.sidebar.bufnr) do
      local m = entry.sidebar.meta_at(l)
      if m and m.kind == "file" then
        local f = entry.model.groups[m.group_i].files[m.file_i]
        rows[#rows + 1] = { lnum = l, group_i = m.group_i, file_i = m.file_i, path = f.path }
      end
    end
    return rows
  end

  --- The sidebar row for a file OTHER than the one auto-open has already put
  --- in the panes — i.e. one whose flat-model file_i is not 1, which is what
  --- makes navigation.update_model's clamp-to-1 observable.
  local function other_file_row(entry, shown_path)
    for _, r in ipairs(file_rows_with_paths(entry)) do
      if r.path ~= shown_path then
        return r
      end
    end
  end

  --- Split the diff into one group per file, with `path`'s hunks in the
  --- SECOND group — so the hovered file moves from (group 1, file 2) in the
  --- flat "All changes" model to (group 2, file 1) in the classified one.
  local function two_groups_isolating(path)
    return function(request)
      local mine, theirs = {}, {}
      for _, h in ipairs(request.hunks) do
        local into = h.file == path and mine or theirs
        into[#into + 1] = h.n
      end
      assert.is_true(#mine > 0 and #theirs > 0, "fixture must span two files")
      return {
        { title = "Other file", ids = table.concat(theirs, ",") },
        { title = "Hovered file", ids = table.concat(mine, ",") },
      }
    end
  end

  describe("the navigation context follows the cursor", function()
    --- Two files whose hunks sit at unmistakably different lines AND whose
    --- lengths differ: the short file's buffer cannot even hold the long
    --- file's second hunk line, so a ]c driven from the wrong file's hunk list
    --- either lands on a visibly wrong line or cannot move at all.
    ---   long.lua  — 200 lines, hunks at 5 and 150
    ---   short.lua —  60 lines, hunks at 10 and 50
    local function make_two_file_repo()
      local long, short = {}, {}
      for i = 1, 200 do long[i] = "long " .. i end
      for i = 1, 60 do short[i] = "short " .. i end
      local r = helpers.make_repo({
        ["long.lua"] = table.concat(long, "\n"),
        ["short.lua"] = table.concat(short, "\n"),
      })
      long[5], long[150] = "CHANGED 5", "CHANGED 150"
      short[10], short[50] = "CHANGED 10", "CHANGED 50"
      helpers.write_file(r, "long.lua", table.concat(long, "\n"))
      helpers.write_file(r, "short.lua", table.concat(short, "\n"))
      vim.cmd("cd " .. r)
      return r
    end

    --- The buffer-local ]c installed on `buf`, asserted to be OURS: codediff
    --- reinstalls its own all-hunks version at the end of every render, and
    --- that one would happily jump to the right line for the wrong reason.
    local function our_next_hunk(buf)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if m.lhs == "]c" then
          assert.truthy((m.desc or ""):find("intent-diff", 1, true),
            "]c is not intent-diff's group-scoped mapping: " .. tostring(m.desc))
          assert.truthy(m.callback, "]c has no Lua callback")
          return m.callback
        end
      end
      error("no ]c mapping on the modified pane")
    end

    it("drives ]c from the file the cursor opened, after classification re-groups it", function()
      -- The whole reported sequence, on default settings, cursor only, no
      -- <CR>: moving onto a file row during the loading phase renders it AND
      -- sets user_selected (apply_hover), which routes classification
      -- completion through refold_shown_file. That branch re-folds the shown
      -- file; navigation.update_model, which ran just before it, has already
      -- clamped the stale flat-model file_i to 1. Without refold_shown_file
      -- also re-pointing the ctx, ]c then plans against a file the panes are
      -- not showing.
      make_two_file_repo()
      local provider, release = gated_provider()
      local tab, entry = open_loading({
        provider = provider,
        preview = { enabled = true, debounce_ms = 10 },
      })
      local view = require("intentdiff.view")
      local row = other_file_row(entry, view._last_shown[tab].file_entry.path)
      assert.truthy(row, "no sidebar row for a second file")
      local hovered = row.path

      hover(entry, row.lnum)
      assert.truthy(helpers.wait_for(function()
        local s = view._last_shown[tab]
        return s and s.file_entry.path == hovered or nil
      end, 15000), "the hovered file was never rendered")
      -- Let the hover's own render SETTLE before releasing the provider (its
      -- on_ready is what restores focus to the sidebar). That pins the
      -- ordering this test is about: the ctx is attached against the flat
      -- model first, and the classification then has to fix it up — rather
      -- than the render landing afterwards and fixing itself up.
      assert.truthy(helpers.wait_for(function()
        return vim.api.nvim_get_current_win() == entry.sidebar.winid or nil
      end, 15000), "the hover render never settled")
      assert.is_true(entry.user_selected == true,
        "hovering a file row must mark the selection (the branch under test)")

      release(two_groups_isolating(hovered))
      assert.truthy(helpers.wait_for(function()
        return entry.model.state == "ready" or nil
      end, 15000), "classification never completed")
      vim.wait(300, function() return false end, 20)
      assert.equals(hovered, entry.model.groups[2].files[1].path,
        "the classified model must put the hovered file at group 2 / file 1")

      local session = view.get_session(tab)
      local win = session.modified_win
      assert.truthy(vim.api.nvim_buf_get_name(session.modified_bufnr):find(hovered, 1, true),
        "the panes must still be showing the hovered file")

      -- Line 20 sits after each file's first hunk and before its second (hunk
      -- start lines carry git's 3 lines of leading context, so they are a few
      -- lines below the changed line itself — read them from the model rather
      -- than hard-coding). The correct answer is the SHOWN file's next hunk;
      -- the stale ctx names the other file, whose next hunk is either past
      -- the end of this buffer (short.lua shown) or simply a different line
      -- (long.lua shown).
      local function next_after(file_entry, line)
        for _, h in ipairs(file_entry.hunks) do
          if h.modified.start_line > line then
            return h.modified.start_line
          end
        end
      end
      local expected = next_after(entry.model.groups[2].files[1], 20)
      local stale = next_after(entry.model.groups[1].files[1], 20)
      assert.truthy(expected, "the shown file must have a hunk below line 20")
      assert.not_equals(stale, expected,
        "fixture is not discriminating: both files' next hunk is the same line")

      local next_hunk = our_next_hunk(session.modified_bufnr)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { 20, 0 })
      local ok, err = pcall(next_hunk)
      assert.is_true(ok, "]c errored: " .. tostring(err))
      assert.equals(expected, vim.api.nvim_win_get_cursor(win)[1])
    end)

    --- Capture show_file() calls instead of rendering, mirroring the one
    --- synchronous side effect the identity gate reads (_last_shown), so a
    --- render's on_ready can be fired at a chosen moment. Real timing cannot
    --- produce "an older render lands after a newer one has taken the panes"
    --- on demand — codediff's when_diff_ready stops matching once the
    --- session's paths move on, so the older poll just gives up silently
    --- (see integration_spec's "does not attach a stale ctx" for the full
    --- account).
    local function stub_show_file()
      local view = require("intentdiff.view")
      local real = view.show_file
      local pending = {}
      view.show_file = function(sess, file_entry, opts)
        view._last_shown[sess.tabpage] = { sess = sess, file_entry = file_entry }
        pending[#pending + 1] = { file_entry = file_entry, opts = opts }
      end
      return pending, function() view.show_file = real end
    end

    local function spy_attach()
      local navigation = require("intentdiff.navigation")
      local real = navigation.attach
      local calls = {}
      navigation.attach = function(tabpage, ctx)
        calls[#calls + 1] = { group_i = ctx.group_i, file_i = ctx.file_i, model = ctx.model }
        return real(tabpage, ctx)
      end
      return calls, function() navigation.attach = real end
    end

    it("ignores a hover render whose on_ready lands after a newer hover took the panes", function()
      -- A hover render is not an auto-open, so the old opts.auto-only
      -- superseded/still_current bail never applied to it and its attach ran
      -- unconditionally — installing indices for a file that is no longer on
      -- screen. Widest for "A"/"D" virtual files, whose on_ready fires from a
      -- buffer-scoped User autocmd rather than from a path-matched poll.
      local pending, restore_show = stub_show_file()
      local attach_calls, restore_attach = spy_attach()
      local ok, err = pcall(function()
        local _, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
        local rows = file_rows_with_paths(entry)
        assert.is_true(#rows >= 2, "fixture must have two file rows")
        assert.not_equals(rows[1].path, rows[2].path)

        hover(entry, rows[1].lnum)
        assert.truthy(helpers.wait_for(function()
          return pending[#pending] and pending[#pending].file_entry.path == rows[1].path or nil
        end, 5000), "the first hover's show_file() call was never captured")
        local older = pending[#pending]

        hover(entry, rows[2].lnum)
        assert.truthy(helpers.wait_for(function()
          return pending[#pending] and pending[#pending].file_entry.path == rows[2].path or nil
        end, 5000), "the second hover's show_file() call was never captured")
        local newer = pending[#pending]

        local before = #attach_calls
        older.opts.on_ready()
        assert.equals(before, #attach_calls,
          "a hover render the panes have moved on from must not attach its ctx")

        -- ...and the render that IS on screen still attaches, so the
        -- assertion above cannot be satisfied by never attaching at all.
        newer.opts.on_ready()
        assert.equals(before + 1, #attach_calls,
          "the render that is on screen must attach its ctx")
        assert.equals(rows[2].group_i, attach_calls[#attach_calls].group_i)
        assert.equals(rows[2].file_i, attach_calls[#attach_calls].file_i)
      end)
      restore_show()
      restore_attach()
      assert.is_true(ok, tostring(err))
    end)

    it("attaches the shown file's position in the model that exists when the render lands", function()
      -- The other half of the same hazard: nothing newer took the panes, but
      -- a classification replaced the model between show_file() and its
      -- on_ready. The group_i/file_i the call was made with index into a
      -- model that no longer exists.
      local provider, release = gated_provider()
      local pending, restore_show = stub_show_file()
      local attach_calls, restore_attach = spy_attach()
      local ok, err = pcall(function()
        local tab, entry = open_loading({
          provider = provider,
          preview = { enabled = true, debounce_ms = 10 },
        })
        local view = require("intentdiff.view")
        local row = other_file_row(entry, view._last_shown[tab].file_entry.path)
        assert.truthy(row, "no sidebar row for a second file")
        assert.equals(2, row.file_i, "the hovered file must be file 2 of the flat group")

        hover(entry, row.lnum)
        assert.truthy(helpers.wait_for(function()
          return pending[#pending] and pending[#pending].file_entry.path == row.path or nil
        end, 5000), "the hover's show_file() call was never captured")
        local in_flight = pending[#pending]

        release(two_groups_isolating(row.path))
        assert.truthy(helpers.wait_for(function()
          return entry.model.state == "ready" or nil
        end, 15000), "classification never completed")
        assert.equals(row.path, entry.model.groups[2].files[1].path)

        local before = #attach_calls
        in_flight.opts.on_ready()
        assert.equals(before + 1, #attach_calls, "the render on screen must attach its ctx")
        local last = attach_calls[#attach_calls]
        assert.equals(entry.model, last.model, "the ctx must carry the current model")
        assert.equals(2, last.group_i,
          "the ctx must name the shown file's position in the CURRENT model, "
            .. "not the flat model's (group 1, file 2)")
        assert.equals(1, last.file_i)
      end)
      restore_show()
      restore_attach()
      assert.is_true(ok, tostring(err))
    end)
  end)
end)
