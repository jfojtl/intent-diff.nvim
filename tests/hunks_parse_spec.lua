local hunks = require("intentdiff.hunks")

local DIFF = table.concat({
  "diff --git a/src/a.lua b/src/a.lua",
  "index 111..222 100644",
  "--- a/src/a.lua",
  "+++ b/src/a.lua",
  "@@ -10,3 +10,4 @@ local ctx",
  " keep",
  "-old",
  "+new",
  "+extra",
  "@@ -30,2 +31,2 @@",
  "-x",
  "+y",
  " keep",
  "diff --git a/old.lua b/renamed.lua",
  "similarity index 90%",
  "rename from old.lua",
  "rename to renamed.lua",
  "--- a/old.lua",
  "+++ b/renamed.lua",
  "@@ -1,1 +1,1 @@",
  "-a",
  "+b",
  "diff --git a/added.lua b/added.lua",
  "new file mode 100644",
  "--- /dev/null",
  "+++ b/added.lua",
  "@@ -0,0 +1,2 @@",
  "+l1",
  "+l2",
  "diff --git a/gone.lua b/gone.lua",
  "deleted file mode 100644",
  "--- a/gone.lua",
  "+++ /dev/null",
  "@@ -1,2 +0,0 @@",
  "-l1",
  "-l2",
}, "\n") .. "\n"

describe("hunks.parse", function()
  local parsed, files
  before_each(function() parsed, files = hunks.parse(DIFF) end)

  it("assigns per-file sequential ids", function()
    assert.equals("src/a.lua:1", parsed[1].id)
    assert.equals("src/a.lua:2", parsed[2].id)
    assert.equals("renamed.lua:1", parsed[3].id)
    assert.equals(5, #parsed)
  end)

  it("parses ranges end-exclusive", function()
    assert.same({ start_line = 10, end_line = 13 }, parsed[1].original)
    assert.same({ start_line = 10, end_line = 14 }, parsed[1].modified)
  end)

  it("normalizes zero-length ranges to zero-width anchors", function()
    assert.same({ start_line = 1, end_line = 1 }, parsed[4].original)  -- @@ -0,0
    assert.same({ start_line = 1, end_line = 1 }, parsed[5].modified)  -- +0,0
  end)

  it("detects rename, added, deleted statuses", function()
    assert.equals("old.lua", parsed[3].old_path)
    assert.equals("A", parsed[4].status)
    assert.equals("D", parsed[5].status)
    assert.same({ path = "added.lua", status = "A", old_path = nil, binary = false }, files[3])
  end)

  it("captures raw hunk text and content hash", function()
    assert.truthy(parsed[1].text:find("^@@ %-10,3"))
    assert.truthy(parsed[1].text:find("%+extra\n"))
    assert.equals(vim.fn.sha256(parsed[1].text), parsed[1].content_hash)
  end)

  it("builds a whole-file hunk for untracked files", function()
    local h = hunks.untracked_hunk("nu.lua", { "a", "b", "c" })
    assert.equals("nu.lua:1", h.id)
    assert.equals("??", h.status)
    assert.same({ start_line = 1, end_line = 1 }, h.original)
    assert.same({ start_line = 1, end_line = 4 }, h.modified)
  end)

  it("does not add phantom trailing line to last hunk", function()
    -- Regression test for FINDING 1: phantom trailing line corruption
    assert.equals("@@ -1,2 +0,0 @@\n-l1\n-l2\n", parsed[5].text)
  end)

  it("normalizes CRLF line endings in diff parsing", function()
    -- Regression test for FINDING 2: CRLF normalization
    local diff_crlf = DIFF:gsub("\n", "\r\n")
    local parsed_crlf, _ = hunks.parse(diff_crlf)
    -- Check first hunk id is correct (file path should have no \r)
    assert.equals("src/a.lua:1", parsed_crlf[1].id)
    -- Check that file path in first hunk has no \r
    assert.not_match("\r", parsed_crlf[1].file)
    -- Check that file path in all hunks has no \r
    for i, hunk in ipairs(parsed_crlf) do
      assert.not_match("\r", hunk.file, "Hunk " .. i .. " file path contains \\r")
    end
  end)
end)

describe("hunks.parse line statistics", function()
  it("counts additions and deletions per hunk", function()
    local diff = table.concat({
      "diff --git a/a.lua b/a.lua",
      "index 1111111..2222222 100644",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,3 +1,4 @@",
      " keep",
      "-gone",
      "-also gone",
      "+new one",
      "+new two",
      "+new three",
      "",
    }, "\n")
    local parsed = require("intentdiff.hunks").parse(diff)
    assert.equals(1, #parsed)
    assert.equals(3, parsed[1].additions)
    assert.equals(2, parsed[1].deletions)
  end)

  it("does not count the --- / +++ file header lines", function()
    -- These precede the first @@, so `current` is nil and they must be
    -- skipped. A naive counter that runs before the @@ check would report
    -- one extra addition and one extra deletion here.
    local diff = table.concat({
      "diff --git a/a.lua b/a.lua",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
      "",
    }, "\n")
    local parsed = require("intentdiff.hunks").parse(diff)
    assert.equals(1, parsed[1].additions)
    assert.equals(1, parsed[1].deletions)
  end)

  it("does not count the no-newline marker", function()
    local diff = table.concat({
      "diff --git a/a.lua b/a.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "\\ No newline at end of file",
      "+new",
      "",
    }, "\n")
    local parsed = require("intentdiff.hunks").parse(diff)
    assert.equals(1, parsed[1].additions)
    assert.equals(1, parsed[1].deletions)
  end)

  it("counts every added line for an untracked file", function()
    local h = require("intentdiff.hunks").untracked_hunk("new.lua", { "a", "b", "c" })
    assert.equals(3, h.additions)
    assert.equals(0, h.deletions)
  end)
end)

describe("hunks.parse binary files", function()
  it("marks a binary file and gives it no hunks", function()
    local diff = table.concat({
      "diff --git a/logo.png b/logo.png",
      "index 1111111..2222222 100644",
      "Binary files a/logo.png and b/logo.png differ",
      "diff --git a/src/a.lua b/src/a.lua",
      "index 3333333..4444444 100644",
      "--- a/src/a.lua",
      "+++ b/src/a.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
    }, "\n") .. "\n"
    local hunks, files = require("intentdiff.hunks").parse(diff)
    assert.equals(2, #files)
    assert.equals("logo.png", files[1].path)
    assert.is_true(files[1].binary)
    assert.equals("src/a.lua", files[2].path)
    assert.is_false(files[2].binary)
    -- Only the text file contributes hunks.
    assert.equals(1, #hunks)
    assert.equals("src/a.lua", hunks[1].file)
  end)

  it("marks a binary file added in this diff", function()
    local diff = table.concat({
      "diff --git a/img.bin b/img.bin",
      "new file mode 100644",
      "index 0000000..5555555",
      "Binary files /dev/null and b/img.bin differ",
    }, "\n") .. "\n"
    local _, files = require("intentdiff.hunks").parse(diff)
    assert.equals(1, #files)
    assert.is_true(files[1].binary)
    assert.equals("A", files[1].status)
  end)
end)
