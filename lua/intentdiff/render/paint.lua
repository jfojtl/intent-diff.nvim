-- Puts a render plan into buffers. The impure half of the renderer: plan.lua
-- decides what the panes contain, this decides nothing and only draws it.
local M = {}

M.ns = vim.api.nvim_create_namespace("intentdiff_render")

--- codediff.ui.inline, if the plugin is installed. Guarded with pcall so a
--- missing codediff degrades to no syntax highlighting instead of erroring.
local function cd_inline()
  local ok, mod = pcall(require, "codediff.ui.inline")
  if ok then
    return mod
  end
  return nil
end

--- codediff.core.diff, if the plugin (and its platform's C library) is
--- installed. Guarded with pcall so a missing binary degrades to no
--- character highlighting instead of erroring.
local function cd_diff()
  local ok, mod = pcall(require, "codediff.core.diff")
  if ok then
    return mod
  end
  return nil
end

--- compute_diff returns 1-based UTF-16 columns (VSCode semantics); extmarks
--- want 0-based byte columns.
---
--- Neovim >=0.11 deprecated the pre-0.11 vim.str_byteindex(s, col16, true)
--- form in favour of vim.str_byteindex(s, encoding, index, strict_indexing).
--- Verified empirically on this build (v0.12.4): the old 3-arg call still
--- works and returns the right byte offset, but it routes through
--- vim.deprecate (confirmed by wrapping vim.deprecate and observing it
--- fire), so it is reimplemented here with the current signature instead.
--- strict_indexing = false so an index at or past the end of the line (the
--- exclusive end_col of a change that reaches the end of the line) clamps
--- to #line rather than raising.
local function utf16_to_byte(line, col16)
  if not line or col16 <= 1 then
    return 0
  end
  local ok, byte = pcall(vim.str_byteindex, line, "utf-16", col16 - 1, false)
  if ok then
    return math.min(byte, #line)
  end
  return math.min(col16 - 1, #line)
end

--- Character ranges inside each changed run, placed on the rows plan.lua
--- recorded for that run. compute_diff only ever runs INSIDE a region git
--- already decided is changed, so the two algorithms can never disagree about
--- line pairing.
local function paint_chars(bufs, plan)
  local diff = cd_diff()
  if not diff then
    return
  end
  for _, run in ipairs(plan.runs) do
    if #run.minus > 0 and #run.plus > 0 then
      local ok, result = pcall(diff.compute_diff, run.minus, run.plus, {})
      if ok and result and result.changes then
        for _, change in ipairs(result.changes) do
          for _, inner in ipairs(change.inner_changes or {}) do
            -- Original side.
            local o = inner.original
            local orow = run.minus_rows[o.start_line]
            if orow and o.start_line == o.end_line then
              local target_buf, target_pane
              if plan.layout == "inline" then
                target_buf, target_pane = bufs.modified, plan.modified
              else
                target_buf, target_pane = bufs.original, plan.original
              end
              if target_buf and target_pane then
                local text = target_pane.lines[orow]
                local sc = utf16_to_byte(text, o.start_col)
                local ec = utf16_to_byte(text, o.end_col)
                if ec > sc then
                  pcall(vim.api.nvim_buf_set_extmark, target_buf, M.ns, orow - 1, sc,
                    { end_col = ec, hl_group = "IntentDiffDeleteChar", priority = 100 })
                end
              end
            end
            -- Modified side.
            local m = inner.modified
            local mrow = run.plus_rows[m.start_line]
            if mrow and m.start_line == m.end_line and bufs.modified then
              local text = plan.modified.lines[mrow]
              local sc = utf16_to_byte(text, m.start_col)
              local ec = utf16_to_byte(text, m.end_col)
              if ec > sc then
                pcall(vim.api.nvim_buf_set_extmark, bufs.modified, M.ns, mrow - 1, sc,
                  { end_col = ec, hl_group = "IntentDiffAddChar", priority = 100 })
              end
            end
          end
        end
      end
    end
  end
end

--- Per-window visible-row sets, read by M.foldexpr.
local folded_by_win = {}

--- Fold expression: 1 inside a fold range, 0 outside. Registered per window by
--- M.render. Reads a per-window set rather than the plan so a recycled window
--- id can never answer with a stale plan's ranges.
function M.foldexpr()
  local win = vim.api.nvim_get_current_win()
  local set = folded_by_win[win]
  if not set then
    return "0"
  end
  return set[vim.v.lnum] and "1" or "0"
end

--- A fresh scratch buffer holding `pane`.
---
--- bufhidden is deliberately "hide", not "wipe": a window may still be being
--- swapped off this buffer when the next generation arrives, and "wipe" would
--- delete it mid-swap, leaving a caller reading an already-invalid buffer id.
--- M.retire cleans up afterwards instead.
local function pane_buf(pane)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, pane.lines)
  vim.bo[buf].modifiable = false
  for _, s in ipairs(pane.spans) do
    if s.col_end == -1 then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, s.line - 1, 0,
        { line_hl_group = s.hl })
    else
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, s.line - 1, s.col_start,
        { end_col = s.col_end, hl_group = s.hl })
    end
  end
  return buf
