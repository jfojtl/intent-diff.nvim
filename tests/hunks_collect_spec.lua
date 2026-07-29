local hunks = require("intentdiff.hunks")
local helpers = require("tests.helpers")

describe("hunks.collect", function()
  it("collects working-tree changes plus untracked files", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\ntwo\nthree" })
    helpers.write_file(repo, "a.lua", "one\nCHANGED\nthree")
    helpers.write_file(repo, "brand_new.lua", "hello")

    local inv, err
    hunks.collect({ git_root = repo }, function(i, e) inv, err = i, e end)
    helpers.wait_for(function() return inv or err end)

    assert.is_nil(err)
    assert.equals(2, #inv.hunks)
    assert.equals("a.lua:1", inv.hunks[1].id)
    assert.equals("brand_new.lua:1", inv.hunks[2].id)
    assert.equals("??", inv.hunks[2].status)
    assert.is_string(inv.diff_hash)
    assert.equals(64, #inv.diff_hash)
  end)

  it("diff hash changes when content changes", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one\ntwo" })
    helpers.write_file(repo, "a.lua", "one\nX")
    local h1
    hunks.collect({ git_root = repo }, function(i) h1 = i.diff_hash end)
    helpers.wait_for(function() return h1 end)
    helpers.write_file(repo, "a.lua", "one\nY")
    local h2
    hunks.collect({ git_root = repo }, function(i) h2 = i.diff_hash end)
    helpers.wait_for(function() return h2 end)
    assert.not_equals(h1, h2)
  end)

  it("two-revision mode skips untracked and reports rev-vs-rev", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    helpers.write_file(repo, "a.lua", "two")
    helpers.git(repo, "add", "-A")
    helpers.git(repo, "commit", "-q", "-m", "second")
    helpers.write_file(repo, "untracked.lua", "x")
    local inv
    hunks.collect({ git_root = repo, base = "HEAD~1", target = "HEAD" }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)
    assert.equals(1, #inv.hunks)
    assert.equals("a.lua:1", inv.hunks[1].id)
  end)

  it("reports git errors", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local err
    hunks.collect({ git_root = repo, base = "no-such-rev" }, function(_, e) err = e end)
    helpers.wait_for(function() return err end)
    assert.truthy(err:find("git diff failed"))
  end)
end)
