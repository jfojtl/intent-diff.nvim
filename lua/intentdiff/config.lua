local M = {}

M.defaults = {
  provider = "claude_cli", -- name under intentdiff.providers.*, or a function(request, callback)
  provider_opts = {
    cmd = "claude",
    model = "haiku",
    timeout_ms = 180000,
    -- Tool restrictions passed to `claude -p` as --disallowedTools /
    -- --allowedTools: the process runs pointed at the user's (possibly
    -- uncommitted) working tree, so it must not be able to edit it. An
    -- empty/nil list omits the corresponding flag entirely rather than
    -- passing an empty value.
    disallowed_tools = { "Edit", "Write", "NotebookEdit" },
    allowed_tools = {
      "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
      "Bash(git blame:*)", "Bash(git status:*)", "Read", "Grep", "Glob",
    },
    -- Let the model run read-only git commands / read files in the repo
    -- (cwd is set to git_root) to understand WHY a change was made, instead
    -- of us pre-stuffing commit messages/log output into the prompt. Set to
    -- false to keep the prompt fully self-contained.
    agentic = true,
  },
  context_lines = nil, -- nil = follow codediff's diff.compact_context_lines
  sidebar_width = 36,
  max_full_diff_bytes = 100 * 1024, -- above this, prompt gets per-hunk summaries only
  max_hunks = 400, -- above this, skip classification with a notice
  cache_dir = vim.fn.stdpath("cache") .. "/intentdiff",
  log_file = vim.fn.stdpath("cache") .. "/intentdiff/intentdiff.log", -- diagnostics log; see :IntentDiffLog
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
