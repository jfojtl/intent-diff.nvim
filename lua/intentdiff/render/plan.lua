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
--
-- `folds` is ONE list of inclusive `{first, last}` row ranges for the WHOLE
-- plan, valid on both panes because both panes are the same height. Separator
-- rows never fold. It is empty in three cases, each deliberate:
--   * no hunk was visible      — the caller asked for no narrowing, and a plan
--                                folded end to end shows nothing;
--   * some file fell back      — a range spans the whole pane, so mixing a
--                                whole-file render with a hunks-only one would
--                                fold real content with nothing to unfold to;
--   * every row was kept open.
--
-- `hunk_rows` is one inclusive `{first, last}` PANE row range per VISIBLE
-- hunk, ascending by `first`. Built from the same `hunk_spans` and the same
-- before/after emission bracketing that `folds` uses — a second, independent
-- way of answering "where is this hunk on screen" is exactly how this
-- codebase previously got two surfaces disagreeing about a drifted comment.
-- `navigation.lua` reads it directly instead of comparing a pane row against
-- file line numbers.
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

--- `fallback_reason` is nil for a normal, whole-file render; when set it names
--- WHY the file rendered hunks-only, on the row the reader is looking at. The
--- old preview's max_lines truncated silently, which read as a renderer bug.
local function separator(file, fallback_reason)
  if file.binary then
    return ("── %s   %s   binary"):format(file.path, file.status or "M")
  end
  local additions, deletions = file_stats(file)
  local base = ("── %s   %s   +%d -%d")
    :format(file.path, file.status or "M", additions, deletions)
  if fallback_reason then
    return base .. "   (" .. fallback_reason .. ")"
  end
  return base
end

-- --------------------------------------------------------------- fold ranges --

--- Mark the FILE-RELATIVE row indices to keep open: every visible hunk's span,
--- grown by `context` on each side. `hunk_spans` is hunk id -> {first, last} in
--- indices into the file's own row array.
---
--- Deliberately file-relative rather than pane-relative: an inline plan emits
--- two pane rows for a 1-for-1 change and none for a filler, so a single
--- pane-row offset per file would drift. The caller translates each file row to
--- the pane rows it actually emitted.
--- @return boolean whether any visible hunk was found at all
local function visible_rows(hunk_spans, visible, context, keep)
  local any = false
  for id, span in pairs(hunk_spans) do
    if visible[id] then
      any = true
      for r = math.max(1, span[1] - context), span[2] + context do
        keep[r] = true
      end
    end
  end
  return any
end

