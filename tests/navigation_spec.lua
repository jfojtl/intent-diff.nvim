local navigation = require("intentdiff.navigation")

local function mk_hunk(line)
  return { modified = { start_line = line, end_line = line + 1 },
           original = { start_line = line, end_line = line + 1 } }
end

describe("navigation.plan_move", function()
  -- plan_move(file_entries, file_i, cursor_line, dir) -> { line = n } | { file_i = n, jump = "first"|"last" } | nil
  local files = {
    { path = "a.lua", hunks = { mk_hunk(5), mk_hunk(50) } },
    { path = "b.lua", hunks = { mk_hunk(10) } },
  }

  it("moves to the next hunk within the file", function()
    assert.same({ line = 50 }, navigation.plan_move(files, 1, 5, 1))
  end)

  it("rolls over to the next file after the last hunk", function()
    assert.same({ file_i = 2, jump = "first" }, navigation.plan_move(files, 1, 50, 1))
  end)

  it("moves back within the file", function()
    assert.same({ line = 5 }, navigation.plan_move(files, 1, 50, -1))
  end)

  it("rolls back to the previous file before the first hunk", function()
    assert.same({ file_i = 1, jump = "last" }, navigation.plan_move(files, 2, 10, -1))
  end)

  it("returns nil at the group's boundaries", function()
    assert.is_nil(navigation.plan_move(files, 2, 10, 1))
    assert.is_nil(navigation.plan_move(files, 1, 5, -1))
  end)
end)
