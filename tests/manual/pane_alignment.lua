-- Manual harness: prove the diff panes stay aligned under REAL scroll and
-- cursor events.
--
-- WHY THIS EXISTS. Headless Neovim never raises WinScrolled or CursorMoved —
-- both come from the main loop's redraw/state check, which needs a UI (verified:
-- feedkeys, `normal!`, winrestview and vim.wait all produce zero firings under
-- --headless). tests/render_paint_spec.lua therefore invokes the registered
-- callbacks through `doautocmd`. That proves the callback body, the leader
-- detection, the echo absorption and the augroup lifecycle — but it CANNOT
-- prove Neovim's delivery: if paint.lua listened for the wrong event, the suite
-- would still be green. This script closes that gap by hand.
--
-- HOW TO RUN (needs a pty, hence `script`):
--
--   script -q /dev/null nvim -u tests/init.lua \
--     -c "luafile tests/manual/pane_alignment.lua" </dev/null >/dev/null
--   cat /tmp/intentdiff-pane-alignment.txt
--
-- Set $INTENTDIFF_ALIGN_OUT to write the log somewhere else. Every line must
-- read PASS, and `applies` must go up by exactly ONE per step — more than one
-- means an alignment is bouncing off its own echo.

local plan = require("intentdiff.render.plan")
local paint = require("intentdiff.render.paint")

local out_path = vim.env.INTENTDIFF_ALIGN_OUT
if not out_path or out_path == "" then
  out_path = "/tmp/intentdiff-pane-alignment.txt"
end

local function tall_file()
  local orig, mod = {}, {}
  for i = 1, 200 do
    orig[i] = "line " .. i
    mod[i] = "line " .. i
  end
  mod[100] = "CHANGED"
  return {
    path = "a.lua", status = "M", filetype = "lua", binary = false,
    original = orig, modified = mod,
    hunks = { {
      id = "a.lua:1", file = "a.lua", header = "@@ -100,1 +100,1 @@",
      text = "@@ -100,1 +100,1 @@\n-line 100\n+CHANGED\n",
      original = { start_line = 100, end_line = 101 },
      modified = { start_line = 100, end_line = 101 },
      additions = 1, deletions = 1,
    } },
  }
end

vim.cmd("tabnew")
local a = vim.api.nvim_get_current_win()
vim.cmd("rightbelow vsplit")
local b = vim.api.nvim_get_current_win()
local tab = vim.api.nvim_get_current_tabpage()
paint.render(plan.build({ tall_file() }, {}, "side-by-side"), { original = a, modified = b })

local log, failures, last_applies = {}, 0, nil

local function topline(win)
  return vim.api.nvim_win_call(win, function() return vim.fn.line("w0") end)
end

local function row(win)
  return vim.api.nvim_win_get_cursor(win)[1]
end

--- Record one observation. Aligned means both panes agree on the top line AND
--- on the cursor row; `applies` must have moved by at most one since the last
--- observation, or an alignment is triggering another.
local function check(tag)
  local state = paint.sync_state(tab)
  local aligned = topline(a) == topline(b) and row(a) == row(b)
  local settled = true
  if last_applies then
    settled = (state.applies - last_applies) <= 1
  end
  last_applies = state.applies
  local verdict = "PASS"
  if not (aligned and settled) then
    verdict = "FAIL"
    failures = failures + 1
  end
  log[#log + 1] = string.format(
    "%s  %-28s a(top=%d,row=%d) b(top=%d,row=%d) applies=%d",
    verdict, tag, topline(a), row(a), topline(b), row(b), state.applies)
end

local function keys(win, s)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(s, true, false, true), "nx", false)
end

-- Each pair is "do something a user would do", then "look at the panes one
-- event-loop turn later", which is when Neovim has delivered the event.
local steps = {
  function() keys(a, "G") end,
  function() check("G in original") end,
  function() keys(a, "gg") end,
  function() check("gg in original") end,
  function() keys(b, "120G") end,
  function() check("120G in modified") end,
  function() keys(b, "5j") end,
  function() check("5j in modified") end,
  function() keys(b, "3<C-e>") end,
  function() check("<C-e> in modified") end,
  function() keys(a, "zz") end,
  function() check("zz in original") end,
  -- The report's own symptom, forced: one pane shoved a hundred rows away.
  -- Native scrollbind would keep that offset forever.
  function()
    vim.api.nvim_win_call(a, function() vim.fn.winrestview({ topline = 5, lnum = 8 }) end)
  end,
  function() check("forced desync of original") end,
  function() keys(a, "j") end,
  function() check("j after forced desync") end,
}

local i = 0
local function tick()
  i = i + 1
  if not steps[i] then
    local verdict = "ALL PASS"
    if failures > 0 then
      verdict = failures .. " FAILURE(S)"
    end
    log[#log + 1] = "---- " .. verdict
    vim.fn.writefile(log, out_path)
    vim.cmd("qa!")
    return
  end
  pcall(steps[i])
  vim.defer_fn(tick, 120)
end

vim.defer_fn(tick, 300)
