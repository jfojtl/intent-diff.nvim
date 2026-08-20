local store = require("intentdiff.comments.store")

describe("comments.store", function()
  -- A fresh instance per test: the store is per-review now, so there is no
  -- shared module state to reset — and listeners registered by one test can no
  -- longer be fired by the next.
  local s

  before_each(function()
    s = store.new()
  end)

  it("hands out independent stores", function()
    local other = store.new()
    s.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "mine" })
    assert.equals(1, s.count())
    assert.equals(0, other.count())
    assert.same({}, other.get_all())
  end)

  it("adds a line comment and returns it", function()
    local c = s.add({ file = "a.lua", line = 5, side = "new", type = "issue", text = "bad" })
    assert.equals("a.lua", c.file)
    assert.equals(5, c.line)
    assert.is_number(c.created_at)
    assert.equals(1, s.count())
  end)

  it("refuses a second comment on the same line and side", function()
    s.add({ file = "a.lua", line = 5, side = "new", type = "issue", text = "one" })
    local c, err = s.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "two" })
    assert.is_nil(c)
    assert.is_truthy(err:match("already exists"))
    assert.equals(1, s.count())
  end)

  it("allows the same line on the other side", function()
    s.add({ file = "a.lua", line = 5, side = "new", type = "issue", text = "new side" })
    local c = s.add({ file = "a.lua", line = 5, side = "old", type = "issue", text = "old side" })
    assert.is_truthy(c)
    assert.equals(2, s.count())
  end)

  it("refuses a range that overlaps an existing comment", function()
    s.add({ file = "a.lua", line = 10, line_end = 20, side = "new", type = "note", text = "range" })
    local c, err = s.add({ file = "a.lua", line = 15, side = "new", type = "issue", text = "inside" })
    assert.is_nil(c)
    assert.is_truthy(err:match("already exists"))
  end)

  it("allows a range that merely abuts another", function()
    s.add({ file = "a.lua", line = 10, line_end = 20, side = "new", type = "note", text = "a" })
    assert.is_truthy(s.add({ file = "a.lua", line = 21, side = "new", type = "note", text = "b" }))
  end)

  it("allows a file-level comment alongside line comments", function()
    s.add({ file = "a.lua", line = 5, side = "new", type = "issue", text = "line" })
    assert.is_truthy(s.add({ file = "a.lua", line = 0, type = "praise", text = "file" }))
  end)

  it("refuses two file-level comments on one file", function()
    s.add({ file = "a.lua", line = 0, type = "praise", text = "one" })
    local c = s.add({ file = "a.lua", line = 0, type = "note", text = "two" })
    assert.is_nil(c)
  end)

  it("finds a comment at a line inside a range", function()
    local c = s.add({ file = "a.lua", line = 10, line_end = 20, side = "new", type = "note", text = "r" })
    assert.equals(c, s.get_at_line("a.lua", 15, "new"))
    assert.equals(c, s.get_at_line("a.lua", 10, "new"))
    assert.equals(c, s.get_at_line("a.lua", 20, "new"))
    assert.is_nil(s.get_at_line("a.lua", 21, "new"))
    assert.is_nil(s.get_at_line("a.lua", 15, "old"))
  end)

  it("filters get_for_file by side but always includes file-level comments", function()
    s.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "n" })
    s.add({ file = "a.lua", line = 2, side = "old", type = "note", text = "o" })
    s.add({ file = "a.lua", line = 0, type = "note", text = "f" })
    s.add({ file = "b.lua", line = 1, side = "new", type = "note", text = "other" })

    -- Test with "new" side: should get new-side comment and file-level comment
    local got_new = s.get_for_file("a.lua", "new")
    assert.equals(2, #got_new)
    local texts_new = {}
    for _, c in ipairs(got_new) do
      texts_new[c.text] = true
    end
    assert.is_true(texts_new["n"])
    assert.is_true(texts_new["f"])
    assert.is_nil(texts_new["o"])

    -- Test with nil side: should get all three a.lua comments
    local got_both = s.get_for_file("a.lua", nil)
    assert.equals(3, #got_both)
    local texts_both = {}
    for _, c in ipairs(got_both) do
      texts_both[c.text] = true
    end
    assert.is_true(texts_both["n"])
    assert.is_true(texts_both["o"])
    assert.is_true(texts_both["f"])
    assert.is_nil(texts_both["other"])
  end)

  it("stores and retrieves intent comments by title", function()
    s.add({ intent_title = "Rename things", type = "issue", text = "wrong" })
    s.add({ intent_title = "Other", type = "note", text = "fine" })
    local got = s.get_for_intent("Rename things")
    assert.equals(1, #got)
    assert.equals("wrong", got[1].text)
  end)

  it("allows several comments on one intent", function()
    s.add({ intent_title = "T", type = "issue", text = "one" })
    assert.is_truthy(s.add({ intent_title = "T", type = "note", text = "two" }))
    assert.equals(2, #s.get_for_intent("T"))
  end)

  it("updates a comment's type and text in place", function()
    local c = s.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "old" })
    assert.is_true(s.update(c, "issue", "new text"))
    assert.equals("issue", c.type)
    assert.equals("new text", c.text)
    assert.equals(1, s.count())
  end)

  it("deletes a comment", function()
    local c = s.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "x" })
    assert.is_true(s.delete(c))
    assert.equals(0, s.count())
    assert.is_false(s.delete(c))
  end)

  it("fires on_change after every mutation", function()
    local n = 0
    s.on_change(function() n = n + 1 end)
    local c = s.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "x" })
    s.update(c, "issue", "y")
    s.delete(c)
    assert.equals(3, n)
  end)

  it("replaces the whole set without firing on_change", function()
    local n = 0
    s.on_change(function() n = n + 1 end)
    s.replace({ { file = "a.lua", line = 1, side = "new", type = "note", text = "x", created_at = 1 } })
    assert.equals(1, s.count())
    assert.equals(0, n)
  end)

  it("keeps fetched discussion separate from local comments", function()
    s.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "local" })
    local remote = { remote = true, remote_kind = "inline", file = "a.lua", line = 2,
      side = "new", type = "note", text = "remote" }
    s.set_remote({ remote })

    assert.equals(1, s.count())
    assert.equals(1, #s.get_all())
    assert.same({ remote }, s.get_remote())
    assert.equals(2, #s.get_visible())
    s.clear()
    assert.same({ remote }, s.get_visible())
  end)

  it("visually replaces a stamped local comment with its fetched thread", function()
    local local_comment = s.add({
      file = "a.lua", line = 3, side = "new", type = "issue", text = "fix this",
      posted = { service = "github", target = "9" },
    })
    local remote = {
      remote = true, remote_kind = "inline", file = "a.lua", line = 3,
      side = "new", type = "note", text = "@me\n**[ISSUE]** fix this\n\n↳ @you\ndone",
      original_body = "**[ISSUE]** fix this",
    }
    s.set_remote({ remote })

    assert.same({ remote }, s.get_visible())
    assert.same({ local_comment }, s.get_all(), "local submission state must remain intact")
  end)
end)
