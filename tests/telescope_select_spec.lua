local targets = require("intentdiff.targets")

local function hunk(adds, dels)
  return { additions = adds or 1, deletions = dels or 0 }
end
local function file(path)
  return { path = path, status = "M", hunks = { hunk(1, 0) } }
end
local function model(groups)
  return { state = "ready", groups = groups }
end
local function target_for(m, pred)
  return vim.tbl_filter(pred, targets.list(m))[1]
end

describe("targets.resolve", function()
  it("resolves a file target to its current indices", function()
    local m = model({
      { title = "First", files = { file("a.lua") } },
      { title = "Second", files = { file("b.lua") } },
    })
    local t = target_for(m, function(x) return x.path == "b.lua" end)
    assert.same({ kind = "file", group_i = 2, file_i = 1 }, targets.resolve(m, t))
  end)

  it("follows the file when the model is reordered underneath it", function()
    local before = model({
      { title = "First", files = { file("a.lua") } },
      { title = "Second", files = { file("b.lua") } },
    })
    local t = target_for(before, function(x) return x.path == "b.lua" end)

    -- Reclassification swaps the model: the intents change places. Index 2
    -- would now address the WRONG intent, which is the whole reason targets
    -- carry identity instead.
    local after = model({
      { title = "Second", files = { file("b.lua") } },
      { title = "First", files = { file("a.lua") } },
    })
    assert.same({ kind = "file", group_i = 1, file_i = 1 }, targets.resolve(after, t))
  end)

  it("resolves a group target by title", function()
    local m = model({
      { title = "Add retry logic", files = { file("a.lua") } },
      { title = "Other", files = { file("b.lua") } },
    })
    local t = target_for(m, function(x) return x.group_title == "Other" and x.kind == "group" end)
    assert.same({ kind = "group", group_i = 2 }, targets.resolve(m, t))
  end)

  it("resolves a directory target to its intent and path", function()
    local m = model({
      { title = "T", files = { file("src/a.lua"), file("other/b.lua") } },
    })
    local t = target_for(m, function(x) return x.kind == "dir" and x.path == "src" end)
    assert.same({ kind = "dir", group_i = 1, dir_path = "src" }, targets.resolve(m, t))
  end)

  it("degrades a vanished file to its intent", function()
    local before = model({ { title = "T", files = { file("gone.lua"), file("kept.lua") } } })
    local t = target_for(before, function(x) return x.path == "gone.lua" end)
    local after = model({ { title = "T", files = { file("kept.lua") } } })
    assert.same({ kind = "group", group_i = 1 }, targets.resolve(after, t))
  end)

  it("degrades a vanished directory to its intent", function()
    local before = model({ { title = "T", files = { file("src/a.lua") } } })
    local t = target_for(before, function(x) return x.kind == "dir" end)
    local after = model({ { title = "T", files = { file("elsewhere/b.lua") } } })
    assert.same({ kind = "group", group_i = 1 }, targets.resolve(after, t))
  end)

  it("resolves to nil when the intent is gone too", function()
    local before = model({ { title = "T", files = { file("gone.lua") } } })
    local t = target_for(before, function(x) return x.path == "gone.lua" end)
    local after = model({ { title = "Different", files = { file("other.lua") } } })
    assert.is_nil(targets.resolve(after, t))
  end)

  it("resolves to nil for a nil model or nil target", function()
    assert.is_nil(targets.resolve(nil, { kind = "group", group_title = "T" }))
    assert.is_nil(targets.resolve(model({}), nil))
  end)
end)

describe("intentdiff.select", function()
  it("returns false when the tab holds no review", function()
    assert.is_false(require("intentdiff").select(vim.api.nvim_get_current_tabpage(),
      { kind = "group", group_title = "T" }))
  end)
end)
