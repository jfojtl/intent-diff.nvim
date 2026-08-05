local plan = require("intentdiff.render.plan")

--- A modified file: original 5 lines, line 3 replaced.
local function modified_file()
  return {
    path = "a.lua", status = "M", filetype = "lua", binary = false,
    original = { "one", "two", "three", "four", "five" },
    modified = { "one", "two", "THREE", "four", "five" },
    hunks = { {
      id = "a.lua:1", file = "a.lua", header = "@@ -3,1 +3,1 @@",
      text = "@@ -3,1 +3,1 @@\n-three\n+THREE\n",
      original = { start_line = 3, end_line = 4 },
      modified = { start_line = 3, end_line = 4 },
      additions = 1, deletions = 1,
    } },
  }
end

--- A file whose uneven change (1 deletion, 2 additions) forces a filler row,
--- so the map has real holes on the original side.
local function uneven_file()
  return {
    path = "a.lua", status = "M", filetype = "lua", binary = false,
    original = { "one", "two" },
    modified = { "one", "TWO", "EXTRA" },
    hunks = { {
      id = "a.lua:1", file = "a.lua", header = "@@ -2,1 +2,2 @@",
      text = "@@ -2,1 +2,2 @@\n-two\n+TWO\n+EXTRA\n",
      original = { start_line = 2, end_line = 3 },
      modified = { start_line = 2, end_line = 4 },
      additions = 2, deletions = 1,
    } },
  }
end

--- A 20-line file with two one-line hunks, at lines 5 and 15.
local function two_hunk_file()
  local orig, mod = {}, {}
  for i = 1, 20 do
    orig[i] = "line" .. i
    mod[i] = "line" .. i
  end
  mod[5] = "CHANGED5"
  mod[15] = "CHANGED15"
  return {
    path = "a.lua", status = "M", filetype = "lua", binary = false,
    original = orig, modified = mod,
    hunks = {
      { id = "a.lua:1", file = "a.lua", header = "@@ -5,1 +5,1 @@",
        text = "@@ -5,1 +5,1 @@\n-line5\n+CHANGED5\n",
        original = { start_line = 5, end_line = 6 },
        modified = { start_line = 5, end_line = 6 },
        additions = 1, deletions = 1 },
      { id = "a.lua:2", file = "a.lua", header = "@@ -15,1 +15,1 @@",
        text = "@@ -15,1 +15,1 @@\n-line15\n+CHANGED15\n",
        original = { start_line = 15, end_line = 16 },
        modified = { start_line = 15, end_line = 16 },
        additions = 1, deletions = 1 },
    },
  }
end

local function is_folded(p, row)
  for _, range in ipairs(p.folds) do
    if row >= range[1] and row <= range[2] then return true end
  end
  return false
end

