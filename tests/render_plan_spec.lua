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
    local p = plan.build({ file }, {}, "side-by-side")
    assert.equals(#p.original.lines, #p.modified.lines)
    assert.equals("", p.original.lines[4], "filler row is empty text")
    assert.is_nil(p.original.map[4], "a filler addresses nothing")
    assert.equals("EXTRA", p.modified.lines[4])
    assert.same({ file = "a.lua", line = 3, side = "new" }, p.modified.map[4])
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
    assert.equals(1, #p.modified.lines)
    assert.truthy(p.modified.lines[1]:find("binary", 1, true))
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

  it("is the exact inverse of target_at over the whole pane", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    for row = 1, #p.modified.lines do
      local t = plan.target_at(p.modified, row)
      if t then
        local rows = plan.rows_for(p.modified, { file = t.file, line = t.line, side = t.side })
        assert.truthy(vim.tbl_contains(rows, row),
          ("row %d maps to %s:%d but rows_for did not return it"):format(row, t.file, t.line))
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
