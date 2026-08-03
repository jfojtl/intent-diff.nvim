-- Commenting inside the whole-intent preview.
--
-- The load-bearing invariant under test: the preview is a COORDINATE SYSTEM,
-- never a storage concept. A comment made on a preview row must be byte-for-
-- byte the record commenting that same line in the file's own diff produces —
-- so the store, the file on disk and the Markdown export never learn that
-- previews exist.
local comments = require("intentdiff.comments")
local marks = require("intentdiff.comments.marks")
local popup = require("intentdiff.comments.popup")
local preview = require("intentdiff.preview")
local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")
local hunks = require("intentdiff.hunks")
local helpers = require("tests.helpers")
local view = require("intentdiff.view")

--- Two files; the second one's hunk starts far from line 1 so a lost offset
--- cannot hide behind small numbers.
local DIFF = table.concat({
  "diff --git a/src/auth.lua b/src/auth.lua",
  "@@ -1,3 +1,4 @@",
  " keep",
  "-old",
  "+new",
  "+extra",
  "diff --git a/zz/late.lua b/zz/late.lua",
  "@@ -120,3 +140,3 @@",
  " ctx a",
  "-gone",
  "+arrived",
  " ctx b",
  "",
}, "\n")

local function group_from(diff)
  local hs, files = hunks.parse(diff)
  local by_path = {}
  for _, f in ipairs(files) do
    f.hunks = {}
    by_path[f.path] = f
  end
  for _, h in ipairs(hs) do
    table.insert(by_path[h.file].hunks, h)
  end
  return { title = "Auth", hunks = hs, files = files }
end

