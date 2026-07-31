local export = require("intentdiff.comments.export")

--- A model with two groups. Hunk ranges are END-EXCLUSIVE, matching hunks.lua.
--
-- The account.ts and client.ts hunks are deliberately ASYMMETRIC (original ~=
-- modified), the way any hunk with a net add or delete is in practice. This
-- lets tests pin old-side vs new-side resolution against DIFFERENT ranges:
-- a hunk where original == modified can't tell a correct implementation from
-- one that resolves every side against the same range.
--   account.ts: shrank.  original 40-51 (incl.), modified 40-49 (incl.) —
--     line 50 is in the old range only.
--   client.ts:  grew.    original 40-49 (incl.), modified 40-55 (incl.) —
--     line 54 is in the new range only.
local function model()
  return {
    state = "ready",
    groups = {
      {
        title = "Rename UserService to AccountService",
        hunks = {
          { id = "src/api/routes.ts:1", file = "src/api/routes.ts",
            original = { start_line = 4, end_line = 6 },
            modified = { start_line = 4, end_line = 6 } },
          { id = "src/services/account.ts:1", file = "src/services/account.ts",
            original = { start_line = 40, end_line = 52 },
            modified = { start_line = 40, end_line = 50 } },
        },
        files = {
          { path = "src/api/routes.ts", status = "M" },
          { path = "src/services/account.ts", status = "M" },
        },
      },
      {
        title = "Add retry logic to HTTP client",
        hunks = {
          { id = "src/http/client.ts:1", file = "src/http/client.ts",
            original = { start_line = 40, end_line = 50 },
            modified = { start_line = 40, end_line = 56 } },
        },
        files = { { path = "src/http/client.ts", status = "M" } },
      },
    },
  }
end

