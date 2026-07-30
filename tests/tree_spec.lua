local tree = require("intentdiff.tree")

local function file(path, adds, dels)
  return {
    path = path,
    status = "M",
    hunks = { { additions = adds or 1, deletions = dels or 0 } },
  }
end

describe("tree.build", function()
  it("nests files under their directories", function()
    local roots = tree.build({ file("src/a.lua"), file("src/b.lua") })
    assert.equals(1, #roots)
    assert.equals("dir", roots[1].kind)
    assert.equals("src", roots[1].name)
    assert.equals(2, #roots[1].children)
  end)

  it("compresses single-child directory chains", function()
    local roots = tree.build({ file("app/api/integrations/route.ts") })
    assert.equals(1, #roots)
    assert.equals("app/api/integrations", roots[1].name)
    assert.equals("app/api/integrations", roots[1].path)
    assert.equals(1, #roots[1].children)
    assert.equals("route.ts", roots[1].children[1].name)
  end)

  it("stops compressing where a directory branches", function()
    local roots = tree.build({
      file("app/api/one/route.ts"),
      file("app/api/two/route.ts"),
    })
    assert.equals("app/api", roots[1].name)
    assert.equals(2, #roots[1].children)
    assert.equals("one", roots[1].children[1].name)
    assert.equals("two", roots[1].children[2].name)
  end)

  it("sorts directories before files, alphabetically within each", function()
    local roots = tree.build({
      file("zeta.lua"),
      file("alpha.lua"),
      file("sub/inner.lua"),
    })
    assert.equals("sub", roots[1].name)
    assert.equals("alpha.lua", roots[2].name)
    assert.equals("zeta.lua", roots[3].name)
  end)

  it("keeps the file's index in the group's files array", function()
    local roots = tree.build({ file("b.lua"), file("a.lua") })
    assert.equals("a.lua", roots[1].name)
    assert.equals(2, roots[1].file_i)
    assert.equals(1, roots[2].file_i)
  end)

  it("handles a file at the repository root", function()
    local roots = tree.build({ file("README.md") })
    assert.equals("file", roots[1].kind)
    assert.equals("README.md", roots[1].name)
  end)
end)

describe("tree.flatten", function()
  it("emits directory then file rows with increasing depth", function()
    local rows = tree.flatten(tree.build({ file("src/a.lua") }), {})
    assert.equals(2, #rows)
    assert.equals("dir", rows[1].kind)
    assert.equals(0, rows[1].depth)
    assert.equals("file", rows[2].kind)
    assert.equals(1, rows[2].depth)
  end)

  it("omits the children of a collapsed directory", function()
    local roots = tree.build({ file("src/a.lua"), file("src/b.lua") })
    local rows = tree.flatten(roots, { src = true })
    assert.equals(1, #rows)
    assert.equals("dir", rows[1].kind)
    assert.is_true(rows[1].collapsed)
  end)

  it("sums additions and deletions across a file's hunks", function()
    local f = {
      path = "a.lua", status = "M",
      hunks = {
        { additions = 3, deletions = 1 },
        { additions = 4, deletions = 6 },
      },
    }
    local rows = tree.flatten(tree.build({ f }), {})
    assert.equals(7, rows[1].additions)
    assert.equals(7, rows[1].deletions)
  end)

  it("marks the last child at each level for indent guides", function()
    local rows = tree.flatten(tree.build({ file("a.lua"), file("b.lua") }), {})
    assert.is_false(rows[1].last)
    assert.is_true(rows[2].last)
  end)

  it("carries the file status through", function()
    local rows = tree.flatten(tree.build({
      { path = "new.lua", status = "A", hunks = { { additions = 5, deletions = 0 } } },
    }), {})
    assert.equals("A", rows[1].status)
  end)
end)
