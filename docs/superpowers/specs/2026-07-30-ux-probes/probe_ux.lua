-- Probe 1: does an "A" (staged-new) file render empty in WORKING mode?
-- Probe 2: can side_by_side.show_welcome host an arbitrary scratch buffer as a
--          single real pane, and does cd.view.update() then restore both panes?
local helpers = require("tests.helpers")

local repo = helpers.make_repo({
  ["a.lua"] = table.concat(vim.fn.range(1, 60), "\n"),
})
-- staged-new file => status "A" against HEAD, content only on disk/index
helpers.write_file(repo, "brand_new.lua", table.concat({
  "local M = {}", "", "function M.one()", "  return 1", "end", "", "return M",
}, "\n"))
helpers.git(repo, "add", "brand_new.lua")
local mod = vim.fn.range(1, 60)
mod[3] = "CHANGED"
helpers.write_file(repo, "a.lua", table.concat(mod, "\n"))
vim.cmd("cd " .. repo)

require("intentdiff").setup({
  cache_dir = vim.fn.tempname(),
  log_file = vim.fn.tempname() .. "/l.log",
  auto_open = false,
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

print("== inventory")
for _, f in ipairs(entry.inventory.files) do
  print(("  %s  status=%s"):format(f.path, f.status))
end
print("target_revision=" .. tostring(entry.sess.target_revision))

-- find the A file's group/file index
local gi, fi
for g, grp in ipairs(entry.model.groups) do
  for i, f in ipairs(grp.files) do
    if f.path == "brand_new.lua" then gi, fi = g, i end
  end
end
print(("A-file at group %s file %s"):format(tostring(gi), tostring(fi)))

-- PROBE 1: select it, inspect the pane contents
entry.sidebar.update(entry.model)
require("intentdiff")._session(tab)
local view = require("intentdiff.view")
view.show_file(entry.sess, entry.model.groups[gi].files[fi], {})
vim.wait(3000, function() return false end, 100)
local s = view.get_session(tab)
local mb = s.modified_bufnr
local lines = mb and vim.api.nvim_buf_get_lines(mb, 0, -1, false) or {}
print(("PROBE1 modified pane: %d lines, first=%q  bufname=%s")
  :format(#lines, lines[1] or "", vim.api.nvim_buf_get_name(mb or 0)))
print("PROBE1 EXPECT-IF-BUGGY: 1 line, empty, codediff:///...///WORKING/brand_new.lua")

-- PROBE 2: show_welcome with our own scratch buffer, then restore
local ok_sbs, sbs = pcall(require, "codediff.ui.view.side_by_side")
print("show_welcome available: " .. tostring(ok_sbs and type(sbs.show_welcome) == "function"))
local scratch = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(scratch, 0, -1, false, {
  "── a.lua  M  +1 -1", "@@ -3,1 +3,1 @@", "-3", "+CHANGED",
})
sbs.show_welcome(tab, scratch)
vim.wait(500, function() return false end, 50)
local s2 = view.get_session(tab)
local wins = vim.api.nvim_tabpage_list_wins(tab)
print(("PROBE2 after show_welcome: wins=%d single_pane=%s orig_win=%s mod_win=%s")
  :format(#wins, tostring(s2.single_pane), tostring(s2.original_win), tostring(s2.modified_win)))
for _, w in ipairs(wins) do
  local b = vim.api.nvim_win_get_buf(w)
  print(("   win=%s buf=%d first=%q"):format(w, b,
    (vim.api.nvim_buf_get_lines(b, 0, 1, false))[1] or ""))
end
print("PROBE2 preview visible: " .. tostring(vim.iter(wins):any(function(w)
  return vim.api.nvim_win_get_buf(w) == scratch end)))

-- restore a normal modified file through our own show_file
view.show_file(entry.sess, entry.model.groups[gi].files[fi == 1 and 2 or 1], {})
vim.wait(3000, function() return false end, 100)
local s3 = view.get_session(tab)
local wins3 = vim.api.nvim_tabpage_list_wins(tab)
print(("PROBE2 after restore: wins=%d single_pane=%s orig_lines=%s mod_lines=%s")
  :format(#wins3, tostring(s3.single_pane),
    s3.original_bufnr and vim.api.nvim_buf_line_count(s3.original_bufnr) or "nil",
    s3.modified_bufnr and vim.api.nvim_buf_line_count(s3.modified_bufnr) or "nil"))
print("PROBE2 EXPECT: wins=3 (sidebar+2 panes), both panes populated")
vim.cmd("qa!")
