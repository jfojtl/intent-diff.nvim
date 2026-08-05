local preview = require("intentdiff.preview")

local function hunk(header, body, additions, deletions)
  return {
    header = header,
    text = header .. "\n" .. table.concat(body, "\n") .. "\n",
    additions = additions,
    deletions = deletions,
    modified = { start_line = 1, end_line = 2 },
    original = { start_line = 1, end_line = 2 },
  }
end

local function group()
  local h1 = hunk("@@ -1,2 +1,3 @@", { " keep", "-old", "+new", "+extra" }, 2, 1)
  local h2 = hunk("@@ -10,1 +11,1 @@", { "-gone", "+arrived" }, 1, 1)
  return {
    title = "Auth",
    hunks = { h1, h2 },
    files = {
      { path = "src/auth.lua", status = "M", hunks = { h1 } },
      { path = "new.lua", status = "A", hunks = { h2 } },
    },
  }
end

describe("preview.render inline", function()
  it("emits a separator per file followed by its hunks", function()
    local r = preview.render(group(), "inline", {})
    assert.equals("inline", r.layout)
    local text = table.concat(r.modified.lines, "\n")
    assert.truthy(text:find("src/auth.lua", 1, true))
    assert.truthy(text:find("new.lua", 1, true))
    assert.truthy(text:find("@@ -1,2 +1,3 @@", 1, true))
    assert.truthy(text:find("+new", 1, true))
  end)

  it("shows the status and +/- totals on each separator", function()
    local r = preview.render(group(), "inline", {})
    local sep = vim.tbl_filter(function(l)
      return l:find("src/auth.lua", 1, true)
    end, r.modified.lines)[1]
    assert.truthy(sep:find("M", 1, true))
    assert.truthy(sep:find("+2", 1, true))
    assert.truthy(sep:find("-1", 1, true))
  end)

  it("orders files the same way the sidebar tree does", function()
    local r = preview.render(group(), "inline", {})
    local auth_i, new_i
    for i, l in ipairs(r.modified.lines) do
      if l:find("src/auth.lua", 1, true) then auth_i = i end
      if l:find("new.lua", 1, true) then new_i = i end
    end
    -- tree order puts the src/ directory before the root-level file
    assert.is_true(auth_i < new_i)
  end)

  it("orders files by tree structure, not by the fixture's array order", function()
    -- The fixture array deliberately lists the root-level file FIRST and the
    -- directory entry SECOND — the opposite of tree order (dirs sort before
    -- root-level files). A naive `ipairs(group.files)` implementation would
    -- render root.lua first; the tree-based implementation must not.
    local h1 = hunk("@@ -1,1 +1,1 @@", { "-a", "+b" }, 1, 1)
    local h2 = hunk("@@ -1,1 +1,1 @@", { "-c", "+d" }, 1, 1)
    local g = {
      title = "T",
      hunks = { h1, h2 },
      files = {
        { path = "root.lua", status = "M", hunks = { h1 } },
        { path = "dir/nested.lua", status = "A", hunks = { h2 } },
      },
    }
    local r = preview.render(g, "inline", {})
    local root_i, nested_i
    for i, l in ipairs(r.modified.lines) do
      if l:find("root.lua", 1, true) then root_i = i end
      if l:find("dir/nested.lua", 1, true) then nested_i = i end
    end
    assert.truthy(root_i)
    assert.truthy(nested_i)
    assert.is_true(nested_i < root_i)
  end)

  it("reports the lines carrying hunk headers", function()
    local r = preview.render(group(), "inline", {})
    assert.equals(2, #r.hunk_lines)
    for _, lnum in ipairs(r.hunk_lines) do
      assert.truthy(r.modified.lines[lnum]:find("^@@"))
    end
  end)

  it("highlights added, deleted, header and separator lines", function()
    local r = preview.render(group(), "inline", {})
    local seen = {}
    for _, s in ipairs(r.modified.highlights) do seen[s.hl] = true end
    assert.is_true(seen.IntentDiffAdd)
    assert.is_true(seen.IntentDiffDelete)
    assert.is_true(seen.IntentDiffPreviewHunk)
    assert.is_true(seen.IntentDiffFileSeparator)
  end)
end)

describe("preview.render side-by-side", function()
  it("returns two panes of equal length", function()
    local r = preview.render(group(), "side-by-side", {})
    assert.equals("side-by-side", r.layout)
    assert.equals(#r.original.lines, #r.modified.lines)
  end)

  it("pairs a deletion run with the following addition run", function()
    local h = hunk("@@ -1,2 +1,3 @@", { "-a", "-b", "+x", "+y", "+z" }, 3, 2)
    local g = { title = "T", hunks = { h },
      files = { { path = "f.lua", status = "M", hunks = { h } } } }
    local r = preview.render(g, "side-by-side", {})
    -- find the row where the first deletion sits
    local row
    for i, l in ipairs(r.original.lines) do
      if l == "a" then row = i end
    end
    assert.truthy(row)
    assert.equals("x", r.modified.lines[row])
    assert.equals("b", r.original.lines[row + 1])
    assert.equals("y", r.modified.lines[row + 1])
    -- third addition has no counterpart: filler on the original side
    assert.equals("", r.original.lines[row + 2])
    assert.equals("z", r.modified.lines[row + 2])
  end)

  it("marks filler rows so they read as absent, not empty", function()
    local h = hunk("@@ -1,1 +1,2 @@", { "-a", "+x", "+y" }, 2, 1)
    local g = { title = "T", hunks = { h },
      files = { { path = "f.lua", status = "M", hunks = { h } } } }
    local r = preview.render(g, "side-by-side", {})
    local filler = vim.tbl_filter(function(s) return s.hl == "IntentDiffFiller" end,
      r.original.highlights)
    assert.is_true(#filler > 0)
  end)

  it("emits context lines on both sides", function()
    local r = preview.render(group(), "side-by-side", {})
    local o = vim.tbl_filter(function(l) return l == "keep" end, r.original.lines)
    local m = vim.tbl_filter(function(l) return l == "keep" end, r.modified.lines)
    assert.equals(1, #o)
    assert.equals(1, #m)
  end)

  it("highlights a plain 1-for-1 replacement, not just runs with fillers", function()
    -- The commonest diff shape: one deletion immediately paired with one
    -- addition, no length mismatch and so no filler row anywhere nearby.
    local h = hunk("@@ -1,3 +1,3 @@", { " ctx", "-old", "+new", " ctx2" }, 1, 1)
    local g = { title = "T", hunks = { h },
      files = { { path = "f.lua", status = "M", hunks = { h } } } }
    local r = preview.render(g, "side-by-side", {})
    local row
    for i, l in ipairs(r.original.lines) do
      if l == "old" then row = i end
    end
    assert.truthy(row)
    assert.equals("new", r.modified.lines[row])
    local orig_hl, mod_hl
    for _, s in ipairs(r.original.highlights) do
      if s.line == row then orig_hl = s.hl end
    end
    for _, s in ipairs(r.modified.highlights) do
      if s.line == row then mod_hl = s.hl end
    end
    assert.equals("IntentDiffDelete", orig_hl)
    assert.equals("IntentDiffAdd", mod_hl)
  end)
end)

-- The row → (file, line, side) map that makes the preview commentable.
--
-- These fixtures go through `hunks.parse` rather than hand-writing hunk
-- records: the map is computed from `hunk.original/modified.start_line`, and a
-- hand-written record whose ranges disagree with its own `@@` header (as the
-- fixture at the top of this file's do) would let a wrong implementation pass.
describe("preview.render line mapping", function()
  local hunks = require("intentdiff.hunks")

  --- A group built from real unified-diff text, so headers and ranges agree.
  local function group_from(diff)
    local hs, files = hunks.parse(diff)
    local by_path = {}
    for _, f in ipairs(files) do
      f.hunks = {}
      by_path[f.path] = f
    end
    for _, h in ipairs(hs) do
      table.insert(by_path[h.file].hunks, h)
    end
    return { title = "T", hunks = hs, files = files }
  end

  --- Two files. The SECOND one's hunk starts at line 120 (old) / 140 (new) —
  --- far from 1 and from each other, so a dropped per-hunk offset, a reused
  --- old counter or an off-by-one is caught rather than masked by small
  --- numbers that happen to coincide.
  local DIFF = table.concat({
    "diff --git a/src/auth.lua b/src/auth.lua",
    "@@ -1,3 +1,4 @@",
    " keep",
    "-old",
    "+new",
    "+extra",
    "diff --git a/zz/late.lua b/zz/late.lua",
    "@@ -120,3 +140,3 @@",
    " ctx a",
    "-gone",
    "+arrived",
    " ctx b",
    "",
  }, "\n")

  --- The single row of `pane` whose text is exactly `text`.
  local function row_of(pane, text)
    local found
    for i, l in ipairs(pane.lines) do
      if l == text then
        assert.is_nil(found, "ambiguous row for " .. text)
        found = i
      end
    end
    assert.truthy(found, "no row for " .. text)
    return found
  end

  describe("inline", function()
    local pane
    before_each(function()
      pane = preview.render(group_from(DIFF), "inline", {}).modified
    end)

    it("maps a - row to the old side and a + row to the new side", function()
      assert.same({ file = "src/auth.lua", line = 2, side = "old" },
        preview.target_at(pane, row_of(pane, "-old")))
      assert.same({ file = "src/auth.lua", line = 2, side = "new" },
        preview.target_at(pane, row_of(pane, "+new")))
      assert.same({ file = "src/auth.lua", line = 3, side = "new" },
        preview.target_at(pane, row_of(pane, "+extra")))
    end)

    it("maps a context row to the new side", function()
      assert.same({ file = "src/auth.lua", line = 1, side = "new" },
        preview.target_at(pane, row_of(pane, " keep")))
    end)

    it("maps separators and @@ headers to nothing", function()
      local sep, header
      for i, l in ipairs(pane.lines) do
        if l:find("src/auth.lua", 1, true) then sep = i end
        if l == "@@ -1,3 +1,4 @@" then header = i end
      end
      assert.is_nil(preview.target_at(pane, sep))
      assert.is_nil(preview.target_at(pane, header))
    end)

    -- The load-bearing one: exact numbers for a file whose hunk starts high.
    it("counts each hunk from ITS OWN @@ start, not from the buffer row", function()
      assert.same({ file = "zz/late.lua", line = 140, side = "new" },
        preview.target_at(pane, row_of(pane, " ctx a")))
      assert.same({ file = "zz/late.lua", line = 121, side = "old" },
        preview.target_at(pane, row_of(pane, "-gone")))
      assert.same({ file = "zz/late.lua", line = 141, side = "new" },
        preview.target_at(pane, row_of(pane, "+arrived")))
      -- Context consumes a line on BOTH sides: getting that wrong leaves this
      -- at 141.
      assert.same({ file = "zz/late.lua", line = 142, side = "new" },
        preview.target_at(pane, row_of(pane, " ctx b")))
    end)
  end)

  describe("side-by-side", function()
    local rendered
    before_each(function()
      rendered = preview.render(group_from(DIFF), "side-by-side", {})
    end)

    it("addresses old-side lines in the original pane", function()
      local pane = rendered.original
      assert.same({ file = "src/auth.lua", line = 2, side = "old" },
        preview.target_at(pane, row_of(pane, "old")))
      assert.same({ file = "src/auth.lua", line = 1, side = "old" },
        preview.target_at(pane, row_of(pane, "keep")))
    end)

    it("addresses new-side lines in the modified pane", function()
      local pane = rendered.modified
      assert.same({ file = "src/auth.lua", line = 2, side = "new" },
        preview.target_at(pane, row_of(pane, "new")))
      assert.same({ file = "src/auth.lua", line = 3, side = "new" },
        preview.target_at(pane, row_of(pane, "extra")))
    end)

    it("counts each hunk from ITS OWN @@ start, per pane", function()
      assert.same({ file = "zz/late.lua", line = 120, side = "old" },
        preview.target_at(rendered.original, row_of(rendered.original, "ctx a")))
      assert.same({ file = "zz/late.lua", line = 121, side = "old" },
        preview.target_at(rendered.original, row_of(rendered.original, "gone")))
      assert.same({ file = "zz/late.lua", line = 122, side = "old" },
        preview.target_at(rendered.original, row_of(rendered.original, "ctx b")))
      assert.same({ file = "zz/late.lua", line = 140, side = "new" },
        preview.target_at(rendered.modified, row_of(rendered.modified, "ctx a")))
      assert.same({ file = "zz/late.lua", line = 141, side = "new" },
        preview.target_at(rendered.modified, row_of(rendered.modified, "arrived")))
      assert.same({ file = "zz/late.lua", line = 142, side = "new" },
        preview.target_at(rendered.modified, row_of(rendered.modified, "ctx b")))
    end)

    it("maps a filler row to nothing", function()
      -- "+extra" has no counterpart, so the original pane carries a filler
      -- opposite it.
      local row = row_of(rendered.modified, "extra")
      assert.equals("", rendered.original.lines[row])
      assert.is_nil(preview.target_at(rendered.original, row))
      assert.same({ file = "src/auth.lua", line = 3, side = "new" },
        preview.target_at(rendered.modified, row))
    end)

    it("maps separators and @@ headers to nothing in both panes", function()
      for _, pane in ipairs({ rendered.original, rendered.modified }) do
        for i, l in ipairs(pane.lines) do
          if l:find("^──") or l:find("^@@") then
            assert.is_nil(preview.target_at(pane, i))
          end
        end
      end
    end)
  end)

  describe("rows_for (the inverse direction)", function()
    it("finds the row a comment's (file, line, side) renders on", function()
      local pane = preview.render(group_from(DIFF), "inline", {}).modified
      local rows = preview.rows_for(pane,
        { file = "zz/late.lua", line = 141, side = "new" })
      assert.equals(1, #rows)
      assert.equals("+arrived", pane.lines[rows[1]])
    end)

    it("agrees with target_at for every mapped row", function()
      local pane = preview.render(group_from(DIFF), "inline", {}).modified
      for row = 1, #pane.lines do
        local t = preview.target_at(pane, row)
        if t then
          assert.same({ row }, preview.rows_for(pane, t),
            "row " .. row .. " disagrees with its own target")
        end
      end
    end)

    it("spans every row of a range comment", function()
      local pane = preview.render(group_from(DIFF), "inline", {}).modified
      local rows = preview.rows_for(pane,
        { file = "src/auth.lua", line = 1, line_end = 3, side = "new" })
      assert.equals(3, #rows)
      assert.same({ " keep", "+new", "+extra" },
        { pane.lines[rows[1]], pane.lines[rows[2]], pane.lines[rows[3]] })
    end)

    it("answers nothing for a file the preview does not show", function()
      local pane = preview.render(group_from(DIFF), "inline", {}).modified
      assert.same({}, preview.rows_for(pane,
        { file = "elsewhere.lua", line = 2, side = "new" }))
    end)

    it("answers nothing for a line past the truncation cut", function()
      local pane = preview.render(group_from(DIFF), "inline", { max_lines = 4 }).modified
      assert.equals(4, #pane.lines)
      assert.same({}, preview.rows_for(pane,
        { file = "zz/late.lua", line = 141, side = "new" }))
      for row = 1, #pane.lines do
        local t = preview.target_at(pane, row)
        assert.is_true(t == nil or pane.lines[row]:find("more line", 1, true) == nil)
      end
    end)

    it("answers nothing for a file-level or intent comment", function()
      local pane = preview.render(group_from(DIFF), "inline", {}).modified
      assert.same({}, preview.rows_for(pane, { file = "src/auth.lua", line = 0 }))
      assert.same({}, preview.rows_for(pane, { intent_title = "T" }))
    end)
  end)
end)

describe("preview.render limits", function()
  it("truncates both panes identically and says so", function()
    local body = {}
    for i = 1, 500 do body[#body + 1] = "+line " .. i end
    local h = hunk("@@ -0,0 +1,500 @@", body, 500, 0)
    local g = { title = "T", hunks = { h },
      files = { { path = "f.lua", status = "A", hunks = { h } } } }
    local r = preview.render(g, "side-by-side", { max_lines = 50 })
    assert.equals(50, #r.modified.lines)
    assert.equals(50, #r.original.lines)
    assert.truthy(r.modified.lines[50]:find("more line", 1, true),
      "truncation must be stated, not silent")
  end)

  it("renders an empty group as a single explanatory line", function()
    local r = preview.render({ title = "T", hunks = {}, files = {} }, "inline", {})
    assert.equals(1, #r.modified.lines)
    assert.truthy(r.modified.lines[1]:find("no changes", 1, true))
  end)

  local function many_files_group(n)
    local hunks, files = {}, {}
    for i = 1, n do
      local h = hunk(("@@ -%d,1 +%d,1 @@"):format(i, i), { "-old" .. i, "+new" .. i }, 1, 1)
      hunks[#hunks + 1] = h
      files[#files + 1] = { path = ("file%02d.lua"):format(i), status = "M", hunks = { h } }
    end
    return { title = "T", hunks = hunks, files = files }
  end

  it("drops hunk_lines entries that fall past a truncated inline buffer", function()
    local r = preview.render(many_files_group(30), "inline", { max_lines = 20 })
    assert.equals(20, #r.modified.lines)
    assert.is_true(#r.hunk_lines > 0)
    for _, lnum in ipairs(r.hunk_lines) do
      assert.is_true(lnum <= #r.modified.lines,
        "hunk_lines entry " .. lnum .. " is out of range")
      assert.truthy(r.modified.lines[lnum]:find("^@@"),
        "hunk_lines entry " .. lnum .. " does not point at a real header")
    end
  end)

  it("drops hunk_lines entries that fall past a truncated side-by-side buffer", function()
    local r = preview.render(many_files_group(30), "side-by-side", { max_lines = 20 })
    assert.equals(20, #r.modified.lines)
    assert.equals(20, #r.original.lines)
    assert.is_true(#r.hunk_lines > 0)
    for _, lnum in ipairs(r.hunk_lines) do
      assert.is_true(lnum <= #r.modified.lines,
        "hunk_lines entry " .. lnum .. " is out of range")
      assert.truthy(r.modified.lines[lnum]:find("^@@"),
        "hunk_lines entry " .. lnum .. " does not point at a real header")
    end
  end)

  it("clamps a max_lines of 1 to a single summary line instead of ignoring it", function()
    local body = {}
    for i = 1, 100 do body[#body + 1] = "+line " .. i end
    local h = hunk("@@ -0,0 +1,100 @@", body, 100, 0)
    local g = { title = "T", hunks = { h },
      files = { { path = "f.lua", status = "A", hunks = { h } } } }
    local r = preview.render(g, "side-by-side", { max_lines = 1 })
    assert.equals(1, #r.modified.lines)
    assert.equals(1, #r.original.lines)
    assert.truthy(r.modified.lines[1]:find("more line", 1, true))
  end)

  it("clamps a max_lines of 0 to a single summary line instead of ignoring it", function()
    local body = {}
    for i = 1, 100 do body[#body + 1] = "+line " .. i end
    local h = hunk("@@ -0,0 +1,100 @@", body, 100, 0)
    local g = { title = "T", hunks = { h },
      files = { { path = "f.lua", status = "A", hunks = { h } } } }
    local r = preview.render(g, "side-by-side", { max_lines = 0 })
    assert.equals(1, #r.modified.lines)
    assert.equals(1, #r.original.lines)
    assert.truthy(r.modified.lines[1]:find("more line", 1, true))
  end)
end)
