local hunks = require("intentdiff.hunks")
local helpers = require("tests.helpers")

--- Build a whole-file addition hunk from `lines`, the shape git emits for a
--- new file and `untracked_hunk` synthesises.
local function added_hunk(path, lines)
  return hunks.untracked_hunk(path, lines)
end

--- 90 lines: three blank-line-separated blocks of 30 lines each.
local function three_blocks()
  local lines = {}
  for block = 1, 3 do
    for i = 1, 29 do
      lines[#lines + 1] = ("block%d line%d"):format(block, i)
    end
    lines[#lines + 1] = ""
  end
  return lines
end

--- `count` blank-line-delimited blocks of `size` body lines each (size-1
--- content lines plus the blank line that closes the block), followed by one
--- final block of `tail` body lines.
---
--- Exists to hit the "fold a short remainder into the previous chunk" branch,
--- which three_blocks() above cannot reach: with 30-line blocks and
--- target_lines=40 the accumulator crosses the target on every second block
--- and the run ends with acc empty, so the remainder branch never executes.
local function blocks_then_tail(count, size, tail)
  local lines = {}
  local function block(n)
    for i = 1, n - 1 do
      lines[#lines + 1] = ("line%d"):format(#lines + 1)
    end
    lines[#lines + 1] = ""
  end
  for _ = 1, count do
    block(size)
  end
  block(tail)
  return lines
end

--- Body lines of `piece` (the "+"-prefixed source lines, header excluded).
local function body_of(piece)
  local body = {}
  for line in piece.text:gmatch("(.-)\n") do
    if not line:match("^@@") then
      body[#body + 1] = line
    end
  end
  return body
end

describe("hunks.split_added short-remainder fold-back", function()
  -- 4 x 20 + 10 = 90 body lines. target_lines = 40, so the accumulator flushes
  -- a 40-line chunk after blocks 2 and 4 and ends holding the 10-line tail —
  -- shorter than target_lines/2 (20), so it must be appended to chunk 2 rather
  -- than surviving as a third, stub chunk.
  local function short_tail()
    return blocks_then_tail(4, 20, 10)
  end

  it("folds a remainder shorter than half the target into the previous chunk", function()
    local out = hunks.split_added(added_hunk("tail.lua", short_tail()),
      { min_lines = 60, target_lines = 40 })
    assert.equals(2, #out, "the 10-line tail must not become a chunk of its own")
    assert.equals(40, #body_of(out[1]))
    assert.equals(50, #body_of(out[2]), "the tail must be appended to the last chunk")
    assert.equals(40, out[1].additions)
    assert.equals(50, out[2].additions)
    -- Ranges stay contiguous and end-exclusive across the fold-back.
    assert.equals(1, out[1].modified.start_line)
    assert.equals(41, out[1].modified.end_line)
    assert.equals(41, out[2].modified.start_line)
    assert.equals(91, out[2].modified.end_line)
  end)

  it("loses and duplicates no source line when the remainder is folded back", function()
    local source = short_tail()
    local out = hunks.split_added(added_hunk("tail.lua", source),
      { min_lines = 60, target_lines = 40 })
    local seen = {}
    for _, piece in ipairs(out) do
      for _, line in ipairs(body_of(piece)) do
        seen[#seen + 1] = line:sub(2)
      end
    end
    assert.same(source, seen)
  end)

  it("keeps a remainder of exactly half the target as its own chunk", function()
    -- The other side of the same boundary (`#acc < target_lines / 2`): a
    -- 20-line tail at target_lines = 40 is NOT short, so it stands alone.
    -- Without this, the fold-back test above would also pass against an
    -- implementation that folded back unconditionally.
    local out = hunks.split_added(added_hunk("tail.lua", blocks_then_tail(4, 20, 20)),
      { min_lines = 60, target_lines = 40 })
    assert.equals(3, #out)
    assert.equals(40, #body_of(out[1]))
    assert.equals(40, #body_of(out[2]))
    assert.equals(20, #body_of(out[3]))
  end)
end)

describe("hunks.split_added", function()
  it("leaves a hunk shorter than min_lines whole", function()
    local h = added_hunk("small.lua", { "a", "b", "c" })
    local out = hunks.split_added(h, { min_lines = 60, target_lines = 40 })
    assert.equals(1, #out)
    assert.equals(h, out[1])
  end)

  it("splits a long addition at blank-line boundaries", function()
    local h = added_hunk("big.lua", three_blocks())
    local out = hunks.split_added(h, { min_lines = 60, target_lines = 40 })
    assert.is_true(#out > 1)
    -- every cut lands immediately after a blank line, never mid-block
    for _, piece in ipairs(out) do
      local body = {}
      for line in piece.text:gmatch("(.-)\n") do
        if not line:match("^@@") then body[#body + 1] = line end
      end
      assert.equals("+", body[#body], "chunk must end on a blank source line")
    end
  end)

  it("produces contiguous, gapless, end-exclusive modified ranges", function()
    local h = added_hunk("big.lua", three_blocks())
    local out = hunks.split_added(h, { min_lines = 60, target_lines = 40 })
    assert.equals(1, out[1].modified.start_line)
    for i = 2, #out do
      assert.equals(out[i - 1].modified.end_line, out[i].modified.start_line)
    end
    assert.equals(#three_blocks() + 1, out[#out].modified.end_line)
  end)

  it("preserves every source line across the split", function()
    local source = three_blocks()
    local out = hunks.split_added(added_hunk("big.lua", source),
      { min_lines = 60, target_lines = 40 })
    local seen = {}
    for _, piece in ipairs(out) do
      for line in piece.text:gmatch("(.-)\n") do
        if not line:match("^@@") then seen[#seen + 1] = line:sub(2) end
      end
    end
    assert.same(source, seen)
  end)

  it("sets additions, zero deletions and a zero-width original anchor", function()
    local source = added_hunk("big.lua", three_blocks())
    local out = hunks.split_added(source, { min_lines = 60, target_lines = 40 })
    for _, piece in ipairs(out) do
      assert.equals(0, piece.deletions)
      assert.equals(piece.modified.end_line - piece.modified.start_line, piece.additions)
      assert.equals(1, piece.original.start_line)
      assert.equals(1, piece.original.end_line)
      assert.equals(source.status, piece.status)
      assert.equals(source.file, piece.file)
      assert.is_string(piece.content_hash)
    end
  end)

  it("gives each sub-hunk a distinct content hash", function()
    local out = hunks.split_added(added_hunk("big.lua", three_blocks()),
      { min_lines = 60, target_lines = 40 })
    local seen = {}
    for _, piece in ipairs(out) do
      assert.is_nil(seen[piece.content_hash], "sub-hunk hashes must differ")
      seen[piece.content_hash] = true
    end
  end)

  it("returns a modification hunk unchanged", function()
    local diff = table.concat({
      "diff --git a/a.lua b/a.lua",
      "@@ -1,2 +1,2 @@",
      " keep",
      "-old",
      "+new",
      "",
    }, "\n")
    local parsed = require("intentdiff.hunks").parse(diff)
    local out = hunks.split_added(parsed[1], { min_lines = 1, target_lines = 1 })
    assert.equals(1, #out)
    assert.equals(parsed[1], out[1])
  end)

  it("returns one chunk when the file has no blank lines", function()
    local lines = {}
    for i = 1, 100 do lines[i] = "line " .. i end
    local out = hunks.split_added(added_hunk("dense.lua", lines),
      { min_lines = 60, target_lines = 40 })
    assert.equals(1, #out)
  end)
end)

describe("hunks.collect with added-file splitting", function()
  it("splits a staged new file and renumbers ids per file", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local lines = {}
    for block = 1, 3 do
      for i = 1, 29 do lines[#lines + 1] = ("block%d line%d"):format(block, i) end
      lines[#lines + 1] = ""
    end
    helpers.write_file(repo, "added.lua", table.concat(lines, "\n"))
    helpers.git(repo, "add", "added.lua")

    require("intentdiff.config").setup({
      added_file_split = { enabled = true, min_lines = 60, target_lines = 40 },
    })
    local inv
    hunks.collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)

    local added = vim.tbl_filter(function(h) return h.file == "added.lua" end, inv.hunks)
    assert.is_true(#added > 1)
    for i, h in ipairs(added) do
      assert.equals("added.lua:" .. i, h.id)
    end
  end)

  it("keeps one hunk per added file when splitting is disabled", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local lines = {}
    for block = 1, 3 do
      for i = 1, 29 do lines[#lines + 1] = ("block%d line%d"):format(block, i) end
      lines[#lines + 1] = ""
    end
    helpers.write_file(repo, "added.lua", table.concat(lines, "\n"))
    helpers.git(repo, "add", "added.lua")

    require("intentdiff.config").setup({ added_file_split = { enabled = false } })
    local inv
    hunks.collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)

    local added = vim.tbl_filter(function(h) return h.file == "added.lua" end, inv.hunks)
    assert.equals(1, #added)
  end)
end)
