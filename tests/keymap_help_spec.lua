local config = require("intentdiff.config")
local help = require("intentdiff.keymap_help")

--- The help float's lines, with the window left open for the caller to close.
local function open()
  help.toggle()
  local win = vim.api.nvim_get_current_win()
  return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), win
end

local function close_all()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

describe("keymap_help", function()
  before_each(function()
    close_all()
    config.setup({})
  end)
  after_each(close_all)

  it("opens a float listing both surfaces", function()
    local lines = open()
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("SIDEBAR", 1, true))
    assert.truthy(text:find("DIFF PANES", 1, true))
    assert.truthy(text:find("Re%-classify"))
  end)

  it("shows the configured key, not a hardcoded one", function()
    config.setup({ keymaps = { sidebar = { reclassify = "gr" } } })
    local text = table.concat((open()), "\n")
    assert.truthy(text:find("gr → Re%-classify"))
  end)

  it("lists every key of a list-valued action", function()
    local text = table.concat((open()), "\n")
    -- fold_open defaults to { "zo", "l" }; both belong on the one row.
    assert.truthy(text:find("zo l → Open fold", 1, true))
  end)

  it("omits a disabled action entirely", function()
    config.setup({ keymaps = { sidebar = { reclassify = false } } })
    local text = table.concat((open()), "\n")
    assert.is_nil(text:find("Re%-classify"))
    assert.truthy(text:find("SIDEBAR", 1, true)) -- the section survives
  end)

  it("drops a section whose every action is disabled", function()
    local sidebar = {}
    for action in pairs(config.defaults.keymaps.sidebar) do
      sidebar[action] = false
    end
    config.setup({ keymaps = { sidebar = sidebar } })
    local text = table.concat((open()), "\n")
    assert.is_nil(text:find("SIDEBAR", 1, true))
    assert.truthy(text:find("DIFF PANES", 1, true))
  end)

  it("toggles closed on a second call", function()
    local _, win = open()
    assert.is_true(vim.api.nvim_win_is_valid(win))
    help.toggle()
    assert.is_false(vim.api.nvim_win_is_valid(win))
  end)

  it("re-opens after being closed, rather than staying latched shut", function()
    local _, first = open()
    help.toggle()
    local _, second = open()
    assert.is_true(vim.api.nvim_win_is_valid(second))
    assert.are_not.equals(first, second)
  end)

  it("closes from q, <Esc> and the show_help key", function()
    for _, key in ipairs({ "q", "<Esc>", "g?" }) do
      local _, win = open()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
      assert.is_false(vim.api.nvim_win_is_valid(win), key .. " did not close the help")
    end
  end)

  it("aligns the arrow column by display width, not byte count", function()
    local lines = open()
    local cols = {}
    for _, line in ipairs(lines) do
      local before = line:match("^(.-) → ")
      if before then
        cols[vim.fn.strdisplaywidth(before)] = true
      end
    end
    local widths = vim.tbl_keys(cols)
    assert.equals(1, #widths, "arrow column is ragged: " .. vim.inspect(widths))
  end)
end)

describe("keymap_help window tracking", function()
  before_each(function()
    close_all()
    config.setup({})
  end)
  after_each(close_all)

  it("keeps tracking a help window reopened right after a dismiss", function()
    help.toggle()
    local first = vim.api.nvim_get_current_win()
    -- Dismissing closes the window AND fires its WinLeave, which schedules a
    -- second close for a window that is already gone. Reopening before that
    -- scheduled callback runs must not let the stale closure clear the NEW
    -- window's tracking — that would strand the reopened help on screen,
    -- untracked and impossible to toggle shut.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("q", true, false, true), "x", false)
    assert.is_false(vim.api.nvim_win_is_valid(first))
    help.toggle()
    local second = vim.api.nvim_get_current_win()
    assert.are_not.equals(first, second)
    vim.wait(50) -- let the stale scheduled close run
    assert.is_true(vim.api.nvim_win_is_valid(second), "the reopened help was closed")

    help.toggle()
    assert.is_false(vim.api.nvim_win_is_valid(second), "the reopened help was untracked")
  end)
end)
