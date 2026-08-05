-- Pure renderer. Files carrying their FULL content plus a set of hunk ids to
-- leave unfolded become paired rows, highlight spans, a row -> coordinate map,
-- character-refinement runs and fold ranges. No Neovim UI state: paint.lua
-- puts the result into buffers.
--
-- Both panes always have the SAME line count, padded with real filler rows.
-- That is what makes a fold range identical on both sides and lets plain
-- scrollbind hold the panes together.
--
-- `map` is row -> { file, line, side }, the real coordinate the row displays.
-- It is what makes every surface commentable without a preview ever becoming a
-- storage concept. Rows that display no line of any file (separators, fillers)
-- have no entry, so `map` is a SPARSE array: never walk it with ipairs, which
-- stops at the first hole. Walk `1 .. #pane.lines`.
--
-- `M.rows_for` is the inverse direction, derived by SCANNING that same array
-- rather than being built alongside it, so the two can never disagree about
-- where a comment lives.
local M = {}

local WHOLE_LINE = -1

-- ------------------------------------------------------------- hunk bodies --

--- Body lines of a hunk, without its @@ header and without the
--- "\ No newline at end of file" marker (metadata, not content).
local function body_of(hunk)
  local body = {}
  for line in hunk.text:gmatch("(.-)\n") do
    if not line:match("^@@") and line:sub(1, 1) ~= "\\" then
      body[#body + 1] = line
    end
  end
  return body
end

local function file_stats(file)
  local additions, deletions = 0, 0
  for _, h in ipairs(file.hunks or {}) do
    additions = additions + (h.additions or 0)
    deletions = deletions + (h.deletions or 0)
  end
  return additions, deletions
end

local function separator(file)
  if file.binary then
    return ("── %s   %s   binary"):format(file.path, file.status or "M")
  end
  local additions, deletions = file_stats(file)
  return ("── %s   %s   +%d -%d")
    :format(file.path, file.status or "M", additions, deletions)
end

--- Pair a hunk body into aligned original/modified rows, carrying the real
--- line number each half addresses. A context line emits on both sides; a run
--- of deletions and the addition run that follows it emit
--- max(#deletions, #additions) rows, paired by index, with a filler row on the
--- shorter side.
---
--- One row is `{ left, right, old_line, new_line, changed, run }`. `left`/`right`
--- are nil exactly on a filler — the row exists only to keep the two panes the
--- same height, and addresses nothing, so `old_line`/`new_line` is nil there
--- too. `changed` says the row came from a deletion/addition run rather than
--- from context, which content alone cannot tell: an ordinary 1-for-1
--- replacement has real text on both sides. `run` is the index of the changed
--- run the row belongs to, so the caller can collect character-refinement runs.
---
--- Deliberately NOT written with `x and y or z` anywhere: `left` is legitimately
--- an empty string for a blank source line, and this codebase has already paid
--- three times for that idiom collapsing a falsy-but-real middle term.
local function pair_body(body, old_start, new_start, runs, file_path)
  local rows = {}
  local minus, plus = {}, {}
  local old_line, new_line = old_start, new_start
  local function flush()
    if #minus == 0 and #plus == 0 then
      return
    end
    local run = {
      file = file_path,
      minus = {}, plus = {},
      minus_rows = {}, plus_rows = {},
    }
    runs[#runs + 1] = run
    local run_i = #runs
    for i = 1, math.max(#minus, #plus) do
      local m, p = minus[i], plus[i]
      local row = { changed = true, run = run_i, run_index = i }
      if m then
        row.left, row.old_line = m.text, m.line
        run.minus[#run.minus + 1] = m.text
      end
      if p then
        row.right, row.new_line = p.text, p.line
        run.plus[#run.plus + 1] = p.text
      end
      rows[#rows + 1] = row
    end
    minus, plus = {}, {}
  end
  for _, line in ipairs(body) do
    local kind = line:sub(1, 1)
    if kind == "-" then
      minus[#minus + 1] = { text = line:sub(2), line = old_line }
      old_line = old_line + 1
    elseif kind == "+" then
      plus[#plus + 1] = { text = line:sub(2), line = new_line }
      new_line = new_line + 1
    else
      flush()
      rows[#rows + 1] = {
        left = line:sub(2), right = line:sub(2),
        old_line = old_line, new_line = new_line, changed = false,
      }
      old_line = old_line + 1
      new_line = new_line + 1
    end
  end
  flush()
  return rows
end

-- ------------------------------------------------------------- the row walk --

--- Every row of one file, over its FULL content, with hunks marking the
--- changed stretches. Returns the rows plus `hunk_spans`, the row index range
--- each hunk occupies (relative to the returned array, 1-based inclusive).
---
--- Hunk ranges are END-EXCLUSIVE and a zero-length side is a zero-width anchor
--- at `start + 1`, so a pure addition never advances `o` and a pure deletion
--- never advances `m` — both fall out of the arithmetic with no special case.
local function file_rows(file, runs)
  local orig = file.original or {}
  local mod = file.modified or {}
  local rows, spans = {}, {}
  local o, m = 1, 1

  local function unchanged()
    -- Bound each side independently: a row past the end of one side's array
    -- is a filler on that side and must not claim a coordinate there, even
    -- though the loops that call this are driven by `o` (or, in the tail
    -- loop, by both together) rather than by each side's own length.
    local row = { changed = false }
    if o <= #orig then
      row.left, row.old_line = orig[o], o
    end
    if m <= #mod then
      row.right, row.new_line = mod[m], m
    end
    rows[#rows + 1] = row
    o, m = o + 1, m + 1
  end

  for _, h in ipairs(file.hunks or {}) do
    while o < h.original.start_line and o <= #orig do
      unchanged()
    end
    local first = #rows + 1
    for _, row in ipairs(pair_body(body_of(h), o, m, runs, file.path)) do
      rows[#rows + 1] = row
    end
    spans[h.id] = { first, #rows }
    o = h.original.end_line
    m = h.modified.end_line
  end

  while o <= #orig do
    unchanged()
  end
  -- A file whose modified side is longer than any hunk accounted for (which
  -- cannot happen for well-formed diffs, but a truncated `git show` would do
  -- it) still renders its tail rather than silently dropping lines.
  while m <= #mod do
    rows[#rows + 1] = { right = mod[m], new_line = m, changed = false }
    m = m + 1
  end

  return rows, spans
end

--- Rows for a file whose content could not be fetched: the hunk bodies alone,
--- exactly as the old preview rendered them. Folds are disabled for such a
--- file by the caller, because the rows are not the whole file.
local function fallback_rows(file, runs)
  local rows, spans = {}, {}
  for _, h in ipairs(file.hunks or {}) do
    local first = #rows + 1
    local o = (h.original or {}).start_line or 1
    local m = (h.modified or {}).start_line or 1
    for _, row in ipairs(pair_body(body_of(h), o, m, runs, file.path)) do
      rows[#rows + 1] = row
    end
    spans[h.id] = { first, #rows }
  end
  return rows, spans
end

-- ------------------------------------------------------------------- panes --

local function new_pane()
  local pane = { lines = {}, spans = {}, map = {} }
  function pane.add(text, group, target)
    pane.lines[#pane.lines + 1] = text
    if group then
      pane.spans[#pane.spans + 1] =
        { line = #pane.lines, col_start = 0, col_end = WHOLE_LINE, hl = group }
    end
    if target then
      pane.map[#pane.lines] = target
    end
    return #pane.lines
  end
  return pane
end

-- --------------------------------------------------------------- public API --

--- The row of `pane` the cursor at `row` addresses, or nil when that row
--- displays no line of any file (separator, filler, binary marker).
--- @return table|nil { file, line, side }
function M.target_at(pane, row)
  if not (pane and pane.map and row) then
    return nil
  end
  return pane.map[row]
end

--- The rows of `pane` that comment `c` covers, ascending.
---
--- The INVERSE of `pane.map`, derived by scanning it rather than accumulated
--- alongside it: a second, independently-built index is exactly how the
--- renderer and the store came to disagree about a drifted comment once
--- already. Whatever `target_at` answers for a row is what this answers with.
---
--- File-level (line 0) and intent comments address no line and yield none.
--- @return integer[] rows
function M.rows_for(pane, c)
  local out = {}
  if not (pane and pane.map and c and c.file) then
    return out
  end
  local first = c.line
  if not first or first == 0 or c.intent_title then
    return out
  end
  local last = c.line_end or first
  local side = c.side or "new"
  -- Numeric loop, NOT ipairs: `map` is sparse by construction and ipairs would
  -- stop at the first row that addresses nothing.
  for row = 1, #pane.lines do
    local t = pane.map[row]
    if t and t.file == c.file and t.side == side and t.line >= first and t.line <= last then
      out[#out + 1] = row
    end
  end
  return out
end

--- Build a render plan.
--- @param files table[] file entries carrying full content and ALL their hunks
--- @param visible table set of hunk ids to leave unfolded
--- @param layout string "inline" | "side-by-side"
--- @param opts table|nil { context = integer, line_budget = integer }
--- @return table plan
function M.build(files, visible, layout, opts)
  opts = opts or {}
  visible = visible or {}
  local original, modified = new_pane(), new_pane()
  local runs, meta = {}, {}

  for _, file in ipairs(files or {}) do
    local sep = separator(file)
    original.add(sep, "IntentDiffFileSeparator")
    modified.add(sep, "IntentDiffFileSeparator")

    if file.binary then
      meta[#meta + 1] = { path = file.path, filetype = file.filetype,
                          status = file.status, binary = true, fallback = false }
    else
      local has_content = file.original ~= nil and file.modified ~= nil
      local rows
      if has_content then
        rows = file_rows(file, runs)
      else
        rows = fallback_rows(file, runs)
      end
      meta[#meta + 1] = { path = file.path, filetype = file.filetype,
                          status = file.status, binary = false,
                          fallback = not has_content }

      for _, row in ipairs(rows) do
        local left_hl, right_hl
        if row.changed then
          if row.left == nil then
            left_hl = "IntentDiffFiller"
          else
            left_hl = "IntentDiffDelete"
          end
          if row.right == nil then
            right_hl = "IntentDiffFiller"
          else
            right_hl = "IntentDiffAdd"
          end
        end
        local left_target, right_target
        if row.old_line then
          left_target = { file = file.path, line = row.old_line, side = "old" }
        end
        if row.new_line then
          right_target = { file = file.path, line = row.new_line, side = "new" }
        end
        local lrow = original.add(row.left or "", left_hl, left_target)
        local rrow = modified.add(row.right or "", right_hl, right_target)
        -- Record where each run's lines landed, for character refinement.
        if row.run then
          local run = runs[row.run]
          if row.left ~= nil then
            run.minus_rows[#run.minus_rows + 1] = lrow
          end
          if row.right ~= nil then
            run.plus_rows[#run.plus_rows + 1] = rrow
          end
        end
      end
    end
  end

  return {
    layout = "side-by-side",
    original = original,
    modified = modified,
    files = meta,
    runs = runs,
    folds = {},
  }
end

return M