--- Maximal runs of rows in `1..total` that are neither kept nor protected.
--- Inclusive `{first, last}`. `protected` holds the separator rows, which must
--- never fold: a closed fold over a separator hides which file follows.
local function fold_ranges(total, keep, protected)
  local ranges, start = {}, nil
  for row = 1, total do
    local hidden = not keep[row] and not protected[row]
    if hidden and not start then
      start = row
    elseif not hidden and start then
      ranges[#ranges + 1] = { start, row - 1 }
      start = nil
    end
  end
  if start then
    ranges[#ranges + 1] = { start, total }
  end
  return ranges
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
  -- Named `hunk_spans`, not `spans`: `pane.spans` is the highlight list, an
  -- entirely different thing.
  local rows, hunk_spans = {}, {}
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
    hunk_spans[h.id] = { first, #rows }
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

  return rows, hunk_spans
end

--- Rows for a file whose content could not be fetched: the hunk bodies alone,
--- exactly as the old preview rendered them. Folds are disabled for such a
--- file by the caller, because the rows are not the whole file.
local function fallback_rows(file, runs)
  local rows, hunk_spans = {}, {}
  for _, h in ipairs(file.hunks or {}) do
    local first = #rows + 1
    local o = (h.original or {}).start_line or 1
    local m = (h.modified or {}).start_line or 1
    for _, row in ipairs(pair_body(body_of(h), o, m, runs, file.path)) do
      rows[#rows + 1] = row
    end
    hunk_spans[h.id] = { first, #rows }
  end
  return rows, hunk_spans
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
--- @param opts table|nil { context = integer (default 3), line_budget = integer
---   (default 20000) — a file with more lines than this on either side renders
---   hunks-only and says so on its separator }
--- @return table plan
function M.build(files, visible, layout, opts)
  opts = opts or {}
  visible = visible or {}
  local context = opts.context or 3
  local budget = opts.line_budget or 20000
  local inline = layout == "inline"
  local original
  if not inline then
    original = new_pane()
  end
  local modified = new_pane()
  local runs, meta = {}, {}

  -- Fold bookkeeping, in MODIFIED-pane rows. One set for the whole plan, not
  -- one per file and not one per pane: side-by-side panes are always the same
  -- height, so a row range means the same thing on both sides.
  local keep, protected = {}, {}
  local any_visible, any_fallback = false, false

  -- Per-hunk PANE row bookkeeping, hunk id -> {first, last}. Built from the
  -- exact same `hunk_spans` the fold `keep` set above is grown from, and by
  -- the exact same before/after emission bracketing (below) that translates a
  -- file-relative row into the pane rows it actually emitted — navigation and
  -- folds read the same source so they can never disagree about where a hunk
  -- is, the way the renderer and the comment store once disagreed about a
  -- drifted comment.
  local hunk_pane_span = {}

  local function add_separator(sep)
    if original then
      original.add(sep, "IntentDiffFileSeparator")
    end
    protected[modified.add(sep, "IntentDiffFileSeparator")] = true
  end

  for _, file in ipairs(files or {}) do
    if file.binary then
      -- The separator IS the binary marker row, and binary files have no rows
      -- to fold, so they neither contribute folds nor disable anyone else's.
      add_separator(separator(file))
      meta[#meta + 1] = { path = file.path, filetype = file.filetype,
                          status = file.status, binary = true, fallback = false }
    else
      -- The reason has to be known before the separator is written, because
      -- the separator states it.
      local has_content = file.original ~= nil and file.modified ~= nil
      local fallback_reason
      -- `file.stale` wins over the generic "content unavailable": the caller
      -- (view.lua) withholds content for a stale file on purpose, even though
      -- content.get could answer for it — pairing fresh worktree lines against
      -- this file's frozen (pre-edit) hunk ranges is exactly the silently
      -- inconsistent diff this render must never produce. Naming the real
      -- reason tells the reader there IS a fix (reopen the review) rather than
      -- looking like an I/O failure.
      if file.stale then
        fallback_reason = "changed on disk since this review opened — reopen for a fresh diff"
      elseif not has_content then
        fallback_reason = "content unavailable"
      elseif #file.original > budget or #file.modified > budget then
        fallback_reason = "over line budget"
      end

      local rows, hunk_spans
      if fallback_reason then
        rows, hunk_spans = fallback_rows(file, runs)
        any_fallback = true
      else
        rows, hunk_spans = file_rows(file, runs)
      end

      add_separator(separator(file, fallback_reason))
      meta[#meta + 1] = { path = file.path, filetype = file.filetype,
                          status = file.status, binary = false,
                          fallback = fallback_reason ~= nil }

      -- File-relative rows to keep open. A fallback file's rows are not the
      -- whole file, so it contributes nothing here either way.
      local keep_row = {}
      if not fallback_reason then
        any_visible = visible_rows(hunk_spans, visible, context, keep_row) or any_visible
      end

      -- File-relative row -> hunk id, for VISIBLE hunks only, unpadded (no
      -- `context`): navigation lands on the hunk itself, not on the context
      -- lines folds additionally keep open around it. Built whether or not
      -- the file fell back to hunks-only rendering — a fallback file's rows
      -- are exactly its hunk bodies, so its hunks are just as reachable.
      local hunk_of_row = {}
      for id, span in pairs(hunk_spans) do
        if visible[id] then
          for r = span[1], span[2] do
            hunk_of_row[r] = id
          end
        end
      end

      for i, row in ipairs(rows) do
        -- Translate the file row to the pane rows it emits by bracketing the
        -- emission, rather than by a fixed offset: inline emits two rows for a
        -- 1-for-1 change and none for a filler, so no offset would hold.
        local before = #modified.lines
        if inline then
          -- One buffer, so a row's SIDE comes from its kind. A filler row has
          -- no content on either side and simply is not emitted here: inline
          -- has no second pane to stay level with.
          if row.left ~= nil and row.right ~= nil and not row.changed then
            local r = modified.add(row.right, nil,
              { file = file.path, line = row.new_line, side = "new" })
            _ = r
          else
            if row.left ~= nil then
              local r = modified.add(row.left, "IntentDiffDelete",
                { file = file.path, line = row.old_line, side = "old" })
              if row.run then
                local run = runs[row.run]
                run.minus_rows[#run.minus_rows + 1] = r
              end
            end
            if row.right ~= nil then
              local r = modified.add(row.right, "IntentDiffAdd",
                { file = file.path, line = row.new_line, side = "new" })
              if row.run then
                local run = runs[row.run]
                run.plus_rows[#run.plus_rows + 1] = r
              end
            end
          end
        else
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
        if keep_row[i] then
          for r = before + 1, #modified.lines do
            keep[r] = true
          end
        end
        local hid = hunk_of_row[i]
        if hid and #modified.lines > before then
          local span = hunk_pane_span[hid]
          if not span then
            hunk_pane_span[hid] = { before + 1, #modified.lines }
          else
            span[1] = math.min(span[1], before + 1)
            span[2] = math.max(span[2], #modified.lines)
          end
        end
      end
    end
  end

  -- No hunk visible means fold NOTHING, not fold everything: the caller asked
  -- for no narrowing, and a plan folded end to end shows the reader nothing.
  -- Any fallback file anywhere disables every fold, because a fold range spans
  -- the whole pane and would otherwise hide a whole file's real content behind
  -- a fold there is nothing to unfold to.
  local folds = {}
  if any_visible and not any_fallback then
    folds = fold_ranges(#modified.lines, keep, protected)
  end

  -- One entry per VISIBLE hunk, ascending PANE row ranges. Navigation reads
  -- this directly instead of comparing a pane row against file line numbers
  -- (the old, off-by-the-separator-row bug): every hunk here already IS a
  -- pane row range, on the plan that is actually painted, so a jump can never
  -- land anywhere the reader cannot see.
  local hunk_rows = {}
  for _, span in pairs(hunk_pane_span) do
    hunk_rows[#hunk_rows + 1] = { span[1], span[2] }
  end
  table.sort(hunk_rows, function(a, b) return a[1] < b[1] end)

  return {
    layout = inline and "inline" or "side-by-side",
    original = original,
    modified = modified,
    files = meta,
    runs = runs,
    folds = folds,
    hunk_rows = hunk_rows,
  }
end

return M
