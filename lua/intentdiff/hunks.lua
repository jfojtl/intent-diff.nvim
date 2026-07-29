local M = {}

local function range(start, len)
  if len == 0 then
    return { start_line = start + 1, end_line = start + 1 } -- zero-width anchor
  end
  return { start_line = start, end_line = start + len } -- end exclusive
end

--- Parse unified `git diff` output.
--- @return Hunk[] hunks, table[] files
function M.parse(diff_text)
  local hunks, files = {}, {}
  local file, old_path, status
  local per_file = {}
  local current
  local function flush()
    if current then
      current.content_hash = vim.fn.sha256(current.text)
      hunks[#hunks + 1] = current
      current = nil
    end
  end
  -- Only append "\n" if diff_text doesn't already end with one (FINDING 1 fix)
  local needs_newline = #diff_text == 0 or diff_text:sub(-1) ~= "\n"
  local text_to_parse = diff_text .. (needs_newline and "\n" or "")
  for line in text_to_parse:gmatch("(.-)\n") do
    -- Strip trailing \r for CRLF normalization (FINDING 2 fix)
    line = line:gsub("\r$", "")
    local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
    if a then
      flush()
      file, old_path, status = b, (a ~= b) and a or nil, "M"
      files[#files + 1] = { path = file, status = "M", old_path = old_path }
    elseif line:match("^new file mode") then
      status = "A"
      files[#files].status = "A"
    elseif line:match("^deleted file mode") then
      status = "D"
      files[#files].status = "D"
    elseif line:match("^@@") then
      flush()
      local os_, ol, ms, ml = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
      per_file[file] = (per_file[file] or 0) + 1
      current = {
        id = file .. ":" .. per_file[file],
        file = file,
        old_path = old_path,
        status = status,
        header = line,
        original = range(tonumber(os_), ol == "" and 1 or tonumber(ol)),
        modified = range(tonumber(ms), ml == "" and 1 or tonumber(ml)),
        text = line .. "\n",
      }
    elseif current then
      current.text = current.text .. line .. "\n"
    end
  end
  flush()
  return hunks, files
end

--- Whole-file synthetic hunk for an untracked file.
function M.untracked_hunk(path, lines)
  local text = ("@@ -0,0 +1,%d @@\n+%s\n"):format(#lines, table.concat(lines, "\n+"))
  return {
    id = path .. ":1",
    file = path,
    status = "??",
    header = ("@@ -0,0 +1,%d @@"):format(#lines),
    original = { start_line = 1, end_line = 1 },
    modified = { start_line = 1, end_line = math.max(1, #lines) + 1 },
    text = text,
    content_hash = vim.fn.sha256(text),
  }
end

return M