describe("comments.export", function()
  it("reports an empty store plainly", function()
    assert.equals("No comments yet.", export.generate({}, model()))
  end)

  it("files each comment under the intent owning its line", function()
    local md = export.generate({
      { file = "src/http/client.ts", line = 44, side = "new", type = "note", text = "No jitter." },
      { file = "src/api/routes.ts", line = 5, side = "new", type = "issue", text = "Old module." },
    }, model())
    assert.is_truthy(md:match("## Rename UserService to AccountService"))
    assert.is_truthy(md:match("## Add retry logic to HTTP client"))
    -- Group order follows the model, not the order comments were added.
    assert.is_true(md:find("## Rename", 1, true) < md:find("## Add retry", 1, true))
  end)

  it("numbers continuously across groups", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "issue", text = "a" },
      { file = "src/http/client.ts", line = 44, side = "new", type = "note", text = "b" },
    }, model())
    assert.is_truthy(md:match("1%. %*%*%[ISSUE%]%*%* `src/api/routes%.ts:5`"))
    assert.is_truthy(md:match("2%. %*%*%[NOTE%]%*%* `src/http/client%.ts:44`"))
  end)

  it("marks an old-side line with ~ and explains it", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "old", type = "suggestion", text = "cleaner" },
    }, model())
    assert.is_truthy(md:match("`src/api/routes%.ts:~5`"))
    assert.is_truthy(md:match("Lines prefixed with ~"))
  end)

  it("omits the ~ legend when no old-side comment exists", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "x" },
    }, model())
    assert.is_nil(md:match("Lines prefixed with ~"))
  end)

  it("renders ranges, old-side ranges and file-level locations", function()
    local md = export.generate({
      { file = "src/http/client.ts", line = 44, line_end = 51, side = "new", type = "note", text = "r" },
      { file = "src/api/routes.ts", line = 4, line_end = 5, side = "old", type = "note", text = "o" },
      { file = "src/http/client.ts", line = 0, type = "praise", text = "f" },
    }, model())
    assert.is_truthy(md:match("`src/http/client%.ts:44%-51`"))
    assert.is_truthy(md:match("`src/api/routes%.ts:~4%-~5`"))
    assert.is_truthy(md:match("`src/http/client%.ts`\n"))
  end)

  it("puts an intent comment as a paragraph before that group's list", function()
    local md = export.generate({
      { intent_title = "Add retry logic to HTTP client", type = "issue", text = "Whole thing is wrong." },
      { file = "src/http/client.ts", line = 44, side = "new", type = "note", text = "detail" },
    }, model())
    local head = md:find("## Add retry logic", 1, true)
    local para = md:find("Whole thing is wrong.", 1, true)
    local item = md:find("**[NOTE]**", 1, true)
    assert.is_true(head < para and para < item)
  end)

  it("indents multi-line comment text instead of breaking the list", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "line one\nline two" },
    }, model())
    assert.is_truthy(md:match("\n   line one\n   line two"))
  end)

  it("always emits the type legend", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "x" },
    }, model())
    assert.is_truthy(md:match("Comment types: ISSUE"))
  end)

  it("falls back to a flat list when there are no groups", function()
    local md = export.generate({
      { file = "a.lua", line = 5, side = "new", type = "note", text = "x" },
    }, { state = "loading", groups = {} })
    assert.is_nil(md:match("\n## "))
    assert.is_truthy(md:match("1%. %*%*%[NOTE%]%*%* `a%.lua:5`"))
  end)

  it("sends a line matching no hunk to Unmatched", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 900, side = "new", type = "note", text = "drifted" },
    }, model())
    assert.is_truthy(md:match("## Unmatched comments"))
  end)

  it("sends an intent comment with no matching group to Unmatched", function()
    local md = export.generate({
      { intent_title = "A group that no longer exists", type = "note", text = "orphan" },
    }, model())
    assert.is_truthy(md:match("## Unmatched comments"))
    assert.is_truthy(md:match("orphan"))
  end)

  it("treats hunk ranges as end-exclusive", function()
    -- routes.ts hunk covers modified lines 4 and 5, not 6.
    local inside = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "in" },
    }, model())
    assert.is_nil(inside:match("Unmatched"))
    local outside = export.generate({
      { file = "src/api/routes.ts", line = 6, side = "new", type = "note", text = "out" },
    }, model())
    assert.is_truthy(outside:match("Unmatched"))
  end)

  it("resolves an old-side comment against the hunk's original range", function()
    -- account.ts hunk shrank: original covers up to line 51, modified only up
    -- to line 49. Line 50 is old-range-only, so this fails if old-side
    -- resolution is ever collapsed onto the modified range.
    local md = export.generate({
      { file = "src/services/account.ts", line = 50, side = "old", type = "note", text = "x" },
    }, model())
    assert.is_nil(md:match("Unmatched"))
    assert.is_truthy(md:match("## Rename UserService"))
  end)

  it("does not resolve a new-side comment against a shrunk hunk's old-only range", function()
    -- Same line 50, but new-side: only the old range covers it, so a
    -- new-side comment there must NOT match.
    local md = export.generate({
      { file = "src/services/account.ts", line = 50, side = "new", type = "note", text = "shrank-new" },
    }, model())
    assert.is_truthy(md:match("## Unmatched comments"))
  end)

  it("resolves a new-side comment against the hunk's modified range, not original", function()
    -- client.ts hunk grew: modified covers up to line 55, original only up to
    -- line 49. Line 54 is new-range-only, so this fails if new-side
    -- resolution is ever collapsed onto the original range.
    local md = export.generate({
      { file = "src/http/client.ts", line = 54, side = "new", type = "note", text = "grew-new" },
    }, model())
    assert.is_nil(md:match("Unmatched"))
    assert.is_truthy(md:match("## Add retry logic"))
  end)

  it("does not resolve an old-side comment against a grown hunk's new-only range", function()
    -- Same line 54, but old-side: only the new range covers it, so an
    -- old-side comment there must NOT match. This is the exact case that
    -- proves old-side resolution isn't silently using hunk.modified.
    local md = export.generate({
      { file = "src/http/client.ts", line = 54, side = "old", type = "note", text = "grew-old" },
    }, model())
    assert.is_truthy(md:match("## Unmatched comments"))
  end)

  it("resolves a file-level comment by file, not by line", function()
    local md = export.generate({
      { file = "src/http/client.ts", line = 0, type = "praise", text = "nice" },
    }, model())
    assert.is_truthy(md:match("## Add retry logic"))
    assert.is_nil(md:match("Unmatched"))
  end)

  it("orders within a group by file then line, file-level first", function()
    local md = export.generate({
      { file = "src/services/account.ts", line = 45, side = "new", type = "note", text = "second-file" },
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "first-file-line" },
      { file = "src/api/routes.ts", line = 0, type = "note", text = "first-file-level" },
    }, model())
    local a = md:find("first-file-level", 1, true)
    local b = md:find("first-file-line", 1, true)
    local c = md:find("second-file", 1, true)
    assert.is_true(a < b and b < c)
  end)

  it("puts Ungrouped last", function()
    local m = model()
    m.groups[#m.groups + 1] = {
      title = "Ungrouped", is_ungrouped = true,
      hunks = { { id = "docs/notes.md:1", file = "docs/notes.md",
        original = { start_line = 1, end_line = 4 },
        modified = { start_line = 1, end_line = 4 } } },
      files = { { path = "docs/notes.md", status = "??" } },
    }
    local md = export.generate({
      { file = "docs/notes.md", line = 2, side = "new", type = "note", text = "u" },
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "g" },
    }, m)
    assert.is_true(md:find("## Rename", 1, true) < md:find("## Ungrouped", 1, true))
  end)

  it("writes a file and creates parent directories", function()
    local path = vim.fn.tempname() .. "/nested/review.md"
    local ok = export.to_file({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "x" },
    }, model(), path)
    assert.is_true(ok)
    assert.is_truthy(table.concat(vim.fn.readfile(path), "\n"):match("%[NOTE%]"))
  end)

  it("refuses to write an empty review", function()
    local path = vim.fn.tempname() .. "/review.md"
    local ok, err = export.to_file({}, model(), path)
    assert.is_false(ok)
    assert.is_truthy(err)
    assert.equals(0, vim.fn.filereadable(path))
  end)

  it("refuses to touch the clipboard for an empty review", function()
    vim.fn.setreg("+", "SENTINEL")
    assert.is_false(export.to_clipboard({}, model()))
    assert.equals("SENTINEL", vim.fn.getreg("+"))
  end)
end)
