local helpers = require("tests.helpers")

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

  it("shows the real contents of a staged new file in working-tree mode", function()
    local repo = repo_with_added(20)
    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)
    local added = vim.tbl_filter(function(h) return h.file == "added.lua" end, inv.hunks)
    assert.equals(1, #added) -- 20 lines is below min_lines, so still whole

    local sess = { tabpage = view.open_tab(), git_root = repo,
      base_revision = base_of(repo), target_revision = "WORKING" }
    local ready = false
    view.show_file(sess, { path = "added.lua", status = "A", hunks = added },
      { on_ready = function() ready = true end })
    helpers.wait_for(function() return ready end, 10000)

    local session = view.get_session(sess.tabpage)
    local lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    assert.equals(20, #lines)
    assert.equals("added line 1", lines[1])
    assert.equals("added line 20", lines[20])
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

    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)
    local added = vim.tbl_filter(function(h) return h.file == "added.lua" end, inv.hunks)
    assert.is_true(#added > 1)

    local sess = { tabpage = view.open_tab(), git_root = repo,
      base_revision = base_of(repo), target_revision = "WORKING" }
    local ready = false
    -- group owns ONLY the first sub-hunk
    view.show_file(sess, { path = "added.lua", status = "A", hunks = { added[1] } },
      { on_ready = function() ready = true end })
    helpers.wait_for(function() return ready end, 10000)

    local session = view.get_session(sess.tabpage)
    local win = session.modified_win
    assert.equals("expr", vim.wo[win].foldmethod)
    local function foldclosed(l)
      return vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(l) end)
    end
    -- first sub-hunk visible, a line from the last sub-hunk folded away
    assert.equals(-1, foldclosed(added[1].modified.start_line))
    assert.is_true(foldclosed(added[#added].modified.start_line) > 0)
  end)

  it("still uses the virtual-file path for a two-revision target", function()
    local repo = repo_with_added(20)
    helpers.git(repo, "commit", "-q", "-m", "add file")
    local sess = { tabpage = view.open_tab(), git_root = repo,
      base_revision = "HEAD~1", target_revision = "HEAD" }
    local ready = false
    view.show_file(sess, { path = "added.lua", status = "A", hunks = {} },
      { on_ready = function() ready = true end })
    helpers.wait_for(function() return ready end, 10000)

    local session = view.get_session(sess.tabpage)
    local lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    assert.equals(20, #lines)
    assert.equals("added line 1", lines[1])
  end)
end)
