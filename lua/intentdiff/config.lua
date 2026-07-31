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
  sidebar_width = 40,
  icons = true, -- file icons from nvim-web-devicons when it is installed
  -- Auto-open the first file worth looking at, instead of leaving codediff's
  -- empty placeholder panes until the user presses <CR>: the first file of
  -- the flat "All changes" group while classification is still running, then
  -- the first file of the first real group once it completes — but only if
  -- the user hasn't already selected (or navigated to) a file of their own.
  -- Set to false to keep the sidebar-only-until-<CR> behavior.
  auto_open = true,
  max_full_diff_bytes = 100 * 1024, -- above this, prompt gets per-hunk summaries only
  max_hunks = 600, -- above this, skip classification with a notice
  -- Added and untracked files arrive from git as a single whole-file hunk, so
  -- they could only ever belong to one intent. Splitting them at blank-line
  -- boundaries lets different parts of one new file land in different intents,
  -- and makes the group fold filter meaningful for them. Set enabled = false
  -- to restore one-hunk-per-added-file.
  added_file_split = { enabled = true, min_lines = 60, target_lines = 40 },
  cache_dir = vim.fn.stdpath("cache") .. "/intentdiff",
  log_file = vim.fn.stdpath("cache") .. "/intentdiff/intentdiff.log", -- diagnostics log; see :IntentDiffLog
  -- Whole-intent preview: putting the cursor on a group or directory row in the
  -- sidebar shows that intent's complete diff in the diff panes, with a
  -- separator per file. debounce_ms keeps scrolling the sidebar from thrashing
  -- the panes; max_lines caps a very large intent, stating what it omitted.
  preview = { enabled = true, debounce_ms = 120, max_lines = 20000 },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
