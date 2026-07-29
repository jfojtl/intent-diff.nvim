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
