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

      press(entry, "r")
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
end)
