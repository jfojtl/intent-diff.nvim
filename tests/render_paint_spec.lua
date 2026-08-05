local plan = require("intentdiff.render.plan")
local paint = require("intentdiff.render.paint")

local function modified_file()
  return {
    path = "a.lua", status = "M", filetype = "lua", binary = false,
    original = { "one", "two", "three" },
    modified = { "one", "TWO", "three" },
    hunks = { {
      id = "a.lua:1", file = "a.lua", header = "@@ -2,1 +2,1 @@",
      text = "@@ -2,1 +2,1 @@\n-two\n+TWO\n",
      original = { start_line = 2, end_line = 3 },
      modified = { start_line = 2, end_line = 3 },
      additions = 1, deletions = 1,
    } },
  }
end

--- Two windows in a scratch tab.
local function two_wins()
  vim.cmd("tabnew")
  local a = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit")
  local b = vim.api.nvim_get_current_win()
  return { original = a, modified = b }, vim.api.nvim_get_current_tabpage()
end

describe("paint.render", function()
  local wins, tab
  before_each(function() wins, tab = two_wins() end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(tab) then
      vim.cmd("tabclose!")
    end
  end)

  it("puts the plan's lines into both panes", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local painted = paint.render(p, wins)
    local orig = vim.api.nvim_buf_get_lines(painted.bufs.original, 0, -1, false)
    local mod = vim.api.nvim_buf_get_lines(painted.bufs.modified, 0, -1, false)
    assert.same(p.original.lines, orig)
    assert.same(p.modified.lines, mod)
  end)

  it("makes the buffers read-only scratch buffers", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local painted = paint.render(p, wins)
    for _, buf in pairs(painted.bufs) do
      assert.equals("nofile", vim.bo[buf].buftype)
      assert.is_false(vim.bo[buf].modifiable)
      assert.equals("hide", vim.bo[buf].bufhidden)
    end
  end)

  it("displays the buffers in the given windows", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local painted = paint.render(p, wins)
    assert.equals(painted.bufs.original, vim.api.nvim_win_get_buf(wins.original))
    assert.equals(painted.bufs.modified, vim.api.nvim_win_get_buf(wins.modified))
  end)

  it("places a line highlight for every span", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local painted = paint.render(p, wins)
    local marks = vim.api.nvim_buf_get_extmarks(
      painted.bufs.modified, paint.ns, 0, -1, { details = true })
    local found = false
    for _, m in ipairs(marks) do
      if m[4].line_hl_group == "IntentDiffAdd" and m[2] == 2 then
        found = true
      end
    end
    assert.is_true(found, "the added line has no IntentDiffAdd line highlight")
  end)

  it("binds the two panes together for scrolling", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    paint.render(p, wins)
    assert.is_true(vim.wo[wins.original].scrollbind)
    assert.is_true(vim.wo[wins.modified].scrollbind)
    assert.is_true(vim.wo[wins.original].cursorbind)
  end)

  it("uses one window and no scrollbind in inline layout", function()
    local p = plan.build({ modified_file() }, {}, "inline")
    local painted = paint.render(p, { modified = wins.modified })
    assert.is_nil(painted.bufs.original)
    assert.is_false(vim.wo[wins.modified].scrollbind)
  end)

  it("closes the plan's fold ranges", function()
    local orig, mod = {}, {}
    for i = 1, 20 do orig[i] = "line" .. i; mod[i] = "line" .. i end
    mod[15] = "CHANGED"
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = orig, modified = mod,
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -15,1 +15,1 @@",
        text = "@@ -15,1 +15,1 @@\n-line15\n+CHANGED\n",
        original = { start_line = 15, end_line = 16 },
        modified = { start_line = 15, end_line = 16 },
        additions = 1, deletions = 1,
      } },
    }
    local p = plan.build({ file }, { ["a.lua:1"] = true }, "side-by-side", { context = 2 })
    paint.render(p, wins)
    vim.api.nvim_win_call(wins.modified, function()
      -- Row 3 is far above the hunk and must be inside a closed fold.
      assert.is_true(vim.fn.foldclosed(3) > 0, "row 3 should be folded away")
      -- The changed row itself must be visible.
      assert.equals(-1, vim.fn.foldclosed(16))
    end)
  end)

  it("retires a previous generation's buffers", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local first = paint.render(p, wins)
    local old = first.bufs.modified
    paint.render(p, wins)
    paint.retire(first.bufs)
    vim.wait(50, function() return not vim.api.nvim_buf_is_valid(old) end)
    assert.is_false(vim.api.nvim_buf_is_valid(old))
  end)

  it("never deletes a buffer still displayed in a window", function()
    local p = plan.build({ modified_file() }, {}, "side-by-side")
    local painted = paint.render(p, wins)
    paint.retire(painted.bufs)
    vim.wait(50)
    assert.is_true(vim.api.nvim_buf_is_valid(painted.bufs.modified),
      "retiring a displayed buffer would close its window and could close the tab")
  end)