end

--- True when `buf` is the current buffer of any window, in any tabpage.
local function buf_is_displayed(buf)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      return true
    end
  end
  return false
end

--- Delete a previous generation's buffers one event-loop tick from now, once
--- whatever replaced them in their windows has settled.
---
--- Never deletes a buffer still displayed: nvim_buf_delete with force closes
--- every window showing it, and takes the tabpage with it if that was the last
--- window — exactly the window-closing this whole mechanism exists to avoid.
function M.retire(bufs)
  if not bufs then
    return
  end
  vim.schedule(function()
    for _, buf in pairs(bufs) do
      if buf and vim.api.nvim_buf_is_valid(buf) and not buf_is_displayed(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end)
end

--- Treesitter highlights for every (file, side) the plan draws, keyed
--- syntax[path][side][file_line] = { {start_col, end_col, hl_group}, ... }.
---
--- Computed per (file, side) rather than per pane row range because
--- compute_syntax_highlights parses its input as ONE document: an inline pane
--- interleaves deletion rows (original content) with addition and context rows
--- (modified content), and parsing that mixture would produce garbage at every
--- changed run.
local function compute_syntax(plan, content)
  local inline = cd_inline()
  if not inline or not content then
    return {}
  end
  local syntax = {}
  for _, file in ipairs(plan.files) do
    local per_file = content[file.path]
    if per_file and file.filetype and file.filetype ~= "" then
      syntax[file.path] = {
        old = inline.compute_syntax_highlights(per_file.old or {}, file.filetype),
        new = inline.compute_syntax_highlights(per_file.new or {}, file.filetype),
      }
    end
  end
  return syntax
end

--- Place syntax extmarks on every row of `pane` that addresses a real line.
--- Separators and fillers have no map entry and so get nothing.
local function paint_syntax(buf, pane, syntax)
  for row = 1, #pane.lines do
    local t = pane.map[row]
    if t then
      local per_file = syntax[t.file]
      local per_side = per_file and per_file[t.side]
      local hls = per_side and per_side[t.line]
      if hls then
        local text = pane.lines[row]
        for _, hl in ipairs(hls) do
          -- compute_syntax_highlights returns 1-based inclusive start_col and
          -- an exclusive end_col; extmarks want 0-based start and exclusive end.
          local sc = math.max(0, hl.start_col - 1)
          local ec = math.min(hl.end_col, #text)
          if ec > sc then
            pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row - 1, sc,
              { end_col = ec, hl_group = hl.hl_group, priority = 90 })
          end
        end
      end
    end
  end
end

--- Whether the panes should wrap long lines (`config.pane_wrap`, off by
--- default). Read through a pcall so the renderer keeps working if it is ever
--- driven before `setup()` has run.
---
--- Wrapping is off because alignment is expressed in BUFFER rows: the two panes
--- hold different text on every changed row, so a 40-character line opposite a
--- 200-character one takes one screen row against three at the same width, and
--- every row below it sits at a different height in each pane — the reported
--- symptom again, from a different cause. The sidebar turns wrapping off for
--- the same reason (its tree alignment) and wraps its own text by hand.
local function pane_wrap()
  local ok, config = pcall(require, "intentdiff.config")
  if not ok then
    return false
  end
  if config.options.pane_wrap == true then
    return true
  end
  return false
end

--- Apply `plan.folds` to `win`, or clear folding when there is nothing to fold.
local function apply_folds(win, plan)
  if #plan.folds == 0 then
    folded_by_win[win] = nil
    vim.wo[win].foldenable = false
    return
  end
  local set = {}
  for _, range in ipairs(plan.folds) do
    for row = range[1], range[2] do
      set[row] = true
    end
  end
  folded_by_win[win] = set
  vim.wo[win].foldmethod = "expr"
  vim.wo[win].foldexpr = "v:lua.require'intentdiff.render.paint'.foldexpr()"
  vim.wo[win].foldlevel = 0
  vim.wo[win].foldminlines = 0
  vim.wo[win].foldenable = true
end

-- --------------------------------------------------------- pane alignment --
--
-- Native `scrollbind` mirrors RELATIVE scroll deltas, so the two panes stay
-- wherever a fold toggle, a jump or a mouse scroll left them: once drifted,
-- forever drifted, and `syncbind` at render time only fixes the drift that
-- already happened. What the reader wants is ABSOLUTE alignment, and here it is
-- exact for free: plan.lua pads both side-by-side panes with real filler rows,
-- so `#plan.original.lines == #plan.modified.lines` and buffer row N in the
-- left pane is buffer row N in the right pane, always. Aligning the panes is
-- therefore "put the other window on the same topline and the same cursor row"
-- — no filler tables, no offset arithmetic.

--- Per-tabpage alignment record:
--- `{ wins = { modified, original }, group = augroup id, expected = { [win] = fp },
---    syncing = boolean, applies = integer }`.
local sync_by_tab = {}

local function win_view(win)
  return vim.api.nvim_win_call(win, vim.fn.winsaveview)
end

--- The part of a window's view a desync would show up in: which line is at the
--- top, and which line the cursor is on.
local function view_fp(win)
  local ok, v = pcall(win_view, win)
  if not ok then
    return ""
  end
  return string.format("%d,%d", v.topline or 0, v.lnum or 0)
end

local function live_wins(state)
  local out = {}
  for _, win in ipairs(state.wins) do
    if vim.api.nvim_win_is_valid(win) then
      out[#out + 1] = win
    end
  end
  return out
end

local function is_member(state, win)
  for _, w in ipairs(state.wins) do
    if w == win then
      return true
    end
  end
  return false
end

--- Remember where every member window ACTUALLY ended up. The recorded views are
--- what makes an echo event (the scroll our own `winrestview` causes, delivered
--- after our callback has already returned) a no-op: it finds no window whose
--- view differs from what we last wrote, so it aligns nothing and fires nothing.
--- Recording the real resulting view rather than the requested one matters when
--- the follower cannot honour the request exactly — a closed fold at the target
--- topline moves the topline to the fold's first row — because otherwise every
--- event afterwards would see a permanent difference and re-align forever.
local function record(state)
  for _, win in ipairs(live_wins(state)) do
    state.expected[win] = view_fp(win)
  end
end

--- The member window the USER moved, i.e. the one whose view no longer matches
--- what we last recorded. The focused window wins a tie, since that is the one
--- the reader is driving.
local function detect_leader(state)
  local cur = vim.api.nvim_get_current_win()
  local candidate
  for _, win in ipairs(live_wins(state)) do
    if view_fp(win) ~= state.expected[win] then
      if win == cur then
        return win
      end
      if not candidate then
        candidate = win
      end
    end
  end
  return candidate
end

--- Put every other member window on `leader`'s ABSOLUTE topline and cursor row.
---
--- `winrestview` rather than `nvim_win_set_cursor`: the cursor API has no say
--- over the topline at all, and moving the cursor makes Neovim scroll the
--- window by 'scrolloff' rules — which is exactly the relative, drift-prone
--- behaviour being replaced. `winrestview` sets topline and cursor in ONE
--- consistent operation.
---
--- The COLUMN is deliberately not copied. The two panes hold different text on
--- every changed row, so the leader's column addresses nothing in particular on
--- the follower's line; the follower keeps its own column (Vim clamps it to the
--- new line for us). Only the row carries meaning across the panes.
local function align(state, leader)
  local lv = win_view(leader)
  for _, win in ipairs(live_wins(state)) do
    if win ~= leader then
      vim.api.nvim_win_call(win, function()
        local v = vim.fn.winsaveview()
        local last = vim.api.nvim_buf_line_count(0)
        v.topline = math.min(math.max(lv.topline or 1, 1), last)
        v.lnum = math.min(math.max(lv.lnum or 1, 1), last)
        vim.fn.winrestview(v)
      end)
    end
  end
  state.applies = state.applies + 1
  record(state)
end

--- Handle one scroll or cursor event.
---
--- `state.syncing` is belt to the braces of Neovim's own rule that an
--- autocommand does not trigger itself (ours are registered without `nested`),
--- and it is what makes this safe even if a future caller drives the handler
--- directly.
local function on_event(state)
  if state.syncing then
    return
  end
  if #live_wins(state) < 2 then
    return
  end
  local leader = detect_leader(state)
  if not leader then
    return -- nothing moved, or only our own alignment did: stop here
  end
  state.syncing = true
  pcall(align, state, leader)
  state.syncing = false
end

--- Stop keeping `tabpage`'s panes aligned and forget its record.
function M.unsync(tabpage)
  local state = sync_by_tab[tabpage]
  if not state then
    return
  end
  sync_by_tab[tabpage] = nil
  pcall(vim.api.nvim_del_augroup_by_id, state.group)
end

--- The alignment record for `tabpage`, or nil. Read-only; exposed for tests and
--- diagnostics.
function M.sync_state(tabpage)
  return sync_by_tab[tabpage]
end

--- Re-align `tabpage`'s panes right now, taking the focused pane as the truth
--- when the cursor is in one and the modified pane otherwise. Called after a
--- render has put the cursors back, so a fresh generation starts aligned rather
--- than waiting for the reader's first move.
function M.resync(tabpage)
  local state = sync_by_tab[tabpage]
  if not state then
    return
  end
  local wins = live_wins(state)
  if #wins < 2 then
    return
  end
  local leader = wins[1]
  local cur = vim.api.nvim_get_current_win()
  if is_member(state, cur) and vim.api.nvim_win_is_valid(cur) then
    leader = cur
  end
  state.syncing = true
  pcall(align, state, leader)
  state.syncing = false
end

--- Keep `tabpage`'s two pane windows vertically aligned.
---
--- The augroup is per tabpage and re-created with `clear = true`, so the
--- repeated renders a review does (every sidebar move, every layout toggle)
--- REPLACE these autocommands instead of stacking a fresh copy on each one.
--- Callbacks close over `state`; a superseded generation's callbacks are gone
--- with the augroup and can never answer for the new one.
local function bind_sync(tabpage, wins)
  local group = vim.api.nvim_create_augroup("IntentDiffSync_" .. tostring(tabpage), { clear = true })
  local state = {
    -- Modified first: it is the default leader, and it is the side a reader
    -- looks at.
    wins = { wins.modified, wins.original },
    group = group,
    expected = {},
    syncing = false,
    applies = 0,
  }
  sync_by_tab[tabpage] = state
  record(state)

  -- WinScrolled covers scrolling — including a mouse scroll over a pane that is
  -- not focused, which no cursor event reports. It does NOT cover a cursor move
  -- inside the visible area (nothing scrolled), which is the other half of the
  -- report: a cursor put on a row must show the SAME row opposite. Hence both
  -- events. Neither callback trusts the event's own window: `detect_leader`
  -- asks which pane actually moved, which is also how an echo is recognised.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function()
      -- WinScrolled fires for a scroll ANYWHERE, and `nvim_win_call` really
      -- does reach into a background tabpage: without this, scrolling an
      -- unrelated buffer would cost two winsaveview calls per open review tab
      -- and could re-align a review the user is not even looking at.
      -- CursorMoved's `is_member` check is the same guard by another route.
      if vim.api.nvim_get_current_tabpage() ~= tabpage then
        return
      end
      on_event(state)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      if not is_member(state, vim.api.nvim_get_current_win()) then
        return -- a cursor moving anywhere else in the tab is none of our business
      end
      on_event(state)
    end,
  })
  -- A pane closed behind our back (`:q` in a pane, or the layout toggle closing
  -- the original side) leaves nothing to align: tear down rather than keep
  -- firing against a dead window id.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local closed = tonumber(args.match)
      if closed and is_member(state, closed) then
        -- Scheduled so the augroup is not deleted from inside its own
        -- dispatch, and guarded by identity: a layout toggle closes the
        -- original window and immediately binds a NEW record for this tabpage,
        -- and this teardown must never take that one down with it.
        vim.schedule(function()
          if sync_by_tab[tabpage] == state then
            M.unsync(tabpage)
          end
        end)
      end
    end,
  })
