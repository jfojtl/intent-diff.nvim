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
        additions = 0,
        deletions = 0,
      }
    elseif current then
      current.text = current.text .. line .. "\n"
      -- Body lines only: `diff --git`, `index`, `---` and `+++` all land here
      -- with `current == nil` (flush() runs at `diff --git`), so the file
      -- header can never be miscounted. "\ No newline at end of file" starts
      -- with a backslash and counts as neither.
      local kind = line:sub(1, 1)
      if kind == "+" then
        current.additions = current.additions + 1
      elseif kind == "-" then
        current.deletions = current.deletions + 1
      end
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
    additions = #lines,
    deletions = 0,
    content_hash = vim.fn.sha256(text),
  }
end

--- Split a whole-file addition into sub-hunks at blank-line boundaries.
---
--- Applies only to pure additions — `@@ -0,0 +1,N @@`, which is what git emits
--- for status "A" and what M.untracked_hunk synthesises for "??". Anything with
--- a non-empty original side is returned unchanged, so this is safe to run over
--- every hunk in an inventory.
---
--- Blocks are delimited by blank source lines (a body line of exactly "+").
--- Whole blocks accumulate until the chunk reaches `target_lines`, so a cut
--- never lands inside a block. A trailing remainder shorter than half the
--- target is folded back into the previous chunk rather than left as a stub.
--- @return Hunk[] one or more hunks; the original table when no split applies
function M.split_added(hunk, opts)
  opts = opts or {}
  local min_lines = opts.min_lines or 60
  local target_lines = opts.target_lines or 40

  local body = {}
  for line in hunk.text:gmatch("(.-)\n") do
    if not line:match("^@@") and line:sub(1, 1) ~= "\\" then
      if line:sub(1, 1) ~= "+" then
        return { hunk } -- not a pure addition
      end
      body[#body + 1] = line
    end
  end
  if #body < min_lines then
    return { hunk }
  end

  local blocks, block = {}, {}
  for _, line in ipairs(body) do
    block[#block + 1] = line
    if line == "+" then -- blank source line closes a block
      blocks[#blocks + 1] = block
      block = {}
    end
  end
  if #block > 0 then
    blocks[#blocks + 1] = block
  end

  local chunks, acc = {}, {}
  for _, b in ipairs(blocks) do
    vim.list_extend(acc, b)
    if #acc >= target_lines then
      chunks[#chunks + 1] = acc
      acc = {}
    end
  end
  if #acc > 0 then
    if #chunks > 0 and #acc < math.floor(target_lines / 2) then
      vim.list_extend(chunks[#chunks], acc)
    else
      chunks[#chunks + 1] = acc
    end
  end
  if #chunks <= 1 then
    return { hunk }
  end

  local out, line_no = {}, hunk.modified.start_line
  for i, chunk in ipairs(chunks) do
    local header = ("@@ -0,0 +%d,%d @@"):format(line_no, #chunk)
    local text = header .. "\n" .. table.concat(chunk, "\n") .. "\n"
    out[i] = {
      id = hunk.file .. ":" .. i, -- re-derived by M.collect below
      file = hunk.file,
      old_path = hunk.old_path,
      status = hunk.status,
      header = header,
      original = { start_line = 1, end_line = 1 },
      modified = { start_line = line_no, end_line = line_no + #chunk },
      text = text,
      additions = #chunk,
      deletions = 0,
      content_hash = vim.fn.sha256(text),
    }
    line_no = line_no + #chunk
  end
  return out
end

--- Expand added-file hunks in place and renumber every id per file, so ids stay
--- `<path>:1`, `<path>:2`, … in modified-line order regardless of splitting.
--- Non-added hunks pass through untouched and keep the id parse() gave them.
local function apply_added_split(hunks)
  local cfg = require("intentdiff.config").options.added_file_split or {}
  local out, per_file = {}, {}
  for _, h in ipairs(hunks) do
    local pieces = (cfg.enabled == false) and { h } or M.split_added(h, cfg)
    for _, piece in ipairs(pieces) do
      per_file[piece.file] = (per_file[piece.file] or 0) + 1
      piece.id = piece.file .. ":" .. per_file[piece.file]
      out[#out + 1] = piece
    end
  end
  return out
end

--- Collect the diff to classify and display. See task interface for opts.
--- @param callback fun(inventory: Inventory|nil, err: string|nil)
function M.collect(opts, callback)
  local args = { "git", "-C", opts.git_root, "diff", "--no-color", "--no-ext-diff" }
  if opts.base and opts.target then
    vim.list_extend(args, { opts.base, opts.target })
  else
    args[#args + 1] = opts.base or "HEAD"
  end

  vim.system(args, { text = true }, function(diff_out)
    local function finish_with(untracked)
      -- Runs on main loop: vim.fn.* is safe here.
      if diff_out.code ~= 0 then
        return callback(nil, "git diff failed: " .. vim.trim(diff_out.stderr or ""))
      end
      local diff_text = diff_out.stdout or ""
      local hunks, files = M.parse(diff_text)
      for _, path in ipairs(untracked or {}) do
        local ok, lines = pcall(vim.fn.readfile, opts.git_root .. "/" .. path)
        if ok then
          files[#files + 1] = { path = path, status = "??" }
          hunks[#hunks + 1] = M.untracked_hunk(path, lines)
        end
      end
      -- Split BEFORE hashing: the inventory hash must describe the hunks the
      -- classifier and the cache actually see.
      hunks = apply_added_split(hunks)
      local hashes = {}
      for i, h in ipairs(hunks) do hashes[i] = h.content_hash end
      callback({
        hunks = hunks,
        files = files,
        diff_text = diff_text,
        diff_hash = vim.fn.sha256(table.concat(hashes, "\n")),
      })
    end

    if opts.base and opts.target then
      return vim.schedule(function() finish_with(nil) end)
    end
    vim.system(
      { "git", "-C", opts.git_root, "ls-files", "--others", "--exclude-standard" },
      { text = true },
      function(ls_out)
        vim.schedule(function()
          local untracked = ls_out.code == 0
              and vim.split(vim.trim(ls_out.stdout or ""), "\n", { trimempty = true })
            or nil
          finish_with(untracked)
        end)
      end
    )
  end)
end

return M
