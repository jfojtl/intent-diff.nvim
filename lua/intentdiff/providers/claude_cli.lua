local M = {}

function M.build_prompt(request)
  local lines = {
    "You are grouping the hunks of a git diff by the REASON the change was made.",
    "Return ONLY JSON, no prose, exactly matching:",
    '{"groups":[{"title":"<short imperative reason>","hunk_ids":["<id>"]}]}',
    "Rules: every hunk id appears in exactly one group; prefer 2-8 groups;",
    "titles describe WHY (intent), not which files changed;",
    "use only the hunk ids listed below.",
    "",
    "Hunks:",
  }
  for _, h in ipairs(request.hunks) do
    lines[#lines + 1] = ("- %s"):format(h.id)
    for _, s in ipairs(h.summary_lines) do
      lines[#lines + 1] = "    " .. s
    end
  end
  if request.diff_text then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Full diff:"
    lines[#lines + 1] = request.diff_text
  end
  return table.concat(lines, "\n")
end

function M.parse_response(text)
  local body = text:match("({.*})") or text -- strips fences/prose; '.' spans newlines
  local ok, decoded = pcall(vim.json.decode, body)
  if ok and type(decoded) == "table" and type(decoded.groups) == "table" then
    return decoded
  end
  return nil, "provider returned unparseable output"
end

--- @return fun(request, callback): { cancel: function }
function M.new(opts)
  opts = opts or {}
  return function(request, callback)
    local finished = false
    local function finish(result, err)
      if not finished then
        finished = true
        callback(result, err)
      end
    end
    local stdout = {}
    local job = vim.fn.jobstart({ opts.cmd or "claude", "-p", "--model", opts.model or "haiku" }, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        stdout = data or {}
      end,
      on_exit = function(_, code)
        if code ~= 0 then
          return finish(nil, ("provider exited with code %d"):format(code))
        end
        finish(M.parse_response(table.concat(stdout, "\n")))
      end,
    })
    if job <= 0 then
      finish(nil, "could not start provider command '" .. (opts.cmd or "claude") .. "'")
      return { cancel = function() end }
    end
    vim.fn.chansend(job, M.build_prompt(request))
    vim.fn.chanclose(job, "stdin")
    vim.defer_fn(function()
      if not finished then
        vim.fn.jobstop(job)
        finish(nil, "provider timed out")
      end
    end, opts.timeout_ms or 60000)
    return {
      cancel = function()
        finished = true
        vim.fn.jobstop(job)
      end,
    }
  end
end

return M
