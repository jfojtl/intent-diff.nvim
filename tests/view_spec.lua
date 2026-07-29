local helpers = require("tests.helpers")

describe("view adapter", function()
  local view

  before_each(function()
    package.loaded["intentdiff.view"] = nil
    view = require("intentdiff.view")
  end)

  it("loads codediff internals", function()
    assert.is_true(view.load())
    assert.is_true(view.available)
  end)

  it("shows a modified file and folds away non-group hunks", function()
    assert.is_true(view.load())
    -- 60-line file with two edits far apart → two hunks
    local lines = {}
    for i = 1, 60 do lines[i] = "line " .. i end
    local repo = helpers.make_repo({ ["big.lua"] = table.concat(lines, "\n") })
    lines[5] = "CHANGED 5"
    lines[55] = "CHANGED 55"
    helpers.write_file(repo, "big.lua", table.concat(lines, "\n"))

    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)
    assert.equals(2, #inv.hunks)

    local git = require("codediff.core.git")
    local base
    git.resolve_revision("HEAD", repo, function(_, hash) base = hash end)
    helpers.wait_for(function() return base end)

    local sess = { tabpage = view.open_tab(), git_root = repo, base_revision = base,
      target_revision = "WORKING" }
    local ready = false
    -- group = ONLY the first hunk (line 5 area)
    view.show_file(sess, { path = "big.lua", status = "M", hunks = { inv.hunks[1] } },
      { on_ready = function() ready = true end })
    helpers.wait_for(function() return ready end, 10000)

    local session = require("codediff.ui.lifecycle").get_session(sess.tabpage)
    assert.truthy(session)
    local win = session.modified_win
    assert.equals("expr", vim.wo[win].foldmethod)
    -- line 5 (group hunk) visible; line 55 (other hunk) folded
    assert.equals(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(5) end))
    assert.is_true(vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(55) end) > 0)
    view.close_tab(sess)
  end)

  it("apply_group_folds returns false without a codediff session", function()
    assert.is_true(view.load())
    vim.cmd("tabnew")
    local tab = vim.api.nvim_get_current_tabpage()
    assert.is_false(view.apply_group_folds(tab, {}))
    vim.cmd("tabclose")
  end)

  it("show_file for a deleted file waits for virtual content before firing on_ready", function()
    assert.is_true(view.load())
    local repo = helpers.make_repo({ ["gone.txt"] = "alpha\nbeta\ngamma" })
    helpers.git(repo, "rm", "-q", "gone.txt")

    local git = require("codediff.core.git")
    local base
    git.resolve_revision("HEAD", repo, function(_, hash) base = hash end)
    helpers.wait_for(function() return base end)

    local sess = { tabpage = view.open_tab(), git_root = repo, base_revision = base }
    local ready = false
    local captured
    view.show_file(sess, { path = "gone.txt", status = "D" }, {
      on_ready = function()
        ready = true
        -- Snapshot the buffer content at the exact moment on_ready fires —
        -- this is what would have been empty before the fix (on_ready used
        -- to fire via vim.schedule regardless of codediff's async virtual
        -- file load).
        local session = require("codediff.ui.lifecycle").get_session(sess.tabpage)
        captured = session and vim.api.nvim_buf_get_lines(session.original_bufnr, 0, -1, false)
      end,
    })
    helpers.wait_for(function() return ready end, 10000)
    assert.is_true(ready)
    assert.same({ "alpha", "beta", "gamma" }, captured)
    view.close_tab(sess)
  end)

  it("re-applies group folds after codediff's compact.refresh clobbers them on TabEnter", function()
    assert.is_true(view.load())
    -- 60-line file with two edits far apart → two hunks
    local lines = {}
    for i = 1, 60 do lines[i] = "line " .. i end
    local repo = helpers.make_repo({ ["big.lua"] = table.concat(lines, "\n") })
    lines[5] = "CHANGED 5"
    lines[55] = "CHANGED 55"
    helpers.write_file(repo, "big.lua", table.concat(lines, "\n"))

    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)
    assert.equals(2, #inv.hunks)

    local git = require("codediff.core.git")
    local base
    git.resolve_revision("HEAD", repo, function(_, hash) base = hash end)
    helpers.wait_for(function() return base end)

    local sess = { tabpage = view.open_tab(), git_root = repo, base_revision = base,
      target_revision = "WORKING" }
    local ready = false
    -- group = ONLY the first hunk (line 5 area)
    view.show_file(sess, { path = "big.lua", status = "M", hunks = { inv.hunks[1] } },
      { on_ready = function() ready = true end })
    helpers.wait_for(function() return ready end, 10000)

    local session = require("codediff.ui.lifecycle").get_session(sess.tabpage)
    local win = session.modified_win
    -- Sanity: our group folds are in effect before the clobber.
    assert.equals("v:lua.require'intentdiff.view'.foldexpr()", vim.wo[win].foldexpr)

    -- Simulate the user having `diff.compact = true`: enabling compact mode
    -- applies codediff's own all-hunks fold, clobbering our foldexpr/visible
    -- lines exactly like session.lua's TabEnter -> reapply_keymaps ->
    -- setup_all_keymaps -> compact.refresh(tabpage) does when compact is
    -- already on.
    local codediff_config = require("codediff.config")
    local prev_compact = codediff_config.options.diff.compact
    codediff_config.options.diff.compact = true
    local compact = require("codediff.ui.view.compact")
    assert.is_true(compact.enable(sess.tabpage))
    assert.equals("v:lua.require'codediff.ui.view.compact'.foldexpr_eval()", vim.wo[win].foldexpr)
    -- Clobbered: compact shows both hunks, so line 55 is no longer folded.
    assert.equals(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(55) end))

    -- Fire a real TabEnter for sess.tabpage (switch away, then back), which
    -- re-triggers codediff's session TabEnter handler (session.lua) — its
    -- vim.schedule'd reapply_keymaps calls compact.refresh(tabpage) again,
    -- re-clobbering our folds — followed by our own IntentDiffFolds TabEnter
    -- handler re-asserting the group filter afterwards.
    local scratch_tab
    vim.cmd("tabnew")
    scratch_tab = vim.api.nvim_get_current_tabpage()
    vim.api.nvim_set_current_tabpage(sess.tabpage)

    helpers.wait_for(function()
      return vim.wo[win].foldexpr == "v:lua.require'intentdiff.view'.foldexpr()"
        and vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(5) end) == -1
        and vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(55) end) > 0
    end, 10000)

    assert.equals("v:lua.require'intentdiff.view'.foldexpr()", vim.wo[win].foldexpr)
    assert.equals(-1, vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(5) end))
    assert.is_true(vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(55) end) > 0)

    codediff_config.options.diff.compact = prev_compact
    if scratch_tab and vim.api.nvim_tabpage_is_valid(scratch_tab) then
      vim.api.nvim_set_current_tabpage(scratch_tab)
      vim.cmd("tabclose")
    end
    view.close_tab(sess)
  end)
end)
