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

  it("pre-fills text when editing", function()
    popup.open({ type = "note", text = "existing", no_insert = true }, function() end)
    assert.same({ "existing" }, vim.api.nvim_buf_get_lines(popup._text_buf, 0, -1, false))
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
end)
