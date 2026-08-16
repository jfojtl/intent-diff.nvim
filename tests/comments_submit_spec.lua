local submit = require("intentdiff.comments.submit")
local store = require("intentdiff.comments.store")
local forges = require("intentdiff.forges")
local config = require("intentdiff.config")
local helpers = require("tests.helpers")

local function target()
  return { service = "github", id = "123", url = "u", title = "T",
    head_sha = "aaaa", base_ref = "main" }
end

describe("comments.submit.plan", function()
  it("refuses and explains when preflight says no PR", function()
    local p = submit.plan({ branch = "feat/x" },
      { mode = "no_pr", reason = "no PR for branch feat/x — create one first (gh pr create)" }, 2, 2)
    assert.is_false(p.ok)
    assert.is_truthy(p.message:match("gh pr create"))
  end)

  it("refuses on the default branch", function()
    local p = submit.plan({ branch = "main" },
      { mode = "default_branch", reason = "you are on main — no PR to comment on" }, 2, 2)
    assert.is_false(p.ok)
    assert.is_truthy(p.message:match("no PR to comment on"))
  end)

  it("announces an inline submit with the PR number", function()
    local p = submit.plan({ target = target() }, { mode = "inline" }, 3, 3)
    assert.is_true(p.ok)
    assert.equals("inline", p.mode)
    assert.is_truthy(p.message:match("#123"))
    assert.is_truthy(p.message:match("3 comment"))
    assert.is_false(p.verdict_only)
  end)

  it("states the reason when degrading to a general comment", function()
    local p = submit.plan({ target = target() },
      { mode = "general", reason = "2 of 3 commented files have uncommitted changes" }, 3, 3)
    assert.is_true(p.ok)
    assert.equals("general", p.mode)
    assert.is_truthy(p.message:match("uncommitted"))
    assert.is_truthy(p.message:match("not on individual lines"))
  end)

  it("reports how many were already posted", function()
    local p = submit.plan({ target = target() }, { mode = "inline" }, 2, 6)
    assert.is_truthy(p.message:match("4 of 6"))
    assert.is_truthy(p.message:match("2 new"))
  end)

  it("offers a verdict-only submit when everything is posted", function()
    local p = submit.plan({ target = target() }, { mode = "inline" }, 0, 6)
    assert.is_true(p.ok)
    assert.is_true(p.verdict_only)
    assert.is_truthy(p.message:match("already posted"))
  end)
end)

