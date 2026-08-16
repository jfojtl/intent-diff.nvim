local helpers = require("tests.helpers")
local anchor = require("intentdiff.comments.anchor")

describe("comments.anchor", function()
  --- END-EXCLUSIVE, matching hunks.lua's range().
  local hunk_list = {
    { file = "a.ts", original = { start_line = 10, end_line = 20 },
      modified = { start_line = 10, end_line = 25 } },
    { file = "b.ts", original = { start_line = 1, end_line = 4 },
      modified = { start_line = 1, end_line = 4 } },
  }

  it("accepts a new-side line inside the modified range", function()
    assert.is_true(anchor.covers(hunk_list, { file = "a.ts", line = 24, side = "new" }))
  end)

  it("rejects a new-side line past the modified range", function()
    assert.is_false(anchor.covers(hunk_list, { file = "a.ts", line = 25, side = "new" }))
  end)

  it("resolves an old-side line against the original range", function()
    -- 22 is inside modified (10-25) but outside original (10-20): a correct
    -- implementation must not answer from the wrong side's range.
    assert.is_true(anchor.covers(hunk_list, { file = "a.ts", line = 19, side = "old" }))
    assert.is_false(anchor.covers(hunk_list, { file = "a.ts", line = 22, side = "old" }))
  end)

  it("requires every line of a range to be covered", function()
    assert.is_true(anchor.covers(hunk_list,
      { file = "a.ts", line = 12, line_end = 18, side = "new" }))
    assert.is_false(anchor.covers(hunk_list,
      { file = "a.ts", line = 12, line_end = 30, side = "new" }))
  end)

  it("accepts a file-level comment on any file in the diff", function()
    assert.is_true(anchor.covers(hunk_list, { file = "b.ts", line = 0 }))
    assert.is_false(anchor.covers(hunk_list, { file = "gone.ts", line = 0 }))
  end)

  it("rejects a file the diff does not touch", function()
    assert.is_false(anchor.covers(hunk_list, { file = "c.ts", line = 3, side = "new" }))
  end)

  it("never anchors an intent comment", function()
    assert.is_false(anchor.covers(hunk_list, { intent_title = "Some intent" }))
  end)

  it("parses the PR diff from a real repository", function()
    local repo = helpers.make_repo({ ["a.ts"] = "1\n2\n3\n4\n5\n" })
    helpers.git(repo, "branch", "-M", "main")
    helpers.git(repo, "checkout", "-q", "-b", "feat/x")
    helpers.write_file(repo, "a.ts", "1\n2\nCHANGED\n4\n5\n")
    helpers.git(repo, "commit", "-qam", "change")
    local hunks, err = anchor.pr_hunks(repo, "main")
    assert.is_nil(err)
    assert.is_true(#hunks > 0)
    assert.equals("a.ts", hunks[1].file)
    local can = anchor.predicate(hunks)
    assert.is_true(can({ file = "a.ts", line = 3, side = "new" }))
    assert.is_false(can({ file = "a.ts", line = 400, side = "new" }))
  end)

  it("reports a base ref it cannot resolve instead of guessing", function()
    local repo = helpers.make_repo({ ["a.ts"] = "1\n" })
    local hunks, err = anchor.pr_hunks(repo, "nosuchbranch")
    assert.is_nil(hunks)
    assert.is_truthy(err:match("nosuchbranch"))
  end)
end)