describe("plan.build side-by-side", function()
  it("renders the whole file, not just the hunk", function()
    local p = plan.build({ modified_file() }, { ["a.lua:1"] = true }, "side-by-side")
    -- separator + 5 content rows
    assert.equals(6, #p.original.lines)
    assert.equals(6, #p.modified.lines)
    assert.equals("one", p.original.lines[2])
    assert.equals("five", p.original.lines[6])
  end)

  it("keeps both panes the same length", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.equals(#p.original.lines, #p.modified.lines)
  end)

  it("shows the changed line differently on each side", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.equals("three", p.original.lines[4])
    assert.equals("THREE", p.modified.lines[4])
  end)

  it("maps each row to its real file coordinate", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.same({ file = "a.lua", line = 1, side = "old" }, p.original.map[2])
    assert.same({ file = "a.lua", line = 3, side = "old" }, p.original.map[4])
    assert.same({ file = "a.lua", line = 3, side = "new" }, p.modified.map[4])
    assert.same({ file = "a.lua", line = 5, side = "new" }, p.modified.map[6])
  end)

  it("gives the separator row no map entry", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.is_nil(p.original.map[1])
    assert.is_nil(p.modified.map[1])
  end)

  it("puts the path, status and totals on the separator", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local sep = p.modified.lines[1]
    assert.truthy(sep:find("a.lua", 1, true))
    assert.truthy(sep:find("M", 1, true))
    assert.truthy(sep:find("+1", 1, true))
    assert.truthy(sep:find("-1", 1, true))
  end)

  it("pads the short side with fillers on an uneven change", function()
    local p = plan.build({ uneven_file() }, {}, "side-by-side")
    assert.equals(#p.original.lines, #p.modified.lines)
    assert.equals("", p.original.lines[4], "filler row is empty text")
    assert.is_nil(p.original.map[4], "a filler addresses nothing")
    assert.equals("EXTRA", p.modified.lines[4])
    assert.same({ file = "a.lua", line = 3, side = "new" }, p.modified.map[4])
  end)

  it("walks a hunk's leading and trailing context lines with a dual advance", function()
    -- original: one / ctx_before / old / ctx_after / five
    -- modified: one / ctx_before / new / ctx_after / five
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "a1", "ctx_before", "old", "ctx_after", "a5" },
      modified = { "a1", "ctx_before", "new", "ctx_after", "a5" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -2,3 +2,3 @@",
        text = "@@ -2,3 +2,3 @@\n ctx_before\n-old\n+new\n ctx_after\n",
        original = { start_line = 2, end_line = 5 },
        modified = { start_line = 2, end_line = 5 },
        additions = 1, deletions = 1,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    -- separator(1) a1(2) ctx_before(3) old/new(4) ctx_after(5) a5(6)
    assert.equals("ctx_before", p.original.lines[3])
    assert.equals("ctx_before", p.modified.lines[3])
    assert.same({ file = "a.lua", line = 2, side = "old" }, p.original.map[3])
    assert.same({ file = "a.lua", line = 2, side = "new" }, p.modified.map[3])

    assert.equals("old", p.original.lines[4])
    assert.equals("new", p.modified.lines[4])
    assert.same({ file = "a.lua", line = 3, side = "old" }, p.original.map[4])
    assert.same({ file = "a.lua", line = 3, side = "new" }, p.modified.map[4])

    assert.equals("ctx_after", p.original.lines[5])
    assert.equals("ctx_after", p.modified.lines[5])
    assert.same({ file = "a.lua", line = 4, side = "old" }, p.original.map[5])
    assert.same({ file = "a.lua", line = 4, side = "new" }, p.modified.map[5])
  end)

  it("renders the unchanged stretch between two hunks once, with correct coordinates", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "one", "two", "three", "four", "five", "six", "seven" },
      modified = { "one", "two", "THREE", "four", "five", "SIX", "seven" },
      hunks = {
        {
          id = "a.lua:1", file = "a.lua", header = "@@ -3,1 +3,1 @@",
          text = "@@ -3,1 +3,1 @@\n-three\n+THREE\n",
          original = { start_line = 3, end_line = 4 },
          modified = { start_line = 3, end_line = 4 },
          additions = 1, deletions = 1,
        },
        {
          id = "a.lua:2", file = "a.lua", header = "@@ -6,1 +6,1 @@",
          text = "@@ -6,1 +6,1 @@\n-six\n+SIX\n",
          original = { start_line = 6, end_line = 7 },
          modified = { start_line = 6, end_line = 7 },
          additions = 1, deletions = 1,
        },
      },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    -- sep(1) one(2) two(3) three/THREE(4) four(5) five(6) six/SIX(7) seven(8)
    assert.equals("four", p.original.lines[5])
    assert.equals("four", p.modified.lines[5])
    assert.same({ file = "a.lua", line = 4, side = "old" }, p.original.map[5])
    assert.same({ file = "a.lua", line = 4, side = "new" }, p.modified.map[5])

    assert.equals("five", p.original.lines[6])
    assert.equals("five", p.modified.lines[6])
    assert.same({ file = "a.lua", line = 5, side = "old" }, p.original.map[6])
    assert.same({ file = "a.lua", line = 5, side = "new" }, p.modified.map[6])
  end)

  it("drifts the trailing stretch's coordinates apart after a mid-file pure addition", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "one", "two", "three" },
      modified = { "one", "INSERTED", "two", "three" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,0 +2,1 @@",
        text = "@@ -1,0 +2,1 @@\n+INSERTED\n",
        original = { start_line = 2, end_line = 2 }, -- zero-width anchor
        modified = { start_line = 2, end_line = 3 },
        additions = 1, deletions = 0,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    -- sep(1) one(2) INSERTED(3, filler on original) two(4) three(5)
    assert.equals("two", p.original.lines[4])
    assert.equals("two", p.modified.lines[4])
    -- original line 2 now pairs with modified line 3: the drift comment
    -- anchoring depends on.
    assert.same({ file = "a.lua", line = 2, side = "old" }, p.original.map[4])
    assert.same({ file = "a.lua", line = 3, side = "new" }, p.modified.map[4])

    assert.equals("three", p.original.lines[5])
    assert.equals("three", p.modified.lines[5])
    assert.same({ file = "a.lua", line = 3, side = "old" }, p.original.map[5])
    assert.same({ file = "a.lua", line = 4, side = "new" }, p.modified.map[5])
  end)

  it("never lets a filler row on the tail claim a coordinate the shorter side does not have", function()
    -- No hunks at all: a pathological (but directly constructible) file
    -- entry whose original side simply outruns its modified side. Exercises
    -- the trailing `unchanged()` walk, not a hunk's own pairing.
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "a", "b", "c", "d", "e" },
      modified = { "x", "y" },
      hunks = {},
    }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.equals(#p.original.lines, #p.modified.lines)
    -- sep(1) a/x(2) b/y(3) c/-(4) d/-(5) e/-(6)
    assert.equals("c", p.original.lines[4])
    assert.equals("", p.modified.lines[4], "modified has no 3rd line to show")
    assert.same({ file = "a.lua", line = 3, side = "old" }, p.original.map[4])
    assert.is_nil(p.modified.map[4], "must not claim a modified coordinate that does not exist")

    assert.equals("d", p.original.lines[5])
    assert.is_nil(p.modified.map[5])
    assert.equals("e", p.original.lines[6])
    assert.is_nil(p.modified.map[6])
  end)

  it("records where a multi-line changed run landed in both panes", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "one", "alpha", "beta", "four" },
      modified = { "one", "ALPHA", "BETA", "four" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -2,2 +2,2 @@",
        text = "@@ -2,2 +2,2 @@\n-alpha\n-beta\n+ALPHA\n+BETA\n",
        original = { start_line = 2, end_line = 4 },
        modified = { start_line = 2, end_line = 4 },
        additions = 2, deletions = 2,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.equals(1, #p.runs)
    local run = p.runs[1]
    assert.equals("a.lua", run.file)
    assert.same({ "alpha", "beta" }, run.minus)
    assert.same({ "ALPHA", "BETA" }, run.plus)
    assert.equals(2, #run.minus_rows)
    assert.equals(2, #run.plus_rows)
    for i, text in ipairs(run.minus) do
      assert.equals(text, p.original.lines[run.minus_rows[i]])
    end
    for i, text in ipairs(run.plus) do
      assert.equals(text, p.modified.lines[run.plus_rows[i]])
    end
  end)

  it("falls back to hunk-only rows when a file's full content was not fetched", function()
    local file = {
      path = "stale.lua", status = "M", filetype = "lua", binary = false,
      -- original/modified deliberately absent: content could not be fetched.
      hunks = { {
        id = "stale.lua:1", file = "stale.lua", header = "@@ -5,1 +5,1 @@",
        text = "@@ -5,1 +5,1 @@\n-old\n+new\n",
        original = { start_line = 5, end_line = 6 },
        modified = { start_line = 5, end_line = 6 },
        additions = 1, deletions = 1,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.is_true(p.files[1].fallback)
    -- separator + just the hunk's own row, not a whole-file walk.
    assert.equals(2, #p.original.lines)
    assert.equals("old", p.original.lines[2])
    assert.equals("new", p.modified.lines[2])
    assert.same({ file = "stale.lua", line = 5, side = "old" }, p.original.map[2])
    assert.same({ file = "stale.lua", line = 5, side = "new" }, p.modified.map[2])
  end)

  it("renders an added file as all-fillers on the original side", function()
    local file = {
      path = "new.lua", status = "A", filetype = "lua", binary = false,
      original = {},
      modified = { "fresh", "code" },
      hunks = { {
        id = "new.lua:1", file = "new.lua", header = "@@ -0,0 +1,2 @@",
        text = "@@ -0,0 +1,2 @@\n+fresh\n+code\n",
        original = { start_line = 1, end_line = 1 },
        modified = { start_line = 1, end_line = 3 },
        additions = 2, deletions = 0,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.equals(3, #p.original.lines)
    assert.equals("", p.original.lines[2])
    assert.equals("", p.original.lines[3])
    assert.equals("fresh", p.modified.lines[2])
    assert.is_nil(p.original.map[2])
    assert.same({ file = "new.lua", line = 1, side = "new" }, p.modified.map[2])
  end)

  it("renders a deleted file as all-fillers on the modified side", function()
    local file = {
      path = "gone.lua", status = "D", filetype = "lua", binary = false,
      original = { "bye", "now" },
      modified = {},
      hunks = { {
        id = "gone.lua:1", file = "gone.lua", header = "@@ -1,2 +0,0 @@",
        text = "@@ -1,2 +0,0 @@\n-bye\n-now\n",
        original = { start_line = 1, end_line = 3 },
        modified = { start_line = 1, end_line = 1 },
        additions = 0, deletions = 2,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.equals("bye", p.original.lines[2])
    assert.equals("", p.modified.lines[2])
    assert.same({ file = "gone.lua", line = 1, side = "old" }, p.original.map[2])
    assert.is_nil(p.modified.map[2])
  end)

  it("concatenates several files in order, each with its own separator", function()
    local a = modified_file()
    local b = {
      path = "b.lua", status = "M", filetype = "lua", binary = false,
      original = { "x" }, modified = { "X" },
      hunks = { {
        id = "b.lua:1", file = "b.lua", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n-x\n+X\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
    local p = plan.build({ a, b }, {}, "side-by-side")
    assert.truthy(p.modified.lines[1]:find("a.lua", 1, true))
    assert.truthy(p.modified.lines[7]:find("b.lua", 1, true))
    assert.same({ file = "b.lua", line = 1, side = "new" }, p.modified.map[8])
    assert.equals(2, #p.files)
    assert.equals("a.lua", p.files[1].path)
  end)

  it("renders a binary file as one marker row addressing nothing", function()
    local file = { path = "logo.png", status = "M", filetype = "", binary = true,
                   original = {}, modified = {}, hunks = {} }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.equals(1, #p.original.lines, "binary skips the row loop but must still keep panes equal")
    assert.equals(1, #p.modified.lines)
    assert.truthy(p.modified.lines[1]:find("binary", 1, true))
    assert.is_nil(p.original.map[1])
    assert.is_nil(p.modified.map[1])
  end)

  it("marks the add and delete rows with the right highlight groups", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local function hl_at(pane, row)
      for _, s in ipairs(pane.spans) do
        if s.line == row then return s.hl end
      end
    end
    assert.equals("IntentDiffDelete", hl_at(p.original, 4))
    assert.equals("IntentDiffAdd", hl_at(p.modified, 4))
    assert.equals("IntentDiffFileSeparator", hl_at(p.modified, 1))
    assert.is_nil(hl_at(p.modified, 2), "unchanged rows carry no line highlight")
  end)
end)

describe("plan.target_at and plan.rows_for", function()
  it("resolves a row to its coordinate", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.same({ file = "a.lua", line = 3, side = "new" },
      plan.target_at(p.modified, 4))
    assert.is_nil(plan.target_at(p.modified, 1))
  end)

  it("finds every row a multi-line comment covers", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local rows = plan.rows_for(p.modified, {
      file = "a.lua", line = 1, line_end = 3, side = "new",
    })
    assert.same({ 2, 3, 4 }, rows)
  end)

  it("is the exact inverse of target_at over the whole pane, fillers included, both sides", function()
    -- Fillers matter here: a naive rows_for that just returned "every row"
    -- would still pass an all-1:1 fixture, so this must have holes in the
    -- map on the short side, and must be checked on BOTH panes.
    local p = plan.build({ uneven_file() }, {}, "side-by-side")
    for _, pane in ipairs({ p.original, p.modified }) do
      for row = 1, #pane.lines do
        local t = plan.target_at(pane, row)
        if t then
          local rows = plan.rows_for(pane, { file = t.file, line = t.line, side = t.side })
          assert.truthy(vim.tbl_contains(rows, row),
            ("row %d maps to %s:%d but rows_for did not return it"):format(row, t.file, t.line))
        end
      end
    end
  end)

  it("returns no rows for a file-level or intent comment", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    assert.same({}, plan.rows_for(p.modified, { file = "a.lua", line = 0, side = "new" }))
    assert.same({}, plan.rows_for(p.modified,
      { file = "a.lua", line = 3, side = "new", intent_title = "Auth" }))
  end)
end)

describe("plan.build inline", function()
  it("puts every row in one pane and leaves the original pane empty", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    assert.equals("inline", p.layout)
    assert.is_nil(p.original)
    -- separator + 2 context + delete + add + 2 context
    assert.equals(7, #p.modified.lines)
  end)

  it("shows the deletion and the addition as separate rows", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    assert.equals("three", p.modified.lines[4])
    assert.equals("THREE", p.modified.lines[5])
  end)

  it("addresses a deletion row to the old side and everything else to new", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    assert.same({ file = "a.lua", line = 2, side = "new" }, p.modified.map[3])
    assert.same({ file = "a.lua", line = 3, side = "old" }, p.modified.map[4])
    assert.same({ file = "a.lua", line = 3, side = "new" }, p.modified.map[5])
    assert.same({ file = "a.lua", line = 4, side = "new" }, p.modified.map[6])
  end)

  it("emits no filler rows at all", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "one", "two" },
      modified = { "one", "TWO", "EXTRA" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -2,1 +2,2 @@",
        text = "@@ -2,1 +2,2 @@\n-two\n+TWO\n+EXTRA\n",
        original = { start_line = 2, end_line = 3 },
        modified = { start_line = 2, end_line = 4 },
        additions = 2, deletions = 1,
      } },
    }
    local p = plan.build({ file }, {}, "inline")
    for _, s in ipairs(p.modified.spans) do
      assert.not_equals("IntentDiffFiller", s.hl)
    end
    -- separator, context "one", "-two", "+TWO", "+EXTRA"
    assert.equals(5, #p.modified.lines)
  end)

  it("records run rows in inline coordinates", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    assert.equals(1, #p.runs)
    assert.same({ 4 }, p.runs[1].minus_rows)
    assert.same({ 5 }, p.runs[1].plus_rows)
  end)

  it("is still the exact inverse of target_at", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    for row = 1, #p.modified.lines do
      local t = plan.target_at(p.modified, row)
      if t then
        local rows = plan.rows_for(p.modified, { file = t.file, line = t.line, side = t.side })
        assert.truthy(vim.tbl_contains(rows, row))
      end
    end
  end)
end)

describe("plan.build folds", function()
  it("leaves a visible hunk and its context unfolded", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    -- row 1 is the separator; file line N is row N+1
    assert.is_false(is_folded(p, 6), "the changed line itself")
    assert.is_false(is_folded(p, 4), "2 lines of context above")
    assert.is_false(is_folded(p, 8), "2 lines of context below")
  end)

  it("folds everything outside the visible hunk", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    assert.is_true(is_folded(p, 2), "far above the hunk")
    assert.is_true(is_folded(p, 16), "the other hunk is not visible")
    assert.is_true(is_folded(p, 21), "far below")
  end)

  it("never folds a separator row", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    assert.is_false(is_folded(p, 1))
  end)

  it("keeps both hunks open when both are visible", function()
    local p = plan.build({ two_hunk_file() },
      { ["a.lua:1"] = true, ["a.lua:2"] = true }, "side-by-side", { context = 2 })
    assert.is_false(is_folded(p, 6))
    assert.is_false(is_folded(p, 16))
    assert.is_true(is_folded(p, 10), "the stretch between them still folds")
  end)

  it("folds nothing when no hunk is visible", function()
    local p = plan.build({ two_hunk_file() }, {}, "side-by-side", { context = 2 })
    assert.same({}, p.folds)
  end)

  it("produces fold ranges valid for both panes", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    assert.equals(#p.original.lines, #p.modified.lines)
    for _, range in ipairs(p.folds) do
      assert.is_true(range[2] <= #p.original.lines)
      assert.is_true(range[1] >= 1)
    end
  end)

  it("emits maximal runs, never two adjacent ranges", function()
    local p = plan.build({ two_hunk_file() },
      { ["a.lua:1"] = true, ["a.lua:2"] = true }, "side-by-side", { context = 2 })
    -- sep(1) protected, rows 4..8 and 14..18 kept, 21 rows in all
    assert.same({ { 2, 3 }, { 9, 13 }, { 19, 21 } }, p.folds)
  end)

  it("defaults context to 3 when opts says nothing", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true }, "side-by-side")
    -- the hunk is row 6; 3 rows of context reach rows 3 and 9
    assert.is_false(is_folded(p, 3), "3 rows of context above")
    assert.is_false(is_folded(p, 9), "3 rows of context below")
    assert.is_true(is_folded(p, 2), "but not a 4th")
    assert.is_true(is_folded(p, 10))
  end)

  it("keeps a second file's visible hunk open at its own offset", function()
    local a, b = two_hunk_file(), two_hunk_file()
    b.path = "b.lua"
    for _, h in ipairs(b.hunks) do
      h.file = "b.lua"
      h.id = h.id:gsub("^a%.lua", "b.lua")
    end
    local p = plan.build({ a, b }, { ["b.lua:1"] = true }, "side-by-side",
      { context = 2 })
    -- a.lua: sep(1) + 20 rows, so b.lua's separator is row 22 and its line N is row 22+N
    assert.truthy(p.modified.lines[22]:find("b.lua", 1, true))
    assert.is_false(is_folded(p, 27), "b.lua's changed line")
    assert.is_false(is_folded(p, 1), "a.lua's separator")
    assert.is_false(is_folded(p, 22), "b.lua's separator")
    assert.is_true(is_folded(p, 6), "a.lua's hunk is not visible")
  end)

  it("folds an inline plan by emitted rows, not by file rows", function()
    -- Inline emits TWO rows for a 1-for-1 change, so a fold computed from a
    -- flat file-row offset drifts by one row per changed run before it.
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "inline", { context = 2 })
    -- sep(1) line1..4(2..5) -line5(6) +CHANGED5(7) line6..(8..)
    assert.equals("line5", p.modified.lines[6])
    assert.equals("CHANGED5", p.modified.lines[7])
    assert.is_false(is_folded(p, 6), "the deletion row")
    assert.is_false(is_folded(p, 7), "the addition row")
    assert.is_false(is_folded(p, 4), "2 rows of context above")
    assert.is_false(is_folded(p, 9), "2 rows of context below the addition")
    assert.is_true(is_folded(p, 3), "a 3rd row above still folds")
    assert.is_true(is_folded(p, 10), "a 3rd row below still folds")
    for _, range in ipairs(p.folds) do
      assert.is_true(range[2] <= #p.modified.lines)
    end
  end)
end)

describe("plan.build fallback", function()
  it("renders hunks only when content is missing and disables its folds", function()
    local file = two_hunk_file()
    file.original, file.modified = nil, nil
    local p = plan.build({ file }, { ["a.lua:1"] = true }, "side-by-side", { context = 2 })
    assert.is_true(p.files[1].fallback)
    assert.same({}, p.folds, "a partial render must not fold")
    -- separator + the two hunks' rows only, not 20 lines
    assert.is_true(#p.modified.lines < 10)
  end)

  it("says on the separator that the content was unavailable", function()
    local file = two_hunk_file()
    file.original, file.modified = nil, nil
    local p = plan.build({ file }, { ["a.lua:1"] = true }, "side-by-side", { context = 2 })
    assert.truthy(p.modified.lines[1]:find("content unavailable", 1, true))
  end)

  it("falls back and says so when a file exceeds the line budget", function()
    local file = two_hunk_file()
    local p = plan.build({ file }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2, line_budget = 5 })
    assert.is_true(p.files[1].fallback)
    assert.truthy(p.modified.lines[1]:find("budget", 1, true),
      "the separator states why it fell back")
    assert.same({}, p.folds)
  end)

  it("does not fall back when the file fits the budget", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2, line_budget = 20000 })
    assert.is_false(p.files[1].fallback)
  end)

  it("defaults the line budget to 20000", function()
    local p = plan.build({ two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    assert.is_false(p.files[1].fallback)
    assert.is_nil(p.modified.lines[1]:find("budget", 1, true))
  end)

  it("disables folds for the whole plan when any one file fell back", function()
    local whole = two_hunk_file()
    local partial = two_hunk_file()
    partial.path = "b.lua"
    partial.original, partial.modified = nil, nil
    for _, h in ipairs(partial.hunks) do
      h.file = "b.lua"
      h.id = h.id:gsub("^a%.lua", "b.lua")
    end
    local p = plan.build({ whole, partial }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    assert.is_false(p.files[1].fallback)
    assert.is_true(p.files[2].fallback)
    assert.same({}, p.folds,
      "a fold range spans the whole pane, so one partial file disables every fold")
  end)

  it("leaves a binary file's marker row unfolded without disabling folds", function()
    local bin = { path = "logo.png", status = "M", filetype = "", binary = true,
                  original = {}, modified = {}, hunks = {} }
    local p = plan.build({ bin, two_hunk_file() }, { ["a.lua:1"] = true },
      "side-by-side", { context = 2 })
    assert.is_false(p.files[1].fallback)
    assert.is_true(#p.folds > 0, "a binary file must not disable the plan's folds")
    assert.is_false(is_folded(p, 1), "the binary marker row")
    assert.is_false(is_folded(p, 2), "a.lua's separator")
  end)
end)