end

--- Render `plan` into `wins`.
--- @param wins table { original = win|nil, modified = win }
--- @param content table|nil { [path] = { old = string[], new = string[] } };
---   when nil, no syntax highlighting is applied.
--- @return table { bufs = { original = bufnr|nil, modified = bufnr }, plan = plan }
function M.render(plan, wins, content)
  -- Drop entries for windows that no longer exist, so foldexpr never answers
  -- for a recycled window id.
  for win in pairs(folded_by_win) do
    if not vim.api.nvim_win_is_valid(win) then
      folded_by_win[win] = nil
    end
  end
  -- Same for tabpages that went away without anyone telling us.
  for tabpage in pairs(sync_by_tab) do
    if not vim.api.nvim_tabpage_is_valid(tabpage) then
      M.unsync(tabpage)
    end
  end

  local bufs = {}
  local two_pane = plan.original ~= nil
    and wins.original ~= nil
    and wins.original ~= wins.modified
    and vim.api.nvim_win_is_valid(wins.original)

  local syntax = compute_syntax(plan, content)

  if two_pane then
    bufs.original = pane_buf(plan.original)
    paint_syntax(bufs.original, plan.original, syntax)
    vim.api.nvim_win_set_buf(wins.original, bufs.original)
  end
  bufs.modified = pane_buf(plan.modified)
  paint_syntax(bufs.modified, plan.modified, syntax)
  vim.api.nvim_win_set_buf(wins.modified, bufs.modified)

  paint_chars(bufs, plan)

  local wrap = pane_wrap()
  for side, win in pairs({ original = wins.original, modified = wins.modified }) do
    if (side ~= "original" or two_pane) and win and vim.api.nvim_win_is_valid(win) then
      -- Explicitly OFF, never merely unset: the panes are aligned structurally
      -- now (see "pane alignment" above), and a window still carrying native
      -- scrollbind from an earlier generation — or from the user's own defaults
      -- — would add its relative scrolling on top of ours and fight it.
      vim.wo[win].scrollbind = false
      vim.wo[win].cursorbind = false
      vim.wo[win].wrap = wrap
      apply_folds(win, plan)
    end
  end

  local tabpage = vim.api.nvim_win_get_tabpage(wins.modified)
  if two_pane then
    bind_sync(tabpage, wins)
    M.resync(tabpage)
  else
    -- Inline layout is ONE pane. There is nothing to align, and any record left
    -- over from a side-by-side generation of this tab has to go.
    M.unsync(tabpage)
  end

  return { bufs = bufs, plan = plan }
end

return M
