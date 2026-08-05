-- Commenting on the painted panes.
--
-- The load-bearing invariant under test: a painted pane is a COORDINATE
-- SYSTEM, never a storage concept. A comment made on a row of a whole-intent
-- render must be byte-for-byte the record commenting that same line in that
-- file's own render produces — so the store, the file on disk and the Markdown
-- export never learn that more than one file was on screen.
--
-- Everything here drives the REAL renderer (view.show over a real repo), which
-- is the point: after the unification there is only one render path, so the
-- test that used to prove the preview agreed with the file diff now proves the
-- one path agrees with itself over one file and over several.
local comments = require("intentdiff.comments")
local marks = require("intentdiff.comments.marks")
local popup = require("intentdiff.comments.popup")
local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")
local helpers = require("tests.helpers")
local view = require("intentdiff.view")

--- Two files. `zz/late.lua` carries an early insertion, so its old and new line
--- numbers differ by the time the interesting hunk arrives — a lost offset
--- cannot hide behind two sides that happen to agree.
---
---   old zz/late.lua              new zz/late.lua
---     1   filler 1                 1   filler 1
---                                  2   INSERTED
---     2   filler 2                 3   filler 2
---     ...                          ...
---     119 filler 119               120 filler 119
---     120 ctx a                    121 ctx a
---     121 gone                     122 arrived
---     122 ctx b                    123 ctx b
local function make_fixture()
  local base_late = {}
  for i = 1, 119 do base_late[i] = "filler " .. i end
  base_late[120] = "ctx a"
  base_late[121] = "gone"
  base_late[122] = "ctx b"

  local repo = helpers.make_repo({
    ["src/auth.lua"] = "keep\nold\n",
    ["zz/late.lua"] = table.concat(base_late, "\n") .. "\n",
  })
  local base = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))

  local new_late = { "filler 1", "INSERTED" }
  for i = 2, 119 do new_late[#new_late + 1] = "filler " .. i end
  new_late[#new_late + 1] = "ctx a"
  new_late[#new_late + 1] = "arrived"
  new_late[#new_late + 1] = "ctx b"

  helpers.write_file(repo, "src/auth.lua", "keep\nnew\nextra\n")
  helpers.write_file(repo, "zz/late.lua", table.concat(new_late, "\n") .. "\n")

  local hs, files = require("intentdiff.hunks").parse(helpers.git(repo, "diff"))
  for _, f in ipairs(files) do
    f.hunks = vim.tbl_filter(function(h) return h.file == f.path end, hs)
  end
  return repo, base, files
end

describe("comments on the painted panes", function()
  local repo, base, files
  local sess, tab, st, restore_session, real_open, notices, real_notify
  local extra_tabs

  --- Render `files` (all of them, or just the ones named) in `layout`.
  ---
  --- `visible` is deliberately EMPTY: with no hunk marked visible the plan
  --- folds nothing, so every row is on screen and a cursor move names exactly
  --- the row it says. Which hunks are unfolded is orthogonal to where a comment
  --- lands, and is pinned in render_plan_spec.
  --- @return table plan, table wins { original, modified }
  local function show(layout, only)
    local entries = files
    if only then
      entries = vim.tbl_filter(function(f) return vim.tbl_contains(only, f.path) end, files)
    end
    local ready = false
    assert.is_true(view.show(sess, entries, {}, {
      layout = layout,
      on_ready = function() ready = true end,
    }))
    assert.truthy(helpers.wait_for(function() return ready end, 10000), "view.show timed out")
    return view.current_plan(tab), view.pane_wins(tab)
  end

  --- The 1-indexed row of `pane` whose text is exactly `text`.
  local function row_of(pane, text)
    local found
    for i, l in ipairs(pane.lines) do
      if l == text then
        assert.is_nil(found, "ambiguous row for " .. text)
        found = i
      end
    end
    assert.truthy(found, "no row reads " .. vim.inspect(text))
    return found
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

  local function boxed_rows(bufnr)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, marks.ns, 0, -1, { details = true })) do
      if m[4].virt_lines then
        out[#out + 1] = m[2] + 1
      end
    end
    table.sort(out)
    return out
  end

  --- The painted buffers, original first.
  local function pane_bufs()
    local out = {}
    for i, entry in ipairs(view.painted_panes(tab)) do
      out[i] = entry.bufnr
    end
    return out
  end

  before_each(function()
    if not repo then
      -- Built once: the fixture is a real git repo and nothing here mutates it.
      repo, base, files = make_fixture()
    end
    config.setup({ cache_dir = vim.fn.tempname() })
    st = store.new()
    notices = {}
    extra_tabs = {}
    sess = { git_root = repo, base_revision = base, target_revision = nil }
    sess.tabpage = view.open_tab()
    tab = sess.tabpage
    restore_session = helpers.fake_session(tab, { comment_store = st })
    real_open = popup.open
    popup.open = function(opts, cb)
      cb(opts.type or "note", opts.text or "a comment")
    end
    real_notify = vim.notify
    vim.notify = function(msg, level)
      notices[#notices + 1] = { msg = msg, level = level }
    end
  end)

  after_each(function()
    popup.open = real_open
    vim.notify = real_notify
    restore_session()
    for _, restore in ipairs(extra_tabs) do
      restore()
    end
    pcall(view.close_tab, sess)
    while #vim.api.nvim_list_tabpages() > 1 do
      pcall(vim.cmd, "tabclose $")
    end
  end)

  local function last_notice()
    if not notices[#notices] then
      return nil
    end
    return notices[#notices].msg
  end

  -- -------------------------------------------------------------- adding --

  describe("adding", function()
    it("records a deletion row as an old-side comment on the real file line", function()
      local plan, wins = show("inline")
      focus(wins.modified, row_of(plan.modified, "gone"))

      comments.add(tab, "issue")

      assert.equals(1, st.count())
      local c = st.get_all()[1]
      assert.equals("zz/late.lua", c.file)
      assert.equals(121, c.line)
      assert.equals("old", c.side)
      assert.equals("issue", c.type)
      assert.is_nil(c.line_end)
    end)

    it("records an addition row as a new-side comment on the real file line", function()
      local plan, wins = show("inline")
      focus(wins.modified, row_of(plan.modified, "arrived"))

      comments.add(tab, "note")

      local c = st.get_all()[1]
      assert.equals("zz/late.lua", c.file)
      assert.equals(122, c.line)
      assert.equals("new", c.side)
    end)

    it("reads the side from the PANE in side-by-side, not from the window", function()
      local plan, wins = show("side-by-side")
      focus(wins.original, row_of(plan.original, "gone"))
      comments.add(tab, "note")
      focus(wins.modified, row_of(plan.modified, "arrived"))
      comments.add(tab, "note")

      local by_side = {}
      for _, c in ipairs(st.get_all()) do
        by_side[c.side] = c
      end
      assert.equals(121, by_side.old.line)
      assert.equals(122, by_side.new.line)
      assert.equals("zz/late.lua", by_side.old.file)
      assert.equals("zz/late.lua", by_side.new.file)
    end)

    it("records a visual range within one file", function()
      local plan, wins = show("inline")
      select_rows(wins.modified, row_of(plan.modified, "ctx a"), row_of(plan.modified, "ctx b"))

      comments.add(tab, "note", { visual = true })

      local c = st.get_all()[1]
      assert.equals("zz/late.lua", c.file)
      assert.equals("new", c.side)
      -- new-side rows in that span: 121 (ctx a), 122 (arrived), 123 (ctx b).
      assert.equals(121, c.line)
      assert.equals(123, c.line_end)
    end)

    it("stores nothing a single-file render would not store", function()
      local plan, wins = show("inline")
      focus(wins.modified, row_of(plan.modified, "arrived"))

      comments.add(tab, "note")

      local keys = {}
      for k in pairs(st.get_all()[1]) do
        keys[#keys + 1] = k
      end
      table.sort(keys)
      assert.same({ "created_at", "file", "line", "side", "text", "type" }, keys,
        "a comment made over an intent must carry no field a single-file one lacks")
    end)

    it("hangs a file-level comment off the file's own block, not the render's first row", function()
      local plan, wins = show("side-by-side")
      focus(wins.modified, row_of(plan.modified, "arrived"))

      comments.add_file(tab)

      local c = st.get_all()[1]
      assert.equals("zz/late.lua", c.file)
      assert.equals(0, c.line)

      marks.refresh(tab)
      local anchors = marks.file_anchors(plan)
      assert.is_true(anchors["zz/late.lua"] > anchors["src/auth.lua"],
        "the second file's block must start after the first's")
      assert.same({ anchors["zz/late.lua"] }, boxed_rows(pane_bufs()[2]))
    end)
  end)

  -- ------------------------------------------------------------ refusals --

  describe("refusing rows that address nothing", function()
    it("refuses a file separator, and says what to do", function()
      local plan, wins = show("inline")
      local sep
      for i, l in ipairs(plan.modified.lines) do
        if l:find("src/auth.lua", 1, true) then sep = i end
      end
      assert.truthy(sep)
      focus(wins.modified, sep)

      comments.add(tab, "note")

      assert.equals(0, st.count())
      assert.truthy(last_notice():find("put the cursor on", 1, true),
        "the refusal must name the fix, got: " .. tostring(last_notice()))
    end)

    it("refuses a side-by-side filler row", function()
      local plan, wins = show("side-by-side")
      -- "extra" has no counterpart, so the original pane carries a filler.
      local row = row_of(plan.modified, "extra")
      assert.equals("", plan.original.lines[row])
      assert.is_nil(plan.original.map[row])
      focus(wins.original, row)

      comments.add(tab, "note")

      assert.equals(0, st.count())
      assert.truthy(last_notice():find("put the cursor on", 1, true))
    end)

    it("refuses a visual range spanning two files, naming the problem", function()
      local plan, wins = show("inline")
      select_rows(wins.modified, row_of(plan.modified, "extra"), row_of(plan.modified, "gone"))

      comments.add(tab, "note", { visual = true })

      assert.equals(0, st.count())
      assert.truthy(last_notice():find("one file", 1, true),
        "the refusal must name the problem, got: " .. tostring(last_notice()))
    end)

    it("refuses when the cursor is not in a diff pane at all", function()
      show("inline")
      local other = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor", row = 0, col = 0, width = 10, height = 3, style = "minimal",
      })
      vim.api.nvim_set_current_win(other)

      comments.add(tab, "note")

      pcall(vim.api.nvim_win_close, other, true)
      assert.equals(0, st.count())
      assert.truthy(last_notice():find("diff pane", 1, true))
    end)
  end)

  -- ---------------------------------------------------------- round trip --

  describe("one file and several files agree", function()
    --- Comparable copy: `created_at` is a wall clock.
    local function shape(c)
      return { file = c.file, line = c.line, line_end = c.line_end, side = c.side,
        type = c.type, text = c.text }
    end

    --- The record commenting `text`'s row produces in a render of zz/late.lua
    --- ALONE, in its own tab.
    local function via_single_file(pane_name, text)
      local other_store = store.new()
      local other_sess = { git_root = repo, base_revision = base, target_revision = nil }
      other_sess.tabpage = view.open_tab()
      local restore = helpers.fake_session(other_sess.tabpage, { comment_store = other_store })
      extra_tabs[#extra_tabs + 1] = function()
        restore()
        pcall(view.close_tab, other_sess)
      end

      local ready = false
      view.show(other_sess, { files[2] }, {}, {
        layout = "side-by-side",
        on_ready = function() ready = true end,
      })
      assert.truthy(helpers.wait_for(function() return ready end, 10000))
      local plan = view.current_plan(other_sess.tabpage)
      local wins = view.pane_wins(other_sess.tabpage)
      focus(wins[pane_name], row_of(plan[pane_name], text))

      comments.add(other_sess.tabpage, "note")
      return other_store.get_all()[1]
    end

    it("produces the same record for a new-side line", function()
      local plan, wins = show("side-by-side")
      focus(wins.modified, row_of(plan.modified, "arrived"))
      comments.add(tab, "note")

      assert.same(shape(via_single_file("modified", "arrived")), shape(st.get_all()[1]))
    end)

    it("produces the same record for an old-side line", function()
      local plan, wins = show("side-by-side")
      focus(wins.original, row_of(plan.original, "gone"))
      comments.add(tab, "note")

      assert.same(shape(via_single_file("original", "gone")), shape(st.get_all()[1]))
    end)
  end)

  -- ----------------------------------------------------------- rendering --

  describe("rendering", function()
    it("draws a comment at its mapped row", function()
      st.add({ file = "zz/late.lua", line = 122, side = "new", type = "note", text = "hi" })
      local plan = show("inline")

      marks.refresh(tab)

      assert.same({ row_of(plan.modified, "arrived") }, boxed_rows(pane_bufs()[1]))
    end)

    -- Inline is one buffer interleaving both sides, and its deletion rows are
    -- real buffer lines — so an old-side comment DOES have a row to hang off.
    it("draws an old-side comment in the INLINE render, on the deletion row", function()
      st.add({ file = "zz/late.lua", line = 121, side = "old", type = "note", text = "hi" })
      local plan = show("inline")

      marks.refresh(tab)

      assert.same({ row_of(plan.modified, "gone") }, boxed_rows(pane_bufs()[1]))
    end)

    it("draws an old-side comment in the ORIGINAL pane only", function()
      st.add({ file = "zz/late.lua", line = 121, side = "old", type = "note", text = "hi" })
      local plan = show("side-by-side")

      marks.refresh(tab)

      local bufs = pane_bufs()
      assert.same({ row_of(plan.original, "gone") }, boxed_rows(bufs[1]))
      assert.same({}, boxed_rows(bufs[2]))
    end)

    -- The two panes are scrollbound and equal in length by construction; a box
    -- on one side is virt_lines, which makes that side taller. Without padding
    -- the sides drift apart.
    it("pads the opposite pane so a box does not break the scroll sync", function()
      st.add({ file = "zz/late.lua", line = 121, side = "old", type = "note", text = "one\ntwo" })
      local plan = show("side-by-side")

      marks.refresh(tab)

      local bufs = pane_bufs()
      local padded = vim.api.nvim_buf_get_extmarks(bufs[2], marks.ns_padding, 0, -1, { details = true })
      assert.equals(1, #padded)
      assert.equals(row_of(plan.original, "gone") - 1, padded[1][2])
      -- 2 text lines + 2 borders.
      assert.equals(4, #padded[1][4].virt_lines)
      assert.same({}, vim.api.nvim_buf_get_extmarks(bufs[1], marks.ns_padding, 0, -1, {}))
    end)

    it("draws nothing, and does not error, for a comment in a file this render omits", function()
      st.add({ file = "elsewhere.lua", line = 3, side = "new", type = "note", text = "hi" })
      show("inline", { "src/auth.lua" })

      marks.refresh(tab)

      assert.same({}, boxed_rows(pane_bufs()[1]))
      assert.equals(1, st.count(), "the comment must survive un-rendered")
    end)

    it("re-applies the boxes on every render, not only on mutation", function()
      st.add({ file = "zz/late.lua", line = 122, side = "new", type = "note", text = "hi" })
      show("inline")
      assert.equals(1, #boxed_rows(pane_bufs()[1]), "view.show must draw them itself")

      -- A re-render paints fresh buffers; extmarks live on the buffer.
      local plan = show("inline")

      assert.same({ row_of(plan.modified, "arrived") }, boxed_rows(pane_bufs()[1]))
    end)
  end)

  -- ------------------------------------------------------ edit and delete --

  describe("editing and deleting at the cursor", function()
    it("edits the comment the cursor's row maps to", function()
      st.add({ file = "zz/late.lua", line = 122, side = "new", type = "note", text = "before" })
      local plan, wins = show("inline")
      focus(wins.modified, row_of(plan.modified, "arrived"))
      popup.open = function(_, cb) cb("issue", "after") end

      comments.edit(tab)

      local c = st.get_all()[1]
      assert.equals("issue", c.type)
      assert.equals("after", c.text)
    end)

    it("deletes the comment the cursor's row maps to", function()
      st.add({ file = "zz/late.lua", line = 122, side = "new", type = "note", text = "x" })
      local plan, wins = show("inline")
      focus(wins.modified, row_of(plan.modified, "arrived"))

      comments.delete(tab)

      assert.equals(0, st.count())
    end)

    it("does not answer for a row the comment is not on", function()
      st.add({ file = "zz/late.lua", line = 122, side = "new", type = "note", text = "x" })
      local plan, wins = show("inline")
      focus(wins.modified, row_of(plan.modified, "ctx b"))

      comments.delete(tab)

      assert.equals(1, st.count())
    end)

    -- A comment can outlive the lines it pointed at. The renderer clamps it
    -- onto the last row of ITS OWN file so it stays visible; the action layer
    -- must agree, and must agree ONLY there.
    describe("a comment that drifted past the end of its file", function()
      before_each(function()
        st.add({ file = "src/auth.lua", line = 500, side = "new", type = "note", text = "drifted" })
      end)

      it("is drawn on its file's last row, not the render's", function()
        local plan = show("side-by-side")
        marks.refresh(tab)
        local rows = boxed_rows(pane_bufs()[2])
        assert.equals(1, #rows)
        assert.equals("src/auth.lua", plan.modified.map[rows[1]].file,
          "the clamp must stay inside the comment's own file")
        assert.is_true(rows[1] < row_of(plan.modified, "arrived"),
          "and must not land in the file that follows it")
      end)

      it("is deletable from the row its box is drawn on", function()
        local plan, wins = show("side-by-side")
        marks.refresh(tab)
        focus(wins.modified, boxed_rows(pane_bufs()[2])[1])

        comments.delete(tab)

        assert.equals(0, st.count())
        assert.truthy(plan)
      end)

      it("is not reachable from another file's rows", function()
        local plan, wins = show("side-by-side")
        focus(wins.modified, row_of(plan.modified, "arrived"))

        comments.delete(tab)

        assert.equals(1, st.count(),
          "a comment drawn in one file's block must not answer from another's")
      end)
    end)
  end)

  -- ------------------------------------------------------------- ]n / [n --

  describe("comment navigation", function()
    it("walks the boxes of the render, across files", function()
      st.add({ file = "src/auth.lua", line = 2, side = "new", type = "note", text = "a" })
      st.add({ file = "zz/late.lua", line = 122, side = "new", type = "note", text = "b" })
      local plan, wins = show("side-by-side")

      local first = row_of(plan.modified, "new")
      local second = row_of(plan.modified, "arrived")
      focus(wins.modified, 1)
      comments.next(tab)
      assert.equals(first, vim.api.nvim_win_get_cursor(wins.modified)[1])
      comments.next(tab)
      assert.equals(second, vim.api.nvim_win_get_cursor(wins.modified)[1],
        "]n must reach the next file's comment in an intent render")
      comments.prev(tab)
      assert.equals(first, vim.api.nvim_win_get_cursor(wins.modified)[1])
    end)

    it("refuses outside a diff pane, leaving that cursor alone", function()
      show("side-by-side")
      st.add({ file = "zz/late.lua", line = 122, side = "new", type = "note", text = "b" })
      local other = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor", row = 0, col = 0, width = 10, height = 3, style = "minimal",
      })
      vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(other), 0, -1, false, { "a", "b", "c" })
      focus(other, 2)

      comments.next(tab)

      assert.equals(2, vim.api.nvim_win_get_cursor(other)[1])
      pcall(vim.api.nvim_win_close, other, true)
      assert.truthy(last_notice():find("diff pane", 1, true))
    end)
  end)
end)
