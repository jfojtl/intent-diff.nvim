-- In-memory review comments for the current review.
--
-- Deliberately knows nothing about intents, buffers or disk: a comment records
-- WHERE it sits, and which intent that turns out to be is recomputed at export
-- time (see comments/export.lua). That is what makes re-classification free —
-- nothing stored ever goes stale.
--
-- Persistence hangs off on_change (wired in comments/storage.lua) rather than
-- being called from here, so this module stays pure and exhaustively testable.
local M = {}

--- @type intentdiff.Comment[]
local comments = {}
local listeners = {}

local function changed()
  for _, fn in ipairs(listeners) do
    pcall(fn)
  end
end

--- Register a callback fired after add/update/delete (not after replace, which
--- IS the load path and would otherwise write straight back out).
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

--- Inclusive last line a comment covers. A file-level comment (line 0) and an
--- intent comment cover nothing addressable.
local function span(c)
  if not c.line or c.line == 0 then
    return nil
  end
  return c.line, c.line_end or c.line
end

--- Does `c` already claim any line `candidate` wants, on the same file+side?
local function collides(c, candidate)
  if c.intent_title or candidate.intent_title then
    return false -- several comments per intent are fine
  end
  if c.file ~= candidate.file then
    return false
  end
  -- File-level: one per file, and never in the way of a line comment.
  if (c.line or 0) == 0 or (candidate.line or 0) == 0 then
    return (c.line or 0) == 0 and (candidate.line or 0) == 0
  end
  if (c.side or "new") ~= (candidate.side or "new") then
    return false
  end
  local a_start, a_end = span(c)
  local b_start, b_end = span(candidate)
  return a_start <= b_end and b_start <= a_end
end

--- @return intentdiff.Comment|nil comment, string|nil err
function M.add(comment)
  for _, existing in ipairs(comments) do
    if collides(existing, comment) then
      return nil, "Comment already exists at this line. Use edit instead."
    end
  end
  comment.created_at = comment.created_at or os.time()
  comments[#comments + 1] = comment
  changed()
  return comment
end

function M.update(comment, comment_type, text)
  for _, c in ipairs(comments) do
    if c == comment then
      c.type = comment_type or c.type
      c.text = text or c.text
      changed()
      return true
    end
  end
  return false
end

function M.delete(comment)
  for i, c in ipairs(comments) do
    if c == comment then
      table.remove(comments, i)
      changed()
      return true
    end
  end
  return false
end

function M.get_all()
  return comments
end

--- Comments to render in one pane. `side` nil means both sides. File-level
--- comments carry no side and belong on every pane showing that file.
function M.get_for_file(file, side)
  local out = {}
  for _, c in ipairs(comments) do
    if c.file == file and not c.intent_title then
      if (c.line or 0) == 0 or not side or (c.side or "new") == side then
        out[#out + 1] = c
      end
    end
  end
  return out
end

--- The comment covering `line`, for edit/delete at the cursor. A range comment
--- matches any line it spans, both endpoints included.
function M.get_at_line(file, line, side)
  for _, c in ipairs(comments) do
    if c.file == file and not c.intent_title and (c.side or "new") == (side or "new") then
      local first, last = span(c)
      if first and line >= first and line <= last then
        return c
      end
    end
  end
  return nil
end

function M.get_for_intent(title)
  local out = {}
  for _, c in ipairs(comments) do
    if c.intent_title == title then
      out[#out + 1] = c
    end
  end
  return out
end

function M.count()
  return #comments
end

function M.clear()
  comments = {}
  changed()
end

--- Bulk load. Does NOT fire on_change: this is the disk→memory direction.
function M.replace(loaded)
  comments = loaded or {}
end

return M
