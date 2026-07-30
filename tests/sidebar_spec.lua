local sidebar = require("intentdiff.sidebar")

local function mk_model(overrides)
  local model = {
    state = "ready",
    total_hunks = 3,
    grouped_hunks = 3,
    provider_label = "claude:haiku",
    groups = {
      {
        title = "Add retry",
        hunks = { {}, {} },
        files = {
          { path = "src/http/client.lua", status = "M", hunks = { {} } },
          { path = "src/http/backoff.lua", status = "A", hunks = { {} } },
        },
      },
      {
        title = "Ungrouped", is_ungrouped = true,
        hunks = { {} },
        files = { { path = "misc.lua", status = "M", hunks = { {} } } },
      },
    },
  }
  if overrides and overrides.groups then
    -- Merge groups element-wise to preserve array structure
    for i, g_override in ipairs(overrides.groups) do
      if model.groups[i] then
        model.groups[i] = vim.tbl_deep_extend("force", model.groups[i], g_override)
      else
        model.groups[i] = g_override
      end
    end
    overrides.groups = nil
  end
  return vim.tbl_deep_extend("force", model, overrides or {})
end

describe("sidebar.layout", function()
  it("renders group headers with counts and file children", function()
    local lines, meta = sidebar.layout(mk_model())
    assert.truthy(lines[1]:find("▾ Add retry"))
    assert.truthy(lines[1]:find("(2)", 1, true))
    assert.truthy(lines[2]:find("├ client.lua"))
    assert.truthy(lines[2]:find("src/http/", 1, true))
    assert.truthy(lines[3]:find("└ backoff.lua"))
    assert.same({ kind = "file", group_i = 1, file_i = 2 }, meta[3])
  end)

  it("collapses groups", function()
    local lines = sidebar.layout(mk_model({ groups = { [1] = { collapsed = true } } }))
    assert.truthy(lines[1]:find("▸ Add retry"))
    assert.truthy(lines[2]:find("▾ Ungrouped")) -- files of group 1 hidden
  end)

  it("shows loading state", function()
    local lines, meta = sidebar.layout({ state = "loading", groups = mk_model().groups,
      total_hunks = 3, grouped_hunks = 0 })
    assert.truthy(lines[1]:find("classifying"))
    assert.equals("info", meta[1].kind)
  end)

  it("shows loading state with an elapsed seconds counter when elapsed_s is a number", function()
    local lines = sidebar.layout({ state = "loading", groups = {}, elapsed_s = 7 })
    assert.equals("⟳ classifying… 7s", lines[1])
  end)

  it("shows the plain loading line when elapsed_s is absent", function()
    local lines = sidebar.layout({ state = "loading", groups = {} })
    assert.equals("⟳ classifying…", lines[1])
  end)

  it("shows footer with hunk accounting and provider", function()
    local lines = sidebar.layout(mk_model())
    local footer = lines[#lines]
    assert.truthy(footer:find("3/3 hunks", 1, true))
    assert.truthy(footer:find("claude:haiku", 1, true))
  end)

  it("shows warning message line when present", function()
    local lines = sidebar.layout(mk_model({ message = "classification failed: boom" }))
    assert.truthy(lines[1]:find("classification failed", 1, true))
  end)
end)

describe("sidebar.create", function()
  it("opens a split, renders, and routes <CR> to on_select", function()
    local selected
    local handle = sidebar.create({
      on_select = function(gi, fi) selected = { gi, fi } end,
      on_toggle_group = function() end, on_reclassify = function() end,
      on_close = function() end, on_next_group = function() end,
      on_prev_group = function() end, on_goto_file = function() end,
    })
    handle.update(mk_model())
    assert.is_true(vim.api.nvim_win_is_valid(handle.winid))
    vim.api.nvim_set_current_win(handle.winid)
    vim.api.nvim_win_set_cursor(handle.winid, { 2, 0 }) -- first file line
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert.same({ 1, 1 }, selected)
    vim.api.nvim_win_close(handle.winid, true)
  end)
end)
