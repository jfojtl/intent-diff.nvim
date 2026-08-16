local payload = require("intentdiff.comments.payload")

--- Two groups, matching tests/comments_export_spec.lua. Ranges END-EXCLUSIVE.
local function model()
  return {
    state = "ready",
    groups = {
      {
        title = "Rename UserService to AccountService",
        hunks = {
          { id = "src/api/routes.ts:1", file = "src/api/routes.ts",
            original = { start_line = 4, end_line = 6 },
            modified = { start_line = 4, end_line = 6 } },
          { id = "src/services/account.ts:1", file = "src/services/account.ts",
            original = { start_line = 40, end_line = 52 },
            modified = { start_line = 40, end_line = 50 } },
        },
        files = {
          { path = "src/api/routes.ts", status = "M" },
          { path = "src/services/account.ts", status = "M" },
        },
      },
      {
        title = "Add retry logic to HTTP client",
        hunks = {
          { id = "src/http/client.ts:1", file = "src/http/client.ts",
            original = { start_line = 40, end_line = 50 },
            modified = { start_line = 40, end_line = 56 } },
        },
        files = { { path = "src/http/client.ts", status = "M" } },
      },
    },
  }
end

local function comments()
  return {
    { file = "src/api/routes.ts", line = 5, side = "new", type = "issue",
      text = "This import still points at the old module." },
    { file = "src/services/account.ts", line = 41, side = "old", type = "suggestion",
      text = "The old implementation was cleaner." },
    { file = "src/http/client.ts", line = 0, type = "praise",
      text = "Good call keeping the timeout separate." },
    { file = "src/http/client.ts", line = 44, line_end = 51, side = "new", type = "note",
      text = "No jitter here — fine for now." },
    { intent_title = "Rename UserService to AccountService", type = "note",
      text = "This rename missed the DI container entirely." },
  }
end

describe("comments.payload", function()
  describe("inline mode", function()
    it("emits one inline comment per line comment, text only", function()
      local p = payload.build(comments(), model(), "inline")
      assert.equals(4, #p.comments)
      local first = p.comments[1]
      assert.equals("src/api/routes.ts", first.path)
      assert.equals(5, first.line)
      assert.equals("new", first.side)
      assert.equals("**[ISSUE]** This import still points at the old module.", first.body)
      -- The intent belongs in the body, never on the inline comment.
      assert.is_nil(first.body:match("Intent"))
    end)

    it("carries range, old side and file-level shape through", function()
      local p = payload.build(comments(), model(), "inline")
      local by_text = {}
      for _, c in ipairs(p.comments) do
        by_text[c.body] = c
      end
      local range = by_text["**[NOTE]** No jitter here — fine for now."]
      assert.equals(44, range.line)
      assert.equals(51, range.line_end)
      local old = by_text["**[SUGGESTION]** The old implementation was cleaner."]
      assert.equals("old", old.side)
      assert.equals(41, old.line)
      local file = by_text["**[PRAISE]** Good call keeping the timeout separate."]
      assert.is_true(file.file_level)
      assert.equals(0, file.line)
    end)

    it("indexes each inline comment under its intent in the body", function()
      local p = payload.build(comments(), model(), "inline")
      assert.is_truthy(p.body:match("## Rename UserService to AccountService"))
      assert.is_truthy(p.body:match("This rename missed the DI container entirely%."))
      assert.is_truthy(p.body:match("`src/api/routes%.ts:5` — ISSUE"))
      assert.is_truthy(p.body:match("`src/services/account%.ts:~41` — SUGGESTION"))
      assert.is_truthy(p.body:match("`src/http/client%.ts:44%-51` — NOTE"))
    end)

    it("does not repeat an inline comment's text in the body", function()
      local p = payload.build(comments(), model(), "inline")
      assert.is_nil(p.body:match("This import still points at the old module"))
    end)

    it("writes an unanchorable comment into the body in full", function()
      local anchorable = function(c)
        return not (c.file == "src/api/routes.ts" and c.line == 5)
      end
      local p = payload.build(comments(), model(), "inline", anchorable)
      assert.equals(3, #p.comments)
      assert.equals(1, p.demoted)
      assert.is_truthy(p.body:match("## Not attached to a line"))
      assert.is_truthy(p.body:match("This import still points at the old module%."))
      -- Demoted once, not also indexed under its intent.
      assert.is_nil(p.body:match("`src/api/routes%.ts:5` — ISSUE"))
    end)

    it("indexes a comment matching no intent, without repeating its text", function()
      local p = payload.build({
        { file = "nowhere.ts", line = 9, side = "new", type = "note", text = "orphan" },
      }, model(), "inline")
      -- Posted inline: matching no intent says nothing about whether GitHub can
      -- anchor it, so its text lives inline and the body only points at it.
      assert.equals(1, #p.comments)
      assert.is_truthy(p.body:match("## Not attached to an intent"))
      assert.is_truthy(p.body:match("`nowhere%.ts:9` — NOTE"))
      assert.is_nil(p.body:match("orphan"))
      assert.is_nil(p.body:match("## Not attached to a line"))
    end)

    it("keeps the two unattached headings apart", function()
      local anchorable = function(c) return c.file ~= "gone.ts" end
      local p = payload.build({
        { file = "nowhere.ts", line = 9, side = "new", type = "note", text = "orphan" },
        { file = "gone.ts", line = 3, side = "new", type = "issue", text = "vanished" },
      }, model(), "inline", anchorable)
      assert.equals(1, #p.comments)
      assert.equals(1, p.demoted)
      -- Indexed: posted inline, just not under any intent.
      assert.is_truthy(p.body:match("## Not attached to an intent"))
      assert.is_truthy(p.body:match("`nowhere%.ts:9` — NOTE"))
      -- Full text: nowhere else for it to live.
      assert.is_truthy(p.body:match("## Not attached to a line"))
      assert.is_truthy(p.body:match("vanished"))
    end)

    it("carries an orphaned intent comment's title in the body", function()
      local p = payload.build({
        { intent_title = "A group that was renamed away", type = "note", text = "prose" },
      }, model(), "inline")
      assert.equals(0, #p.comments)
      assert.is_truthy(p.body:match("_Intent: A group that was renamed away_"))
      assert.is_truthy(p.body:match("prose"))
    end)

    it("degrades to a flat body when classification produced no groups", function()
      local p = payload.build(comments(), { groups = {} }, "inline")
      assert.is_nil(p.body:match("## Rename"))
      assert.is_truthy(p.body:match("This rename missed the DI container entirely%."))
      -- No heading names the intent in the flat fallback, so the title has to
      -- travel with the comment — same rule as export.generate.
      assert.is_truthy(p.body:match("_Intent: Rename UserService to AccountService_"))
      assert.equals(4, #p.comments)
    end)
  end)

  describe("general mode", function()
    it("posts the Markdown export as the body with no inline comments", function()
      local export = require("intentdiff.comments.export")
      local p = payload.build(comments(), model(), "general")
      assert.equals(0, #p.comments)
      assert.equals(export.generate(comments(), model()), p.body)
    end)

    it("ignores the anchorable predicate entirely", function()
      local p = payload.build(comments(), model(), "general", function() return false end)
      assert.equals(0, p.demoted)
    end)
  end)

  it("builds a verdict-only body when there are no comments", function()
    local p = payload.build({}, model(), "inline")
    assert.equals(0, #p.comments)
    assert.is_truthy(p.body:match("no new comments"))
  end)
end)
