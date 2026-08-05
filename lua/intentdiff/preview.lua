-- Pure renderer for the whole-intent preview: a group's complete diff with
-- visible file boundaries, in either layout. No Neovim UI state — view.lua puts
-- the result into buffers.
--
-- Each pane also carries a `map`: row → { file, line, side }, the real
-- coordinate the row displays. That is what makes the preview COMMENTABLE
-- without the preview ever becoming a storage concept — a comment placed here
-- records the same (file, line, side) it would have recorded in that file's
-- own diff. Rows that display no line of any file (the `── path` separators,
-- the `@@` headers, side-by-side fillers and the truncation summary) simply
-- have no entry, so `map` is a SPARSE array: never walk it with ipairs, which
-- stops at the first hole. Walk `1 .. #pane.lines` instead.
--
-- `M.rows_for` is the inverse direction (comment → rows), derived by scanning
-- that same array rather than being built alongside it, so the two can never
-- disagree about where a comment lives.
local M = {}

local tree = require("intentdiff.tree")

local WHOLE_LINE = -1

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
  local additions, deletions = file_stats(file)
  return ("── %s   %s   +%d -%d")
    :format(file.path, file.status or "M", additions, deletions)
end

--- Files in the same order the sidebar tree shows them, so the preview and the
--- sidebar always agree about ordering.
local function ordered_files(group)
  local files, seen = {}, {}
  for _, row in ipairs(tree.flatten(tree.build(group.files or {}), {})) do
    if row.kind == "file" and not seen[row.file_i] then
      seen[row.file_i] = true
      files[#files + 1] = group.files[row.file_i]
    end
  end
  return files
end

--- A pane under construction: lines, highlight spans, and the row → target map.
--- `target` is nil for every row that displays no line of any file.
local function new_pane()
  local pane = { lines = {}, highlights = {}, map = {} }
  function pane.add(text, group, target)
    pane.lines[#pane.lines + 1] = text
    if group then
      pane.highlights[#pane.highlights + 1] =
        { line = #pane.lines, col_start = 0, col_end = WHOLE_LINE, hl = group }
    end
    if target then
      pane.map[#pane.lines] = target
    end
    return #pane.lines
  end
  return pane
end

--- The old/new line numbers a hunk's body starts counting from.
---
--- `hunks.range` is END-EXCLUSIVE and represents a zero-length side as a
--- zero-width anchor at `start + 1` — so `original.start_line` is one past the
--- git header's number exactly when the hunk has NO `-` and no context rows
--- (a pure addition), and `modified.start_line` likewise exactly when it has
--- no `+` and no context rows (a pure deletion). In both cases the skewed
--- counter is never consumed by the walk below, so reading `start_line`
--- directly is exact for every hunk shape. `end_line` is deliberately unused:
--- the walk consumes rows, it does not measure ranges.
local function start_lines(hunk)
  local original = hunk.original or {}
  local modified = hunk.modified or {}
  return original.start_line or 1, modified.start_line or 1
end

local function line_group(line)
  local kind = line:sub(1, 1)
  if kind == "+" then
    return "IntentDiffAdd"
  elseif kind == "-" then
    return "IntentDiffDelete"
  end
  return nil
end

--- Inline puts one buffer in the pane, so a row's SIDE comes from its marker:
--- a `-` row shows a line of the original file, `+` and context rows a line of
--- the modified one. (This is the same rule the real inline diff follows —
--- there the buffer is the modified file outright.)
local function render_inline(group)
  local pane, hunk_lines = new_pane(), {}
  for _, file in ipairs(ordered_files(group)) do
    pane.add(separator(file), "IntentDiffFileSeparator")
    for _, hunk in ipairs(file.hunks or {}) do
      hunk_lines[#hunk_lines + 1] = pane.add(hunk.header, "IntentDiffPreviewHunk")
      local old_line, new_line = start_lines(hunk)
      for _, line in ipairs(body_of(hunk)) do
        local kind = line:sub(1, 1)
        local target
        if kind == "-" then
          target = { file = file.path, line = old_line, side = "old" }
          old_line = old_line + 1
        elseif kind == "+" then
          target = { file = file.path, line = new_line, side = "new" }
          new_line = new_line + 1
        else
          -- Context: consumes a line on BOTH sides, and is addressed as the
          -- new side (the side this buffer otherwise shows).
          target = { file = file.path, line = new_line, side = "new" }
          old_line = old_line + 1
          new_line = new_line + 1
        end
        pane.add(line, line_group(line), target)
      end
    end
  end
  return pane, hunk_lines
end

--- Pair a hunk body into aligned original/modified rows, carrying the real
--- line number each half addresses. A context line emits on both sides; a run
--- of deletions and the addition run that follows it emit
--- max(#deletions, #additions) rows, paired by index, with a filler row on the
--- shorter side.
---
--- One row is `{ left, right, old_line, new_line, changed }`. `left`/`right`
--- are nil exactly on a filler — the row exists only to keep the two panes the
--- same height, and addresses nothing, so `old_line`/`new_line` is nil there
--- too. `changed` says the row came from a deletion/addition run rather than
--- from context, which content alone cannot tell: an ordinary 1-for-1
--- replacement has real text on both sides.
---
--- Deliberately NOT written with `x and y or z` anywhere: `left` is legitimately
--- an empty string for a blank source line, and this codebase has already paid
--- three times for that idiom collapsing a falsy-but-real middle term.
local function pair_body(body, old_start, new_start)
  local rows = {}
  local minus, plus = {}, {}
  local old_line, new_line = old_start, new_start
  local function flush()
    for i = 1, math.max(#minus, #plus) do
      local m, p = minus[i], plus[i]
      local row = { changed = true }
      if m then
        row.left, row.old_line = m.text, m.line
      end
      if p then
        row.right, row.new_line = p.text, p.line
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
        left = line:sub(2),
        right = line:sub(2),
        old_line = old_line,
        new_line = new_line,
        changed = false,
      }
      old_line = old_line + 1
      new_line = new_line + 1
    end
  end
  flush()
  return rows
end

--- Side-by-side gives each side its own buffer, so the SIDE of a row is the
--- pane it is in: original-pane rows address old-side lines, modified-pane rows
--- new-side ones. Filler rows address nothing on either side.
local function render_side_by_side(group)
  local original, modified, hunk_lines = new_pane(), new_pane(), {}
  for _, file in ipairs(ordered_files(group)) do
    local text = separator(file)
    original.add(text, "IntentDiffFileSeparator")
    modified.add(text, "IntentDiffFileSeparator")
    for _, hunk in ipairs(file.hunks or {}) do
      original.add(hunk.header, "IntentDiffPreviewHunk")
      hunk_lines[#hunk_lines + 1] = modified.add(hunk.header, "IntentDiffPreviewHunk")
      local old_start, new_start = start_lines(hunk)
      for _, row in ipairs(pair_body(body_of(hunk), old_start, new_start)) do
        local original_hl, modified_hl
        if row.changed then
          original_hl = (row.left == nil) and "IntentDiffFiller" or "IntentDiffDelete"
          modified_hl = (row.right == nil) and "IntentDiffFiller" or "IntentDiffAdd"
        end
        local left_target, right_target
        if row.old_line then
          left_target = { file = file.path, line = row.old_line, side = "old" }
        end
        if row.new_line then
          right_target = { file = file.path, line = row.new_line, side = "new" }
        end
        original.add(row.left or "", original_hl, left_target)
        modified.add(row.right or "", modified_hl, right_target)
      end
    end
  end
  return original, modified, hunk_lines
end

--- Drop everything past `max_lines`, replacing the last line with a stated
--- count. Truncation is applied identically to every pane so the two sides stay
--- aligned; highlight spans pointing past the cut are dropped. `max_lines`
--- below 1 (0 or negative) is clamped to 1 rather than silently ignored, so
--- the cap always does something and the buffer is left with just the
--- summary line. Returns `hunk_lines` filtered to entries that still index a
--- real line — a hunk_lines entry landing exactly on the cut would otherwise
--- point at the summary line instead of a `@@` header.
local function truncate(panes, max_lines, hunk_lines)
  local total = #panes[1].lines
  if not max_lines then
    return hunk_lines
  end
  local limit = math.max(max_lines, 1)
  if total <= limit then
    return hunk_lines
  end
  local omitted = total - limit + 1
  for _, pane in ipairs(panes) do
    for i = total, limit, -1 do
      pane.lines[i] = nil
      -- The summary line replaces row `limit` and addresses nothing, so its
      -- map entry goes too: a comment on a line past the cut simply does not
      -- render here (it still exists, still exports), and no row of the
      -- surviving buffer may claim a coordinate it no longer shows.
      pane.map[i] = nil
    end
    pane.lines[limit] = ("── %d more line%s not shown (preview.max_lines)")
      :format(omitted, omitted == 1 and "" or "s")
    pane.highlights = vim.tbl_filter(function(s)
      return s.line < limit
    end, pane.highlights)
    pane.highlights[#pane.highlights + 1] =
      { line = limit, col_start = 0, col_end = WHOLE_LINE, hl = "IntentDiffFileSeparator" }
  end
  return vim.tbl_filter(function(lnum)
    return lnum < limit
  end, hunk_lines)
end

--- The row of `pane` the cursor at `row` addresses, or nil when that row
--- displays no line of any file (separator, `@@` header, filler, truncation
--- summary).
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
--- A comment whose lines are not in the rendered region (a different intent,
--- or past `preview.max_lines`) yields no rows — it is simply not drawn here.
--- File-level (line 0) and intent comments address no line and yield none
--- either.
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

local function empty_pane()
  local pane = new_pane()
  pane.add("no changes in this intent", "IntentDiffPreviewHunk")
  return pane
end

--- Render `group`'s complete diff.
--- @param group table { title, hunks, files }
--- @param layout string "inline" | "side-by-side"
--- @param opts table|nil { max_lines }
--- @return table rendered — see the plan's Interfaces block for the shape
function M.render(group, layout, opts)
  opts = opts or {}
  local has_files = #(group.files or {}) > 0
  if layout == "inline" then
    local pane, hunk_lines = render_inline(group)
    if not has_files then
      pane, hunk_lines = empty_pane(), {}
    end
    hunk_lines = truncate({ pane }, opts.max_lines, hunk_lines)
    return { layout = "inline", modified = pane, hunk_lines = hunk_lines }
  end
  local original, modified, hunk_lines = render_side_by_side(group)
  if not has_files then
    original, modified, hunk_lines = empty_pane(), empty_pane(), {}
  end
  hunk_lines = truncate({ original, modified }, opts.max_lines, hunk_lines)
  return {
    layout = "side-by-side",
    original = original,
    modified = modified,
    hunk_lines = hunk_lines,
  }
end

return M
