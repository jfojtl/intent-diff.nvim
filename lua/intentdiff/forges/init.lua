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

local git = require("intentdiff.git")

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

--- @return string|nil
function M.remote_url(git_root)
  return git.first(git_root, "remote", "get-url", "origin")
end

--- The default branch, without the `origin/` prefix, or nil when it cannot be
--- determined. nil is not an error: preflight simply skips its default-branch
--- check rather than blocking a submit over a missing symbolic ref.
--- @return string|nil
function M.default_branch(git_root)
  local ref = git.first(git_root, "rev-parse", "--abbrev-ref", "origin/HEAD")
  if not ref then
    return nil
  end
  return (ref:gsub("^origin/", ""))
end

--- Paths with uncommitted changes.
---
--- `-z` rather than the default porcelain format: the default QUOTES a path
--- containing special characters and renders a rename as `R  old -> "new"`,
--- which no pattern can split unambiguously once the new path itself contains
--- " -> ". With `-z` each record is NUL-terminated and never quoted, and a
--- rename emits TWO records — the new path, then the old.
---
--- Vim converts those NULs to \n inside systemlist's single returned element,
--- so the records are split here rather than by git.
--- @return string[]
function M.dirty_files(git_root)
  local raw = git.lines(git_root, "status", "--porcelain", "-z")
  if not raw then
    return {}
  end
  local records = vim.split(table.concat(raw, "\n"), "\n", { plain = true })
  local out = {}
  local i = 1
  while i <= #records do
    local record = records[i]
    i = i + 1
    -- `XY path`: two status columns, a space, then the path. Anything shorter
    -- is the empty trailing record after the final NUL.
    if #record > 3 then
      local x, y = record:sub(1, 1), record:sub(2, 2)
      out[#out + 1] = record:sub(4)
      -- A rename or copy emits its OLD path as the very next record. That path
      -- is not dirty in its own right, and consuming it here is what keeps it
      -- out of the commented-file intersection.
      if x == "R" or x == "C" or y == "R" or y == "C" then
        i = i + 1
      end
    end
  end
  return out
end

--- The forge serving this repository.
---
--- `false` disables the feature outright, which is NOT the same as no forge
--- matching the remote: one means the user turned it off, the other that they
--- are pushing somewhere this plugin cannot post to. They get different
--- messages, so they get different return shapes.
--- @return table|nil mod, string|nil name, string|nil err
function M.resolve(remote_url)
  local configured = require("intentdiff.config").options.forge
  if configured == false then
    return nil, nil, "review export is disabled (forge = false)"
  end
  if type(configured) == "table" then
    return configured, "custom"
  end
  if type(configured) == "string" and configured ~= "auto" then
    local ok, mod = pcall(require, "intentdiff.forges." .. configured)
    if not ok or type(mod) ~= "table" then
      return nil, nil, ("no forge named '%s'"):format(configured)
    end
    return mod, configured
  end
  for _, name in ipairs(REGISTRY) do
    local ok, mod = pcall(require, "intentdiff.forges." .. name)
    if ok and type(mod) == "table" and mod.matches(remote_url) then
      return mod, name
    end
  end
  return nil, nil
end

--- Everything preflight needs, gathered from git and the forge.
---
--- Detection is the only asynchronous part, so the git facts are read first and
--- the callback fires once the forge answers. A detection ERROR still calls back
--- with a state (target = nil) plus the error, so the caller reports the real
--- reason instead of the generic "no PR".
--- @param cb fun(state: table, err: string|nil)
function M.collect(git_root, commented_files, cb)
  local remote_url = M.remote_url(git_root)
  local forge, forge_name, err = M.resolve(remote_url)
  local state = {
    branch = git.first(git_root, "rev-parse", "--abbrev-ref", "HEAD"),
    head_sha = git.first(git_root, "rev-parse", "HEAD"),
    default_branch = M.default_branch(git_root),
    dirty_files = M.dirty_files(git_root),
    commented_files = commented_files or {},
    remote_url = remote_url,
    forge_name = forge_name,
    forge = forge,
    git_root = git_root,
  }
  if not forge then
    return cb(state, err)
  end
  forge.detect(git_root, state.branch, function(target, detect_err)
    state.target = target
    cb(state, detect_err)
  end)
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
