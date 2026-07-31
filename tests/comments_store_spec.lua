local store = require("intentdiff.comments.store")

describe("comments.store", function()
  before_each(function()
    store.clear()
  end)

  it("adds a line comment and returns it", function()
    local c = store.add({ file = "a.lua", line = 5, side = "new", type = "issue", text = "bad" })
    assert.equals("a.lua", c.file)
    assert.equals(5, c.line)
    assert.is_number(c.created_at)
    assert.equals(1, store.count())
  end)

  it("refuses a second comment on the same line and side", function()
    store.add({ file = "a.lua", line = 5, side = "new", type = "issue", text = "one" })
    local c, err = store.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "two" })
    assert.is_nil(c)
    assert.is_truthy(err:match("already exists"))
    assert.equals(1, store.count())
  end)

  it("allows the same line on the other side", function()
    store.add({ file = "a.lua", line = 5, side = "new", type = "issue", text = "new side" })
    local c = store.add({ file = "a.lua", line = 5, side = "old", type = "issue", text = "old side" })
    assert.is_truthy(c)
    assert.equals(2, store.count())
  end)

  it("refuses a range that overlaps an existing comment", function()
    store.add({ file = "a.lua", line = 10, line_end = 20, side = "new", type = "note", text = "range" })
    local c, err = store.add({ file = "a.lua", line = 15, side = "new", type = "issue", text = "inside" })
    assert.is_nil(c)
    assert.is_truthy(err:match("already exists"))
  end)

  it("allows a range that merely abuts another", function()
    store.add({ file = "a.lua", line = 10, line_end = 20, side = "new", type = "note", text = "a" })
    assert.is_truthy(store.add({ file = "a.lua", line = 21, side = "new", type = "note", text = "b" }))
  end)

  it("allows a file-level comment alongside line comments", function()
    store.add({ file = "a.lua", line = 5, side = "new", type = "issue", text = "line" })
    assert.is_truthy(store.add({ file = "a.lua", line = 0, type = "praise", text = "file" }))
  end)

  it("refuses two file-level comments on one file", function()
    store.add({ file = "a.lua", line = 0, type = "praise", text = "one" })
    local c = store.add({ file = "a.lua", line = 0, type = "note", text = "two" })
    assert.is_nil(c)
  end)

  it("finds a comment at a line inside a range", function()
    local c = store.add({ file = "a.lua", line = 10, line_end = 20, side = "new", type = "note", text = "r" })
    assert.equals(c, store.get_at_line("a.lua", 15, "new"))
    assert.equals(c, store.get_at_line("a.lua", 10, "new"))
    assert.equals(c, store.get_at_line("a.lua", 20, "new"))
    assert.is_nil(store.get_at_line("a.lua", 21, "new"))
    assert.is_nil(store.get_at_line("a.lua", 15, "old"))
  end)

  it("filters get_for_file by side but always includes file-level comments", function()
    store.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "n" })
    store.add({ file = "a.lua", line = 2, side = "old", type = "note", text = "o" })
    store.add({ file = "a.lua", line = 0, type = "note", text = "f" })
    store.add({ file = "b.lua", line = 1, side = "new", type = "note", text = "other" })

    -- Test with "new" side: should get new-side comment and file-level comment
    local got_new = store.get_for_file("a.lua", "new")
    assert.equals(2, #got_new)
    local texts_new = {}
    for _, c in ipairs(got_new) do
      texts_new[c.text] = true
    end
    assert.is_true(texts_new["n"])
    assert.is_true(texts_new["f"])
    assert.is_nil(texts_new["o"])

    -- Test with nil side: should get all three a.lua comments
    local got_both = store.get_for_file("a.lua", nil)
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
    store.add({ intent_title = "Rename things", type = "issue", text = "wrong" })
    store.add({ intent_title = "Other", type = "note", text = "fine" })
    local got = store.get_for_intent("Rename things")
    assert.equals(1, #got)
    assert.equals("wrong", got[1].text)
  end)

  it("allows several comments on one intent", function()
    store.add({ intent_title = "T", type = "issue", text = "one" })
    assert.is_truthy(store.add({ intent_title = "T", type = "note", text = "two" }))
    assert.equals(2, #store.get_for_intent("T"))
  end)

  it("updates a comment's type and text in place", function()
    local c = store.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "old" })
    assert.is_true(store.update(c, "issue", "new text"))
    assert.equals("issue", c.type)
    assert.equals("new text", c.text)
    assert.equals(1, store.count())
  end)

  it("deletes a comment", function()
    local c = store.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "x" })
    assert.is_true(store.delete(c))
    assert.equals(0, store.count())
    assert.is_false(store.delete(c))
  end)

  it("fires on_change after every mutation", function()
    local n = 0
    store.on_change(function() n = n + 1 end)
    local c = store.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "x" })
    store.update(c, "issue", "y")
    store.delete(c)
    assert.equals(3, n)
  end)

  it("replaces the whole set without firing on_change", function()
    local n = 0
    store.on_change(function() n = n + 1 end)
    store.replace({ { file = "a.lua", line = 1, side = "new", type = "note", text = "x", created_at = 1 } })
    assert.equals(1, store.count())
    assert.equals(0, n)
  end)
end)
