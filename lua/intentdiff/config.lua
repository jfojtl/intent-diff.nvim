local M = {}

M.defaults = {
  provider = "claude_cli", -- name under intentdiff.providers.*, or a function(request, callback)
  provider_opts = {
    cmd = "claude",
    model = "haiku",
    timeout_ms = 60000,
  },
  context_lines = nil, -- nil = follow codediff's diff.compact_context_lines
  sidebar_width = 36,
  max_full_diff_bytes = 100 * 1024, -- above this, prompt gets per-hunk summaries only
  max_hunks = 400, -- above this, skip classification with a notice
  cache_dir = vim.fn.stdpath("cache") .. "/intentdiff",
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
