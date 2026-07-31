local marks = require("intentdiff.comments.marks")
local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")

local function scratch(nlines)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, nlines do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function extmarks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, marks.ns, 0, -1, { details = true })
end

describe("comments.marks", function()
  before_each(function()
    config.setup({})
    store.detach()
    store.clear()
  end)

  it("draws a box sized to the widest line with a minimum width", function()
    local box = marks.build_box("hi", "Issue", "IntentDiffCommentIssue")
    assert.equals(3, #box) -- top border, one text line, bottom border
    assert.is_truthy(box[1][1][1]:match("^╭─%[ISSUE%]"))
    assert.is_truthy(box[#box][1][1]:match("^╰"))
    -- Minimum content width of 20 keeps a one-word comment from being a sliver.
    assert.is_true(vim.fn.strdisplaywidth(box[1][1][1]) >= 22)
  end)

  it("keeps every box line the same display width", function()
    local box = marks.build_box("short\na much longer line here", "Note", "IntentDiffCommentNote")
    local width = vim.fn.strdisplaywidth(box[1][1][1])
    for _, line in ipairs(box) do
      assert.equals(width, vim.fn.strdisplaywidth(line[1][1]))
    end
  end)

  it("places a sign, a line highlight and a box for a single-line comment", function()
    local buf = scratch(10)
    store.add({ file = "a.lua", line = 3, side = "new", type = "issue", text = "bad" })
    marks.render_buffer(buf, "a.lua", "new")
    local got = extmarks(buf)
    assert.equals(1, #got)
    assert.equals(2, got[1][2]) -- 0-indexed row for line 3
    assert.equals("⚠", got[1][4].sign_text:gsub("%s+$", ""))
    assert.equals("IntentDiffCommentIssue", got[1][4].sign_hl_group)
    assert.equals("IntentDiffCommentIssueLine", got[1][4].line_hl_group)
    assert.is_truthy(got[1][4].virt_lines)
  end)

  it("highlights every line of a range and boxes only the last", function()
    local buf = scratch(10)
    store.add({ file = "a.lua", line = 3, line_end = 6, side = "new", type = "note", text = "r" })
    marks.render_buffer(buf, "a.lua", "new")
    local got = extmarks(buf)
    assert.equals(4, #got) -- rows 3,4,5,6
    assert.is_truthy(got[1][4].sign_text)
    assert.is_nil(got[1][4].virt_lines)
    assert.is_truthy(got[#got][4].virt_lines)
    for _, m in ipairs(got) do
      assert.equals("IntentDiffCommentNoteLine", m[4].line_hl_group)
    end
  end)

  it("anchors a file-level comment above the first line", function()
    local buf = scratch(5)
    store.add({ file = "a.lua", line = 0, type = "praise", text = "nice" })
    marks.render_buffer(buf, "a.lua", "new")
    local got = extmarks(buf)
    assert.equals(1, #got)
    assert.equals(0, got[1][2])
    assert.is_true(got[1][4].virt_lines_above)
  end)

  it("renders a file-level comment on both sides", function()
    local old_buf, new_buf = scratch(5), scratch(5)
    store.add({ file = "a.lua", line = 0, type = "praise", text = "nice" })
    marks.render_buffer(old_buf, "a.lua", "old")
    marks.render_buffer(new_buf, "a.lua", "new")
    assert.equals(1, #extmarks(old_buf))
    assert.equals(1, #extmarks(new_buf))
  end)

  it("nudges a live window's topfill so a file-level box is visible", function()
    local buf = scratch(5)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 5,
      style = "minimal",
    })
    store.add({ file = "a.lua", line = 0, type = "praise", text = "nice" })

    assert.has_no.errors(function()
      marks.render_buffer(buf, "a.lua", "new")
    end)

    local topfill
    vim.api.nvim_win_call(win, function()
      topfill = vim.fn.winsaveview().topfill
    end)

    -- Closing before the assertion so a failure never leaks the window into
    -- later tests in this file.
    pcall(vim.api.nvim_win_close, win, true)

    assert.is_true(topfill > 0)
  end)

  it("keeps an old-side comment off the new-side pane", function()
    local buf = scratch(10)
    store.add({ file = "a.lua", line = 3, side = "old", type = "note", text = "o" })
    marks.render_buffer(buf, "a.lua", "new")
    assert.equals(0, #extmarks(buf))
    marks.render_buffer(buf, "a.lua", "old")
    assert.equals(1, #extmarks(buf))
  end)

  it("clears previous marks before re-rendering", function()
    local buf = scratch(10)
    local c = store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
    marks.render_buffer(buf, "a.lua", "new")
    store.delete(c)
    marks.render_buffer(buf, "a.lua", "new")
    assert.equals(0, #extmarks(buf))
  end)

  it("survives a line number past the end of the buffer", function()
    local buf = scratch(3)
    store.add({ file = "a.lua", line = 99, side = "new", type = "note", text = "drifted" })
    assert.has_no.errors(function()
      marks.render_buffer(buf, "a.lua", "new")
    end)
  end)

  it("pads the shorter side so boxes do not desync the panes", function()
    local old_buf, new_buf = scratch(10), scratch(10)
    store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "one\ntwo" })
    marks.render_buffer(old_buf, "a.lua", "old")
    marks.render_buffer(new_buf, "a.lua", "new")
    marks.align(old_buf, new_buf, "a.lua")
    local pad = vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, { details = true })
    assert.equals(1, #pad)
    assert.equals(4, #pad[1][4].virt_lines) -- 2 text lines + 2 borders
  end)

  it("adds no padding when both sides carry the same box height", function()
    local old_buf, new_buf = scratch(10), scratch(10)
    store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
    store.add({ file = "a.lua", line = 3, side = "old", type = "note", text = "y" })
    marks.render_buffer(old_buf, "a.lua", "old")
    marks.render_buffer(new_buf, "a.lua", "new")
    marks.align(old_buf, new_buf, "a.lua")
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, {}))
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(new_buf, marks.ns_padding, 0, -1, {}))
  end)

  it("signs a sidebar group row that has an intent comment", function()
    local buf = scratch(6)
    store.add({ intent_title = "Rename things", type = "issue", text = "wrong" })
    marks.render_sidebar(buf, { { lnum = 1, title = "Rename things" }, { lnum = 4, title = "Other" } })
    local got = extmarks(buf)
    assert.equals(1, #got)
    assert.equals(0, got[1][2])
    assert.is_nil(got[1][4].virt_lines) -- no box in the sidebar
  end)
end)
