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
  it("marks a binary file and gives it only a marker hunk", function()
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
    -- The binary file contributes a marker hunk and no diff body, so it still
    -- reaches a group and the sidebar; only the text file contributes content.
    assert.equals(2, #hunks)
    assert.equals("logo.png", hunks[1].file)
    assert.equals(0, hunks[1].additions)
    assert.equals(0, hunks[1].deletions)
    assert.equals("src/a.lua", hunks[2].file)
    assert.equals(1, hunks[2].additions)
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

describe("hunks.is_binary", function()
  local helpers = require("tests.helpers")
  local hunks = require("intentdiff.hunks")

  local function repo()
    return helpers.make_repo({ ["seed.lua"] = "x" })
  end

  it("is true for a file with a NUL byte in the first bytes", function()
    local r = repo()
    helpers.write_bytes(r, "logo.png", "\137PNG\r\n\26\n\0\0\0\13IHDR")
    assert.is_true(hunks.is_binary(r .. "/logo.png"))
  end)

  it("is false for plain text", function()
    local r = repo()
    helpers.write_bytes(r, "notes.md", "# hello\n\nsome text\n")
    assert.is_false(hunks.is_binary(r .. "/notes.md"))
  end)

  it("is false for an empty file", function()
    local r = repo()
    helpers.write_bytes(r, "empty.txt", "")
    assert.is_false(hunks.is_binary(r .. "/empty.txt"))
  end)

  it("is false for a path that cannot be opened", function()
    local r = repo()
    assert.is_false(hunks.is_binary(r .. "/no/such/file"))
  end)

  it("ignores a NUL that lands past the sniffed prefix", function()
    local r = repo()
    helpers.write_bytes(r, "late.txt", string.rep("a", 8000) .. "\0")
    assert.is_false(hunks.is_binary(r .. "/late.txt"))
  end)
end)

describe("hunks.parse files with no hunks", function()
  local hunks = require("intentdiff.hunks")

  local function diff_of(lines)
    return table.concat(lines, "\n") .. "\n"
  end

  it("gives a binary file a marker hunk so it reaches a group", function()
    local hs, files = hunks.parse(diff_of({
      "diff --git a/logo.png b/logo.png",
      "index 111..222 100644",
      "Binary files a/logo.png and b/logo.png differ",
    }))
    assert.equals(1, #files)
    assert.is_true(files[1].binary)
    assert.equals("binary — no diff", files[1].no_diff_reason)
    assert.equals(1, #hs)
    assert.equals("logo.png:1", hs[1].id)
    assert.equals(0, hs[1].additions)
    assert.equals(0, hs[1].deletions)
  end)

  it("gives a pure rename a marker hunk naming the old path", function()
    local hs, files = hunks.parse(diff_of({
      "diff --git a/moved.txt b/renamed.txt",
      "similarity index 100%",
      "rename from moved.txt",
      "rename to renamed.txt",
    }))
    assert.equals(1, #files)
    assert.is_false(files[1].binary)
    assert.equals("renamed from moved.txt — no content change", files[1].no_diff_reason)
    assert.equals(1, #hs)
    assert.equals("renamed.txt:1", hs[1].id)
  end)

  it("gives a mode-only change a marker hunk naming both modes", function()
    local hs, files = hunks.parse(diff_of({
      "diff --git a/run.sh b/run.sh",
      "old mode 100644",
      "new mode 100755",
    }))
    assert.equals(1, #files)
    assert.equals("mode changed 100644 → 100755", files[1].no_diff_reason)
    assert.equals(1, #hs)
    assert.equals("run.sh:1", hs[1].id)
  end)

  it("leaves a file with real hunks alone", function()
    local hs, files = hunks.parse(diff_of({
      "diff --git a/a.lua b/a.lua",
      "index 333..444 100644",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
    }))
    assert.is_nil(files[1].no_diff_reason)
    assert.equals(1, #hs)
    assert.equals(1, hs[1].additions)
  end)

  it("keeps marker hunks in file order among real hunks", function()
    local hs = hunks.parse(diff_of({
      "diff --git a/logo.png b/logo.png",
      "index 111..222 100644",
      "Binary files a/logo.png and b/logo.png differ",
      "diff --git a/a.lua b/a.lua",
      "index 333..444 100644",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
    }))
    assert.equals(2, #hs)
    assert.equals("logo.png:1", hs[1].id)
    assert.equals("a.lua:1", hs[2].id)
  end)

  it("never lets a marker hunk be split as an addition", function()
    local hs = hunks.parse(diff_of({
      "diff --git a/logo.png b/logo.png",
      "index 111..222 100644",
      "Binary files a/logo.png and b/logo.png differ",
    }))
    assert.same({ hs[1] }, hunks.split_added(hs[1], { min_lines = 1, target_lines = 1 }))
  end)
end)
