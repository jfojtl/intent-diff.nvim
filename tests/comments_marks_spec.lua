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
    -- Multi-byte content: strdisplaywidth("日本語のコメント") is 16 (wide
    -- CJK characters), but its BYTE length is 24. Padding by byte count
    -- instead of display width (e.g. swapping strdisplaywidth for #) would
    -- pad this line differently from the others; plain ASCII text cannot
    -- catch that, since width and byte count always agree there.
    local box = marks.build_box("日本語のコメント\nshort", "Note", "IntentDiffCommentNote")
    local width = vim.fn.strdisplaywidth(box[1][1][1])
    for _, line in ipairs(box) do
      assert.equals(width, vim.fn.strdisplaywidth(line[1][1]))
    end
  end)

  it("keeps the top border full width when the type name is long", function()
    -- A header longer than `width + 1` used to drive string.rep's count
    -- negative; Lua silently returns "" for n <= 0 (no error to catch), so
    -- the top border came out shorter than every other line.
    local box = marks.build_box("hi", "AVeryLongTypeNameThatExceedsMinimumWidth", "IntentDiffCommentNote")
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
    assert.is_nil(got[#got][4].sign_text) -- only the first row carries a sign
    -- Interior rows (lines 4 and 5) carry the line highlight and nothing else.
    for i = 2, #got - 1 do
      assert.is_nil(got[i][4].sign_text)
      assert.is_nil(got[i][4].virt_lines)
    end
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

    -- Exact height (top border + one text line + bottom border = 3), not
    -- just "> 0" — a nudge hard-coded to a constant 1 would otherwise pass.
    assert.equals(3, topfill)
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

  it("clamps a line number past the end of the buffer to the last line", function()
    local buf = scratch(3)
    store.add({ file = "a.lua", line = 99, side = "new", type = "note", text = "drifted" })
    assert.has_no.errors(function()
      marks.render_buffer(buf, "a.lua", "new")
    end)
    local got = extmarks(buf)
    -- Genuinely clamped, not dropped: exactly one extmark, anchored on the
    -- last row of the buffer (row 2 of 3), still carrying its box.
    assert.equals(1, #got)
    assert.equals(2, got[1][2])
    assert.is_truthy(got[1][4].virt_lines)
  end)

  it("pads the shorter side so boxes do not desync the panes", function()
    local old_buf, new_buf = scratch(10), scratch(10)
    store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "one\ntwo" })
    marks.render_buffer(old_buf, "a.lua", "old")
    marks.render_buffer(new_buf, "a.lua", "new")
    marks.align(old_buf, new_buf, "a.lua")
    local pad = vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, { details = true })
    assert.equals(1, #pad)
    assert.equals(2, pad[1][2]) -- anchored at row 2 (line 3), not just any row
    assert.equals(4, #pad[1][4].virt_lines) -- 2 text lines + 2 borders
    -- The taller (new) side gets no padding of its own.
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(new_buf, marks.ns_padding, 0, -1, {}))
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

  it("clears its own stale padding on re-align, not just on fresh buffers", function()
    local old_buf, new_buf = scratch(10), scratch(10)
    local c = store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "one\ntwo" })
    marks.render_buffer(old_buf, "a.lua", "old")
    marks.render_buffer(new_buf, "a.lua", "new")
    marks.align(old_buf, new_buf, "a.lua")
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, {}))

    store.delete(c)
    marks.render_buffer(old_buf, "a.lua", "old")
    marks.render_buffer(new_buf, "a.lua", "new")
    marks.align(old_buf, new_buf, "a.lua")
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, {}))
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(new_buf, marks.ns_padding, 0, -1, {}))
  end)

  describe("refresh", function()
    local view = require("intentdiff.view")
    local tab
    local real_get_session, real_diff_wins

    before_each(function()
      tab = 900001 -- a sentinel key, never a real tabpage id
      real_get_session = view.get_session
      real_diff_wins = view.diff_wins
    end)

    after_each(function()
      view.get_session = real_get_session
      view.diff_wins = real_diff_wins
      view._last_shown[tab] = nil
      view._preview_active[tab] = nil
    end)

    --- Regression: M.align is the only place that clears ns_padding, so
    --- skipping it (inline layout, or a whole-file single-pane render) must
    --- not also skip that cleanup. Reproduces the concrete path: a
    --- side-by-side working-tree review with an old-side comment (so the
    --- shorter NEW side gets the padding), then a layout toggle that
    --- collapses both windows onto the (real, modified) buffer — mirroring
    --- inline layout reusing the modified buffer.
    it("clears stale padding once a layout toggle collapses both panes onto one buffer", function()
      local win_orig = vim.api.nvim_open_win(scratch(10), false, {
        relative = "editor", row = 0, col = 0, width = 20, height = 5, style = "minimal",
      })
      local win_mod = vim.api.nvim_open_win(scratch(10), false, {
        relative = "editor", row = 6, col = 0, width = 20, height = 5, style = "minimal",
      })
      local buf_orig = vim.api.nvim_win_get_buf(win_orig)
      local buf_mod = vim.api.nvim_win_get_buf(win_mod)

      store.add({ file = "a.lua", line = 3, side = "old", type = "note", text = "one\ntwo" })
      marks.render_buffer(buf_orig, "a.lua", "old")
      marks.render_buffer(buf_mod, "a.lua", "new")
      marks.align(buf_orig, buf_mod, "a.lua")
      -- Old side is taller (2-line box vs. no comment on new) — padding lands
      -- on the shorter, new side.
      assert.equals(1, #vim.api.nvim_buf_get_extmarks(buf_mod, marks.ns_padding, 0, -1, {}))

      -- Simulate the toggle to inline: both windows now show the (real,
      -- modified) buffer — exactly what inline layout does with a
      -- working-tree review's buffer.
      vim.api.nvim_win_set_buf(win_orig, buf_mod)

      view.get_session = function() return { original_win = win_orig, modified_win = win_mod } end
      view.diff_wins = function() return { win_orig, win_mod } end
      view._last_shown[tab] = { file_entry = { path = "a.lua" } }
      view._preview_active[tab] = nil

      marks.refresh(tab)

      assert.equals(0, #vim.api.nvim_buf_get_extmarks(buf_mod, marks.ns_padding, 0, -1, {}))

      pcall(vim.api.nvim_win_close, win_orig, true)
      pcall(vim.api.nvim_win_close, win_mod, true)
    end)
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
