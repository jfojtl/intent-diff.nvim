local cli = require("intentdiff.providers.cli")

local M = {
  build_prompt = cli.build_prompt,
  parse_response = cli.parse_response,
}

--- @return fun(request, callback): { cancel: function }
function M.new(opts)
  opts = opts or {}
  return function(request, callback)
    local argv = {
      opts.cmd or "codex",
      "exec",
      "--model", opts.model or "gpt-5.6-luna",
      "--sandbox", opts.sandbox or "read-only",
      "--color", "never",
    }
    if opts.ephemeral ~= false then
      argv[#argv + 1] = "--ephemeral"
    end
    -- Explicitly tell `codex exec` that stdin is the complete prompt. This
    -- avoids argument-length limits for large diffs and keeps the command
    -- visible in diagnostics free of user code.
    argv[#argv + 1] = "-"
    local prompt = cli.build_prompt(request, opts)
    return cli.run(argv, prompt, request, callback, opts.timeout_ms)
  end
end

return M
