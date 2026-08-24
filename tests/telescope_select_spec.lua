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

  it("reaches a file under the second of two identically titled intents", function()
    -- classify.lua defaults a missing title to "Untitled", so a provider that
    -- returns two title-less groups yields two groups with the SAME title.
    -- Resolving by title first would stop at group 1, not find the path there,
    -- and silently render the wrong intent — making every row of the second
    -- duplicate-titled intent unreachable.
    local m = model({
      { title = "Untitled", files = { file("a.lua") } },
      { title = "Untitled", files = { file("b.lua") } },
    })
    local t = target_for(m, function(x) return x.path == "b.lua" end)
    assert.same({ kind = "file", group_i = 2, file_i = 1 }, targets.resolve(m, t))
  end)

  it("still finds the file after its intent title is reworded", function()
    -- Intent titles are LLM prose and are rewritten on every reclassify. This
    -- is the resume-after-reclassify case: the file is plainly still there, so
    -- a title rewording must not report it as gone.
    local before = model({ { title = "Add retry logic", files = { file("a.lua") } } })
    local t = target_for(before, function(x) return x.path == "a.lua" end)
    local after = model({
      { title = "Add retry logic to the API client", files = { file("a.lua") } },
    })
    assert.same({ kind = "file", group_i = 1, file_i = 1 }, targets.resolve(after, t))
  end)

  it("prefers the title-matched intent when two intents hold the same path", function()
    local m = model({
      { title = "First", files = { file("shared.lua") } },
      { title = "Second", files = { file("shared.lua") } },
    })
    local t = target_for(m, function(x)
      return x.path == "shared.lua" and x.group_title == "Second"
    end)
    assert.same({ kind = "file", group_i = 2, file_i = 1 }, targets.resolve(m, t))
  end)

  it("finds a directory under any intent, not only the title-matched one", function()
    local before = model({ { title = "Old title", files = { file("src/a.lua") } } })
    local t = target_for(before, function(x) return x.kind == "dir" and x.path == "src" end)
    local after = model({ { title = "New title", files = { file("src/a.lua") } } })
    assert.same({ kind = "dir", group_i = 1, dir_path = "src" }, targets.resolve(after, t))
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

  it("degrades a vanished file to its intent, marked as degraded", function()
    local before = model({ { title = "T", files = { file("gone.lua"), file("kept.lua") } } })
    local t = target_for(before, function(x) return x.path == "gone.lua" end)
    local after = model({ { title = "T", files = { file("kept.lua") } } })
    -- degraded_from carries the path that could not be found, so the caller
    -- can say WHICH pick fell back rather than rendering an intent silently.
    assert.same({ kind = "group", group_i = 1, degraded_from = "gone.lua" },
      targets.resolve(after, t))
  end)

  it("degrades a vanished directory to its intent, marked as degraded", function()
    local before = model({ { title = "T", files = { file("src/a.lua") } } })
    local t = target_for(before, function(x) return x.kind == "dir" end)
    local after = model({ { title = "T", files = { file("elsewhere/b.lua") } } })
    assert.same({ kind = "group", group_i = 1, degraded_from = "src" },
      targets.resolve(after, t))
  end)

  it("leaves a genuine group pick unmarked", function()
    local m = model({ { title = "T", files = { file("a.lua") } } })
    local t = target_for(m, function(x) return x.kind == "group" end)
    local resolved = targets.resolve(m, t)
    assert.same({ kind = "group", group_i = 1 }, resolved)
    assert.is_nil(resolved.degraded_from)
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
