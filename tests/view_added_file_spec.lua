local helpers = require("tests.intentdiff_helpers")

describe("view: added files", function()
  local view

  before_each(function()
    package.loaded["intentdiff.view"] = nil
    view = require("intentdiff.view")
    assert.is_true(view.load())
    require("intentdiff.config").setup({})
  end)

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      pcall(vim.cmd, "tabclose $")
    end
  end)

  --- Repo with a staged-new file of `n` numbered lines (status "A" vs HEAD,
  --- content only on disk and in the index — never in a commit).
  local function repo_with_added(n)
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local lines = {}
    for i = 1, n do lines[i] = "added line " .. i end
    helpers.write_file(repo, "added.lua", table.concat(lines, "\n"))
    helpers.git(repo, "add", "added.lua")
    return repo
  end

  local function base_of(repo)
    local base
    require("codediff.core.git").resolve_revision("HEAD", repo, function(_, h) base = h end)
    helpers.wait_for(function() return base end)
    return base
  end

  local function added_hunks(repo)
    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)
    return vim.tbl_filter(function(h) return h.file == "added.lua" end, inv.hunks)
  end

  local function visible_all(hunks)
    local visible = {}
    for _, h in ipairs(hunks) do visible[h.id] = true end
    return visible
  end

  --- The new-side lines of `path` the plan actually renders, in row order.
  local function rendered_lines(plan, path)
    local out = {}
    for row = 1, #plan.modified.lines do
      local t = plan.modified.map[row]
      if t and t.file == path and t.side == "new" then
        out[#out + 1] = plan.modified.lines[row]
      end
    end
    return out
  end

  local function show(sess, entry, visible)
    local ready = false
    view.show(sess, { entry }, visible, { on_ready = function() ready = true end })
    assert.truthy(helpers.wait_for(function() return ready end, 10000))
    return view.current_plan(sess.tabpage)
  end

  it("shows the real contents of a staged new file in working-tree mode", function()
    local repo = repo_with_added(20)
    local added = added_hunks(repo)
    assert.equals(1, #added) -- 20 lines is below min_lines, so still whole

    local sess = { tabpage = view.open_tab(), git_root = repo,
      base_revision = base_of(repo), target_revision = nil }
    local plan = show(sess, { path = "added.lua", status = "A", hunks = added },
      visible_all(added))

    local lines = rendered_lines(plan, "added.lua")
    assert.equals(20, #lines)
    assert.equals("added line 1", lines[1])
    assert.equals("added line 20", lines[20])
    view.close_tab(sess)
  end)

  it("installs the buffer-local keys on every painted pane", function()
    local repo = repo_with_added(20)
    require("intentdiff.config").setup({ keymaps = { comments = { add_issue = "gI" } } })
    local added = added_hunks(repo)

    local sess = { tabpage = view.open_tab(), git_root = repo,
      base_revision = base_of(repo), target_revision = nil }
    show(sess, { path = "added.lua", status = "A", hunks = added }, visible_all(added))

    local wins = view.diff_wins(sess.tabpage)
    assert.equals(2, #wins, "an added file still renders both panes; its old side is simply empty")
    for _, win in ipairs(wins) do
      local found = {}
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_win_get_buf(win), "n")) do
        found[m.lhs] = true
      end
      assert.is_true(found["gI"] or false, "the comment keys must reach an added file's pane")
      assert.is_true(found["g?"] or false, "the view keys must reach an added file's pane")
    end
    view.close_tab(sess)
    require("intentdiff.config").setup({})
  end)

  it("folds a split added file down to the open group's sub-hunks", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local src = {}
    for block = 1, 3 do
      for i = 1, 29 do src[#src + 1] = ("block%d line%d"):format(block, i) end
      src[#src + 1] = ""
    end
    helpers.write_file(repo, "added.lua", table.concat(src, "\n"))
    helpers.git(repo, "add", "added.lua")

    local added = added_hunks(repo)
    assert.is_true(#added > 1)

    local sess = { tabpage = view.open_tab(), git_root = repo,
      base_revision = base_of(repo), target_revision = nil }
    -- The intent owns ONLY the first sub-hunk.
    local plan = show(sess, { path = "added.lua", status = "A", hunks = added },
      { [added[1].id] = true })

    local win = view.pane_wins(sess.tabpage).modified
    local function row_of(line)
      for row = 1, #plan.modified.lines do
        local t = plan.modified.map[row]
        if t and t.file == "added.lua" and t.side == "new" and t.line == line then
          return row
        end
      end
    end
    local function foldclosed(row)
      return vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(row) end)
    end
    local open_row = row_of(added[1].modified.start_line)
    -- Ten lines INTO the last sub-hunk, not its first line: the renderer pads
    -- every visible hunk with `context_lines` on each side, and a split added
    -- file's sub-hunks are adjacent partitions of one continuous addition — so
    -- the first few lines of the next sub-hunk are deliberately in view, the
    -- same way surrounding code is for a modified file.
    local folded_row = row_of(added[#added].modified.start_line + 10)
    assert.truthy(open_row)
    assert.truthy(folded_row)
    assert.equals(-1, foldclosed(open_row))
    assert.is_true(foldclosed(folded_row) > 0)
    view.close_tab(sess)
  end)

  it("reads the target REVISION's content, not the working tree, for a revision pair", function()
    local repo = repo_with_added(20)
    helpers.git(repo, "commit", "-q", "-m", "add file")
    -- Diverge disk from the committed (HEAD) content: only a render that reads
    -- `git show HEAD:added.lua` can still produce the 20 "added line N" lines
    -- asserted below; reading the worktree would show this mutated text.
    helpers.write_file(repo, "added.lua", "MUTATED ON DISK, NOT COMMITTED")
    local sess = { tabpage = view.open_tab(), git_root = repo,
      base_revision = "HEAD~1", target_revision = "HEAD" }
    local plan = show(sess, { path = "added.lua", status = "A", hunks = {} }, {})

    local lines = rendered_lines(plan, "added.lua")
    assert.equals(20, #lines)
    assert.equals("added line 1", lines[1])
    assert.equals("added line 20", lines[20])
    view.close_tab(sess)
  end)
end)
