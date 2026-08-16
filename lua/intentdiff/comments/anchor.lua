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
---
--- A file-level comment addresses no line (subject_type = "file"), so it is
--- tested only for its file being present — but present IN `hunk_list`, which
--- is stricter than the service's own rule of "present in the diff". A file
--- that appears in the diff while contributing no hunk at all — a binary
--- change, a pure rename — is demoted here even though GitHub would have taken
--- the comment. That is the safe direction: a comment moved into the review
--- body is still read, while a comment the service rejects takes the entire
--- atomic review down with it.
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

--- The commit the service diffs the PR against: where the branch DIVERGED from
--- the base branch, not the tip of the base branch.
---
--- Its own function, and not merely a step inside pr_hunks, because preflight
--- needs it as a FACT before it can decide anything: a review pinned to a base
--- that is not this SHA was read against a different diff from the one the PR
--- shows, and its line numbers must not be trusted inline. Synchronous — it is
--- `git merge-base` against local objects, not a network call.
--- @return string|nil sha, string|nil err
function M.merge_base(git_root, base_ref)
  local git = require("intentdiff.git")
  -- A target with no base branch answers "unknown", not an error: concatenating
  -- nil into "origin/" .. base_ref below would throw, and preflight already
  -- reads a missing merge base as a reason to degrade.
  if not base_ref then
    return nil, "the PR does not name a base branch"
  end
  -- The remote-tracking ref first: it is what the service actually has. A local
  -- branch of the same name may be behind or ahead of it.
  for _, ref in ipairs({ "origin/" .. base_ref, base_ref }) do
    local sha = git.first(git_root, "merge-base", ref, "HEAD")
    if sha then
      return sha
    end
  end
  return nil, ("cannot resolve the merge base with %s"):format(base_ref)
end

--- The PR's diff, parsed into hunks.
---
--- Synchronous: this is `git diff` against local objects, not a network call,
--- and the flow is already mid-prompt when it runs.
--- @return table[]|nil hunks, string|nil err
function M.pr_hunks(git_root, base_ref)
  local git = require("intentdiff.git")
  local base, base_err = M.merge_base(git_root, base_ref)
  if not base then
    return nil, base_err
  end
  local out = git.lines(git_root, "diff", "-U" .. CONTEXT, base .. "...HEAD")
  if not out then
    return nil, ("cannot diff %s...HEAD"):format(base:sub(1, 8))
  end
  local hunk_list = require("intentdiff.hunks").parse(table.concat(out, "\n"))
  return hunk_list
end

return M
