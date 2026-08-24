local M = {}

local function range(start, len)
  if len == 0 then
    return { start_line = start + 1, end_line = start + 1 } -- zero-width anchor
  end
  return { start_line = start, end_line = start + len } -- end exclusive
end

--- Why a file appears in the diff while producing no hunk at all.
---
--- Binary wins over rename: a renamed binary is still, to a reader, a binary
--- file. The trailing fallback is deliberate rather than an assert — git grows
--- new headers (typechange, submodule commits), and an unfamiliar one must
--- still leave the file visible in the review with an honest label.
local function no_diff_reason(f)
  if f.binary then
    return "binary — no diff"
  end
  if f.old_path then
    return ("renamed from %s — no content change"):format(f.old_path)
  end
  if f.old_mode and f.new_mode then
    return ("mode changed %s → %s"):format(f.old_mode, f.new_mode)
  end
  return "no content change"
end

--- One synthetic hunk standing in for a file that has no real hunks.
---
--- It exists to carry the file somewhere, not to be read: classify.group_files
--- keeps a file only if it owns at least one hunk, so without this a binary
--- change, a pure rename and a chmod were dropped between the inventory and
--- the sidebar — silently absent from a review that claims to be complete.
---
--- The body is the reason line and nothing else. That matters twice over:
--- classify.build_request ships only a hunk's first four lines to the provider,
--- so the model sees one honest sentence instead of a file's bytes; and
--- split_added bails on the first body line (it does not start with "+"), so a
--- marker can never be mistaken for a whole-file addition and split.
local function marker_hunk(f, reason)
  local header = ("@@ %s @@"):format(f.path)
  local text = header .. "\n" .. reason .. "\n"
  return {
    id = f.path .. ":1",
    file = f.path,
    old_path = f.old_path,
    status = f.status,
    header = header,
    -- Zero-width on both sides: the file paints no rows, so nothing may
    -- resolve a pane line to this hunk (comments/anchor.lua walks these).
    original = { start_line = 1, end_line = 1 },
    modified = { start_line = 1, end_line = 1 },
    text = text,
    additions = 0,
    deletions = 0,
    content_hash = vim.fn.sha256(text),
  }
end

--- Record on `f` why it has no diff and hand back its marker hunk.
local function mark_no_diff(f)
  local reason = no_diff_reason(f)
  f.no_diff_reason = reason
  return marker_hunk(f, reason)
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
  -- Runs as the NEXT `diff --git` arrives (and once more at the end), while
  -- files[#files] is still the file just finished. Appending the marker here
  -- rather than in a sweep afterwards is what keeps hunk order file order,
  -- which is the order build_request numbers hunks in for the provider.
  local function close_file()
    flush()
    local f = files[#files]
    if not f or per_file[f.path] then
      return
    end
    hunks[#hunks + 1] = mark_no_diff(f)
  end
  -- Only append "\n" if diff_text doesn't already end with one (FINDING 1 fix)
  local needs_newline = #diff_text == 0 or diff_text:sub(-1) ~= "\n"
  local text_to_parse = diff_text .. (needs_newline and "\n" or "")
  for line in text_to_parse:gmatch("(.-)\n") do
    -- Strip trailing \r for CRLF normalization (FINDING 2 fix)
    line = line:gsub("\r$", "")
    local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
    if a then
      close_file()
      file, old_path, status = b, (a ~= b) and a or nil, "M"
      files[#files + 1] = { path = file, status = "M", old_path = old_path, binary = false }
    elseif line:match("^new file mode") then
      status = "A"
      files[#files].status = "A"
    elseif line:match("^deleted file mode") then
      status = "D"
      files[#files].status = "D"
    elseif line:match("^old mode ") then
      -- Distinct from "new file mode", matched above: this pair is a chmod,
      -- which git reports with no hunk of any kind.
      files[#files].old_mode = line:match("^old mode (%S+)")
    elseif line:match("^new mode ") then
      files[#files].new_mode = line:match("^new mode (%S+)")
    elseif line:match("^Binary files ") then
      -- No @@ header follows, so `current` stays nil and this file
      -- contributes no hunks. Mark it so the renderer shows a marker row
      -- instead of trying to read the file's bytes as text.
      files[#files].binary = true
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
  close_file()
  return hunks, files
end

-- git reads this many bytes before deciding text-vs-binary
-- (xdiff-interface.c's FIRST_FEW_BYTES).
local SNIFF_BYTES = 8000

--- Whether `abs_path` looks binary to git.
---
--- Deliberately git's own heuristic (buffer_is_binary): a NUL byte anywhere in
--- the first SNIFF_BYTES. Matching it is the point — an untracked file is
--- called binary here exactly when git would call it binary in a diff, so a
--- file's rendering does not change the moment someone `git add`s it.
---
--- An unopenable path answers false rather than raising: the caller's readfile
--- fails on it too and skips the file, which is the pre-existing behaviour for
--- a path `ls-files` named but nobody can read.
function M.is_binary(abs_path)
  local fh = io.open(abs_path, "rb")
  if not fh then
    return false
  end
  local chunk = fh:read(SNIFF_BYTES)
  fh:close()
  return chunk ~= nil and chunk:find("\0", 1, true) ~= nil
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
        local abs = opts.git_root .. "/" .. path
        if M.is_binary(abs) then
          -- No hunk, on purpose. readfile would happily hand back the raw
          -- bytes as `+` lines, which then get split, hashed, rendered as a
          -- wall of garbage AND shipped to the classifier. Marking the file
          -- instead is all the renderer needs: it draws the binary marker row
          -- off this flag alone (render/plan.lua's separator).
          local entry = { path = path, status = "??", binary = true }
          files[#files + 1] = entry
          hunks[#hunks + 1] = mark_no_diff(entry)
        else
          local ok, lines = pcall(vim.fn.readfile, abs)
          if ok then
            files[#files + 1] = { path = path, status = "??", binary = false }
            hunks[#hunks + 1] = M.untracked_hunk(path, lines)
          end
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
