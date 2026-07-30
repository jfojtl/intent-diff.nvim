local sidebar = require("intentdiff.sidebar")

local function mk_model(overrides)
  local model = {
    state = "ready",
    total_hunks = 3,
    grouped_hunks = 3,
    provider_label = "claude:haiku",
    groups = {
      {
        title = "Add retry",
        hunks = { { additions = 2, deletions = 1 }, { additions = 1, deletions = 0 } },
        files = {
          { path = "src/http/client.lua", status = "M",
            hunks = { { additions = 1, deletions = 0 } } },
          { path = "src/http/backoff.lua", status = "A",
            hunks = { { additions = 1, deletions = 0 } } },
        },
      },
      {
        title = "Ungrouped", is_ungrouped = true,
        hunks = { { additions = 1, deletions = 0 } },
        files = { { path = "misc.lua", status = "M",
          hunks = { { additions = 1, deletions = 0 } } } },
      },
    },
  }
  if overrides and overrides.groups then
    -- Merge groups element-wise to preserve array structure
    for i, g_override in ipairs(overrides.groups) do
      if model.groups[i] then
        model.groups[i] = vim.tbl_deep_extend("force", model.groups[i], g_override)
      else
        model.groups[i] = g_override
      end
    end
    overrides.groups = nil
  end
  return vim.tbl_deep_extend("force", model, overrides or {})
end

