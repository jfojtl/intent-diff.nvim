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
end)
