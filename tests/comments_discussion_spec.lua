local comments = require("intentdiff.comments")
local discussion = require("intentdiff.comments.discussion")
local helpers = require("tests.helpers")
local popup = require("intentdiff.comments.popup")
local store = require("intentdiff.comments.store")

describe("GitHub discussion actions", function()
  local tab, entry, thread, restore_session
  local real_context, real_fetch, real_open, real_notify, notices

  before_each(function()
    tab = vim.api.nvim_get_current_tabpage()
    local st = store.new()
    thread = {
      remote = true, remote_kind = "inline", remote_id = "10", thread_id = "THREAD_10",
      file = "a.lua", line = 3, side = "new", type = "note", text = "@alice\nfix this",
      author = "alice", viewer_can_reply = true, viewer_can_resolve = true,
      viewer_can_unresolve = true, is_resolved = false,
    }
    st.set_remote({ thread })
    entry = {
      sess = { git_root = "/repo" }, comment_store = st,
      forge_target = { id = "7", git_root = "/repo" }, forge = {},
    }
    restore_session = helpers.fake_session(tab, entry)
    real_context, real_fetch = comments.context, comments.fetch
    real_open, real_notify = popup.open, vim.notify
    comments.context = function() return { file = "a.lua", line = 3, side = "new" } end
    notices = {}
    vim.notify = function(message) notices[#notices + 1] = message end
  end)

  after_each(function()
    restore_session()
    comments.context, comments.fetch = real_context, real_fetch
    popup.open, vim.notify = real_open, real_notify
    popup.cancel()
  end)

  it("posts a multi-line reply and refreshes the remote snapshot", function()
    local sent, refreshed
    popup.open = function(opts, cb)
      assert.is_true(opts.plain)
      assert.truthy(opts.title:find("alice", 1, true))
      cb("reply", "fixed\nthanks")
    end
    entry.forge.reply = function(target, got_thread, body, cb)
      assert.equals(entry.forge_target, target)
      assert.equals(thread, got_thread)
      sent = body
      cb({ id = 11 })
    end
    comments.fetch = function(got_tab, opts)
      refreshed = { tab = got_tab, opts = opts }
    end

    discussion.reply(tab)
    assert.truthy(helpers.wait_for(function() return refreshed end))
    assert.equals("fixed\nthanks", sent)
    assert.equals(tab, refreshed.tab)
    assert.is_true(refreshed.opts.automatic)
    assert.is_true(refreshed.opts.quiet_success)
    assert.truthy(notices[#notices]:find("replied", 1, true))
  end)

  it("resolves an open thread and reopens a resolved one", function()
    local requested, refreshes = {}, 0
    entry.forge.resolve_thread = function(target, got_thread, resolve, cb)
      requested[#requested + 1] = resolve
      cb({ data = {} })
    end
    comments.fetch = function() refreshes = refreshes + 1 end

    discussion.resolve(tab)
    assert.truthy(helpers.wait_for(function() return refreshes == 1 end))
    assert.same({ true }, requested)

    thread.is_resolved = true
    discussion.resolve(tab)
    assert.truthy(helpers.wait_for(function() return refreshes == 2 end))
    assert.same({ true, false }, requested)
    assert.truthy(notices[#notices]:find("reopened", 1, true))
  end)

  it("honors GitHub's per-thread resolve permission", function()
    thread.viewer_can_resolve = false
    local called = false
    entry.forge.resolve_thread = function() called = true end

    discussion.resolve(tab)

    assert.is_false(called)
    assert.truthy(notices[#notices]:find("does not allow", 1, true))
  end)
end)