describe("comments in the whole-intent preview", function()
  local tab = 900011 -- sentinel key, never a real tabpage id
  local st, restore_session, real_open, notices
  local wins, panes
  --- vim.notify as it was before the spec swapped it out.
  local real_notify

  --- Put `pane` in a fresh scratch buffer and a floating window, and register
  --- both as one of the tab's live preview panes.
  local function install_pane(pane)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, pane.lines)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor", row = 0, col = 0, width = 60, height = 10, style = "minimal",
    })
    wins[#wins + 1] = win
    panes[#panes + 1] = { bufnr = buf, pane = pane }
    return win, buf
  end

  --- Render `diff` (the two-file fixture by default) and drive it into the tab
  --- exactly as view.show_preview does: buffers in windows, maps registered,
  --- the preview flag set.
  --- @return table rendered, table wins_by_role
  local function show_preview(layout, diff)
    local rendered = preview.render(group_from(diff or DIFF), layout, {})
    local roles = {}
    if layout == "inline" then
      roles.modified = select(1, install_pane(rendered.modified))
    else
      roles.original = select(1, install_pane(rendered.original))
      roles.modified = select(1, install_pane(rendered.modified))
    end
    view._preview_maps[tab] = panes
    view._preview_active[tab] = { title = "Auth" }
    return rendered, roles
  end

  --- The 1-indexed row of `pane` whose text is exactly `text`.
  local function row_of(pane, text)
    for i, l in ipairs(pane.lines) do
      if l == text then
        return i
      end
    end
    error("no preview row reads " .. vim.inspect(text))
  end

  local function focus(win, row)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end

  --- A real visual selection, left behind for `'<`/`'>` the way the visual
  --- keymaps' own <Esc> leaves it.
  local function select_rows(win, a, b)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { a, 0 })
    vim.cmd(("normal! V%dG"):format(b))
    vim.cmd("normal! \27")
  end

  before_each(function()
    config.setup({ cache_dir = vim.fn.tempname() })
    st = store.new()
    wins, panes = {}, {}
    notices = {}
    restore_session = helpers.fake_session(tab, { comment_store = st })
    real_open = popup.open
    popup.open = function(opts, cb)
      cb(opts.type or "note", opts.text or "a comment")
    end
    -- Restored in after_each via the describe-scope upvalue above.
    real_notify = vim.notify
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    popup.open = real_open
    vim.notify = real_notify
    restore_session()
    view._preview_active[tab] = nil
    view._preview_maps[tab] = nil
    view._last_shown[tab] = nil
    for _, w in ipairs(wins) do
      pcall(vim.api.nvim_win_close, w, true)
    end
  end)

  local function last_notice()
    return notices[#notices] and notices[#notices].msg or nil
  end

  -- ------------------------------------------------------------ adding --

  describe("adding", function()
    it("records a - row as an old-side comment on the real file line", function()
      local rendered, roles = show_preview("inline")
      focus(roles.modified, row_of(rendered.modified, "-gone"))

      comments.add(tab, "issue")

      assert.equals(1, st.count())
      local c = st.get_all()[1]
      assert.equals("zz/late.lua", c.file)
      assert.equals(121, c.line)
      assert.equals("old", c.side)
      assert.equals("issue", c.type)
      assert.is_nil(c.line_end)
    end)

    it("records a + row as a new-side comment on the real file line", function()
      local rendered, roles = show_preview("inline")
      focus(roles.modified, row_of(rendered.modified, "+arrived"))

      comments.add(tab, "note")

      local c = st.get_all()[1]
      assert.equals("zz/late.lua", c.file)
      assert.equals(141, c.line)
      assert.equals("new", c.side)
    end)

    it("reads the side from the PANE in side-by-side, not from the window", function()
      local rendered, roles = show_preview("side-by-side")
      focus(roles.original, row_of(rendered.original, "gone"))
      comments.add(tab, "note")
      focus(roles.modified, row_of(rendered.modified, "arrived"))
      comments.add(tab, "note")

      local by_side = {}
      for _, c in ipairs(st.get_all()) do
        by_side[c.side] = c
      end
      assert.equals(121, by_side.old.line)
      assert.equals(141, by_side.new.line)
      assert.equals("zz/late.lua", by_side.old.file)
      assert.equals("zz/late.lua", by_side.new.file)
    end)

    it("records a visual range within one file", function()
      local rendered, roles = show_preview("inline")
      local first = row_of(rendered.modified, " ctx a")
      local last = row_of(rendered.modified, " ctx b")
      select_rows(roles.modified, first, last)

      comments.add(tab, "note", { visual = true })

      local c = st.get_all()[1]
      assert.equals("zz/late.lua", c.file)
      assert.equals("new", c.side)
      -- new-side rows in that span: 140 (ctx a), 141 (arrived), 142 (ctx b).
      assert.equals(140, c.line)
      assert.equals(142, c.line_end)
    end)

    it("stores nothing a file diff would not store", function()
      local rendered, roles = show_preview("inline")
      focus(roles.modified, row_of(rendered.modified, "+arrived"))

      comments.add(tab, "note")

      local keys = {}
      for k in pairs(st.get_all()[1]) do
        keys[#keys + 1] = k
      end
      table.sort(keys)
      assert.same({ "created_at", "file", "line", "side", "text", "type" }, keys,
        "a preview comment must carry no field a file-diff comment lacks")
    end)
  end)

  -- ------------------------------------------------------------ refusals --

  describe("refusing rows that address nothing", function()
    it("refuses a file separator, and says what to do", function()
      local rendered, roles = show_preview("inline")
      local sep
      for i, l in ipairs(rendered.modified.lines) do
        if l:find("src/auth.lua", 1, true) then sep = i end
      end
      focus(roles.modified, sep)

      comments.add(tab, "note")

      assert.equals(0, st.count())
      assert.truthy(last_notice():find("put the cursor on", 1, true),
        "the refusal must name the fix, got: " .. tostring(last_notice()))
    end)

    it("refuses a @@ hunk header", function()
      local rendered, roles = show_preview("inline")
      focus(roles.modified, row_of(rendered.modified, "@@ -120,3 +140,3 @@"))

      comments.add(tab, "note")

      assert.equals(0, st.count())
      assert.truthy(last_notice():find("put the cursor on", 1, true))
    end)

    it("refuses a side-by-side filler row", function()
      local rendered, roles = show_preview("side-by-side")
      -- "+extra" has no counterpart, so the original pane carries a filler.
      local row = row_of(rendered.modified, "extra")
      assert.equals("", rendered.original.lines[row])
      focus(roles.original, row)

      comments.add(tab, "note")

      assert.equals(0, st.count())
      assert.truthy(last_notice():find("put the cursor on", 1, true))
    end)

    it("refuses a visual range spanning two files, naming the problem", function()
      local rendered, roles = show_preview("inline")
      select_rows(roles.modified, row_of(rendered.modified, "+new"),
        row_of(rendered.modified, "-gone"))

      comments.add(tab, "note", { visual = true })

      assert.equals(0, st.count())
      assert.truthy(last_notice():find("one file", 1, true),
        "the refusal must name the problem, got: " .. tostring(last_notice()))
    end)

    it("refuses when the cursor is not in a preview pane at all", function()
      show_preview("inline")
      local other = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor", row = 0, col = 0, width = 10, height = 3, style = "minimal",
      })
      wins[#wins + 1] = other
      vim.api.nvim_set_current_win(other)

      comments.add(tab, "note")

      assert.equals(0, st.count())
      assert.truthy(last_notice():find("intent preview", 1, true))
    end)
  end)

  -- ---------------------------------------------------------- round trip --

  describe("round trip with a real file diff", function()
    --- The record commenting `line` on `side` of `file`'s OWN diff produces,
    --- driven through the same M.add the keymaps call.
    local function via_file_diff(file, line, side)
      local other_store = store.new()
      local other_tab = 900012
      local restore = helpers.fake_session(other_tab, { comment_store = other_store })
      local real_get_session = view.get_session
      local buf = vim.api.nvim_create_buf(false, true)
      local lines = {}
      for i = 1, line do lines[i] = "l" .. i end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor", row = 0, col = 0, width = 20, height = 5, style = "minimal",
      })
      local other_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor", row = 0, col = 0, width = 20, height = 5, style = "minimal",
      })
      -- side_for_win reads "old" from the original window only.
      if side == "old" then
        view.get_session = function() return { original_win = win, modified_win = other_win } end
      else
        view.get_session = function() return { original_win = other_win, modified_win = win } end
      end
      view._last_shown[other_tab] = { file_entry = { path = file } }
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { line, 0 })

      comments.add(other_tab, "note")

      local c = other_store.get_all()[1]
      view.get_session = real_get_session
      view._last_shown[other_tab] = nil
      restore()
      pcall(vim.api.nvim_win_close, win, true)
      pcall(vim.api.nvim_win_close, other_win, true)
      return c
    end

    --- Comparable copy: `created_at` is a wall clock.
    local function shape(c)
      return { file = c.file, line = c.line, line_end = c.line_end, side = c.side,
        type = c.type, text = c.text }
    end

    it("produces the same record as commenting that line in the file's diff", function()
      local rendered, roles = show_preview("inline")
      focus(roles.modified, row_of(rendered.modified, "+arrived"))
      comments.add(tab, "note")

      assert.same(shape(via_file_diff("zz/late.lua", 141, "new")),
        shape(st.get_all()[1]))
    end)

    it("produces the same record for an old-side line", function()
      local rendered, roles = show_preview("side-by-side")
      focus(roles.original, row_of(rendered.original, "gone"))
      comments.add(tab, "note")

      assert.same(shape(via_file_diff("zz/late.lua", 121, "old")),
        shape(st.get_all()[1]))
    end)
  end)

  -- ----------------------------------------------------------- rendering --

  describe("rendering", function()
    local function boxed_rows(bufnr)
      local out = {}
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, marks.ns, 0, -1, { details = true })) do
        if m[4].virt_lines then
          out[#out + 1] = m[2] + 1
        end
      end
      return out
    end

    it("draws a comment made in a file diff at its mapped preview row", function()
      st.add({ file = "zz/late.lua", line = 141, side = "new", type = "note", text = "hi" })
      local rendered, _ = show_preview("inline")

      marks.refresh(tab)

      assert.same({ row_of(rendered.modified, "+arrived") }, boxed_rows(panes[1].bufnr))
    end)

    -- An inline FILE diff cannot show an old-side comment: its buffer is the
    -- modified file and deletions are codediff virt_lines, so there is no row
    -- to hang the box off. The inline PREVIEW is the exception — its `-` rows
    -- are real buffer lines — and the README now says so, so assert it.
    it("draws an old-side comment in the INLINE preview, on the - row", function()
      st.add({ file = "zz/late.lua", line = 121, side = "old", type = "note", text = "hi" })
      local rendered = show_preview("inline")

      marks.refresh(tab)

      assert.same({ row_of(rendered.modified, "-gone") }, boxed_rows(panes[1].bufnr))
    end)

    it("draws an old-side comment in the ORIGINAL pane only", function()
      st.add({ file = "zz/late.lua", line = 121, side = "old", type = "note", text = "hi" })
      local rendered, _ = show_preview("side-by-side")

      marks.refresh(tab)

      assert.same({ row_of(rendered.original, "gone") }, boxed_rows(panes[1].bufnr))
      assert.same({}, boxed_rows(panes[2].bufnr))
    end)

    -- The two preview panes are scrollbound and equal in length by
    -- construction; a box on one side is virt_lines, which makes that side
    -- taller. Without padding the sides drift apart.
    it("pads the opposite pane so a box does not break the scroll sync", function()
      st.add({ file = "zz/late.lua", line = 121, side = "old", type = "note", text = "one\ntwo" })
      local rendered = show_preview("side-by-side")

      marks.refresh(tab)

      local padded = vim.api.nvim_buf_get_extmarks(
        panes[2].bufnr, marks.ns_padding, 0, -1, { details = true })
      assert.equals(1, #padded)
      assert.equals(row_of(rendered.original, "gone") - 1, padded[1][2])
      -- 2 text lines + 2 borders.
      assert.equals(4, #padded[1][4].virt_lines)
      assert.same({}, vim.api.nvim_buf_get_extmarks(
        panes[1].bufnr, marks.ns_padding, 0, -1, {}))
    end)

    it("draws a comment made in the preview, in the file's own diff", function()
      local rendered, roles = show_preview("inline")
      focus(roles.modified, row_of(rendered.modified, "+arrived"))
      comments.add(tab, "note")

      -- The file's own buffer, 200 lines long.
      local buf = vim.api.nvim_create_buf(false, true)
      local lines = {}
      for i = 1, 200 do lines[i] = "l" .. i end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      marks.render_buffer(st, buf, "zz/late.lua", "new")

      assert.same({ 141 }, boxed_rows(buf))
    end)

    it("draws nothing, and does not error, for a comment past the render", function()
      st.add({ file = "zz/late.lua", line = 9999, side = "new", type = "note", text = "hi" })
      st.add({ file = "elsewhere.lua", line = 3, side = "new", type = "note", text = "hi" })
      show_preview("inline")

      marks.refresh(tab)

      assert.same({}, boxed_rows(panes[1].bufnr))
      assert.equals(2, st.count(), "the comments must survive un-rendered")
    end)

    it("re-applies the boxes on every preview render, not only on mutation", function()
      st.add({ file = "zz/late.lua", line = 141, side = "new", type = "note", text = "hi" })
      local rendered = show_preview("inline")
      marks.refresh(tab)
      assert.equals(1, #boxed_rows(panes[1].bufnr))

      -- A debounced re-render replaces the buffer; extmarks live on the buffer.
      wins, panes = {}, {}
      local again = show_preview("inline")
      marks.refresh(tab)

      assert.same({ row_of(again.modified, "+arrived") }, boxed_rows(panes[1].bufnr))
      assert.truthy(rendered)
    end)
  end)

  -- ------------------------------------------------------ edit and delete --

  describe("editing and deleting at the cursor", function()
    it("edits the comment the cursor's row maps to", function()
      st.add({ file = "zz/late.lua", line = 141, side = "new", type = "note", text = "before" })
      local rendered, roles = show_preview("inline")
      focus(roles.modified, row_of(rendered.modified, "+arrived"))
      popup.open = function(_, cb) cb("issue", "after") end

      comments.edit(tab)

      local c = st.get_all()[1]
      assert.equals("issue", c.type)
      assert.equals("after", c.text)
    end)

    it("deletes the comment the cursor's row maps to", function()
      st.add({ file = "zz/late.lua", line = 141, side = "new", type = "note", text = "x" })
      local rendered, roles = show_preview("inline")
      focus(roles.modified, row_of(rendered.modified, "+arrived"))

      comments.delete(tab)

      assert.equals(0, st.count())
    end)

    it("does not answer for a row the comment is not on", function()
      st.add({ file = "zz/late.lua", line = 141, side = "new", type = "note", text = "x" })
      local rendered, roles = show_preview("inline")
      focus(roles.modified, row_of(rendered.modified, " ctx b"))

      comments.delete(tab)

      assert.equals(1, st.count())
    end)

    -- The drifted-comment fallback clamps a past-EOF comment onto a BUFFER's
    -- last line and then matches the cursor's line against that clamped span.
    -- In a preview the cursor's line is a FILE line while the clamp measures
    -- the preview BUFFER — so the fallback fires exactly when a mapped row's
    -- file line numerically equals the preview's row count, which is entirely
    -- ordinary (a 100-row preview and a file line 100).
    --
    -- This fixture is built to hit that coincidence: seven rendered rows, and
    -- row 5 addresses one.lua:7 on the new side. Without the guard, deleting
    -- there deletes the comment stored at line 9999 — a comment the preview
    -- does not draw anywhere. The assertion below on the coincidence is what
    -- keeps this test from quietly going vacuous if the fixture drifts.
    local COINCIDENT_DIFF = table.concat({
      "diff --git a/one.lua b/one.lua",
      "@@ -5,4 +5,4 @@",
      " p",
      " q",
      "-r",
      "+R",
      " s",
      "",
    }, "\n")

    it("does not reach a drifted comment through the preview's last row", function()
      st.add({ file = "one.lua", line = 9999, side = "new", type = "note", text = "drifted" })
      local rendered, roles = show_preview("inline", COINCIDENT_DIFF)
      local row = row_of(rendered.modified, "+R")
      local target = preview.target_at(rendered.modified, row)
      assert.same({ file = "one.lua", line = 7, side = "new" }, target)
      assert.equals(target.line, #rendered.modified.lines,
        "fixture must make a mapped row's FILE line equal the preview's ROW count, "
        .. "or the clamped fallback can never fire and this test proves nothing")

      focus(roles.modified, row)
      comments.delete(tab)

      assert.equals(1, st.count(),
        "a comment the preview does not draw must not be reachable in it")
    end)

    it("still reaches a drifted comment in a real file diff", function()
      -- The mirror: the guard must be scoped to previews, not disable the
      -- fallback outright. Five-line buffer, comment stored at line 500.
      st.add({ file = "a.lua", line = 500, side = "new", type = "note", text = "drifted" })
      local win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor", row = 0, col = 0, width = 20, height = 5, style = "minimal",
      })
      wins[#wins + 1] = win
      vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(win), 0, -1, false,
        { "1", "2", "3", "4", "5" })
      local real_get_session = view.get_session
      view.get_session = function() return { original_win = -1, modified_win = win } end
      view._last_shown[tab] = { file_entry = { path = "a.lua" } }
      focus(win, 5)

      comments.delete(tab)

      view.get_session = real_get_session
      assert.equals(0, st.count(),
        "the clamped fallback must still work where the buffer IS the file")
    end)
  end)
end)
