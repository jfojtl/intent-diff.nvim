local marks = require("intentdiff.comments.marks")
local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")
local helpers = require("tests.intentdiff_helpers")

--- A painted pane over `n` lines of "a.lua" on `side`. Every comment placement
--- goes through a pane's row map now — there is no file-shaped render path.
local function pane(side, n)
  return helpers.fake_pane("a.lua", side, n)
end

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
  --- The store under test. Rendering takes the store explicitly now: with two
  --- review tabs open, the store handed in is the only thing that says which
  --- comments belong in this buffer.
  local st

  before_each(function()
    config.setup({})
    st = store.new()
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
    st.add({ file = "a.lua", line = 3, side = "new", type = "issue", text = "bad" })
    marks.render_pane(st, buf, pane("new", 10))
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
    st.add({ file = "a.lua", line = 3, line_end = 6, side = "new", type = "note", text = "r" })
    marks.render_pane(st, buf, pane("new", 10))
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
    st.add({ file = "a.lua", line = 0, type = "praise", text = "nice" })
    marks.render_pane(st, buf, pane("new", 10))
    local got = extmarks(buf)
    assert.equals(1, #got)
    assert.equals(0, got[1][2])
    assert.is_true(got[1][4].virt_lines_above)
  end)

  it("renders a file-level comment on both sides", function()
    local old_buf, new_buf = scratch(5), scratch(5)
    st.add({ file = "a.lua", line = 0, type = "praise", text = "nice" })
    marks.render_pane(st, old_buf, pane("old", 10))
    marks.render_pane(st, new_buf, pane("new", 10))
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
    st.add({ file = "a.lua", line = 0, type = "praise", text = "nice" })

    assert.has_no.errors(function()
      marks.render_pane(st, buf, pane("new", 10))
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
    st.add({ file = "a.lua", line = 3, side = "old", type = "note", text = "o" })
    marks.render_pane(st, buf, pane("new", 10))
    assert.equals(0, #extmarks(buf))
    marks.render_pane(st, buf, pane("old", 10))
    assert.equals(1, #extmarks(buf))
  end)

  it("clears previous marks before re-rendering", function()
    local buf = scratch(10)
    local c = st.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
    marks.render_pane(st, buf, pane("new", 10))
    st.delete(c)
    marks.render_pane(st, buf, pane("new", 10))
    assert.equals(0, #extmarks(buf))
  end)

  it("clamps a comment whose lines this render no longer shows", function()
    local buf = scratch(3)
    st.add({ file = "a.lua", line = 99, side = "new", type = "note", text = "drifted" })
    assert.has_no.errors(function()
      marks.render_pane(st, buf, pane("new", 3))
    end)
    local got = extmarks(buf)
    -- Genuinely clamped, not dropped: exactly one extmark, on the last row of
    -- that file on that side, still carrying its box.
    assert.equals(1, #got)
    assert.equals(2, got[1][2])
    assert.is_truthy(got[1][4].virt_lines)
  end)

  it("reports the clamp, so the action layer can agree with it", function()
    st.add({ file = "a.lua", line = 99, side = "new", type = "note", text = "drifted" })
    local rows, drifted = marks.rows_for_comment(pane("new", 3), st.get_all()[1])
    assert.same({ 3 }, rows)
    assert.is_true(drifted)

    local live = { file = "a.lua", line = 2, side = "new", type = "note", text = "here" }
    local live_rows, live_drifted = marks.rows_for_comment(pane("new", 3), live)
    assert.same({ 2 }, live_rows)
    assert.is_false(live_drifted)
  end)

  it("clamps onto its OWN file's rows, never another file's", function()
    -- Two files in one render — an intent view. A comment of the FIRST file
    -- that drifted past its lines must not land on the second file's rows.
    local buf = scratch(6)
    local p = { lines = {}, spans = {}, map = {} }
    for i = 1, 3 do
      p.lines[i] = "a " .. i
      p.map[i] = { file = "a.lua", line = i, side = "new" }
    end
    for i = 4, 6 do
      p.lines[i] = "b " .. (i - 3)
      p.map[i] = { file = "b.lua", line = i - 3, side = "new" }
    end
    st.add({ file = "a.lua", line = 99, side = "new", type = "note", text = "drifted" })
    marks.render_pane(st, buf, p)
    local got = extmarks(buf)
    assert.equals(1, #got)
    assert.equals(2, got[1][2], "row 3 (a.lua's last), not row 6 (the pane's last)")
  end)

  it("draws nothing, and does not error, for a comment in a file this render omits", function()
    local buf = scratch(10)
    st.add({ file = "elsewhere.lua", line = 2, side = "new", type = "note", text = "other" })
    assert.has_no.errors(function()
      marks.render_pane(st, buf, pane("new", 10))
    end)
    assert.equals(0, #extmarks(buf))
  end)

  it("anchors a file-level comment above the file's FIRST row, not the buffer's", function()
    -- An intent view: b.lua's block starts at row 4, so its file-level box
    -- hangs there rather than above line 1 of the whole render.
    local buf = scratch(6)
    local p = { lines = {}, spans = {}, map = {} }
    for i = 1, 3 do
      p.lines[i] = "a " .. i
      p.map[i] = { file = "a.lua", line = i, side = "new" }
    end
    for i = 4, 6 do
      p.lines[i] = "b " .. (i - 3)
      p.map[i] = { file = "b.lua", line = i - 3, side = "new" }
    end
    st.add({ file = "b.lua", line = 0, type = "praise", text = "nice" })
    marks.render_pane(st, buf, p)
    local got = extmarks(buf)
    assert.equals(1, #got)
    assert.equals(3, got[1][2]) -- 0-indexed row 3 == pane row 4
    assert.is_true(got[1][4].virt_lines_above)
  end)

  it("pads the shorter side so boxes do not desync the panes", function()
    local old_buf, new_buf = scratch(10), scratch(10)
    st.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "one\ntwo" })
    marks.render_pane(st, old_buf, pane("old", 10))
    marks.render_pane(st, new_buf, pane("new", 10))
    marks.align_panes(st, {
      { bufnr = old_buf, pane = pane("old", 10) },
      { bufnr = new_buf, pane = pane("new", 10) },
    })
    local pad = vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, { details = true })
    assert.equals(1, #pad)
    assert.equals(2, pad[1][2]) -- anchored at row 2 (line 3), not just any row
    assert.equals(4, #pad[1][4].virt_lines) -- 2 text lines + 2 borders
    -- The taller (new) side gets no padding of its own.
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(new_buf, marks.ns_padding, 0, -1, {}))
  end)

  it("adds no padding when both sides carry the same box height", function()
    local old_buf, new_buf = scratch(10), scratch(10)
    st.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
    st.add({ file = "a.lua", line = 3, side = "old", type = "note", text = "y" })
    marks.render_pane(st, old_buf, pane("old", 10))
    marks.render_pane(st, new_buf, pane("new", 10))
    marks.align_panes(st, {
      { bufnr = old_buf, pane = pane("old", 10) },
      { bufnr = new_buf, pane = pane("new", 10) },
    })
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, {}))
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(new_buf, marks.ns_padding, 0, -1, {}))
  end)

  it("clears its own stale padding on re-align, not just on fresh buffers", function()
    local old_buf, new_buf = scratch(10), scratch(10)
    local c = st.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "one\ntwo" })
    marks.render_pane(st, old_buf, pane("old", 10))
    marks.render_pane(st, new_buf, pane("new", 10))
    marks.align_panes(st, {
      { bufnr = old_buf, pane = pane("old", 10) },
      { bufnr = new_buf, pane = pane("new", 10) },
    })
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, {}))

    st.delete(c)
    marks.render_pane(st, old_buf, pane("old", 10))
    marks.render_pane(st, new_buf, pane("new", 10))
    marks.align_panes(st, {
      { bufnr = old_buf, pane = pane("old", 10) },
      { bufnr = new_buf, pane = pane("new", 10) },
    })
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, {}))
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(new_buf, marks.ns_padding, 0, -1, {}))
  end)

  --- Regression: align_panes is the only place that clears ns_padding, so a
  --- render with only ONE pane (inline layout) must still clear what a previous
  --- side-by-side render left behind — otherwise the blank filler lines outlive
  --- the box they were compensating for.
  it("clears stale padding when the next render has only one pane", function()
    local old_buf, new_buf = scratch(10), scratch(10)
    st.add({ file = "a.lua", line = 3, side = "old", type = "note", text = "one\ntwo" })
    marks.render_pane(st, old_buf, pane("old", 10))
    marks.render_pane(st, new_buf, pane("new", 10))
    marks.align_panes(st, {
      { bufnr = old_buf, pane = pane("old", 10) },
      { bufnr = new_buf, pane = pane("new", 10) },
    })
    -- Old side is taller (a 2-line box vs. nothing on new) — padding lands on
    -- the shorter, new side.
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(new_buf, marks.ns_padding, 0, -1, {}))

    -- Inline: one pane, reusing the same buffer.
    marks.align_panes(st, { { bufnr = new_buf, pane = pane("new", 10) } })
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(new_buf, marks.ns_padding, 0, -1, {}))
  end)

  describe("refresh", function()
    local view = require("intentdiff.view")
    local tab
    local real_painted, real_plan, restore_session

    before_each(function()
      tab = 900001 -- a sentinel key, never a real tabpage id
      real_painted = view.painted_panes
      real_plan = view.current_plan
      -- refresh resolves the store from the tab's session entry, so the tab
      -- needs one: this is exactly the lookup that keeps two review tabs apart.
      restore_session = helpers.fake_session(tab, { comment_store = st })
    end)

    after_each(function()
      view.painted_panes = real_painted
      view.current_plan = real_plan
      restore_session()
    end)

    it("renders every painted pane through its own map, and aligns them", function()
      local old_buf, new_buf = scratch(10), scratch(10)
      local orig_pane, mod_pane = pane("old", 10), pane("new", 10)
      view.painted_panes = function()
        return { { bufnr = old_buf, pane = orig_pane }, { bufnr = new_buf, pane = mod_pane } }
      end
      view.current_plan = function()
        return { original = orig_pane, modified = mod_pane, files = { { path = "a.lua" } } }
      end
      st.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "one\ntwo" })

      marks.refresh(tab)

      assert.equals(0, #extmarks(old_buf), "a new-side comment belongs to the new pane only")
      assert.equals(1, #extmarks(new_buf))
      -- The taller side pushed the other out of sync; padding puts it back.
      assert.equals(1, #vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, {}))
    end)

    it("is a no-op when nothing is painted", function()
      view.painted_panes = function() return {} end
      view.current_plan = function() return nil end
      st.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
      assert.has_no.errors(function() marks.refresh(tab) end)
    end)
  end)

  it("signs a sidebar group row that has an intent comment", function()
    local buf = scratch(6)
    st.add({ intent_title = "Rename things", type = "issue", text = "wrong" })
    marks.render_sidebar(st, buf, { { lnum = 1, title = "Rename things" }, { lnum = 4, title = "Other" } })
    local got = extmarks(buf)
    assert.equals(1, #got)
    assert.equals(0, got[1][2])
    assert.is_nil(got[1][4].virt_lines) -- no box in the sidebar
  end)
end)
