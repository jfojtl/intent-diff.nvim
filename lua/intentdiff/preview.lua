-- Pure renderer for the whole-intent preview: a group's complete diff with
-- visible file boundaries, in either layout. No Neovim UI state — view.lua puts
-- the result into buffers.
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

--- A pane under construction: lines plus highlight spans.
local function new_pane()
  local pane = { lines = {}, highlights = {} }
  function pane.add(text, group)
    pane.lines[#pane.lines + 1] = text
    if group then
      pane.highlights[#pane.highlights + 1] =
        { line = #pane.lines, col_start = 0, col_end = WHOLE_LINE, hl = group }
    end
    return #pane.lines
  end
  return pane
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

local function render_inline(group)
  local pane, hunk_lines = new_pane(), {}
  for _, file in ipairs(ordered_files(group)) do
    pane.add(separator(file), "IntentDiffPreviewFile")
    for _, hunk in ipairs(file.hunks or {}) do
      hunk_lines[#hunk_lines + 1] = pane.add(hunk.header, "IntentDiffPreviewHunk")
      for _, line in ipairs(body_of(hunk)) do
        pane.add(line, line_group(line))
      end
    end
  end
  return pane, hunk_lines
end

--- Pair a hunk body into aligned original/modified rows. A context line emits
--- on both sides; a run of deletions and the addition run that follows it emit
--- max(#deletions, #additions) rows, paired by index, with a filler row on the
--- shorter side. `false` marks a filler. The third return value marks, per
--- row, whether it came from a deletion/addition run (as opposed to context)
--- — needed because an ordinary 1-for-1 replacement has real text on both
--- sides and so can't be told apart from context by content alone.
local function pair_body(body)
  local original, modified, changed = {}, {}, {}
  local minus, plus = {}, {}
  local function flush()
    for i = 1, math.max(#minus, #plus) do
      original[#original + 1] = minus[i] or false
      modified[#modified + 1] = plus[i] or false
      changed[#changed + 1] = true
    end
    minus, plus = {}, {}
  end
  for _, line in ipairs(body) do
    local kind = line:sub(1, 1)
    if kind == "-" then
      minus[#minus + 1] = line:sub(2)
    elseif kind == "+" then
      plus[#plus + 1] = line:sub(2)
    else
      flush()
      original[#original + 1] = line:sub(2)
      modified[#modified + 1] = line:sub(2)
      changed[#changed + 1] = false
    end
  end
  flush()
  return original, modified, changed
end

local function render_side_by_side(group)
  local original, modified, hunk_lines = new_pane(), new_pane(), {}
  for _, file in ipairs(ordered_files(group)) do
    local text = separator(file)
    original.add(text, "IntentDiffPreviewFile")
    modified.add(text, "IntentDiffPreviewFile")
    for _, hunk in ipairs(file.hunks or {}) do
      original.add(hunk.header, "IntentDiffPreviewHunk")
      hunk_lines[#hunk_lines + 1] = modified.add(hunk.header, "IntentDiffPreviewHunk")
      local left, right, changed = pair_body(body_of(hunk))
      for i = 1, #left do
        local original_hl, modified_hl
        if changed[i] then
          original_hl = left[i] == false and "IntentDiffFiller" or "IntentDiffDelete"
          modified_hl = right[i] == false and "IntentDiffFiller" or "IntentDiffAdd"
        end
        original.add(left[i] or "", original_hl)
        modified.add(right[i] or "", modified_hl)
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
    end
    pane.lines[limit] = ("── %d more line%s not shown (preview.max_lines)")
      :format(omitted, omitted == 1 and "" or "s")
    pane.highlights = vim.tbl_filter(function(s)
      return s.line < limit
    end, pane.highlights)
    pane.highlights[#pane.highlights + 1] =
      { line = limit, col_start = 0, col_end = WHOLE_LINE, hl = "IntentDiffPreviewFile" }
  end
  return vim.tbl_filter(function(lnum)
    return lnum < limit
  end, hunk_lines)
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
