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
end)
