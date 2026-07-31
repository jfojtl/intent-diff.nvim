local helpers = require("tests.helpers")

describe("sidebar show/hide", function()
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

  local function open_ready()
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
    assert.truthy(entry, "session never became ready")
    return tab, entry
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
    local before = vim.api.nvim_buf_get_lines(entry.sidebar.bufnr, 0, -1, false)
    require("intentdiff").toggle_sidebar(tab)
    require("intentdiff").toggle_sidebar(tab)
    local after = vim.api.nvim_buf_get_lines(entry.sidebar.bufnr, 0, -1, false)
    assert.same(before, after)
  end)

  it("survives group navigation while hidden", function()
    local tab, entry = open_ready()
    require("intentdiff").toggle_sidebar(tab)
    -- these read the sidebar cursor; with the sidebar hidden they must no-op
    assert.has_no.errors(function()
      require("intentdiff").toggle_all(tab)
    end)
    require("intentdiff").toggle_sidebar(tab)
    assert.is_true(entry.sidebar.visible)
  end)

  it("deletes the sidebar buffer when the session closes", function()
    local tab, entry = open_ready()
    local bufnr = entry.sidebar.bufnr
    require("intentdiff").close(tab)
    vim.wait(500, function() return not vim.api.nvim_buf_is_valid(bufnr) end, 20)
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr),
      "bufhidden is no longer 'wipe' — the session must delete its own buffer")
  end)
end)