describe("comments.submit.verdict_choices", function()
  it("offers the three verdicts a forge advertises, plus cancel", function()
    local choices = submit.verdict_choices({
      verdicts = { "approve", "request_changes", "comment" },
    })
    assert.equals(4, #choices)
    assert.equals("approve", choices[1].verdict)
    assert.equals("request_changes", choices[2].verdict)
    assert.equals("comment", choices[3].verdict)
    assert.is_nil(choices[4].verdict)
    assert.is_truthy(choices[4].label:match("[Cc]ancel"))
  end)

  it("omits a verdict the forge cannot express", function()
    local choices = submit.verdict_choices({ verdicts = { "comment" } })
    assert.equals(2, #choices)
    assert.equals("comment", choices[1].verdict)
  end)
end)

--- `M.plan` and `M.verdict_choices` are pure and covered above, but `M.run`,
--- `post` and `choose_verdict` are what actually ENFORCE the two safety
--- properties the feature rests on: nothing is sent before the verdict
--- select, and stamping happens only on success. Those three functions touch
--- `vim.ui.select`, `vim.fn.confirm`, `vim.notify`, and `forges.collect` /
--- `.preflight`, so they are driven here end-to-end with stubs standing in
--- for all four, plus a fake forge standing in for `gh`. A real
--- `comments.store.new()` is used rather than a fake store: it is cheap, and
--- it means the stamping assertions exercise the real `mark_posted`.
---
--- `preflight` is stubbed to always return "general" mode, which sidesteps
--- `anchor.pr_hunks` (a real `git merge-base` call) entirely — inline
--- anchoring is already covered by comments_anchor_spec.lua and
--- comments_payload_spec.lua. What is under test here is the orchestration
--- around a submit, not which mode payload.build renders.
describe("comments.submit.run (integration)", function()
  local st, repo, tab, restore_session
  local real_collect, real_preflight, real_select, real_confirm, real_notify
  local notifications

  --- Any message vim.notify received this test, matched by pattern. Used
  --- instead of a bare synchronous read because the whole flow runs inside
  --- vim.schedule: a test that checked `notifications` right after M.run(tab)
  --- returned would see an empty list even on a passing implementation.
  local function notified(pattern)
    for _, n in ipairs(notifications) do
      if n:match(pattern) then
        return true
      end
    end
    return false
  end

  --- A minimal forge: what `choose_verdict` needs from `capabilities()`, plus
  --- whatever `submit_fn` the test supplies.
  local function fake_forge(submit_fn)
    return {
      capabilities = function() return { verdicts = { "approve", "request_changes", "comment" } } end,
      submit = submit_fn,
    }
  end

  --- Stub forges.collect to hand `choose_verdict`/`post` a state built around
  --- `forge`, scheduled exactly as the real one is (a network call, even a
  --- fake one, never resolves synchronously).
  local function stub_collect(forge)
    forges.collect = function(git_root, _files, cb)
      vim.schedule(function()
        cb({
          git_root = git_root,
          target = { service = "github", id = "123", url = "u", title = "T", base_ref = "main" },
          forge = forge,
        })
      end)
    end
  end

  --- confirm() is called at up to three distinct prompts in one run (submit,
  --- self-approve retry, close-the-tab); each test supplies exactly the
  --- answers it expects, in order. Anything beyond the list defaults to 2
  --- (decline) so an unexpected extra prompt never accidentally triggers a
  --- destructive action (like closing the tab) in a test that isn't checking
  --- for it.
  local function confirm_answers(list)
    local i = 0
    return function()
      i = i + 1
      return list[i] or 2
    end
  end

  --- Picks the choice whose .verdict matches `verdict` (nil = the Cancel row).
  local function select_verdict(verdict)
    return function(choices, _, cb)
      for _, c in ipairs(choices) do
        if c.verdict == verdict then
          return cb(c)
        end
      end
    end
  end

  before_each(function()
    config.setup({ cache_dir = vim.fn.tempname() })
    st = store.new()
    repo = helpers.make_repo({ ["a.lua"] = "x" })
    tab = 900555 + math.random(1, 100000) -- distinct sentinel per test, no real tab behind it
    restore_session = helpers.fake_session(tab, { comment_store = st, sess = { git_root = repo }, model = { groups = {} } })

    real_collect, real_preflight = forges.collect, forges.preflight
    real_select, real_confirm, real_notify = vim.ui.select, vim.fn.confirm, vim.notify
    notifications = {}
    vim.notify = function(msg) notifications[#notifications + 1] = msg end
    forges.preflight = function() return { mode = "general", reason = "test mode" } end
  end)

  after_each(function()
    forges.collect, forges.preflight = real_collect, real_preflight
    vim.ui.select, vim.fn.confirm, vim.notify = real_select, real_confirm, real_notify
    restore_session()
  end)

  it("stamps exactly the comments it sent, and no others", function()
    local c1 = st.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
    -- Already posted BEFORE this run — must be excluded from st.unposted(),
    -- and its stamp must be untouched by this run's mark_posted call.
    local c2 = st.add({ file = "a.lua", line = 2, side = "new", type = "note", text = "two" })
    st.mark_posted({ c2 }, { service = "github", target = "999", url = "https://old", at = 111 })

    stub_collect(fake_forge(function(_target, _payload, cb)
      vim.schedule(function() cb({ url = "https://github.com/x/y/pull/123" }) end)
    end))
    vim.fn.confirm = confirm_answers({ 1, 2 }) -- submit, then decline the close-tab prompt
    vim.ui.select = select_verdict("approve")

    submit.run(tab)

    assert.is_true(helpers.wait_for(function() return c1.posted ~= nil end),
      "the submit callback never fired — c1 was never stamped")
    assert.equals("123", c1.posted.target)
    assert.equals("https://github.com/x/y/pull/123", c1.posted.url)
    -- c2's PRE-EXISTING stamp, from before this run, is unchanged — proof
    -- that mark_posted was handed only the newly-sent comments, not st.get_all().
    assert.equals("999", c2.posted.target)
    assert.equals("https://old", c2.posted.url)
    assert.equals(111, c2.posted.at)
  end)

  it("stamps nothing when the submit fails", function()
    local c1 = st.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
    local c2 = st.add({ file = "a.lua", line = 3, side = "new", type = "issue", text = "two" })

    stub_collect(fake_forge(function(_target, _payload, cb)
      vim.schedule(function() cb(nil, "boom") end)
    end))
    vim.fn.confirm = confirm_answers({ 1 })
    vim.ui.select = select_verdict("approve")

    submit.run(tab)

    assert.is_true(helpers.wait_for(function() return notified("boom") end),
      "the failure notification never fired")
    assert.is_nil(c1.posted)
    assert.is_nil(c2.posted)
  end)

  it("sets target.git_root to the session's git root before calling submit", function()
    local c1 = st.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
    local captured_target

    stub_collect(fake_forge(function(t, _payload, cb)
      captured_target = t
      vim.schedule(function() cb({ url = "https://x" }) end)
    end))
    vim.fn.confirm = confirm_answers({ 1, 2 })
    vim.ui.select = select_verdict("approve")

    submit.run(tab)

    assert.is_true(helpers.wait_for(function() return c1.posted ~= nil end),
      "the submit callback never fired — git_root was never captured")
    assert.equals(repo, captured_target.git_root)
  end)

  it("cancelling at the submit confirm sends nothing", function()
    local c1 = st.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
    local submit_called = false
    local select_called = false

    stub_collect(fake_forge(function() submit_called = true end))
    vim.fn.confirm = confirm_answers({ 2 }) -- Cancel
    vim.ui.select = function(...) select_called = true end

    submit.run(tab)

    assert.is_true(helpers.wait_for(function() return notified("cancelled") end),
      "the cancellation notification never fired")
    assert.is_false(submit_called)
    assert.is_false(select_called, "the verdict picker must never open once the plan confirm is cancelled")
    assert.is_nil(c1.posted)
  end)

  it("cancelling at the verdict picker sends nothing", function()
    local c1 = st.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
    local submit_called = false

    stub_collect(fake_forge(function() submit_called = true end))
    vim.fn.confirm = confirm_answers({ 1 }) -- proceed to the picker
    vim.ui.select = select_verdict(nil) -- the Cancel row

    submit.run(tab)

    assert.is_true(helpers.wait_for(function() return notified("cancelled") end),
      "the cancellation notification never fired")
    assert.is_false(submit_called)
    assert.is_nil(c1.posted)
  end)

  it("retries as a plain comment after a self-approve rejection, without recursing forever", function()
    local c1 = st.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
    local submit_calls = 0
    local last_payload

    stub_collect(fake_forge(function(_t, payload, cb)
      submit_calls = submit_calls + 1
      last_payload = payload
      if submit_calls == 1 then
        vim.schedule(function() cb(nil, "cannot approve your own pull request", "self_approve") end)
      else
        vim.schedule(function() cb({ url = "https://x" }) end)
      end
    end))
    -- submit, then "post as plain Comment instead?" (yes), then decline close.
    vim.fn.confirm = confirm_answers({ 1, 1, 2 })
    vim.ui.select = select_verdict("approve")

    submit.run(tab)

    assert.is_true(helpers.wait_for(function() return submit_calls == 2 end),
      "the retry after self_approve never happened")
    assert.equals("comment", last_payload.verdict)
    assert.is_truthy(c1.posted)
  end)

  -- Regression: notify() does "intent-diff: " .. msg, so a self_approve
  -- callback with a nil err (the forge sending kind without a message) would
  -- throw on that concatenation and silently kill the retry offer — the
  -- second submit() call, and the confirm prompt before it, would simply
  -- never happen. wait_for's timeout is what catches that: without the nil
  -- guard this test fails on "the retry after a nil-err self_approve never
  -- happened" rather than erroring loudly, because the throw happens inside
  -- vim.schedule, off the test's own call stack.
  it("offers the self-approve retry even when the forge sends no err message", function()
    local c1 = st.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
    local submit_calls = 0

    stub_collect(fake_forge(function(_t, _payload, cb)
      submit_calls = submit_calls + 1
      if submit_calls == 1 then
        vim.schedule(function() cb(nil, nil, "self_approve") end)
      else
        vim.schedule(function() cb({ url = "https://x" }) end)
      end
    end))
    vim.fn.confirm = confirm_answers({ 1, 1, 2 })
    vim.ui.select = select_verdict("approve")

    submit.run(tab)

    assert.is_true(helpers.wait_for(function() return submit_calls == 2 end),
      "the retry after a nil-err self_approve never happened")
    assert.is_truthy(c1.posted)
  end)

  -- verdict_only: every comment in the store is already posted, so `to_send`
  -- is empty and only a verdict goes to the service. The success notification
  -- must say so rather than "submitted 0 comment(s)", which would read as if
  -- nothing happened when a verdict genuinely just landed.
  it("announces the verdict, not a comment count, on a verdict-only submit", function()
    local c1 = st.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
    st.mark_posted({ c1 }, { service = "github", target = "999", url = "https://old", at = 111 })

    stub_collect(fake_forge(function(_t, _payload, cb)
      vim.schedule(function() cb({ url = "https://github.com/x/y/pull/123" }) end)
    end))
    vim.fn.confirm = confirm_answers({ 1, 2 })
    vim.ui.select = select_verdict("approve")

    submit.run(tab)

    assert.is_true(helpers.wait_for(function() return notified("PR #123") end),
      "the success notification never fired")
    assert.is_true(notified("verdict"), "the message should announce a verdict, not a comment count")
    assert.is_false(notified("0 comment"), 'the message must not read "submitted 0 comment(s)"')
  end)
end)
