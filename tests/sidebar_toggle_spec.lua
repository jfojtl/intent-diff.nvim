local helpers = require("tests.helpers")

describe("sidebar show/hide", function()
  local repo

  local function fake_provider(groups)
    return function(_, cb)
      vim.schedule(function() cb({ groups = groups }) end)
      return { cancel = function() end }
    end
  end

  --- A provider whose grouping changes on each successive call — the first
  --- call is the initial `:IntentDiff` classification, later calls are
  --- reclassifies (`r`). Used to prove a preview actually RE-DERIVES from a
  --- fresh model, rather than merely surviving without erroring.
  local function fake_provider_sequence(list)
    local i = 0
    return function(_, cb)
      i = i + 1
      local groups = list[i] or list[#list]
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

  --- Invoke a sidebar buffer-local keymap by its callback rather than via
  --- feedkeys: buffer-local keymaps live on the BUFFER, not the window, so
  --- this still works when the sidebar window is closed (hidden) — which is
  --- exactly the scenario several tests below need to drive.
  local function press(entry, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(entry.sidebar.bufnr, "n")) do
      if map.lhs == lhs and map.callback then
        return map.callback()
      end
    end
    error("no sidebar mapping for " .. lhs)
  end

  it("hides and shows without disturbing the diff panes", function()
    local tab, entry = open_ready()
    helpers.wait_for(function()
      return require("intentdiff.view")._last_shown[tab] ~= nil or nil
    end, 10000)
    local session = require("intentdiff.view").get_session(tab)
    local orig_buf, mod_buf = session.original_bufnr, session.modified_bufnr
    local bufnr = entry.sidebar.bufnr

    require("intentdiff").toggle_sidebar(tab)
    assert.is_false(entry.sidebar.visible)
    assert.is_true(vim.api.nvim_buf_is_valid(bufnr), "buffer must survive hiding")

    require("intentdiff").toggle_sidebar(tab)
    assert.is_true(entry.sidebar.visible)
    assert.is_true(vim.api.nvim_win_is_valid(entry.sidebar.winid))
    assert.equals(bufnr, vim.api.nvim_win_get_buf(entry.sidebar.winid))

    local after = require("intentdiff.view").get_session(tab)
    assert.equals(orig_buf, after.original_bufnr, "diff panes must survive a hide/show cycle")
    assert.equals(mod_buf, after.modified_bufnr)
  end)

  it("re-renders the current model after showing", function()
    local tab, entry = open_ready()
    require("intentdiff").toggle_sidebar(tab) -- hide
    -- Mutate the model WHILE hidden: bufhidden="hide" means the buffer keeps
    -- its old (pre-hide) lines on disk regardless of what handle.show does,
    -- so comparing before/after a plain hide/show round-trip (the original
    -- version of this test) can never fail even if `show` never calls
    -- handle.update — the stale lines already equal the "before" snapshot.
    -- Forcing a real content change between hide and show, and asserting
    -- against a freshly computed expected layout, is what makes this
    -- discriminating.
    entry.model.groups[1].collapsed = true
    local expected = require("intentdiff.sidebar").layout(entry.model)
    require("intentdiff").toggle_sidebar(tab) -- show
    local after = vim.api.nvim_buf_get_lines(entry.sidebar.bufnr, 0, -1, false)
    assert.same(expected, after,
      "show() must re-render from the current model, not leave stale pre-hide lines on screen")
  end)

  it("survives calling toggle_all while hidden", function()
    local tab, entry = open_ready()
    require("intentdiff").toggle_sidebar(tab)
    -- toggle_all only ever touches entry.model.groups — it never reads the
    -- sidebar cursor/winid — so this is a basic smoke check that hiding
    -- doesn't break unrelated model-mutation paths, not a winid-guard pin.
    -- The real guard pins live in the two tests below (on_next_group/
    -- on_prev_group, and apply_hover).
    assert.has_no.errors(function()
      require("intentdiff").toggle_all(tab)
    end)
    require("intentdiff").toggle_sidebar(tab)
    assert.is_true(entry.sidebar.visible)
  end)

  it("on_next_group/on_prev_group no-op instead of throwing while hidden", function()
    local tab, entry = open_ready()
    require("intentdiff").toggle_sidebar(tab)
    assert.is_false(entry.sidebar.visible)
    -- Both callbacks read entry.sidebar.winid unconditionally before this
    -- task's guard; with the sidebar hidden that field is nil, and
    -- nvim_win_get_cursor(nil) throws exactly like nvim_win_is_valid(nil)
    -- does. Invoke the actual <Tab>/<S-Tab> keymap callbacks (not just the
    -- guard condition in isolation) so a regression in the real wiring is
    -- caught too.
    assert.has_no.errors(function() press(entry, "<Tab>") end)
    assert.has_no.errors(function() press(entry, "<S-Tab>") end)
  end)

  it("deletes the sidebar buffer when the session closes", function()
    local tab, entry = open_ready()
    local bufnr = entry.sidebar.bufnr
    require("intentdiff").close(tab)
    vim.wait(500, function() return not vim.api.nvim_buf_is_valid(bufnr) end, 20)
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr),
      "bufhidden is no longer 'wipe' — the session must delete its own buffer")
  end)

  it("apply_hover no-ops instead of throwing when a model re-render lands while "
      .. "a preview is active and the sidebar is hidden, then the preview re-derives "
      .. "once the sidebar is shown again", function()
    local tab, entry = open_ready({
      provider = fake_provider_sequence({
        { { title = "Everything", ids = "1-99" } },
        { { title = "Reclassified", ids = "1-99" } },
      }),
      preview = { enabled = true, debounce_ms = 10 },
    })
    hover(entry, line_of(entry, "group"))
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab]
    end, 5000), "preview never activated")

    require("intentdiff").toggle_sidebar(tab) -- hide
    assert.is_false(entry.sidebar.visible)

    -- `r` re-enters classify_and_render, which calls rerender_preview →
    -- apply_hover SYNCHRONOUSLY (before the async provider even runs)
    -- because _preview_active[tab] is still truthy. With the sidebar hidden,
    -- entry.sidebar.winid is nil, so this is the exact crash the guard
    -- exists for: nvim_win_is_valid(nil) throws rather than returning false.
    assert.has_no.errors(function() press(entry, "r") end)

    assert.truthy(helpers.wait_for(function()
      return entry.model.state == "ready"
        and entry.model.groups[1]
        and entry.model.groups[1].title == "Reclassified" or nil
    end, 15000), "reclassify never completed")

    -- The completion handler also calls rerender_preview while still
    -- hidden — give it a moment past `ready` to prove that second call
    -- doesn't throw either.
    vim.wait(200, function() return false end, 20)

    require("intentdiff").toggle_sidebar(tab) -- show again
    assert.is_true(entry.sidebar.visible)
    -- hover_key was cleared by rerender_preview while hidden and never
    -- reset (apply_hover returned before reaching that point), so hovering
    -- the SAME row again is not a de-duped no-op — it must re-render.
    hover(entry, line_of(entry, "group"))
    assert.truthy(helpers.wait_for(function()
      local active = require("intentdiff.view")._preview_active[tab]
      return (active and active.title == "Reclassified") or nil
    end, 5000), "the preview must re-derive from the reclassified model once shown again")
  end)

  it("keeps the sidebar toggle key on the diff panes even when codediff's own "
      .. "toggle_layout key is disabled", function()
    local tab = select(1, open_ready())
    local cd_config = require("codediff.config")
    local prev_toggle_layout = cd_config.options.keymaps.view.toggle_layout
    cd_config.options.keymaps.view.toggle_layout = false
    local ok, err = pcall(function()
      -- Force a re-install with codediff's key disabled — mirrors what
      -- happens on every real render (M.install_keymaps is re-run after
      -- every show_file/toggle_layout/reassert).
      require("intentdiff.view").install_keymaps(tab)
      local session = require("intentdiff.view").get_session(tab)
      local found = false
      for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
        if buf and vim.api.nvim_buf_is_valid(buf) then
          for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            if m.desc == "intent-diff: show/hide the sidebar" then
              found = true
            end
          end
        end
      end
      assert.is_true(found,
        "the sidebar-toggle key must still be installed on the pane buffers — "
          .. "it is the only way back once the sidebar is hidden and a "
          .. "sidebar-local key is unreachable")
    end)
    cd_config.options.keymaps.view.toggle_layout = prev_toggle_layout
    assert.is_true(ok, tostring(err))
  end)
end)
