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

--- `git -C git_root <...>`'s output lines, or nil on any failure — including
--- git not being executable at all.
---
--- vim.fn.systemlist RAISES (E475) rather than returning an error value when
--- argv[0] cannot be found, so this must be pcall'd, not merely checked against
--- vim.v.shell_error.
--- @return string[]|nil
function M.git_lines(git_root, ...)
  local ok, out = pcall(vim.fn.systemlist, { "git", "-C", git_root, ... })
  if not ok or vim.v.shell_error ~= 0 then
    return nil
  end
  return out
end

local function git_first(git_root, ...)
  local out = M.git_lines(git_root, ...)
  local first = out and out[1]
  if not first or first == "" then
    return nil
  end
  return first
end

--- @return string|nil
function M.remote_url(git_root)
  return git_first(git_root, "remote", "get-url", "origin")
end

--- The default branch, without the `origin/` prefix, or nil when it cannot be
--- determined. nil is not an error: preflight simply skips its default-branch
--- check rather than blocking a submit over a missing symbolic ref.
--- @return string|nil
function M.default_branch(git_root)
  local ref = git_first(git_root, "rev-parse", "--abbrev-ref", "origin/HEAD")
  if not ref then
    return nil
  end
  return (ref:gsub("^origin/", ""))
end

--- Paths with uncommitted changes, from porcelain status. Renames report
--- `R  old -> new`; the NEW path is what a comment addresses.
--- @return string[]
function M.dirty_files(git_root)
  local out = {}
  for _, line in ipairs(M.git_lines(git_root, "status", "--porcelain") or {}) do
    local path = line:sub(4)
    local _, new = path:match("^(.+) %-> (.+)$")
    out[#out + 1] = new or path
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
    branch = git_first(git_root, "rev-parse", "--abbrev-ref", "HEAD"),
    head_sha = git_first(git_root, "rev-parse", "HEAD"),
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
