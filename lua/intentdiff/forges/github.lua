-- GitHub, over the `gh` CLI.
--
-- `gh` rather than raw HTTP because it already holds the user's credentials,
-- knows the host aliases and enterprise instances they have configured, and
-- resolves {owner}/{repo} from the checkout — none of which this plugin should
-- reimplement.
--
-- Only M.submit writes. detect and the repo lookups are read-only, so the
-- preflight can run freely before the user has chosen anything.
local M = {}

local VERDICTS = { approve = "APPROVE", request_changes = "REQUEST_CHANGES", comment = "COMMENT" }

function M.matches(remote_url)
  if not remote_url then
    return false
  end
  return remote_url:match("github%.com") ~= nil
end

function M.capabilities()
  return {
    inline = true,
    file_comments = true,
    verdicts = { "approve", "request_changes", "comment" },
  }
end

--- Configured options, defaulted. Read at call time, not at require time, so
--- setup() ordering cannot matter.
function M.opts()
  local configured = ((require("intentdiff.config").options.forge_opts or {}).github) or {}
  return {
    cmd = configured.cmd or "gh",
    timeout_ms = configured.timeout_ms or 30000,
  }
end

--- Run `gh` in `git_root`, buffered, with a timeout. `stdin` is written and
--- the channel closed when given.
---
--- jobstart is used rather than vim.fn.system for the same reason
--- providers/claude_cli.lua uses it: a synchronous system() call freezes the
--- editor for however long the network takes.
--- @param cb fun(code: integer, stdout: string, stderr: string)
local function run(argv, git_root, stdin, cb)
  local opts = M.opts()
  local out, err = {}, {}
  local finished = false
  local function finish(code)
    if finished then
      return
    end
    finished = true
    cb(code, table.concat(out, "\n"), table.concat(err, "\n"))
  end
  local ok, job = pcall(vim.fn.jobstart, argv, {
    cwd = git_root,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data) out = data or {} end,
    on_stderr = function(_, data) err = data or {} end,
    on_exit = function(_, code) finish(code) end,
  })
  if not ok or job <= 0 then
    return finish(-1)
  end
  if stdin then
    pcall(vim.fn.chansend, job, stdin)
    pcall(vim.fn.chanclose, job, "stdin")
  end
  vim.defer_fn(function()
    if not finished then
      pcall(vim.fn.jobstop, job)
      finish(-2)
    end
  end, opts.timeout_ms)
end

--- Record one `gh` invocation to :IntentDiffLog. Never the comment text — the
--- log is a diagnostics file the user may paste into an issue.
local function record(fields)
  local ok, log = pcall(require, "intentdiff.log")
  if ok then
    log.append(vim.tbl_extend("force", { kind = "forge", service = "github" }, fields))
  end
end

local function failure(code, stderr, what)
  if code == -1 then
    return ("could not start '%s' — is the GitHub CLI installed?"):format(M.opts().cmd)
  end
  if code == -2 then
    return ("gh timed out while %s"):format(what)
  end
  local trimmed = vim.trim(stderr or "")
  if trimmed == "" then
    return ("gh exited with code %d while %s"):format(code, what)
  end
  return trimmed
end

local PR_FIELDS = "number,url,title,headRefOid,baseRefName,state"

--- Is `branch` linked to an open PR? Read-only.
---
--- "no pull requests found" is an ANSWER, not a failure: it means the branch
--- has no PR yet, which preflight turns into "create one first". Every other
--- non-zero exit is a real error and surfaces verbatim, because a missing or
--- unauthenticated gh must not read as "you have no PR".
--- @param cb fun(target: table|nil, err: string|nil)
function M.detect(git_root, branch, cb)
  local argv = { M.opts().cmd, "pr", "view", branch, "--json", PR_FIELDS }
  run(argv, git_root, nil, function(code, stdout, stderr)
    record({ event = "detect", exit_code = code })
    if code ~= 0 then
      if (stderr or ""):match("no pull requests found") then
        return cb(nil, nil)
      end
      return cb(nil, failure(code, stderr, "looking up the pull request"))
    end
    local ok, pr = pcall(vim.json.decode, stdout)
    if not ok or type(pr) ~= "table" or not pr.number then
      return cb(nil, "could not read gh's pull request JSON")
    end
    if pr.state and pr.state ~= "OPEN" then
      return cb(nil, ("PR #%d is %s — nothing to review"):format(pr.number, pr.state))
    end
    cb({
      service = "github",
      id = tostring(pr.number),
      url = pr.url,
      title = pr.title,
      head_sha = pr.headRefOid,
      base_ref = pr.baseRefName,
    })
  end)
end

M._run = run
M._failure = failure
M._VERDICTS = VERDICTS

return M
