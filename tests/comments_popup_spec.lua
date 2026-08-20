local popup = require("intentdiff.comments.popup")
local config = require("intentdiff.config")

local TYPES = {
  { key = "note", name = "Note", icon = "✍" },
  { key = "issue", name = "Issue", icon = "⚠" },
}

describe("comments.popup", function()
  before_each(function()
    config.setup({})
  end)

  after_each(function()
    popup.cancel()
  end)

  it("brackets the selected type", function()
    local line = popup.type_line(TYPES, 2)
    assert.is_truthy(line:match("%[⚠ Issue%]"))
    assert.is_nil(line:match("%[✍ Note%]"))
  end)

  it("cycles with wrap-around", function()
    assert.equals(2, popup.cycle(1, 2))
    assert.equals(1, popup.cycle(2, 2))
  end)

  it("opens two floats and focuses the text one", function()
    popup.open({ no_insert = true }, function() end)
    assert.is_true(vim.api.nvim_win_is_valid(popup._type_win))
    assert.is_true(vim.api.nvim_win_is_valid(popup._text_win))
    assert.equals(popup._text_win, vim.api.nvim_get_current_win())
  end)

  it("opens a plain multi-line editor without the type selector", function()
    local got_type, got_text
    popup.open({ plain = true, title = "Reply", no_insert = true }, function(t, text)
      got_type, got_text = t, text
    end)
    assert.is_nil(popup._type_win)
    assert.is_true(vim.api.nvim_win_is_valid(popup._text_win))
    local title = vim.api.nvim_win_get_config(popup._text_win).title[1][1]
    assert.truthy(title:find("Reply", 1, true))
    local text_win = popup._text_win
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "one", "two" })
    popup.submit()
    assert.equals("reply", got_type)
    assert.equals("one\ntwo", got_text)
    assert.is_false(vim.api.nvim_win_is_valid(text_win))
  end)

  it("returns the typed text and selected type on submit", function()
    local got_type, got_text
    popup.open({ type = "issue", no_insert = true }, function(t, x)
      got_type, got_text = t, x
    end)
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "first", "second" })
    popup.submit()
    assert.equals("issue", got_type)
    assert.equals("first\nsecond", got_text)
  end)

  it("pre-fills text and selects the type when editing", function()
    popup.open({ type = "issue", text = "existing", no_insert = true }, function() end)
    assert.same({ "existing" }, vim.api.nvim_buf_get_lines(popup._text_buf, 0, -1, false))
    local type_line = vim.api.nvim_buf_get_lines(popup._type_buf, 0, -1, false)[1]
    assert.is_truthy(type_line:match("%[⚠ Issue%]"))
  end)

  it("reports a cancel as nil, nil", function()
    local called, got = false, "unset"
    popup.open({ no_insert = true }, function(t)
      called, got = true, t
    end)
    popup.cancel()
    assert.is_true(called)
    assert.is_nil(got)
  end)

  it("treats empty text as a cancel", function()
    local got = "unset"
    popup.open({ no_insert = true }, function(t)
      got = t
    end)
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "   ", "" })
    popup.submit()
    assert.is_nil(got)
  end)

  it("closes both windows on submit", function()
    local type_win, text_win
    popup.open({ no_insert = true }, function() end)
    type_win, text_win = popup._type_win, popup._text_win
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "x" })
    popup.submit()
    assert.is_false(vim.api.nvim_win_is_valid(type_win))
    assert.is_false(vim.api.nvim_win_is_valid(text_win))
  end)

  it("calls back exactly once even if submit is called twice", function()
    local n = 0
    popup.open({ no_insert = true }, function() n = n + 1 end)
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "x" })
    popup.submit()
    popup.submit()
    assert.equals(1, n)
  end)

  it("truncates the type line by display width, not codepoint count", function()
    -- Ten double-width-icon types comfortably overflow the float even after
    -- the old strcharpart-based cut (measured: raw width 110, old cut's
    -- display width 64 against a 58-column budget).
    local wide_types = {}
    for i = 1, 10 do
      wide_types[i] = { key = "t" .. i, name = "Type" .. i, icon = "💡" }
    end
    local line = popup.type_line(wide_types, 1)
    assert.is_true(vim.fn.strdisplaywidth(line) <= 58)
  end)

  it("cycle_type changes what submit returns", function()
    local got_type
    popup.open({ type = "note", no_insert = true }, function(t)
      got_type = t
    end)
    popup.cycle_type()
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "x" })
    popup.submit()
    -- Default types are note, suggestion, issue, praise: cycling from note
    -- lands on suggestion.
    assert.equals("suggestion", got_type)
  end)

  it("closes both windows on cancel", function()
    popup.open({ no_insert = true }, function() end)
    local type_win, text_win = popup._type_win, popup._text_win
    popup.cancel()
    assert.is_false(vim.api.nvim_win_is_valid(type_win))
    assert.is_false(vim.api.nvim_win_is_valid(text_win))
  end)

  it("restores focus to the pre-popup window after submit", function()
    local prev_win = vim.api.nvim_get_current_win()
    popup.open({ no_insert = true }, function() end)
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "x" })
    popup.submit()
    assert.equals(prev_win, vim.api.nvim_get_current_win())
  end)

  it("restores focus to the pre-popup window after cancel", function()
    local prev_win = vim.api.nvim_get_current_win()
    popup.open({ no_insert = true }, function() end)
    popup.cancel()
    assert.equals(prev_win, vim.api.nvim_get_current_win())
  end)

  it("does not bind a popup key configured as false", function()
    config.setup({ keymaps = { comments = { popup_cycle_type = false } } })
    popup.open({ no_insert = true }, function() end)
    local bound = false
    for _, mode in ipairs({ "i", "n" }) do
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(popup._text_buf, mode)) do
        if m.callback == popup.cycle_type then
          bound = true
        end
      end
    end
    assert.is_false(bound)
  end)

  it("binds every key of a list-valued action", function()
    config.setup({ keymaps = { comments = { popup_submit = { "<C-s>", "<F5>" } } } })
    popup.open({ no_insert = true }, function() end)
    -- Check by lhs presence rather than a raw count: normal mode also carries
    -- the hardcoded <CR> submit binding, so counting entries would couple
    -- this test to that unrelated implementation detail.
    for _, mode in ipairs({ "i", "n" }) do
      local seen = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(popup._text_buf, mode)) do
        if m.callback == popup.submit then
          seen[m.lhs] = true
        end
      end
      assert.is_true(seen["<C-S>"], mode .. " mode missing <C-s>")
      assert.is_true(seen["<F5>"], mode .. " mode missing <F5>")
    end
  end)

  it("reflects a rebound submit key in the comment float's title", function()
    config.setup({ keymaps = { comments = { popup_submit = "<F9>" } } })
    popup.open({ no_insert = true }, function() end)
    local cfg = vim.api.nvim_win_get_config(popup._text_win)
    local title = cfg.title[1][1]
    assert.is_truthy(title:find("<F9>", 1, true))
  end)
end)
