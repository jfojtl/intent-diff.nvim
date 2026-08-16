-- Which comments the service will accept on a line, decided LOCALLY.
--
-- The GitHub reviews API is atomic: one comment on a line outside the diff
-- rejects the entire review, comments and verdict together. Discovering that
-- from a 422 costs the whole submit, so the same question is answered here
-- first, against the very diff the service is showing.
--
-- That is only sound in `inline` mode, where the preflight has already
-- established that the checkout IS the PR head with no uncommitted changes in
-- the commented files. Under those conditions `base...HEAD` locally is the
-- service's diff, byte for byte.
local M = {}

--- Context matching what GitHub renders around a hunk, so a comment on a
--- context line is accepted here exactly when the service would accept it.
local CONTEXT = 3

--- Is `line` inside `range`? Ranges are END-EXCLUSIVE — see hunks.lua range().
local function inside(range, line)
  if not range then
    return false
  end
  return line >= range.start_line and line < range.end_line
end

--- Can `comment` be posted on a line of the PR diff?
---
--- A range must be covered ENTIRELY: GitHub anchors a multi-line comment to
--- both endpoints, and half a range inside the diff is a 422 like any other.
--- A file-level comment needs only its file to appear in the diff, since
--- subject_type = "file" addresses no line.
--- @return boolean
function M.covers(hunk_list, comment)
  if comment.intent_title then
    return false
  end
  if (comment.line or 0) == 0 then
    for _, h in ipairs(hunk_list or {}) do
      if h.file == comment.file then
        return true
      end
    end
    return false
  end
  local side = comment.side or "new"
  -- math.min/max, not the fields as given: `for line = 12, 8` runs ZERO
  -- iterations and falls through to `return true` below — every backwards
  -- range accepted without one line being checked. visual_range normalizes at
  -- creation, but covers() is a pure general-purpose function and stored
  -- comments are never revalidated on load.
  local first = math.min(comment.line, comment.line_end or comment.line)
  local last = math.max(comment.line, comment.line_end or comment.line)
  for line = first, last do
    local found = false
    for _, h in ipairs(hunk_list or {}) do
      if h.file == comment.file then
        local range = (side == "old") and h.original or h.modified
        if inside(range, line) then
          found = true
          break
        end
      end
    end
    if not found then
      return false
    end
  end
  return true
end

--- The `anchorable` predicate comments/payload.lua takes.
--- @return fun(c: intentdiff.Comment): boolean
function M.predicate(hunk_list)
  return function(c)
    return M.covers(hunk_list, c)
  end
end

--- The PR's diff, parsed into hunks.
---
--- Synchronous: this is `git diff` against local objects, not a network call,
--- and the flow is already mid-prompt when it runs. `merge-base` rather than a
--- plain two-dot diff, because the service diffs the PR against where the
--- branch DIVERGED, not against the tip of the base branch.
--- @return table[]|nil hunks, string|nil err
function M.pr_hunks(git_root, base_ref)
  local forges = require("intentdiff.forges")
  local base = nil
  -- The remote-tracking ref first: it is what the service actually has. A local
  -- branch of the same name may be behind or ahead of it.
  for _, ref in ipairs({ "origin/" .. base_ref, base_ref }) do
    local out = forges.git_lines(git_root, "merge-base", ref, "HEAD")
    if out and out[1] and out[1] ~= "" then
      base = out[1]
      break
    end
  end
  if not base then
    return nil, ("cannot resolve the merge base with %s"):format(base_ref)
  end
  local out = forges.git_lines(git_root, "diff", "-U" .. CONTEXT, base .. "...HEAD")
  if not out then
    return nil, ("cannot diff %s...HEAD"):format(base:sub(1, 8))
  end
  local hunk_list = require("intentdiff.hunks").parse(table.concat(out, "\n"))
  return hunk_list
end

return M