end)

describe("paint syntax highlighting", function()
  local wins, tab
  before_each(function() wins, tab = two_wins() end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(tab) then vim.cmd("tabclose!") end
  end)

  local function syntax_marks(buf, row)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(
        buf, paint.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      if m[4].hl_group and m[4].hl_group:sub(1, 1) == "@" then
        out[#out + 1] = m[4].hl_group
      end
    end
    return out
  end

  it("highlights an unchanged row from the file's own parse", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "local x = 1", "return x" },
      modified = { "local x = 2", "return x" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n-local x = 1\n+local x = 2\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
    local content = { ["a.lua"] = { old = file.original, new = file.modified } }
    local p = plan.build({ file }, {}, "side-by-side")
    local painted = paint.render(p, wins, content)
    -- Row 3 is "return x" on the modified side.
    assert.is_true(#syntax_marks(painted.bufs.modified, 3) > 0,
      "an unchanged row got no treesitter highlights")
  end)

  it("highlights an inline deletion row from the ORIGINAL parse, not the interleaved pane slice", function()
    -- The old side opens an unterminated long-string bracket. Parsed on its
    -- own (correct), it does not touch the addition row at all. Parsed as ONE
    -- document concatenated with the addition row (the bug this task exists
    -- to prevent -- treating a pane's interleaved row range as coherent
    -- content), the `[[` swallows the addition row's "local" into the
    -- unterminated string and it loses its @keyword capture, coming back as
    -- @variable instead. Verified empirically:
    --   compute_syntax_highlights({"local s = [["}, "lua")[1]        -> @keyword/@variable/@operator (local s =)
    --   compute_syntax_highlights({"local x = 1"}, "lua")[1]         -> @keyword/@variable/@operator/@number (local x = 1)
    --   compute_syntax_highlights({"local s = [[","local x = 1"}, "lua")[2]
    --     -> "local" comes back as @variable, not @keyword: concatenation changed the parse.
    -- Two independent `local x = n` statements (no unterminated construct)
    -- tokenise identically whether parsed alone or concatenated, so that
    -- fixture would pass against a buggy single-parse implementation too;
    -- this one does not.
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "local s = [[" },
      modified = { "local x = 1" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n-local s = [[\n+local x = 1\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
    local content = { ["a.lua"] = { old = file.original, new = file.modified } }
    local p = plan.build({ file }, {}, "inline")
    local painted = paint.render(p, { modified = wins.modified }, content)
    -- Row 2 is the deletion (original content), row 3 the addition.
    assert.is_true(#syntax_marks(painted.bufs.modified, 2) > 0,
      "the deletion row must be highlighted from the original file's parse")
    assert.is_true(vim.tbl_contains(syntax_marks(painted.bufs.modified, 3), "@keyword"),
      "the addition row must be parsed from the modified file alone: "
        .. "under the interleaved-slice bug 'local' loses its @keyword capture")
  end)

  it("leaves separators and fillers unhighlighted", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "local x = 1" },
      modified = { "local x = 1", "local y = 2" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,0 +2,1 @@",
        text = "@@ -1,0 +2,1 @@\n+local y = 2\n",
        original = { start_line = 2, end_line = 2 },
        modified = { start_line = 2, end_line = 3 },
        additions = 1, deletions = 0,
      } },
    }
    local content = { ["a.lua"] = { old = file.original, new = file.modified } }
    local p = plan.build({ file }, {}, "side-by-side")
    local painted = paint.render(p, wins, content)
    assert.same({}, syntax_marks(painted.bufs.modified, 1), "separator row")
    assert.same({}, syntax_marks(painted.bufs.original, 3), "filler row")
  end)

  it("survives a filetype with no parser", function()
    local file = {
      path = "a.weird", status = "M", filetype = "definitely_not_a_language",
      binary = false,
      original = { "a" }, modified = { "b" },
      hunks = { {
        id = "a.weird:1", file = "a.weird", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n-a\n+b\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
    local content = { ["a.weird"] = { old = file.original, new = file.modified } }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.has_no.errors(function() paint.render(p, wins, content) end)
  end)

  it("looks a fallback file's syntax up by its real file line, not its pane row", function()
    -- A fallback file (no `original`/`modified` content, so plan.lua renders
    -- hunks-only) still carries the hunk's REAL start_line into
    -- map[row].line via fallback_rows -> pair_body, exactly like a normal
    -- file. The design's correctness rests on that: pane rows are dense
    -- (separator, then one row per changed pair) and do NOT line up with
    -- file line numbers once a hunk starts anywhere past line 1. Lines 1-4
    -- are numeral filler (only ever an @number capture); line 5, the hunk's
    -- real start_line, is the only line with an @keyword capture. The
    -- addition lands on pane row 2 (row 1 is the separator) -- if the lookup
    -- used the pane row instead of map[row].line it would hit content.new[2]
    -- ("2", @number only) instead of content.new[5] ("local x = 1", @keyword).
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = nil, modified = nil,
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -5,1 +5,1 @@",
        text = "@@ -5,1 +5,1 @@\n-local removed = 1\n+local x = 1\n",
        original = { start_line = 5, end_line = 6 },
        modified = { start_line = 5, end_line = 6 },
        additions = 1, deletions = 1,
      } },
    }
    local content = {
      ["a.lua"] = {
        old = { "1", "2", "3", "4", "local removed = 1" },
        new = { "1", "2", "3", "4", "local x = 1" },
      },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    assert.is_true(p.files[1].fallback, "the file must actually take the fallback path")
    local painted = paint.render(p, wins, content)
    assert.is_true(vim.tbl_contains(syntax_marks(painted.bufs.modified, 2), "@keyword"),
      "the fallback row must be looked up by its real file line (5), not its pane row (2)")
  end)
end)

describe("paint character highlighting", function()
  local wins, tab
  before_each(function() wins, tab = two_wins() end)
  after_each(function()
    if vim.api.nvim_tabpage_is_valid(tab) then vim.cmd("tabclose!") end
  end)

  local function char_marks(buf, row, group)
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(
        buf, paint.ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      if m[4].hl_group == group then
        out[#out + 1] = { m[3], m[4].end_col }
      end
    end
    return out
  end

  local function one_word_changed()
    return {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { "local alpha = 1" },
      modified = { "local omega = 1" },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n-local alpha = 1\n+local omega = 1\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
  end

  it("highlights only the changed word, not the whole line", function()
    local p = plan.build({ one_word_changed() }, {}, "side-by-side")
    local painted = paint.render(p, wins, nil)
    local adds = char_marks(painted.bufs.modified, 2, "IntentDiffAddChar")
    assert.is_true(#adds > 0, "no character highlight on the changed line")
    local start_col, end_col = adds[1][1], adds[1][2]
    assert.is_true(start_col >= 6, "highlight should start at 'omega', not column 0")
    assert.is_true(end_col <= #"local omega = 1")
  end)

  it("highlights the deleted word on the original side", function()
    local p = plan.build({ one_word_changed() }, {}, "side-by-side")
    local painted = paint.render(p, wins, nil)
    assert.is_true(#char_marks(painted.bufs.original, 2, "IntentDiffDeleteChar") > 0)
  end)

  it("places character highlights in inline layout too", function()
    local p = plan.build({ one_word_changed() }, {}, "inline")
    local painted = paint.render(p, { modified = wins.modified }, nil)
    assert.is_true(#char_marks(painted.bufs.modified, 2, "IntentDiffDeleteChar") > 0)
    assert.is_true(#char_marks(painted.bufs.modified, 3, "IntentDiffAddChar") > 0)
  end)

  it("converts UTF-16 columns to byte columns", function()
    local file = {
      path = "a.lua", status = "M", filetype = "lua", binary = false,
      original = { '-- 日本語 alpha' },
      modified = { '-- 日本語 omega' },
      hunks = { {
        id = "a.lua:1", file = "a.lua", header = "@@ -1,1 +1,1 @@",
        text = "@@ -1,1 +1,1 @@\n--- 日本語 alpha\n+-- 日本語 omega\n",
        original = { start_line = 1, end_line = 2 },
        modified = { start_line = 1, end_line = 2 },
        additions = 1, deletions = 1,
      } },
    }
    local p = plan.build({ file }, {}, "side-by-side")
    local painted = paint.render(p, wins, nil)
    local adds = char_marks(painted.bufs.modified, 2, "IntentDiffAddChar")
    assert.is_true(#adds > 0)
    -- "-- 日本語 " is 3 + 9 + 1 = 13 bytes, so a byte-correct highlight starts
    -- at or after 13. A raw UTF-16 column would land near 6.
    assert.is_true(adds[1][1] >= 10,
      "UTF-16 column was not converted to a byte column")
  end)

  it("degrades to no character highlights when the C library is unavailable", function()
    local real = package.loaded["codediff.core.diff"]
    package.loaded["codediff.core.diff"] = nil
    package.preload["codediff.core.diff"] = function() error("unavailable") end
    package.loaded["intentdiff.render.paint"] = nil

    -- Restoration MUST happen even if the body errors or an assertion fails,
    -- or a corrupted package.loaded/package.preload leaks into every later
    -- spec in this sequential run.
    local ok, err = pcall(function()
      local fresh = require("intentdiff.render.paint")
      local p = plan.build({ one_word_changed() }, {}, "side-by-side")
      assert.has_no.errors(function() fresh.render(p, wins, nil) end)
    end)

    package.preload["codediff.core.diff"] = nil
    package.loaded["codediff.core.diff"] = real
    package.loaded["intentdiff.render.paint"] = nil

    if not ok then
      error(err, 0)
    end
  end)
end)
