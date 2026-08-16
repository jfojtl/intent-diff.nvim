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
--- @return { ok: boolean, mode: string|nil, message: string, verdict_only: boolean }
function M.plan(state, pf, unposted, total)
  if pf.mode ~= "inline" and pf.mode ~= "general" then
    return { ok = false, mode = pf.mode, message = pf.reason or pf.mode, verdict_only = false }
  end
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
    if pf.mode == "general" then
      lines[#lines + 1] = pf.reason
      lines[#lines + 1] =
        "Comments will be posted as ONE general comment on the PR, not on individual lines."
    end
  end
  return {
    ok = true,
    mode = pf.mode,
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
          notify(err, vim.log.levels.WARN)
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
      notify(("submitted %d comment(s) to PR #%s — %s")
        :format(#sent_comments, state.target.id, result.url or ""))
      local answer = vim.fn.confirm("Close the review tab?", "&Yes\n&No", 2)
      if answer == 1 then
        require("intentdiff").close(tabpage)
      end
    end)
  end)
end

--- Ask for a verdict, build the payload, post.
local function choose_verdict(entry, tabpage, state, pf, to_send, model)
  local choices = M.verdict_choices(state.forge.capabilities())
  vim.ui.select(choices, {
    prompt = ("Submit review to PR #%s"):format(state.target.id),
    format_item = function(c) return c.label end,
  }, function(choice)
    if not (choice and choice.verdict) then
      return notify("cancelled — nothing was posted")
    end
    local anchorable = nil
    local mode = pf.mode
    if mode == "inline" then
      local hunk_list, err = require("intentdiff.comments.anchor")
        .pr_hunks(state.git_root, state.target.base_ref)
      if not hunk_list then
        -- No local view of the PR diff means no way to know which lines
        -- anchor. Degrade rather than gamble on a 422 that costs the review.
        notify((err or "cannot read the PR diff") .. " — posting as a general comment",
          vim.log.levels.WARN)
        mode = "general"
      else
        anchorable = require("intentdiff.comments.anchor").predicate(hunk_list)
      end
    end
    local payload = require("intentdiff.comments.payload")
      .build(to_send, model, mode, anchorable)
    payload.verdict = choice.verdict
    if payload.demoted > 0 then
      notify(("%d comment(s) could not be anchored and were added to the review body")
        :format(payload.demoted), vim.log.levels.WARN)
    end
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
      local pf = forges.preflight(state)
      local unposted = st.unposted()
      local plan = M.plan(state, pf, #unposted, #all)
      if not plan.ok then
        return notify(plan.message, vim.log.levels.WARN)
      end
      local answer = vim.fn.confirm(plan.message, "&Submit\n&Cancel", 2)
      if answer ~= 1 then
        return notify("cancelled — nothing was posted")
      end
      local model = entry.model or { groups = {} }
      choose_verdict(entry, tabpage, state, pf, plan.verdict_only and {} or unposted, model)
    end)
  end)
end

return M
