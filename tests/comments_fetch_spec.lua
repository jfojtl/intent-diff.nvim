local fetch = require("intentdiff.comments.fetch")
local forges = require("intentdiff.forges")
local helpers = require("tests.helpers")
local marks = require("intentdiff.comments.marks")
local store = require("intentdiff.comments.store")

describe("comments.fetch", function()
  local tab, st, entry, restore_session, real_collect, real_refresh, real_notify, notices

  before_each(function()
    tab = vim.api.nvim_get_current_tabpage()
    st = store.new()
    entry = { sess = { git_root = "/repo" }, comment_store = st }
    restore_session = helpers.fake_session(tab, entry)
    real_collect = forges.collect
    real_refresh = marks.refresh
    real_notify = vim.notify
    notices = {}
    marks.refresh = function(got_tab) assert.equals(tab, got_tab) end
    vim.notify = function(message) notices[#notices + 1] = message end
  end)

  after_each(function()
    restore_session()
    forges.collect = real_collect
    marks.refresh = real_refresh
    vim.notify = real_notify
  end)

  it("replaces the session's remote discussion and repaints", function()
    local remote = { remote = true, remote_kind = "inline", file = "a.lua",
      line = 2, side = "new", type = "note", text = "hello" }
    local forge = {
      fetch_comments = function(target, cb)
        assert.equals("7", target.id)
        assert.equals("/repo", target.git_root)
        cb({ comments = { remote }, comment_count = 1, thread_count = 1, general = {} })
      end,
    }
    forges.collect = function(root, files, cb)
      assert.equals("/repo", root)
      assert.same({}, files)
      cb({ branch = "feature", git_root = root, forge = forge, target = { id = "7" } })
    end

    fetch.run(tab)
    assert.truthy(helpers.wait_for(function() return #st.get_remote() > 0 end))
    assert.same({ remote }, st.get_remote())
    assert.equals(forge, entry.forge)
    assert.equals("7", entry.forge_target.id)
    assert.truthy(notices[#notices]:find("1 PR comment", 1, true))
  end)

  it("reports a branch with no pull request", function()
    forges.collect = function(root, files, cb)
      cb({ branch = "feature", git_root = root, forge = {} })
    end

    fetch.run(tab)
    assert.truthy(helpers.wait_for(function() return #notices > 1 end))
    assert.truthy(notices[#notices]:find("no PR for branch feature", 1, true))
    assert.same({}, st.get_remote())
  end)

  it("silently ignores a non-PR branch during automatic fetch", function()
    forges.collect = function(root, files, cb)
      cb({ branch = "feature", git_root = root, forge = {} })
    end

    fetch.run(tab, { automatic = true })
    vim.wait(20)
    assert.same({}, notices)
    assert.same({}, st.get_remote())
  end)
end)
