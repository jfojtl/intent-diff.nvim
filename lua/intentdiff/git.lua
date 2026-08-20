-- Running `git` and getting its output back, safely.
--
-- ONE home for the environment hazard below, because two copies of a
-- workaround is how the next hazard gets fixed in only one of them. Neutral
-- ground on purpose: comments/init.lua must not have to require the forge
-- layer to run `git rev-parse`, and forges/init.lua must not have to require
-- the comments layer to read a remote URL.
local M = {}

--- `git -C git_root <...>`'s output lines, or nil on any failure — including
--- `git` not being executable at all.
---
--- vim.fn.systemlist RAISES (E475) rather than returning an error value when
--- argv[0] cannot be found, so this must be pcall'd, not merely checked
--- against vim.v.shell_error.
--- @return string[]|nil
function M.lines(git_root, ...)
  local ok, out = pcall(vim.fn.systemlist, { "git", "-C", git_root, ... })
  if not ok or vim.v.shell_error ~= 0 then
    return nil
  end
  return out
end

--- The first output line, or nil when the command failed OR produced nothing.
---
--- An empty first line is treated as no answer: `git rev-parse` and friends
--- can exit 0 having printed nothing, and "" is never a useful branch name,
--- SHA or URL.
--- @return string|nil
function M.first(git_root, ...)
  local out = M.lines(git_root, ...)
  local first = out and out[1]
  if not first or first == "" then
    return nil
  end
  return first
end

return M
