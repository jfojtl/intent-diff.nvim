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
  -- Try candidates in order until one decodes to a table with 'groups' table
  local candidates = { text }

  -- Candidate 2: the greedy span (fallback from previous approach)
  local greedy = text:match("({.*})")
  if greedy then
    table.insert(candidates, greedy)
  end

  -- Candidate 3+: extract balanced {..} spans in a single linear scan
  -- For each { that starts a balanced span (depth returns to 0), add as candidate
  local i = 1
  local candidate_count = 2  -- already have 2 candidates above
  while i <= #text and candidate_count < 20 do
    if text:sub(i, i) == "{" then
      local start = i
      local depth = 0
      local j = i
      while j <= #text do
        local c = text:sub(j, j)
        if c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
        end
        j = j + 1
        if depth == 0 then
          local span = text:sub(start, j - 1)
          -- Skip spans > 1MB
          if #span <= 1048576 then
            table.insert(candidates, span)
            candidate_count = candidate_count + 1
          end
          break
        end
      end
      i = j
    else
      i = i + 1
    end
  end

  for _, candidate in ipairs(candidates) do
    local ok, decoded = pcall(vim.json.decode, candidate)
    if ok and type(decoded) == "table" and type(decoded.groups) == "table" then
      return decoded
    end
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
