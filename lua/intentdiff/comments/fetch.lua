-- Read the discussion already on the pull request into the current review.
-- The forge owns transport and normalization; this module owns only session
-- lifecycle, notifications, and repainting.
local M = {}

local function notify(message, level)
  vim.notify("intent-diff: " .. message, level or vim.log.levels.INFO)
end

function M.run(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = require("intentdiff")._session(tabpage)
  if not (entry and entry.comment_store) then
    return notify("no comments available in this tab", vim.log.levels.WARN)
  end
  local git_root = entry.sess and entry.sess.git_root
  if not git_root then
    return notify("this review has no repository to fetch from", vim.log.levels.WARN)
  end

  entry.discussion_fetch_seq = (entry.discussion_fetch_seq or 0) + 1
  local fetch_seq = entry.discussion_fetch_seq
  notify("fetching pull request discussion…")

  local function is_current()
    local current = require("intentdiff")._session(tabpage)
    return current == entry and current.discussion_fetch_seq == fetch_seq
  end

  require("intentdiff.forges").collect(git_root, {}, function(state, err)
    if not is_current() then return end
    if err then
      return vim.schedule(function()
        if is_current() then notify(err, vim.log.levels.WARN) end
      end)
    end
    if not state.target then
      return vim.schedule(function()
        if is_current() then
          notify(("no PR for branch %s — create one first (gh pr create)")
            :format(state.branch or "(unknown)"), vim.log.levels.WARN)
        end
      end)
    end
    if type(state.forge.fetch_comments) ~= "function" then
      return vim.schedule(function()
        if is_current() then
          notify("this forge does not support fetching discussion", vim.log.levels.WARN)
        end
      end)
    end
    state.target.git_root = state.git_root
    state.forge.fetch_comments(state.target, function(discussion, fetch_err)
      vim.schedule(function()
        -- The tab may have closed while gh was running, or a different review
        -- may now occupy it. Never attach an old callback's discussion there.
        if not is_current() then return end
        if not discussion then
          return notify(fetch_err or "could not fetch pull request discussion",
            vim.log.levels.ERROR)
        end
        entry.comment_store.set_remote(discussion.comments)
        entry.forge_discussion = discussion
        require("intentdiff.comments.marks").refresh(tabpage)
        notify(("fetched %d PR comment(s) in %d inline thread(s); %d general item(s)")
          :format(discussion.comment_count, discussion.thread_count, #discussion.general))
      end)
    end)
  end)
end

return M
