local helpers = require("tests.helpers")
local github = require("intentdiff.forges.github")

local restore

describe("forges.github.detect", function()
  after_each(function()
    if restore then
      restore()
      restore = nil
    end
  end)

  it("matches github remotes in both URL forms", function()
    assert.is_true(github.matches("git@github.com:o/r.git"))
    assert.is_true(github.matches("https://github.com/o/r.git"))
    assert.is_false(github.matches("git@gitlab.com:o/r.git"))
    assert.is_false(github.matches(nil))
  end)

  it("returns a target for an open PR", function()
    restore = helpers.fake_bin("gh", [[
echo '{"number":123,"url":"https://github.com/o/r/pull/123","title":"Add retries","headRefOid":"aaaabbbb","baseRefName":"main","state":"OPEN"}'
]])
    local got, err, done
    github.detect(vim.fn.getcwd(), "feat/x", function(t, e)
      got, err, done = t, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_nil(err)
    assert.equals("github", got.service)
    assert.equals("123", got.id)
    assert.equals("aaaabbbb", got.head_sha)
    assert.equals("main", got.base_ref)
    assert.equals("https://github.com/o/r/pull/123", got.url)
  end)

  it("answers no-PR without an error when gh finds none", function()
    restore = helpers.fake_bin("gh", [[
echo "no pull requests found for branch \"feat/x\"" >&2
exit 1
]])
    local got, err, done
    github.detect(vim.fn.getcwd(), "feat/x", function(t, e)
      got, err, done = t, e, true
    end)
    helpers.wait_for(function() return done end)
    -- Without this, the two is_nil assertions below are exactly the
    -- pre-callback values of these locals: a detect() that never called back
    -- would pass. wait_for returns silently on timeout, so nothing else catches it.
    assert.is_true(done)
    assert.is_nil(got)
    assert.is_nil(err)
  end)

  it("treats a merged PR as nothing to review", function()
    restore = helpers.fake_bin("gh", [[
echo '{"number":9,"url":"u","title":"t","headRefOid":"a","baseRefName":"main","state":"MERGED"}'
]])
    local got, err, done
    github.detect(vim.fn.getcwd(), "feat/x", function(t, e)
      got, err, done = t, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_nil(got)
    assert.is_truthy(err:match("MERGED"))
  end)

  it("surfaces an authentication failure as a real error", function()
    restore = helpers.fake_bin("gh", [[
echo "gh: To use GitHub CLI in a GitHub Actions workflow, set the GH_TOKEN" >&2
exit 4
]])
    local got, err, done
    github.detect(vim.fn.getcwd(), "feat/x", function(t, e)
      got, err, done = t, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_nil(got)
    assert.is_truthy(err:match("GH_TOKEN"))
  end)

  it("reports a missing gh instead of raising", function()
    local old = vim.env.PATH
    vim.env.PATH = "/nonexistent"
    restore = function() vim.env.PATH = old end
    local got, err, done
    github.detect(vim.fn.getcwd(), "feat/x", function(t, e)
      got, err, done = t, e, true
    end)
    helpers.wait_for(function() return done end)
    assert.is_nil(got)
    assert.is_truthy(err)
  end)
end)
