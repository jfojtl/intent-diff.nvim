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

  -- Candidate 2: the greedy span (current behavior as fallback)
  local greedy = text:match("({.*})")
  if greedy then
    table.insert(candidates, greedy)
  end

  -- Candidate 3: try all {..} spans from each { position to each } position
  local open_positions = {}
  local close_positions = {}

  -- Find all { positions
  local pos = 0
  while true do
    pos = text:find("{", pos + 1)
    if not pos then break end
    table.insert(open_positions, pos)
  end

  -- Find all } positions
  pos = 0
  while true do
    pos = text:find("}", pos + 1)
    if not pos then break end
    table.insert(close_positions, pos)
  end

  -- Try combinations: for each opening, try closings from last to first
  for _, open_pos in ipairs(open_positions) do
    for i = #close_positions, 1, -1 do
      local close_pos = close_positions[i]
      if close_pos > open_pos then
        table.insert(candidates, text:sub(open_pos, close_pos))
      end
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
