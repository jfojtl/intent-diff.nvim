local comments = require("intentdiff.comments")
local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")
local helpers = require("tests.helpers")

describe("comments actions", function()
  --- The store of the review under test. The action layer resolves it from the
  --- tabpage's session entry, so tests that go through an action (edit,
  --- delete, list) install a fake session carrying this store; the pure
  --- helpers (next_line, prev_line, list_entries) take it directly.
  local st

  before_each(function()
    config.setup({ cache_dir = vim.fn.tempname() })
    st = store.new()
  end)

  describe("side_for_win", function()
    it("reads old from the original window and new from the modified one", function()
      assert.equals("old", comments.side_for_win(10, { original_win = 10, modified_win = 11 }))
      assert.equals("new", comments.side_for_win(11, { original_win = 10, modified_win = 11 }))
    end)

    it("defaults to new when the window is neither pane", function()
      assert.equals("new", comments.side_for_win(99, { original_win = 10, modified_win = 11 }))
    end)

    it("is new in inline layout, where there is one pane", function()
      assert.equals("new", comments.side_for_win(11, { original_win = 11, modified_win = 11 }))
    end)
  end)

  describe("visual_range", function()
    it("returns start and end for a multi-line selection", function()
      local first, last = comments.visual_range(7, 3)
      assert.equals(3, first)
      assert.equals(7, last)
    end)

    it("collapses a single-line selection to no range", function()
      local first, last = comments.visual_range(4, 4)
      assert.equals(4, first)
      assert.is_nil(last)
    end)
  end)

  describe("next/prev targets", function()
    it("finds the next comment line after the cursor", function()
      st.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
      st.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "y" })
      assert.equals(9, comments.next_line(st, "a.lua", 3, "new"))
      assert.equals(3, comments.next_line(st, "a.lua", 1, "new"))
      assert.is_nil(comments.next_line(st, "a.lua", 9, "new"))
    end)

    it("finds the previous comment line before the cursor", function()
      st.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
      st.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "y" })
      assert.equals(3, comments.prev_line(st, "a.lua", 9, "new"))
      assert.is_nil(comments.prev_line(st, "a.lua", 3, "new"))
    end)

    it("returns the NEAREST previous comment, not the earliest", function()
      -- With only comments at 3 and 9, prev_line(9) == 3 under both the
      -- correct "nearest" implementation and a mutant that just returns the
      -- first match found. A third comment at 5 pins down which one it is:
      -- only "nearest" answers 5 here.
      st.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
      st.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "z" })
      st.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "y" })
      assert.equals(5, comments.prev_line(st, "a.lua", 9, "new"))
      assert.is_nil(comments.prev_line(st, "a.lua", 3, "new"))
    end)

    it("ignores file-level comments when navigating", function()
      st.add({ file = "a.lua", line = 0, type = "note", text = "f" })
      st.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "x" })
      assert.equals(5, comments.next_line(st, "a.lua", 1, "new"))
    end)
  end)

  describe("list entries", function()
    it("labels each comment with type, location and first text line", function()
      st.add({ file = "a.lua", line = 3, side = "new", type = "issue", text = "bad thing\nmore" })
      st.add({ intent_title = "Rename", type = "note", text = "whole intent" })
      local entries = comments.list_entries(st)
      assert.equals(2, #entries)
      assert.is_truthy(entries[1].label:match("ISSUE"))
      assert.is_truthy(entries[1].label:match("a%.lua:3"))
      assert.is_truthy(entries[1].label:match("bad thing"))
      assert.is_nil(entries[1].label:match("more"))
      assert.is_truthy(entries[2].label:match("Rename"))
    end)

    it("labels a range comment with both endpoints", function()
      st.add({ file = "b.lua", line = 4, line_end = 8, side = "new", type = "suggestion", text = "range" })
      local entries = comments.list_entries(st)
      assert.equals(1, #entries)
      assert.is_truthy(entries[1].label:match("b%.lua:4%-8"))
    end)

    it("labels a file-level comment with just the file path", function()
      st.add({ file = "c.lua", line = 0, type = "praise", text = "nice file" })
      local entries = comments.list_entries(st)
      assert.equals(1, #entries)
      assert.is_truthy(entries[1].label:match("PRAISE"))
      assert.is_truthy(entries[1].label:match("c%.lua"))
      assert.is_nil(entries[1].label:match("c%.lua:"))
    end)
  end)

  --- `attach_session` now gives the session entry its own store and returns
  --- it, so each of these attaches yields a distinct store — exactly what a
  --- second review tab gets. Every assertion is against the store of the
  --- attach it is about.
  describe("session attach", function()
    it("keys a working-tree session by branch", function()
      local repo = require("tests.helpers").make_repo({ ["a.lua"] = "x" })
      local first = comments.attach_session({ sess = { git_root = repo } })
      first.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "x" })
      -- Re-attaching the same session must find the comment on disk.
      local again = comments.attach_session({ sess = { git_root = repo } })
      assert.are_not.equals(first, again, "each attach must get its own store")
      assert.equals(1, again.count())
    end)

    it("hangs the store off the session entry it was given", function()
      local repo = require("tests.helpers").make_repo({ ["a.lua"] = "x" })
      local entry = { sess = { git_root = repo } }
      local returned = comments.attach_session(entry)
      assert.equals(returned, entry.comment_store)
      -- And the tabpage lookup the action layer uses finds exactly that store.
      local tab = 900010
      entry.sess.tabpage = tab
      local restore = helpers.fake_session(tab, entry)
      assert.equals(returned, comments.store_for(tab))
      restore()
    end)

    it("keeps two revision ranges of one repo apart", function()
      local repo = require("tests.helpers").make_repo({ ["a.lua"] = "x" })
      local a = comments.attach_session({
        sess = { git_root = repo, base_revision = "aaa", target_revision = "bbb" } })
      a.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
      local b = comments.attach_session({
        sess = { git_root = repo, base_revision = "ccc", target_revision = "ddd" } })
      assert.equals(0, b.count())
    end)

    -- Regression for the bug in the original brief: init.lua ALWAYS populates
    -- both base_revision and target_revision once a review resolves — for a
    -- plain `:IntentDiff` working-tree review, base_revision becomes the
    -- resolved HEAD hash and target_revision becomes "WORKING". Keying on
    -- "are both revisions present" (rather than "is target explicitly
    -- WORKING and base still exactly HEAD") would therefore ALWAYS take the
    -- revision-pair branch for a working-tree review too, pinning its
    -- storage key to whatever commit HEAD happened to be at the moment it was
    -- opened. The moment the user commits, HEAD moves, the key changes, and
    -- every comment the review holds silently vanishes.
    it("survives a new commit for a working-tree review, and keeps a HEAD~1-pinned review separate", function()
      local repo = helpers.make_repo({ ["a.lua"] = "x" })
      local base_before = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))

      -- Attach exactly as init.lua does once the FIRST review of a plain
      -- `:IntentDiff` resolves: base_revision = the resolved HEAD hash,
      -- target_revision = "WORKING".
      local first = comments.attach_session({
        sess = { git_root = repo, base_revision = base_before, target_revision = "WORKING" },
      })
      first.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "worktree comment" })
      assert.equals(1, first.count())

      -- The user commits. HEAD moves.
      helpers.write_file(repo, "b.lua", "y")
      helpers.git(repo, "add", "-A")
      helpers.git(repo, "commit", "-q", "-m", "second")
      local head_after = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
      assert.are_not.equals(base_before, head_after)

      -- A SECOND `:IntentDiff` now resolves against the NEW HEAD: init.lua
      -- would populate base_revision = head_after, target_revision =
      -- "WORKING" again. This must land on the SAME storage key as before —
      -- the comment must still be there. A brand-new store, loaded from disk:
      -- nothing can be inherited in memory.
      local second = comments.attach_session({
        sess = { git_root = repo, base_revision = head_after, target_revision = "WORKING" },
      })
      assert.equals(1, second.count())
      assert.equals("worktree comment", second.get_all()[1].text)

      -- A `:IntentDiff HEAD~1`-shaped review — base pinned away from HEAD,
      -- target still "WORKING" — must NOT share that key: it is reviewing a
      -- fixed, explicit revision range, not "whatever the branch is now".
      local pinned = comments.attach_session({
        sess = { git_root = repo, base_revision = base_before, target_revision = "WORKING" },
      })
      assert.equals(0, pinned.count())
    end)
  end)

  -- `store.collides` deliberately allows several comments on ONE intent (the
  -- design spec's "a group can have several; they are emitted in creation
  -- order"). edit/delete resolve the comment under the cursor via
  -- `at_cursor`, which acts directly when there is exactly one, and opens a
  -- `vim.ui.select` picker — the same one `list` uses, with matching labels —
  -- to disambiguate when there are several. A file-level comment never hits
  -- the picker: `store.collides` enforces one per file.
  describe("edit/delete disambiguation for multiple intent comments", function()
    local popup = require("intentdiff.comments.popup")
    local view = require("intentdiff.view")
    local real_context, real_select, real_open, real_get_session, restore_session

    before_each(function()
      real_context = comments.context
      real_select = vim.ui.select
      real_open = popup.open
      -- edit/delete call marks.refresh() on success, which calls
      -- view.get_session() unconditionally (even with no file shown for this
      -- tabpage). The real one indexes codediff internals that view.load()
      -- (never called in this spec) leaves nil, so it must be stubbed here —
      -- these tests are about the disambiguation picker, not a real review
      -- tab's pane rendering.
      real_get_session = view.get_session
      view.get_session = function() return nil end
      -- edit/delete take no tabpage here, so they resolve the CURRENT one; the
      -- store they act on is the one on that tab's session entry.
      restore_session = helpers.fake_session(vim.api.nvim_get_current_tabpage(),
        { comment_store = st })
    end)

    after_each(function()
      comments.context = real_context
      vim.ui.select = real_select
      popup.open = real_open
      view.get_session = real_get_session
      restore_session()
    end)

    it("edits a single intent comment directly, without opening a picker", function()
      comments.context = function() return { intent_title = "Rename" } end
      local c = st.add({ intent_title = "Rename", type = "note", text = "only one" })

      local select_called = false
      vim.ui.select = function() select_called = true end
      popup.open = function(_, cb) cb("issue", "edited text") end

      comments.edit()

      assert.is_false(select_called)
      assert.equals("issue", c.type)
      assert.equals("edited text", c.text)
    end)

    it("opens a picker to disambiguate several intent comments, and edits only the chosen one", function()
      comments.context = function() return { intent_title = "Rename" } end
      local first = st.add({ intent_title = "Rename", type = "note", text = "first" })
      local second = st.add({ intent_title = "Rename", type = "note", text = "second" })

      vim.ui.select = function(entries, _, cb)
        for _, e in ipairs(entries) do
          if e.comment == second then
            return cb(e)
          end
        end
      end
      popup.open = function(_, cb) cb("praise", "edited second") end

      comments.edit()

      assert.equals("note", first.type)
      assert.equals("first", first.text)
      assert.equals("praise", second.type)
      assert.equals("edited second", second.text)
    end)

    it("opens a picker to disambiguate on delete, removing only the chosen one", function()
      comments.context = function() return { intent_title = "Rename" } end
      local first = st.add({ intent_title = "Rename", type = "note", text = "first" })
      local second = st.add({ intent_title = "Rename", type = "note", text = "second" })

      -- Picks SECOND, not first: get_for_intent returns comments in creation
      -- order, so a mutant that skips the picker and always acts on
      -- candidates[1] would delete `first` here and pass by coincidence if
      -- this test picked `first` instead.
      vim.ui.select = function(entries, _, cb)
        for _, e in ipairs(entries) do
          if e.comment == second then
            return cb(e)
          end
        end
      end

      comments.delete()

      assert.equals(1, st.count())
      assert.equals(first, st.get_all()[1])
    end)
  end)

  -- Picking a comment in a file that is NOT on screen opens that file first
  -- (intentdiff.open_path — the same select_file/open_file route sidebar <CR>
  -- takes, so it arrives folded to its intent) and places the cursor from the
  -- open path's completion callback. Jumping straight to the comment's line
  -- number in whatever happens to be displayed would land on the wrong line of
  -- the WRONG file, so a file this review cannot open still refuses rather
  -- than guessing. Same hazard for an old-side comment jumped into a pane that
  -- isn't the original side.
  describe("list", function()
    local view = require("intentdiff.view")
    local tab
    local real_select, real_get_session, real_diff_wins, real_open_path
    local win_orig, win_mod, restore_session

    before_each(function()
      tab = 900002 -- sentinel key, never a real tabpage id
      real_select = vim.ui.select
      real_get_session = view.get_session
      real_diff_wins = view.diff_wins
      real_open_path = require("intentdiff").open_path
      win_orig = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor", row = 0, col = 0, width = 20, height = 5, style = "minimal",
      })
      win_mod = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
        relative = "editor", row = 6, col = 0, width = 20, height = 5, style = "minimal",
      })
      -- Buffers need >= 5 lines for a cursor move to line 5 to succeed.
      for _, w in ipairs({ win_orig, win_mod }) do
        vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(w), 0, -1, false,
          { "1", "2", "3", "4", "5" })
      end
      view.get_session = function() return { original_win = win_orig, modified_win = win_mod } end
      view.diff_wins = function() return { win_orig, win_mod } end
      view._last_shown[tab] = { file_entry = { path = "a.lua" } }
      -- `list` resolves the review's store from this tab's session entry.
      restore_session = helpers.fake_session(tab, { comment_store = st })
    end)

    after_each(function()
      vim.ui.select = real_select
      view.get_session = real_get_session
      view.diff_wins = real_diff_wins
      require("intentdiff").open_path = real_open_path
      restore_session()
      view._last_shown[tab] = nil
      view._preview_active[tab] = nil
      pcall(vim.api.nvim_win_close, win_orig, true)
      pcall(vim.api.nvim_win_close, win_mod, true)
    end)

    it("opens the comment's file, then jumps, when it is not the one on screen", function()
      st.add({ file = "b.lua", line = 5, side = "new", type = "note", text = "x" })
      vim.ui.select = function(entries, _, cb) cb(entries[1]) end

      local asked_tab, asked_path
      require("intentdiff").open_path = function(tabpage, path, on_shown)
        asked_tab, asked_path = tabpage, path
        -- The real one renders the file and folds it to its intent before
        -- calling back; the cursor must be placed from THAT callback, not
        -- before it.
        assert.equals(1, vim.api.nvim_win_get_cursor(win_mod)[1])
        on_shown()
        return true
      end

      comments.list(tab)

      assert.equals(tab, asked_tab)
      assert.equals("b.lua", asked_path)
      assert.equals(5, vim.api.nvim_win_get_cursor(win_mod)[1])
    end)

    it("refuses to jump when the review cannot open the comment's file", function()
      st.add({ file = "b.lua", line = 5, side = "new", type = "note", text = "x" })
      vim.ui.select = function(entries, _, cb) cb(entries[1]) end
      require("intentdiff").open_path = function() return false end

      comments.list(tab)

      -- Never the shown file's line 5: that is a different file's line.
      assert.equals(1, vim.api.nvim_win_get_cursor(win_orig)[1])
      assert.equals(1, vim.api.nvim_win_get_cursor(win_mod)[1])
    end)

    it("jumps straight in when the comment's file is already shown", function()
      st.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "x" })
      vim.ui.select = function(entries, _, cb) cb(entries[1]) end
      local opened = false
      require("intentdiff").open_path = function()
        opened = true
        return true
      end

      comments.list(tab)

      assert.is_false(opened, "the file on screen must not be re-opened")
      assert.equals(5, vim.api.nvim_win_get_cursor(win_mod)[1])
    end)

    -- `_last_shown` names the last file RENDERED, not what the panes DISPLAY.
    -- A hover preview swaps its own buffers in without touching it, so during
    -- a preview _last_shown still names the pre-preview file while the panes
    -- hold a whole intent's files concatenated. Jumping to c.line there lands
    -- on an arbitrary line of an unrelated file — the same wrong-file hazard
    -- this function refuses to take when the file simply isn't open.
    it("does not jump into a hover preview's buffers, even for the last-shown file", function()
      st.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "x" })
      vim.ui.select = function(entries, _, cb) cb(entries[1]) end
      view._preview_active[tab] = { title = "An intent" }
      local asked_path
      require("intentdiff").open_path = function(_, path)
        asked_path = path
        return true -- the real one re-renders the file; on_shown deliberately
                    -- not called, so any cursor move here would be this
                    -- function jumping on its own.
      end

      comments.list(tab)

      assert.equals("a.lua", asked_path,
        "a live preview must route through open_path, not be treated as shown")
      assert.equals(1, vim.api.nvim_win_get_cursor(win_mod)[1])
      assert.equals(1, vim.api.nvim_win_get_cursor(win_orig)[1])
    end)

    it("jumps only the pane whose side matches an old-side comment", function()
      st.add({ file = "a.lua", line = 5, side = "old", type = "note", text = "x" })
      vim.ui.select = function(entries, _, cb) cb(entries[1]) end

      comments.list(tab)

      assert.equals(5, vim.api.nvim_win_get_cursor(win_orig)[1])
      assert.equals(1, vim.api.nvim_win_get_cursor(win_mod)[1])
    end)

    -- `place_cursor` clamps like marks does, so the picker lands on the box
    -- rather than failing a cursor move to a line that no longer exists.
    it("jumps to the line a drifted comment's box is actually drawn on", function()
      st.add({ file = "a.lua", line = 500, side = "new", type = "note", text = "drifted" })
      vim.ui.select = function(entries, _, cb) cb(entries[1]) end

      comments.list(tab)

      assert.equals(5, vim.api.nvim_win_get_cursor(win_mod)[1])
    end)
  end)

  -- The action layer itself — `M.edit`, `M.delete`, `M.next`, `M.prev` driven
  -- exactly as the keymaps drive them, with a real window under a real cursor.
  -- Nothing here stubs `M.context`: the two bugs these cover (a drifted comment
  -- that renders but cannot be reached, and `]n` fired from the sidebar) both
  -- live between the cursor and the store, which is precisely what a stubbed
  -- context hides.
  describe("edit/delete/next/prev at a real cursor", function()
    local view = require("intentdiff.view")
    local popup = require("intentdiff.comments.popup")
    local tab
    local real_get_session, real_diff_wins, real_open
    local win_orig, win_mod, win_sidebar, restore_session

    local function float(rows)
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, rows)
      return vim.api.nvim_open_win(buf, false, {
        relative = "editor", row = 0, col = 0, width = 20, height = 5, style = "minimal",
      })
    end

    before_each(function()
      tab = 900003 -- sentinel key, never a real tabpage id
      real_get_session = view.get_session
      real_diff_wins = view.diff_wins
      real_open = popup.open
      -- Five-line panes: a comment stored at line 500 is well past EOF.
      win_orig = float({ "1", "2", "3", "4", "5" })
      win_mod = float({ "1", "2", "3", "4", "5" })
      win_sidebar = float({ "s1", "s2", "s3", "s4", "s5" })
      view.get_session = function() return { original_win = win_orig, modified_win = win_mod } end
      view.diff_wins = function() return { win_orig, win_mod } end
      view._last_shown[tab] = { file_entry = { path = "a.lua" } }
      restore_session = helpers.fake_session(tab, {
        comment_store = st,
        -- The sidebar the comment keys are also installed on.
        sidebar = { winid = win_sidebar, meta_at = function() return {} end },
      })
    end)

    after_each(function()
      view.get_session = real_get_session
      view.diff_wins = real_diff_wins
      popup.open = real_open
      restore_session()
      view._last_shown[tab] = nil
      view._preview_active[tab] = nil
      for _, w in ipairs({ win_orig, win_mod, win_sidebar }) do
        pcall(vim.api.nvim_win_close, w, true)
      end
    end)

    --- Focus `win` with the cursor on `line`, the way a keypress would arrive.
    local function focus(win, line)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { line, 0 })
    end

    -- A working-tree review outlives the tree it reviews (that is what branch
    -- keying is FOR), so a stored comment can end up past the end of the file.
    -- marks clamps its box onto the last line so it "degrades visibly"; the
    -- action layer used to keep matching on the RAW line, so the box was
    -- visible and the comment was un-editable, un-deletable and un-jumpable —
    -- escapable only by destroying the whole review.
    describe("a comment that drifted past the end of the file", function()
      before_each(function()
        st.add({ file = "a.lua", line = 500, side = "new", type = "note", text = "drifted" })
      end)

      it("is editable from the line its box is drawn on", function()
        focus(win_mod, 5)
        popup.open = function(_, cb) cb("issue", "edited drifted") end

        comments.edit(tab)

        local c = st.get_all()[1]
        assert.equals("issue", c.type)
        assert.equals("edited drifted", c.text)
      end)

      it("is deletable from the line its box is drawn on", function()
        focus(win_mod, 5)

        comments.delete(tab)

        assert.equals(0, st.count())
      end)

      it("does not answer for a line its box is NOT drawn on", function()
        focus(win_mod, 2)
        popup.open = function(_, cb) cb("issue", "must not happen") end

        comments.edit(tab)

        assert.equals("drifted", st.get_all()[1].text,
          "the clamped fallback must only match the row the box is on")
      end)

      it("is reachable with ]n, which lands on the box's real row", function()
        focus(win_mod, 1)

        comments.next(tab)

        assert.equals(5, vim.api.nvim_win_get_cursor(win_mod)[1])
      end)
    end)

    -- `]n`/`[n` are installed on the SIDEBAR too (all the comment keys are, so
    -- the export keys are reachable from either surface). Read there, the
    -- sidebar's ROW is not a diff line: the cursor jumped to an arbitrary row,
    -- and with `preview.hover_opens_files` on by default that fired the hover
    -- preview and re-rendered the panes to whatever intent that row belongs to.
    describe("navigation outside a diff pane", function()
      before_each(function()
        st.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
      end)

      it("moves the cursor when it IS in a diff pane", function()
        focus(win_mod, 1)
        comments.next(tab)
        assert.equals(3, vim.api.nvim_win_get_cursor(win_mod)[1],
          "the guard must not refuse in the pane the keys are meant for")
      end)

      it("refuses ]n in the sidebar, leaving the sidebar cursor alone", function()
        focus(win_sidebar, 1)

        comments.next(tab)

        assert.equals(1, vim.api.nvim_win_get_cursor(win_sidebar)[1])
      end)

      it("refuses [n in the sidebar, leaving the sidebar cursor alone", function()
        focus(win_sidebar, 5)

        comments.prev(tab)

        assert.equals(5, vim.api.nvim_win_get_cursor(win_sidebar)[1])
      end)

      -- A preview buffer holds a whole intent's files concatenated. Its rows
      -- ARE resolvable — M.context and marks.refresh go through the render's
      -- row map — but they are not the SHOWN file's lines, which is what
      -- `finder` walks, so ]n/[n still refuse (as does M.list's jump).
      it("refuses in a hover preview", function()
        view._preview_active[tab] = { title = "An intent" }
        focus(win_mod, 1)

        comments.next(tab)

        assert.equals(1, vim.api.nvim_win_get_cursor(win_mod)[1])
      end)
    end)
  end)
end)
