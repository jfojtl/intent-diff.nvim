-- Probe: two-pane whole-intent preview.
--  A) inject two scratch buffers into codediff's existing panes
--  B) restore a real file diff afterwards
--  C) collapse to inline (single unified buffer) and restore again
--  D) go inline -> side-by-side by creating the second window ourselves
local helpers = require("tests.helpers")

local repo = helpers.make_repo({ ["a.lua"] = table.concat(vim.fn.range(1, 60), "\n") })
local mod = vim.fn.range(1, 60)
mod[3] = "CHANGED"
helpers.write_file(repo, "a.lua", table.concat(mod, "\n"))
vim.cmd("cd " .. repo)

require("intentdiff").setup({
  cache_dir = vim.fn.tempname(), log_file = vim.fn.tempname() .. "/l.log", auto_open = false,
  provider = function(_, cb)
    vim.schedule(function() cb({ groups = { { title = "All", ids = "1-99" } } }) end)
    return { cancel = function() end }
  end,
})
require("intentdiff").open("")
local tab = vim.api.nvim_get_current_tabpage()
local entry = helpers.wait_for(function()
  local s = require("intentdiff")._session(tab)
  return s and s.model and s.model.state == "ready" and s or nil
end, 15000)
if not entry then print("NEVER READY"); vim.cmd("qa!") end

local view = require("intentdiff.view")
local lifecycle = require("codediff.ui.lifecycle")
local cdpath = require("codediff.core.path")
local file_entry = entry.model.groups[1].files[1]

local function scratch(lines)
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end
local function dump(tag)
  local s = lifecycle.get_session(tab)
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  print(("%s: wins=%d layout=%s single_pane=%s ow=%s mw=%s")
    :format(tag, #wins, tostring(s.layout), tostring(s.single_pane),
      tostring(s.original_win), tostring(s.modified_win)))
  for _, w in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(w)
    print(("    win=%s buf=%d lines=%d first=%q"):format(w, b,
      vim.api.nvim_buf_line_count(b), (vim.api.nvim_buf_get_lines(b, 0, 1, false))[1] or ""))
  end
end

-- baseline: a real file diff, side-by-side
view.show_file(entry.sess, file_entry, {})
vim.wait(3000, function() return false end, 100)
dump("BASELINE")

-- A) inject two preview buffers into the existing panes
local s = lifecycle.get_session(tab)
local ob = scratch({ "-- ORIGINAL SIDE --", "3", "", "(filler)" })
local nb = scratch({ "-- MODIFIED SIDE --", "CHANGED", "", "(filler)" })
vim.api.nvim_win_set_buf(s.original_win, ob)
vim.api.nvim_win_set_buf(s.modified_win, nb)
lifecycle.update_buffers(tab, ob, nb)
lifecycle.update_paths(tab, cdpath.empty(), cdpath.empty())
lifecycle.update_revisions(tab, nil, nil)
lifecycle.update_diff_result(tab, { changes = {}, moves = {} })
vim.wait(300, function() return false end, 50)
dump("A) two-pane preview injected")

-- B) restore the real file
view.show_file(entry.sess, file_entry, {})
vim.wait(3000, function() return false end, 100)
dump("B) restored after two-pane preview")

-- C) inline preview: collapse to one window via show_welcome, unified buffer
require("codediff.ui.view.side_by_side").show_welcome(tab, scratch({
  "-- UNIFIED --", "@@ -3,1 +3,1 @@", "-3", "+CHANGED",
}))
lifecycle.update_layout(tab, "inline")
vim.wait(300, function() return false end, 50)
dump("C) inline preview")

view.show_file(entry.sess, file_entry, {})
vim.wait(3000, function() return false end, 100)
dump("C') restored after inline preview")

-- D) inline codediff layout -> can we host a two-pane preview by splitting?
print("--- toggling codediff to inline, then previewing side-by-side ---")
require("codediff.ui.view").toggle_layout(tab)
vim.wait(2000, function() return false end, 100)
dump("D0) codediff inline")
local s2 = lifecycle.get_session(tab)
local ob2, nb2 = scratch({ "ORIG2", "3" }), scratch({ "MOD2", "CHANGED" })
vim.api.nvim_set_current_win(s2.modified_win)
vim.api.nvim_win_set_buf(s2.modified_win, ob2)
vim.cmd("rightbelow vsplit")
local new_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(new_win, nb2)
s2.original_win, s2.modified_win = s2.modified_win, new_win
lifecycle.update_buffers(tab, ob2, nb2)
lifecycle.update_paths(tab, cdpath.empty(), cdpath.empty())
lifecycle.update_diff_result(tab, { changes = {}, moves = {} })
lifecycle.update_layout(tab, "side-by-side")
s2.single_pane = nil
vim.wait(300, function() return false end, 50)
dump("D) two-pane preview built from inline")

view.show_file(entry.sess, file_entry, {})
vim.wait(3000, function() return false end, 100)
dump("D') restored after D")
print("EXPECT throughout: restores show wins=3, two panes of 60 lines each")
vim.cmd("qa!")
