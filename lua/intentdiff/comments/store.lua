-- In-memory review comments. ONE STORE PER REVIEW SESSION — `M.new()` returns
-- an independent store, and `comments/init.lua` hangs it off the session entry
-- (`entry.comment_store`), the same token-keyed registry the rest of the plugin
-- uses for concurrency.
--
-- It used to be a module-level singleton, which two review tabs corrupted: the
-- second `:IntentDiff` re-keyed and re-loaded the shared list, so a comment
-- added afterwards in the FIRST tab was saved under the SECOND review's key,
-- and closing either tab blanked both. Nothing here may become module-level
-- mutable state again.
--
-- Deliberately knows nothing about intents or buffers: a comment records WHERE
-- it sits, and which intent that turns out to be is recomputed at export time
-- (see comments/export.lua). That is what makes re-classification free —
-- nothing stored ever goes stale.
local M = {}

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

--- A fresh, independent comment store.
---
--- Closure-based rather than metatable-based on purpose: every piece of state
--- (`comments`, `listeners`, `key`) is a private upvalue of THIS store, so
--- there is no `self` to forget and no shared table to leak between reviews.
--- Call sites keep dot syntax (`st.add(...)`), which is what the module-level
--- API looked like.
--- @return table store
function M.new()
  --- @type intentdiff.Comment[]
  local comments = {}
  -- Read-only comments fetched from the review service. They are deliberately
  -- session-only: persistence belongs to the service, and mixing these into
  -- `comments` would make edit/delete/export/submit treat somebody else's
  -- discussion as local review input.
  local remote_comments = {}
  local listeners = {}
  --- Storage key this review persists under, or nil for a non-persisting one.
  local key = nil

  local self = {}

  local function changed()
    for _, fn in ipairs(listeners) do
      pcall(fn)
    end
  end

  --- Register a callback fired after add/update/delete (not after replace,
  --- which IS the load path and would otherwise write straight back out).
  function self.on_change(fn)
    listeners[#listeners + 1] = fn
  end

  --- @return intentdiff.Comment|nil comment, string|nil err
  function self.add(comment)
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

  function self.update(comment, comment_type, text)
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

  function self.delete(comment)
    for i, c in ipairs(comments) do
      if c == comment then
        table.remove(comments, i)
        changed()
        return true
      end
    end
    return false
  end

  function self.get_all()
    return comments
  end

  --- Replace the session's read-only forge discussion.
  function self.set_remote(fetched)
    remote_comments = fetched or {}
  end

  function self.get_remote()
    return remote_comments
  end

  --- Comments that should be painted and listed: local input plus fetched
  --- discussion. If a fetched root is the exact GitHub representation of a
  --- stamped local inline comment, prefer the fetched thread visually. It
  --- contains the same root plus any replies, whereas drawing both produces
  --- duplicate boxes on the same line.
  function self.get_visible()
    local shadowed = {}
    for _, remote in ipairs(remote_comments) do
      if remote.remote and remote.original_body then
        for _, local_comment in ipairs(comments) do
          local expected = ("**[%s]** %s")
            :format(tostring(local_comment.type):upper(), local_comment.text or "")
          if local_comment.posted
              and local_comment.file == remote.file
              and (local_comment.line or 0) == (remote.line or 0)
              and local_comment.line_end == remote.line_end
              and (local_comment.side or "new") == (remote.side or "new")
              and expected == remote.original_body then
            shadowed[local_comment] = true
            break
          end
        end
      end
    end
    local out = {}
    for _, c in ipairs(comments) do
      if not shadowed[c] then
        out[#out + 1] = c
      end
    end
    for _, c in ipairs(remote_comments) do
      out[#out + 1] = c
    end
    return out
  end

  --- Comments to render in one pane. `side` nil means both sides. File-level
  --- comments carry no side and belong on every pane showing that file.
  function self.get_for_file(file, side)
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

  --- The comment covering `line`, for edit/delete at the cursor. A range
  --- comment matches any line it spans, both endpoints included.
  function self.get_at_line(file, line, side)
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

  function self.get_for_intent(title)
    local out = {}
    for _, c in ipairs(comments) do
      if c.intent_title == title then
        out[#out + 1] = c
      end
    end
    return out
  end

  function self.count()
    return #comments
  end

  --- Record that `posted_list` reached a review service.
  ---
  --- One change event for the whole batch, not one per comment: the listener
  --- writes the entire store to disk, and a 40-comment review would otherwise
  --- rewrite the file 40 times.
  ---
  --- Editing a stamped comment deliberately does NOT clear the stamp — see
  --- comments/submit.lua. The edit is local; the service still holds what was
  --- sent, and re-posting would open a second thread.
  function self.mark_posted(posted_list, stamp)
    if #(posted_list or {}) == 0 then
      return
    end
    for _, c in ipairs(posted_list) do
      c.posted = stamp
    end
    changed()
  end

  --- Comments not yet sent to a review service.
  --- @return intentdiff.Comment[]
  function self.unposted()
    local out = {}
    for _, c in ipairs(comments) do
      if not c.posted then
        out[#out + 1] = c
      end
    end
    return out
  end

  function self.clear()
    comments = {}
    changed()
  end

  --- Bulk load. Does NOT fire on_change: this is the disk→memory direction.
  function self.replace(loaded)
    comments = loaded or {}
  end

  --- The persistence listener, registered ONCE here rather than in `attach`
  --- so re-attaching cannot stack listeners, and closing over this store's own
  --- `key` upvalue so it can never write under another review's key — the two
  --- failure modes the module-level `hooked` flag used to invite.
  self.on_change(function()
    if key then
      require("intentdiff.comments.storage").save(key, comments)
    end
  end)

  --- Load `storage_key`'s stored comments and persist every later change
  --- to it.
  function self.attach(storage_key)
    key = storage_key
    self.replace(require("intentdiff.comments.storage").load(key))
  end

  --- Stop persisting. The in-memory comments are left alone.
  function self.detach()
    key = nil
  end

  --- The key this store persists under, or nil. Read-only; for tests and
  --- diagnostics.
  function self.key()
    return key
  end

  return self
end

return M
