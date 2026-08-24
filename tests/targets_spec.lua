local targets = require("intentdiff.targets")

local function hunk(adds, dels)
  return { additions = adds or 1, deletions = dels or 0 }
end

local function file(path, hunks)
  return { path = path, status = "M", hunks = hunks or { hunk(1, 0) } }
end

local function model(groups)
  return { state = "ready", groups = groups }
end

describe("targets.list", function()
  it("emits one target per intent, directory and file, in sidebar order", function()
    local out = targets.list(model({
      { title = "Add retry logic", files = { file("src/a.lua"), file("src/b.lua") } },
    }))
    assert.equals(4, #out)
    assert.equals("group", out[1].kind)
    assert.equals("Add retry logic", out[1].group_title)
    assert.is_nil(out[1].path)
    assert.equals("dir", out[2].kind)
    assert.equals("src", out[2].path)
    assert.equals("file", out[3].kind)
    assert.equals("src/a.lua", out[3].path)
    assert.equals("file", out[4].kind)
    assert.equals("src/b.lua", out[4].path)
  end)

  it("carries the intent title on every target, not an index", function()
    local out = targets.list(model({
      { title = "First", files = { file("a.lua") } },
      { title = "Second", files = { file("b.lua") } },
    }))
    for _, t in ipairs(out) do
      assert.is_string(t.group_title)
      assert.is_nil(t.group_i)
      assert.is_nil(t.file_i)
    end
    assert.equals("Second", out[#out].group_title)
  end)

  it("sums additions and deletions per kind", function()
    local out = targets.list(model({
      { title = "T", files = {
        file("src/a.lua", { hunk(3, 1), hunk(2, 0) }),
        file("src/b.lua", { hunk(5, 4) }),
      } },
    }))
    assert.equals(10, out[1].additions) -- intent: every hunk it owns
    assert.equals(5, out[1].deletions)
    assert.equals(10, out[2].additions) -- dir "src": every file beneath it
    assert.equals(5, out[2].deletions)
    assert.equals(5, out[3].additions)  -- file src/a.lua
    assert.equals(1, out[3].deletions)
  end)

  it("omits directory rows when include_dirs is false", function()
    local out = targets.list(model({
      { title = "T", files = { file("src/a.lua") } },
    }), { include_dirs = false })
    assert.equals(2, #out)
    assert.equals("group", out[1].kind)
    assert.equals("file", out[2].kind)
  end)

  it("ignores collapse state — a collapsed intent still yields its files", function()
    local out = targets.list(model({
      { title = "T", collapsed = true, collapsed_dirs = { src = true },
        files = { file("src/a.lua") } },
    }))
    assert.equals(3, #out)
  end)

  it("handles the loading model and an empty model", function()
    local out = targets.list(model({
      { title = "All changes", files = { file("a.lua") } },
    }))
    assert.equals(2, #out)
    assert.same({}, targets.list(model({})))
    assert.same({}, targets.list(nil))
  end)

  it("handles an intent with no files", function()
    local out = targets.list(model({ { title = "Empty", files = {} } }))
    assert.equals(1, #out)
    assert.equals("group", out[1].kind)
    assert.equals(0, out[1].additions)
  end)
end)
