-- Actions on fetched, read-only forge discussion. The local comment store
-- remains untouched: replies/resolution mutate GitHub, then a quiet fetch
-- replaces the remote snapshot with GitHub's answer.
local M = {}

local function notify(message, level)
  vim.notify("intent-diff: " .. message, level or vim.log.levels.INFO)
end

local function label(thread)
  local state = thread.is_resolved and "resolved" or "open"
  local location = thread.file or "PR"
  if (thread.line or 0) > 0 then
    location = location .. ":" .. tostring(thread.line)
  end
  return ("[%s] @%s · %s"):format(state, thread.author or "unknown", location)
end

--- Fetched inline threads under the cursor. The coordinate match is the
--- ordinary path; the rendered-row fallback reaches an outdated thread that
--- marks.rows_for_comment clamped because its original line vanished.
local function threads_at_cursor(tabpage, store)
  local comments = require("intentdiff.comments")
  local ctx = comments.context(tabpage)
  if not ctx then return {} end
  local out, seen = {}, {}
  for _, thread in ipairs(store.get_remote()) do
    if thread.remote_kind == "inline" and thread.file == ctx.file then
      local matches = false
      if (thread.line or 0) == 0 then
        matches = (ctx.line or 0) == 0
      elseif (thread.side or "new") == (ctx.side or "new") then
        local last = thread.line_end or thread.line
        matches = ctx.line and ctx.line >= thread.line and ctx.line <= last
      end
      if matches then
        out[#out + 1] = thread
        seen[thread] = true
      end
    end
  end

  local view = require("intentdiff.view")
  local win = vim.api.nvim_get_current_win()
  local ok, bufnr = pcall(vim.api.nvim_win_get_buf, win)
  local pane = ok and view.pane_for_buf(tabpage, bufnr) or nil
  local cursor = pane and vim.api.nvim_win_get_cursor(win)[1] or nil
  if pane and cursor then
    for _, thread in ipairs(store.get_remote()) do
      if thread.remote_kind == "inline" and not seen[thread] then
        local rows, drifted = require("intentdiff.comments.marks")
          .rows_for_comment(pane, thread)
        if drifted and vim.tbl_contains(rows, cursor) then
          out[#out + 1] = thread
        end
      end
    end
  end
  return out
end

local function choose_thread(tabpage, callback)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = require("intentdiff")._session(tabpage)
  local store = entry and entry.comment_store
  if not store then
    return notify("no comments available in this tab", vim.log.levels.WARN)
  end
  local candidates = threads_at_cursor(tabpage, store)
  if #candidates == 0 then
    return notify("no GitHub review thread here", vim.log.levels.WARN)
  end
  if #candidates == 1 then return callback(entry, candidates[1], tabpage) end
  local choices = {}
  for _, thread in ipairs(candidates) do
    choices[#choices + 1] = { thread = thread, label = label(thread) }
  end
  vim.ui.select(choices, {
    prompt = "intent-diff: which GitHub thread?",
    format_item = function(choice) return choice.label end,
  }, function(choice)
    if choice then callback(entry, choice.thread, tabpage) end
  end)
end

local function refresh(tabpage)
  require("intentdiff.comments").fetch(tabpage, {
    automatic = true,
    quiet_success = true,
  })
end

function M.reply(tabpage)
  choose_thread(tabpage, function(entry, thread, resolved_tabpage)
    if thread.viewer_can_reply == false then
      return notify("GitHub does not allow you to reply to this thread", vim.log.levels.WARN)
    end
    if not (entry.forge and entry.forge.reply and entry.forge_target) then
      return notify("this forge does not support thread replies", vim.log.levels.WARN)
    end
    require("intentdiff.comments.popup").open({
      plain = true,
      title = "Reply to @" .. (thread.author or "reviewer"),
    }, function(_, text)
      if not text then return end
      entry.forge.reply(entry.forge_target, thread, text, function(result, err)
        vim.schedule(function()
          if require("intentdiff")._session(resolved_tabpage) ~= entry then return end
          if not result then
            return notify(err or "could not reply to the review thread", vim.log.levels.ERROR)
          end
          notify("replied to GitHub review thread")
          refresh(resolved_tabpage)
        end)
      end)
    end)
  end)
end

function M.resolve(tabpage)
  choose_thread(tabpage, function(entry, thread, resolved_tabpage)
    local resolving = not thread.is_resolved
    if not thread.thread_id then
      return notify("GitHub thread metadata is unavailable — refresh and try again",
        vim.log.levels.WARN)
    end
    if resolving and thread.viewer_can_resolve == false then
      return notify("GitHub does not allow you to resolve this thread", vim.log.levels.WARN)
    end
    if not resolving and thread.viewer_can_unresolve == false then
      return notify("GitHub does not allow you to reopen this thread", vim.log.levels.WARN)
    end
    if not (entry.forge and entry.forge.resolve_thread and entry.forge_target) then
      return notify("this forge does not support resolving threads", vim.log.levels.WARN)
    end
    entry.forge.resolve_thread(entry.forge_target, thread, resolving, function(result, err)
      vim.schedule(function()
        if require("intentdiff")._session(resolved_tabpage) ~= entry then return end
        if not result then
          return notify(err or "could not update the review thread", vim.log.levels.ERROR)
        end
        notify(resolving and "resolved GitHub review thread" or "reopened GitHub review thread")
        refresh(resolved_tabpage)
      end)
    end)
  end)
end

M._threads_at_cursor = threads_at_cursor

return M
