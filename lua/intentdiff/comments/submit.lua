-- Sending a review to the service hosting it.
--
-- NOTHING here contacts the service until the user has picked a verdict.
-- Everything before that point is local: git facts, a preflight decision, and a
-- payload built in memory. Cancelling at any prompt posts nothing.
--
-- The DECISIONS (what to say, what to offer) are pure functions at the top;
-- the vim.ui round trips that string them together are at the bottom. That is
-- what makes the wording and the mode logic testable without a review tab, a
-- repository, or a `gh`.
local M = {}

local VERDICT_LABELS = {
  approve = "Approve",
  request_changes = "Request changes",
  comment = "Comment (no verdict)",
}
local VERDICT_ORDER = { "approve", "request_changes", "comment" }

--- What the confirmation prompt says, and whether there is anything to confirm.
---
--- `unposted` vs `total` is what keeps a second submit from duplicating a
--- review: only the new comments are sent, and the prompt says how many are
--- being skipped so the count is never a surprise.
---
--- `effective` is what will ACTUALLY happen, which is not always what preflight
--- decided: inline degrades to general when the PR diff cannot be read locally,
--- and some comments may already be known to be unanchorable. Both are settled
--- before this prompt precisely so the prompt can state them — telling the user
--- after the POST is telling them nothing they can act on. Omitted, it defaults
--- to preflight's own verdict with nothing demoted.
--- @param effective { mode: string, reason: string|nil, demoted: integer }|nil
--- @return { ok: boolean, mode: string|nil, message: string, verdict_only: boolean }
function M.plan(state, pf, unposted, total, effective)
  if pf.mode ~= "inline" and pf.mode ~= "general" then
    return { ok = false, mode = pf.mode, message = pf.reason or pf.mode, verdict_only = false }
  end
  effective = effective or { mode = pf.mode, reason = pf.reason, demoted = 0 }
  local mode = effective.mode or pf.mode
  local target = state.target
  local lines = {}
  local verdict_only = unposted == 0

  if verdict_only then
    lines[#lines + 1] = ("All %d comment(s) are already posted to PR #%s.")
      :format(total, target.id)
    lines[#lines + 1] = "Submit a verdict on its own?"
  else
    if unposted < total then
      lines[#lines + 1] = ("%d of %d comment(s) already posted to PR #%s — submitting the %d new one(s).")
        :format(total - unposted, total, target.id, unposted)
    else
      lines[#lines + 1] = ("Submitting %d comment(s) to PR #%s (%s).")
        :format(unposted, target.id, target.title or "")
    end
    if mode == "general" then
      lines[#lines + 1] = effective.reason or pf.reason
      lines[#lines + 1] =
        "Comments will be posted as ONE general comment on the PR, not on individual lines."
    end
    if (effective.demoted or 0) > 0 then
      lines[#lines + 1] = ("%d comment(s) could not be anchored to a line and will be added to the review body.")
        :format(effective.demoted)
    end
  end
  return {
    ok = true,
    mode = mode,
    message = table.concat(lines, "\n"),
    verdict_only = verdict_only,
  }
end

--- The verdict picker's rows: what this forge can express, then Cancel.
---
--- Driven by capabilities rather than hardcoded, so a service that cannot
--- express "request changes" simply does not offer it.
--- @return { verdict: string|nil, label: string }[]
function M.verdict_choices(capabilities)
  local allowed = {}
  for _, v in ipairs((capabilities or {}).verdicts or VERDICT_ORDER) do
    allowed[v] = true
  end
  local out = {}
  for _, v in ipairs(VERDICT_ORDER) do
    if allowed[v] then
      out[#out + 1] = { verdict = v, label = VERDICT_LABELS[v] }
    end
  end
  out[#out + 1] = { verdict = nil, label = "Cancel — post nothing" }
  return out
end

local function notify(msg, level)
  vim.notify("intent-diff: " .. msg, level or vim.log.levels.INFO)
end

--- The distinct files the comments touch, for preflight's dirty intersection.
local function files_of(comment_list)
  local seen, out = {}, {}
  for _, c in ipairs(comment_list) do
    if c.file and not seen[c.file] then
      seen[c.file] = true
      out[#out + 1] = c.file
    end
  end
  return out
end

--- Post `payload`, stamp what landed, offer to close.
---
--- Stamping happens ONLY on success. The reviews API is atomic, so a failure
--- means nothing reached the service and marking anything posted would strand
--- real feedback with no way to resend it.
local function post(entry, tabpage, state, payload, sent_comments)
  state.target.git_root = state.git_root
  state.forge.submit(state.target, payload, function(result, err, kind)
    vim.schedule(function()
      if not result then
        if kind == "self_approve" then
          notify(err or "cannot approve your own pull request", vim.log.levels.WARN)
          local answer = vim.fn.confirm(
            "GitHub will not let you approve your own PR. Post the same review as a plain Comment?",
            "&Yes\n&No", 2)
          if answer == 1 then
            payload.verdict = "comment"
            return post(entry, tabpage, state, payload, sent_comments)
          end
          return
        end
        return notify(err or "submit failed", vim.log.levels.ERROR)
      end
      local st = entry.comment_store
      if st then
        st.mark_posted(sent_comments, {
          service = state.target.service,
          target = state.target.id,
          url = result.url,
          at = os.time(),
        })
      end
      require("intentdiff.comments.marks").refresh(tabpage)
      require("intentdiff.comments").refresh_sidebar(tabpage)
      if #sent_comments == 0 then
        -- verdict_only: every comment was already posted, so "submitted 0
        -- comment(s)" would read as if nothing happened when a verdict
        -- (approve/request changes/comment) genuinely just landed.
        notify(("submitted the verdict to PR #%s — %s"):format(state.target.id, result.url or ""))
      else
        notify(("submitted %d comment(s) to PR #%s — %s")
          :format(#sent_comments, state.target.id, result.url or ""))
      end
      local answer = vim.fn.confirm("Close the review tab?", "&Yes\n&No", 2)
      if answer == 1 then
        require("intentdiff").close(tabpage)
      end
    end)
  end)
end

--- The mode that will actually be used, and the payload it produces. ENTIRELY
--- LOCAL: `git diff` against local objects, then pure string building. Nothing
--- here contacts the service, which is what lets it run before the confirm.
---
--- It has to run before the confirm, because both of its outcomes are things
--- the user may want to refuse: an inline plan that quietly became a general
--- one, and comments that will be moved out of the margin and into the body.
--- @return table payload, { mode: string, reason: string|nil, demoted: integer } effective
local function compose(state, pf, to_send, model)
  local mode, anchorable, reason = pf.mode, nil, pf.reason
  -- Skipped when there is nothing to anchor: a verdict-only submit carries no
  -- comments, so reading the PR diff would answer a question nobody asked.
  if mode == "inline" and #to_send > 0 then
    local anchor = require("intentdiff.comments.anchor")
    local hunk_list, err = anchor.pr_hunks(state.git_root, state.target.base_ref)
    if not hunk_list then
      -- No local view of the PR diff means no way to know which lines anchor.
      -- Degrade rather than gamble on a 422 that costs the whole review.
      mode = "general"
      reason = err or "cannot read the PR diff"
    else
      anchorable = anchor.predicate(hunk_list)
    end
  end
  local payload = require("intentdiff.comments.payload").build(to_send, model, mode, anchorable)
  return payload, { mode = mode, reason = reason, demoted = payload.demoted }
end

--- Ask for a verdict, then post the payload that was already built.
local function choose_verdict(entry, tabpage, state, payload, to_send)
  local choices = M.verdict_choices(state.forge.capabilities())
  vim.ui.select(choices, {
    prompt = ("Submit review to PR #%s"):format(state.target.id),
    format_item = function(c) return c.label end,
  }, function(choice)
    if not (choice and choice.verdict) then
      return notify("cancelled — nothing was posted")
    end
    payload.verdict = choice.verdict
    post(entry, tabpage, state, payload, to_send)
  end)
end

--- The whole flow, from a key press to a posted review.
function M.run(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = require("intentdiff")._session(tabpage)
  local st = entry and entry.comment_store
  if not st then
    return notify("no comments available in this tab", vim.log.levels.WARN)
  end
  local all = st.get_all()
  if #all == 0 then
    return notify("no comments to submit", vim.log.levels.WARN)
  end
  local git_root = entry.sess and entry.sess.git_root
  if not git_root then
    return notify("this review has no repository to submit to", vim.log.levels.WARN)
  end

  local forges = require("intentdiff.forges")
  forges.collect(git_root, files_of(all), function(state, err)
    vim.schedule(function()
      if err then
        return notify(err, vim.log.levels.WARN)
      end
      -- collect() gathers facts about the REPOSITORY. These three are facts
      -- about THIS REVIEW — which revisions its line numbers describe, and
      -- where the PR says its old side begins — and only the session and the
      -- detected target know them. Without them preflight would happily call a
      -- `:IntentDiff v1.0 v1.1` review inline, because HEAD does match the PR
      -- head and the working tree is clean; the comments would then land on
      -- whichever PR lines happen to share those numbers.
      state.target_revision = entry.sess.target_revision
      state.base_revision = entry.sess.base_revision
      if state.target then
        state.merge_base = require("intentdiff.comments.anchor")
          .merge_base(git_root, state.target.base_ref)
      end
      local pf = forges.preflight(state)
      local unposted = st.unposted()
      -- Nothing unposted means a verdict-only submit: the store's comments all
      -- reached the PR in an earlier sitting, and re-sending them would open a
      -- second thread on every line.
      local to_send = (#unposted == 0) and {} or unposted

      -- Composed BEFORE the confirm, so the prompt can state the mode that
      -- will really be used and how many comments will be demoted. Only on a
      -- mode preflight would let through: on a refusal there is nothing to
      -- compose, and `state.target` may not even exist.
      local payload, effective
      if pf.mode == "inline" or pf.mode == "general" then
        payload, effective = compose(state, pf, to_send, entry.model or { groups = {} })
      end

      local plan = M.plan(state, pf, #unposted, #all, effective)
      if not plan.ok then
        return notify(plan.message, vim.log.levels.WARN)
      end
      local answer = vim.fn.confirm(plan.message, "&Submit\n&Cancel", 2)
      if answer ~= 1 then
        return notify("cancelled — nothing was posted")
      end
      choose_verdict(entry, tabpage, state, payload, to_send)
    end)
  end)
end

return M
