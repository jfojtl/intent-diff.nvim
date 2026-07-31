local comments = require("intentdiff.comments")
local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")

describe("comments actions", function()
  before_each(function()
    config.setup({ cache_dir = vim.fn.tempname() })
    store.detach()
    store.clear()
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
      store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
      store.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "y" })
      assert.equals(9, comments.next_line("a.lua", 3, "new"))
      assert.equals(3, comments.next_line("a.lua", 1, "new"))
      assert.is_nil(comments.next_line("a.lua", 9, "new"))
    end)

    it("finds the previous comment line before the cursor", function()
      store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
      store.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "y" })
      assert.equals(3, comments.prev_line("a.lua", 9, "new"))
      assert.is_nil(comments.prev_line("a.lua", 3, "new"))
    end)

    it("returns the NEAREST previous comment, not the earliest", function()
      -- With only comments at 3 and 9, prev_line(9) == 3 under both the
      -- correct "nearest" implementation and a mutant that just returns the
      -- first match found. A third comment at 5 pins down which one it is:
      -- only "nearest" answers 5 here.
      store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
      store.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "z" })
      store.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "y" })
      assert.equals(5, comments.prev_line("a.lua", 9, "new"))
      assert.is_nil(comments.prev_line("a.lua", 3, "new"))
    end)

    it("ignores file-level comments when navigating", function()
      store.add({ file = "a.lua", line = 0, type = "note", text = "f" })
      store.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "x" })
      assert.equals(5, comments.next_line("a.lua", 1, "new"))
    end)
  end)

  describe("list entries", function()
    it("labels each comment with type, location and first text line", function()
      store.add({ file = "a.lua", line = 3, side = "new", type = "issue", text = "bad thing\nmore" })
      store.add({ intent_title = "Rename", type = "note", text = "whole intent" })
      local entries = comments.list_entries()
      assert.equals(2, #entries)
      assert.is_truthy(entries[1].label:match("ISSUE"))
      assert.is_truthy(entries[1].label:match("a%.lua:3"))
      assert.is_truthy(entries[1].label:match("bad thing"))
      assert.is_nil(entries[1].label:match("more"))
      assert.is_truthy(entries[2].label:match("Rename"))
    end)

    it("labels a range comment with both endpoints", function()
      store.add({ file = "b.lua", line = 4, line_end = 8, side = "new", type = "suggestion", text = "range" })
      local entries = comments.list_entries()
      assert.equals(1, #entries)
      assert.is_truthy(entries[1].label:match("b%.lua:4%-8"))
    end)

    it("labels a file-level comment with just the file path", function()
      store.add({ file = "c.lua", line = 0, type = "praise", text = "nice file" })
      local entries = comments.list_entries()
      assert.equals(1, #entries)
      assert.is_truthy(entries[1].label:match("PRAISE"))
      assert.is_truthy(entries[1].label:match("c%.lua"))
      assert.is_nil(entries[1].label:match("c%.lua:"))
    end)
  end)

  describe("session attach", function()
    it("keys a working-tree session by branch", function()
      local repo = require("tests.helpers").make_repo({ ["a.lua"] = "x" })
      comments.attach_session({ sess = { git_root = repo } })
      store.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "x" })
      -- Re-attaching the same session must find the comment on disk.
      store.replace({})
      comments.attach_session({ sess = { git_root = repo } })
      assert.equals(1, store.count())
    end)

    it("keeps two revision ranges of one repo apart", function()
      local repo = require("tests.helpers").make_repo({ ["a.lua"] = "x" })
      comments.attach_session({ sess = { git_root = repo, base_revision = "aaa", target_revision = "bbb" } })
      store.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
      comments.attach_session({ sess = { git_root = repo, base_revision = "ccc", target_revision = "ddd" } })
      assert.equals(0, store.count())
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
      local helpers = require("tests.helpers")
      local repo = helpers.make_repo({ ["a.lua"] = "x" })
      local base_before = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))

      -- Attach exactly as init.lua does once the FIRST review of a plain
      -- `:IntentDiff` resolves: base_revision = the resolved HEAD hash,
      -- target_revision = "WORKING".
      comments.attach_session({
        sess = { git_root = repo, base_revision = base_before, target_revision = "WORKING" },
      })
      store.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "worktree comment" })
      assert.equals(1, store.count())

      -- The user commits. HEAD moves.
      helpers.write_file(repo, "b.lua", "y")
      helpers.git(repo, "add", "-A")
      helpers.git(repo, "commit", "-q", "-m", "second")
      local head_after = vim.trim(helpers.git(repo, "rev-parse", "HEAD"))
      assert.are_not.equals(base_before, head_after)

      -- A SECOND `:IntentDiff` now resolves against the NEW HEAD: init.lua
      -- would populate base_revision = head_after, target_revision =
      -- "WORKING" again. This must land on the SAME storage key as before —
      -- the comment must still be there.
      store.replace({})
      comments.attach_session({
        sess = { git_root = repo, base_revision = head_after, target_revision = "WORKING" },
      })
      assert.equals(1, store.count())
      assert.equals("worktree comment", store.get_all()[1].text)

      -- A `:IntentDiff HEAD~1`-shaped review — base pinned away from HEAD,
      -- target still "WORKING" — must NOT share that key: it is reviewing a
      -- fixed, explicit revision range, not "whatever the branch is now".
      comments.attach_session({
        sess = { git_root = repo, base_revision = base_before, target_revision = "WORKING" },
      })
      assert.equals(0, store.count())
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
    local real_context, real_select, real_open, real_get_session

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
    end)

    after_each(function()
      comments.context = real_context
      vim.ui.select = real_select
      popup.open = real_open
      view.get_session = real_get_session
    end)

    it("edits a single intent comment directly, without opening a picker", function()
      comments.context = function() return { intent_title = "Rename" } end
      local c = store.add({ intent_title = "Rename", type = "note", text = "only one" })

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
      local first = store.add({ intent_title = "Rename", type = "note", text = "first" })
      local second = store.add({ intent_title = "Rename", type = "note", text = "second" })

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
      local first = store.add({ intent_title = "Rename", type = "note", text = "first" })
      local second = store.add({ intent_title = "Rename", type = "note", text = "second" })

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

      assert.equals(1, store.count())
      assert.equals(first, store.get_all()[1])
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
    local win_orig, win_mod

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
    end)

    after_each(function()
      vim.ui.select = real_select
      view.get_session = real_get_session
      view.diff_wins = real_diff_wins
      require("intentdiff").open_path = real_open_path
      view._last_shown[tab] = nil
      pcall(vim.api.nvim_win_close, win_orig, true)
      pcall(vim.api.nvim_win_close, win_mod, true)
    end)

    it("opens the comment's file, then jumps, when it is not the one on screen", function()
      store.add({ file = "b.lua", line = 5, side = "new", type = "note", text = "x" })
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
      store.add({ file = "b.lua", line = 5, side = "new", type = "note", text = "x" })
      vim.ui.select = function(entries, _, cb) cb(entries[1]) end
      require("intentdiff").open_path = function() return false end

      comments.list(tab)

      -- Never the shown file's line 5: that is a different file's line.
      assert.equals(1, vim.api.nvim_win_get_cursor(win_orig)[1])
      assert.equals(1, vim.api.nvim_win_get_cursor(win_mod)[1])
    end)

    it("jumps straight in when the comment's file is already shown", function()
      store.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "x" })
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

    it("jumps only the pane whose side matches an old-side comment", function()
      store.add({ file = "a.lua", line = 5, side = "old", type = "note", text = "x" })
      vim.ui.select = function(entries, _, cb) cb(entries[1]) end

      comments.list(tab)

      assert.equals(5, vim.api.nvim_win_get_cursor(win_orig)[1])
      assert.equals(1, vim.api.nvim_win_get_cursor(win_mod)[1])
    end)
  end)
end)
