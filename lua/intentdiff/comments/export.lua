-- Markdown generation: the plugin's contract with whatever agent reads the
-- review. Pure — comments plus a model in, a string out — so it is tested
-- exhaustively without a running review tab.
--
-- Intent membership is computed HERE, never stored, which is what makes
-- re-classification free: the same comments re-file themselves under whatever
-- groups exist now.
local M = {}

local HEADER = "I reviewed your code and have the following comments. Please address them."
local TYPE_LEGEND = "Comment types: ISSUE (problems to fix), SUGGESTION (improvements),\n"
  .. "NOTE (observations), PRAISE (positive feedback)"
local OLD_SIDE_LEGEND = "Lines prefixed with ~ refer to the old (left) side of the diff."
local UNMATCHED = "Unmatched comments"

--- Does `hunk` cover `line` on `side`? Ranges are END-EXCLUSIVE — see
--- hunks.lua's range(): { start_line = s, end_line = s + len }.
local function hunk_covers(hunk, line, side)
  local r = (side == "old") and hunk.original or hunk.modified
  if not r then
    return false
  end
  return line >= r.start_line and line < r.end_line
end

--- Index of the group a comment belongs to, or nil.
---
--- A line comment resolves through the hunk containing its line; a file-level
--- comment resolves by file (it has no line to place); an intent comment
--- resolves by title, so a group renamed by re-classification surfaces as
--- unattached rather than being silently misfiled onto whatever group now
--- occupies that position.
local function group_index(comment, model)
  local groups = (model and model.groups) or {}
  if comment.intent_title then
    for gi, g in ipairs(groups) do
      if g.title == comment.intent_title then
        return gi
      end
    end
    return nil
  end
  local side = comment.side or "new"
  for gi, g in ipairs(groups) do
    if (comment.line or 0) == 0 then
      for _, f in ipairs(g.files or {}) do
        if f.path == comment.file then
          return gi
        end
      end
    else
      for _, h in ipairs(g.hunks or {}) do
        if h.file == comment.file and hunk_covers(h, comment.line, side) then
          return gi
        end
      end
    end
  end
  return nil
end

--- `src/a.ts:12`, `src/a.ts:12-18`, `src/a.ts:~12`, `src/a.ts:~12-~18`, or a
--- bare path for a file-level comment.
local function location(c)
  if (c.line or 0) == 0 then
    return c.file
  end
  local mark = (c.side == "old") and "~" or ""
  if c.line_end and c.line_end ~= c.line then
    return ("%s:%s%d-%s%d"):format(c.file, mark, c.line, mark, c.line_end)
  end
  return ("%s:%s%d"):format(c.file, mark, c.line)
end

--- Sort key within a group: file path, then line, with the file-level comment
--- for a file ahead of its line comments.
local function before(a, b)
  if a.file ~= b.file then
    return (a.file or "") < (b.file or "")
  end
  return (a.line or 0) < (b.line or 0)
end

local function entry_lines(index, c, out)
  out[#out + 1] = ("%d. **[%s]** `%s`"):format(index, tostring(c.type):upper(), location(c))
  -- Text on its own indented lines, not after a " - " separator: a comment
  -- containing newlines would otherwise corrupt the numbered list.
  for _, line in ipairs(vim.split(c.text or "", "\n")) do
    out[#out + 1] = "   " .. line
  end
  out[#out + 1] = ""
end

--- @return string
function M.generate(comments, model)
  comments = comments or {}
  if #comments == 0 then
    return "No comments yet."
  end

  local groups = (model and model.groups) or {}
  -- Bucket by group index; unmatched comments collect separately.
  local buckets, unmatched = {}, {}
  for _, c in ipairs(comments) do
    if #groups == 0 then
      -- No grouping available (classification running or failed): flat
      -- list. An intent comment has no group to hang under, so it still
      -- reads as an unattached paragraph rather than a numbered entry.
      buckets[0] = buckets[0] or { intents = {}, items = {} }
      if c.intent_title then
        table.insert(buckets[0].intents, c)
      else
        table.insert(buckets[0].items, c)
      end
    else
      local gi = group_index(c, model)
      if gi then
        buckets[gi] = buckets[gi] or { intents = {}, items = {} }
        if c.intent_title then
          table.insert(buckets[gi].intents, c)
        else
          table.insert(buckets[gi].items, c)
        end
      else
        unmatched[#unmatched + 1] = c
      end
    end
  end

  local has_old = false
  for _, c in ipairs(comments) do
    if c.side == "old" and (c.line or 0) ~= 0 then
      has_old = true
      break
    end
  end

  local out = { HEADER, "", TYPE_LEGEND }
  if has_old then
    out[#out + 1] = OLD_SIDE_LEGEND
  end
  out[#out + 1] = ""

  local n = 0
  local function emit(bucket)
    for _, c in ipairs(bucket.intents) do
      for _, line in ipairs(vim.split(c.text or "", "\n")) do
        out[#out + 1] = line
      end
      out[#out + 1] = ""
    end
    table.sort(bucket.items, before)
    for _, c in ipairs(bucket.items) do
      n = n + 1
      entry_lines(n, c, out)
    end
  end

  if buckets[0] then
    emit(buckets[0]) -- flat fallback: no headings
  end
  for gi, g in ipairs(groups) do
    local bucket = buckets[gi]
    if bucket then
      out[#out + 1] = "## " .. g.title
      out[#out + 1] = ""
      emit(bucket)
    end
  end
  if #unmatched > 0 then
    out[#out + 1] = "## " .. UNMATCHED
    out[#out + 1] = ""
    local bucket = { intents = {}, items = {} }
    for _, c in ipairs(unmatched) do
      if c.intent_title then
        table.insert(bucket.intents, c)
      else
        table.insert(bucket.items, c)
      end
    end
    emit(bucket)
  end

  -- Trim the trailing blank line an entry always emits.
  while out[#out] == "" do
    table.remove(out)
  end
  return table.concat(out, "\n")
end

--- @return boolean
function M.to_clipboard(comments, model)
  if #(comments or {}) == 0 then
    vim.notify("intent-diff: no comments to export", vim.log.levels.WARN)
    return false
  end
  local markdown = M.generate(comments, model)
  vim.fn.setreg("+", markdown)
  vim.fn.setreg("*", markdown)
  vim.notify(("intent-diff: copied %d comment(s)"):format(#comments), vim.log.levels.INFO)
  return true
end

--- @return boolean ok, string|nil err
function M.to_file(comments, model, path)
  if #(comments or {}) == 0 then
    return false, "no comments to export"
  end
  if not path or path == "" then
    return false, "no path given"
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    local ok = pcall(vim.fn.mkdir, dir, "p")
    if not ok then
      return false, "cannot create " .. dir
    end
  end
  local file = io.open(path, "w")
  if not file then
    return false, "cannot write " .. path
  end
  file:write(M.generate(comments, model))
  file:write("\n")
  file:close()
  return true
end

return M
