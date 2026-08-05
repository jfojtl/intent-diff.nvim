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
