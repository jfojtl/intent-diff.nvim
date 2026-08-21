local cli = require("intentdiff.providers.cli")

local M = {
  build_prompt = cli.build_prompt,
  parse_response = cli.parse_response,
}

--- @return fun(request, callback): { cancel: function }
function M.new(opts)
  opts = opts or {}
  return function(request, callback)
    local argv = { opts.cmd or "claude", "-p", "--model", opts.model or "haiku" }
    if opts.allowed_tools and #opts.allowed_tools > 0 then
      vim.list_extend(argv, { "--allowedTools", table.concat(opts.allowed_tools, ",") })
    end
    if opts.disallowed_tools and #opts.disallowed_tools > 0 then
      vim.list_extend(argv, { "--disallowedTools", table.concat(opts.disallowed_tools, ",") })
    end
    local prompt = cli.build_prompt(request, opts)
    return cli.run(argv, prompt, request, callback, opts.timeout_ms)
  end
end

return M