describe("sidebar.layout", function()
  it("wraps a long group title across lines with shared meta", function()
    local model = mk_model({ groups = { { title =
      "Extract the integration catalog into a shared provider registry" } } })
    local lines, meta = sidebar.layout(model)
    assert.truthy(lines[1]:find("▾ Extract"))
    -- title needs more than one line at the default width
    assert.equals("group", meta[1].kind)
    assert.equals("group", meta[2].kind)
    assert.equals(1, meta[1].group_i)
    assert.equals(1, meta[2].group_i)
    -- the wrap guarantee covers title lines only. File and directory rows are
    -- never wrapped — a long path just runs past the window edge, as in
    -- diffview — so they are excluded here deliberately.
    local title_lines = 0
    for i, line in ipairs(lines) do
      if meta[i].kind == "group" and not line:find("hunks", 1, true) then
        title_lines = title_lines + 1
        assert.is_true(vim.fn.strdisplaywidth(line) <= 40,
          ("title line exceeds sidebar width: %q"):format(line))
      end
    end
    assert.is_true(title_lines >= 2, "long title must occupy more than one line")
  end)

  it("renders a stats line with hunk count, file count and +/- totals", function()
    local model = mk_model()
    model.groups[1].hunks = {
      { additions = 10, deletions = 4 },
      { additions = 3, deletions = 0 },
    }
    local lines, meta = sidebar.layout(model)
    local stats_line, stats_i
    for i, line in ipairs(lines) do
      if line:find("hunks", 1, true) and line:find("+13", 1, true) then
        stats_line, stats_i = line, i
      end
    end
    assert.truthy(stats_line, "expected a stats line")
    assert.truthy(stats_line:find("2 hunks", 1, true))
    assert.truthy(stats_line:find("2 files", 1, true))
    assert.truthy(stats_line:find("+13", 1, true))
    assert.truthy(stats_line:find("-4", 1, true))
    -- the stats line belongs to its group, so hover/toggle treat it as one row
    assert.equals("group", meta[stats_i].kind)
    assert.equals(1, meta[stats_i].group_i)
  end)

  it("renders files as a tree with directory rows", function()
    local model = mk_model()
    local lines, meta = sidebar.layout(model)
    local dir_i, file_i
    for i, m in ipairs(meta) do
      if m.kind == "dir" and not dir_i then dir_i = i end
      if m.kind == "file" and not file_i then file_i = i end
    end
    assert.truthy(dir_i, "expected a directory row")
    assert.truthy(lines[dir_i]:find("src/http", 1, true),
      "single-child chain must be compressed")
    assert.equals("src/http", meta[dir_i].dir_path)
    assert.truthy(file_i > dir_i, "files come after their directory")
    assert.truthy(lines[file_i]:find("backoff.lua", 1, true))
  end)

  it("keeps file meta as group_i/file_i indices into the group's files", function()
    local model = mk_model()
    local _, meta = sidebar.layout(model)
    for _, m in ipairs(meta) do
      if m.kind == "file" then
        assert.is_number(m.group_i)
        assert.is_number(m.file_i)
        assert.truthy(model.groups[m.group_i].files[m.file_i])
      end
    end
  end)

  it("puts the status letter in the leading gutter", function()
    local model = mk_model()
    local lines, meta = sidebar.layout(model)
    for i, m in ipairs(meta) do
      if m.kind == "file" then
        local status = model.groups[m.group_i].files[m.file_i].status
        assert.equals(status == "??" and "?" or status, vim.trim(lines[i]:sub(1, 2)))
      end
    end
  end)

  it("returns highlight spans for stats and status letters", function()
    local model = mk_model()
    model.groups[1].hunks = { { additions = 10, deletions = 4 } }
    local lines, _, highlights = sidebar.layout(model)
    assert.is_table(highlights)
    local groups = {}
    for _, span in ipairs(highlights) do
      groups[span.hl] = true
      -- spans must address real byte ranges on their line
      assert.truthy(lines[span.line], "span points at a missing line")
      assert.is_true(span.col_end <= #lines[span.line])
      assert.is_true(span.col_start < span.col_end)
    end
    assert.is_true(groups.IntentDiffAdd, "expected an IntentDiffAdd span")
    assert.is_true(groups.IntentDiffDelete, "expected an IntentDiffDelete span")
    assert.is_true(groups.IntentDiffGroupTitle, "expected a title span")
  end)

  it("omits a zero side of the stats", function()
    local model = mk_model()
    model.groups[1].hunks = { { additions = 5, deletions = 0 } }
    local lines = sidebar.layout(model)
    local stats = vim.tbl_filter(function(l) return l:find("hunks", 1, true) end, lines)[1]
    assert.truthy(stats:find("+5", 1, true))
    assert.is_nil(stats:find("-0", 1, true))
  end)

  it("hides a collapsed directory's files", function()
    local model = mk_model()
    model.groups[1].collapsed_dirs = { ["src/http"] = true }
    local _, meta = sidebar.layout(model)
    for _, m in ipairs(meta) do
      assert.is_false(m.kind == "file" and m.group_i == 1,
        "collapsed directory must hide its files")
    end
  end)

  it("still renders the loading and footer rows", function()
    local lines, meta = sidebar.layout(mk_model({ state = "loading", elapsed_s = 7 }))
    assert.truthy(lines[1]:find("classifying"))
    assert.equals("info", meta[1].kind)
  end)
end)

describe("sidebar.create", function()
  it("opens a split, renders, and routes <CR> to on_select", function()
    local selected
    local handle = sidebar.create({
      on_select = function(gi, fi) selected = { gi, fi } end,
      on_toggle_group = function() end, on_toggle_dir = function() end,
      on_reclassify = function() end,
      on_close = function() end, on_next_group = function() end,
      on_prev_group = function() end, on_goto_file = function() end,
    })
    handle.update(mk_model())
    assert.is_true(vim.api.nvim_win_is_valid(handle.winid))
    vim.api.nvim_set_current_win(handle.winid)
    -- line 1: title, line 2: stats, line 3: "src/http" dir row (compressed
    -- single-child chain), line 4+: files sorted alphabetically within the dir
    -- (backoff.lua, file_i = 2, before client.lua, file_i = 1)
    local file_lnum, file_i
    for i, m in ipairs(handle.meta) do
      if m.kind == "file" then
        file_lnum, file_i = i, m.file_i
        break
      end
    end
    vim.api.nvim_win_set_cursor(handle.winid, { file_lnum, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    assert.same({ 1, file_i }, selected)
    vim.api.nvim_win_close(handle.winid, true)
  end)
end)
