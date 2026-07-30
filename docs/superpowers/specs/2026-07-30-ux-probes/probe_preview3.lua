-- Probe: uniform preview mechanism — inject into WHATEVER pane windows the
-- session already has; never create or close a window. Verify in BOTH layouts,
-- and verify the toggle recipe: restore file -> view.toggle_layout -> re-preview.
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
  vim.bo[b].buftype = "nofile"; vim.bo[b].bufhidden = "hide"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  return b
end
local function dump(tag)
  local s = lifecycle.get_session(tab)
  local wins = vim.api.nvim_tabpage_list_wins(tab)
  local descr = {}
  for _, w in ipairs(wins) do
    local b = vim.api.nvim_win_get_buf(w)
    descr[#descr + 1] = ("w%s/b%d(%dL,%q)"):format(w, b, vim.api.nvim_buf_line_count(b),
      ((vim.api.nvim_buf_get_lines(b, 0, 1, false))[1] or ""):sub(1, 14))
  end
  print(("%-34s wins=%d layout=%-12s sp=%-5s %s"):format(tag, #wins, tostring(s.layout),
    tostring(s.single_pane), table.concat(descr, " ")))
end

--- THE MECHANISM UNDER TEST: no window is created or closed.
local function show_preview(unified_lines, orig_lines, mod_lines)
  local s = lifecycle.get_session(tab)
  local ow, mw = s.original_win, s.modified_win
  local single = (ow == mw) or not (ow and vim.api.nvim_win_is_valid(ow))
  if single then
    local w = (mw and vim.api.nvim_win_is_valid(mw)) and mw or ow
    local b = scratch(unified_lines)
    vim.api.nvim_win_set_buf(w, b)
    lifecycle.update_buffers(tab, b, b)
  else
    local ob, nb = scratch(orig_lines), scratch(mod_lines)
    vim.api.nvim_win_set_buf(ow, ob)
    vim.api.nvim_win_set_buf(mw, nb)
    lifecycle.update_buffers(tab, ob, nb)
  end
  lifecycle.update_paths(tab, cdpath.empty(), cdpath.empty())
  lifecycle.update_revisions(tab, nil, nil)
  lifecycle.update_diff_result(tab, { changes = {}, moves = {} })
end

view.show_file(entry.sess, file_entry, {})
vim.wait(3000, function() return false end, 100)
dump("1 baseline side-by-side file")

show_preview({ "UNIFIED" }, { "ORIG" }, { "MOD" })
vim.wait(300, function() return false end, 50)
dump("2 preview (side-by-side)")

view.show_file(entry.sess, file_entry, {})
vim.wait(3000, function() return false end, 100)
dump("3 restored file")

-- toggle recipe: we are on a real file, so codediff's own toggle applies
view.toggle_layout(tab)
vim.wait(3000, function() return false end, 100)
dump("4 toggled -> inline file")

show_preview({ "UNIFIED-INLINE", "@@ -3,1 +3,1 @@", "-3", "+CHANGED" }, nil, nil)
vim.wait(300, function() return false end, 50)
dump("5 preview (inline)")

view.show_file(entry.sess, file_entry, {})
vim.wait(3000, function() return false end, 100)
dump("6 restored inline file")

view.toggle_layout(tab)
vim.wait(3000, function() return false end, 100)
dump("7 toggled -> side-by-side file")

show_preview({ "UNIFIED" }, { "ORIG-AGAIN" }, { "MOD-AGAIN" })
vim.wait(300, function() return false end, 50)
dump("8 preview (side-by-side again)")

view.show_file(entry.sess, file_entry, {})
vim.wait(3000, function() return false end, 100)
dump("9 restored file")
print("EXPECT: wins never exceeds 3; inline steps show wins=2; file restores show 60L panes")
vim.cmd("qa!")
