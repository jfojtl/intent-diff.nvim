local submit = require("intentdiff.comments.submit")

local function target()
  return { service = "github", id = "123", url = "u", title = "T",
    head_sha = "aaaa", base_ref = "main" }
end

describe("comments.submit.plan", function()
  it("refuses and explains when preflight says no PR", function()
    local p = submit.plan({ branch = "feat/x" },
      { mode = "no_pr", reason = "no PR for branch feat/x — create one first (gh pr create)" }, 2, 2)
    assert.is_false(p.ok)
    assert.is_truthy(p.message:match("gh pr create"))
  end)

  it("refuses on the default branch", function()
    local p = submit.plan({ branch = "main" },
      { mode = "default_branch", reason = "you are on main — no PR to comment on" }, 2, 2)
    assert.is_false(p.ok)
    assert.is_truthy(p.message:match("no PR to comment on"))
  end)

  it("announces an inline submit with the PR number", function()
    local p = submit.plan({ target = target() }, { mode = "inline" }, 3, 3)
    assert.is_true(p.ok)
    assert.equals("inline", p.mode)
    assert.is_truthy(p.message:match("#123"))
    assert.is_truthy(p.message:match("3 comment"))
    assert.is_false(p.verdict_only)
  end)

  it("states the reason when degrading to a general comment", function()
    local p = submit.plan({ target = target() },
      { mode = "general", reason = "2 of 3 commented files have uncommitted changes" }, 3, 3)
    assert.is_true(p.ok)
    assert.equals("general", p.mode)
    assert.is_truthy(p.message:match("uncommitted"))
    assert.is_truthy(p.message:match("not on individual lines"))
  end)

  it("reports how many were already posted", function()
    local p = submit.plan({ target = target() }, { mode = "inline" }, 2, 6)
    assert.is_truthy(p.message:match("4 of 6"))
    assert.is_truthy(p.message:match("2 new"))
  end)

  it("offers a verdict-only submit when everything is posted", function()
    local p = submit.plan({ target = target() }, { mode = "inline" }, 0, 6)
    assert.is_true(p.ok)
    assert.is_true(p.verdict_only)
    assert.is_truthy(p.message:match("already posted"))
  end)
end)

describe("comments.submit.verdict_choices", function()
  it("offers the three verdicts a forge advertises, plus cancel", function()
    local choices = submit.verdict_choices({
      verdicts = { "approve", "request_changes", "comment" },
    })
    assert.equals(4, #choices)
    assert.equals("approve", choices[1].verdict)
    assert.equals("request_changes", choices[2].verdict)
    assert.equals("comment", choices[3].verdict)
    assert.is_nil(choices[4].verdict)
    assert.is_truthy(choices[4].label:match("[Cc]ancel"))
  end)

  it("omits a verdict the forge cannot express", function()
    local choices = submit.verdict_choices({ verdicts = { "comment" } })
    assert.equals(2, #choices)
    assert.equals("comment", choices[1].verdict)
  end)
end)
