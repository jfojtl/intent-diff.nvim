-- `]c` / `[c`, and nothing else.
--
-- This module used to also keep a per-tabpage ctx (`{ model, group_i, file_i,
-- select_file }`) that init.lua wrote on every selection. Nothing read it:
-- `jump` below plans against the plan that is actually painted, which is the
-- only description of the panes that cannot go stale. The store and its four
-- accessors are gone rather than kept "for bookkeeping" — a value with no
-- consumer is a value that can silently disagree with the screen.
local M = {}

--- Move to the next/previous hunk of the plan CURRENTLY PAINTED in
--- `tabpage`, by reading `plan.hunk_rows` — the pane row range of every
--- VISIBLE hunk, ascending, built by `plan.build` from the exact same
--- `hunk_spans` its folds are. Reading it directly (rather than comparing a
--- pane row against a file's own line numbers, the way this used to work) is
--- what fixes the off-by-the-separator-row bug: `hunk_rows` is already
--- expressed in the coordinate space the cursor lives in.
---
--- Group-scoping falls out for free: `hunk_rows` holds only hunks the caller
--- asked to leave visible, whether the painted plan is one file or a whole
--- intent spanning several — there is no "next file" to roll over to, because
--- a multi-file intent's hunks are already all in this one list, in order.
--- @return boolean whether the cursor moved
local function jump(tabpage, forward)
  local view = require("intentdiff.view")
  local plan = view.current_plan(tabpage)
  if not plan or not plan.hunk_rows or #plan.hunk_rows == 0 then
    return false
  end
  local win = vim.api.nvim_get_current_win()
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok then
    return false
  end
  local row = cursor[1]
  local target
  if forward then
    for _, range in ipairs(plan.hunk_rows) do
      if range[1] > row then
        target = range[1]
        break
      end
    end
  else
    for i = #plan.hunk_rows, 1, -1 do
      if plan.hunk_rows[i][1] < row then
        target = plan.hunk_rows[i][1]
        break
      end
    end
  end
  if not target then
    return false
  end
  pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
  return true
end

function M.next_hunk(tabpage)
  return jump(tabpage or vim.api.nvim_get_current_tabpage(), true)
end

function M.prev_hunk(tabpage)
  return jump(tabpage or vim.api.nvim_get_current_tabpage(), false)
end

local function install_keymaps(tabpage)
  local keymaps = require("intentdiff.keymaps")
  for _, win in ipairs(require("intentdiff.view").diff_wins(tabpage)) do
    keymaps.install(vim.api.nvim_win_get_buf(win), "view", {
      next_hunk = function() M.next_hunk(tabpage) end,
      prev_hunk = function() M.prev_hunk(tabpage) end,
    }, {
      next_hunk = "intent-diff: next hunk in group",
      prev_hunk = "intent-diff: previous hunk in group",
    })
  end
end

--- (Re)install ]c/[c on `tabpage`'s CURRENT diff pane buffers.
---
--- Called from `view.install_keymaps` after every render, because the panes
--- are fresh scratch buffers each time and inherit nothing. Unconditional:
--- `jump` above reads the painted plan, so there is no per-tab state that
--- could make installing the keys premature or wrong.
function M.reattach_keymaps(tabpage)
  install_keymaps(tabpage)
  return true
end

return M
