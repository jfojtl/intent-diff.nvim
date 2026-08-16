-- Exporting a review to the service hosting it — a GitHub PR today, a GitLab
-- MR the day someone writes forges/gitlab.lua.
--
-- Mirrors intentdiff.providers deliberately: a named module under a directory,
-- resolved through config, behind a small documented interface. A reader who
-- understands one understands the other.
--
-- The DECISION about what may be posted (preflight) is a pure function over
-- plain facts, separate from the git and `gh` calls that gather them, so every
-- branch is tested with no repository and no network.
local M = {}

--- Forges tried in order when `config.forge` is "auto".
local REGISTRY = { "github" }

--- Comments' files, as a set, for the dirty-file intersection.
local function set_of(list)
  local out = {}
  for _, v in ipairs(list or {}) do
    out[v] = true
  end
  return out
end

--- What may be posted, from plain facts. Pure — no git, no network, no Neovim
--- state.
---
--- The checks are ORDERED and the first match wins. `default_branch` is asked
--- before `no_pr` on purpose: sitting on `master` deserves "there is no PR to
--- comment on", not "create a PR for master first".
---
--- Only files that CARRY a comment count as dirty. An unrelated edit elsewhere
--- in the repo cannot move a line number in a commented file, and degrading the
--- whole export for it would be noise.
--- @return { mode: string, reason: string|nil, dirty: string[]|nil }
function M.preflight(state)
  state = state or {}
  if not state.forge_name then
    return {
      mode = "no_forge",
      reason = ("no supported forge for remote %s"):format(state.remote_url or "(none)"),
    }
  end
  if state.default_branch and state.branch == state.default_branch then
    return {
      mode = "default_branch",
      reason = ("you are on %s — no PR to comment on"):format(state.branch),
    }
  end
  if not state.target then
    return {
      mode = "no_pr",
      reason = ("no PR for branch %s — create one first (gh pr create)")
        :format(state.branch or "(unknown)"),
    }
  end

  local reasons = {}
  if state.head_sha ~= state.target.head_sha then
    reasons[#reasons + 1] = ("local HEAD is ahead of the PR head (%s vs %s)")
      :format(tostring(state.head_sha):sub(1, 8), tostring(state.target.head_sha):sub(1, 8))
  end
  local commented = state.commented_files or {}
  local dirty_set = set_of(state.dirty_files)
  local dirty = {}
  for _, path in ipairs(commented) do
    if dirty_set[path] then
      dirty[#dirty + 1] = path
    end
  end
  if #dirty > 0 then
    reasons[#reasons + 1] = ("%d of %d commented files have uncommitted changes")
      :format(#dirty, #commented)
  end
  if #reasons > 0 then
    return { mode = "general", reason = table.concat(reasons, "; "), dirty = dirty }
  end
  return { mode = "inline" }
end

return M
