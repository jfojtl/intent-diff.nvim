# Review comments and Markdown export — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add line, range, file-level and whole-intent review comments to intent-diff's diff panes and sidebar, exportable as Markdown grouped by intent, to clipboard or file.

**Architecture:** A comment stores `(file, line, side)` and nothing about intents; intent membership is recomputed on every export by finding the hunk whose line range contains the line and asking the model which group owns that hunk. Six new modules under `lua/intentdiff/comments/` split by responsibility — pure store, disk persistence, float popup, extmark rendering, Markdown generation, and an action layer that the keymaps call. Everything else in the plugin is touched only to call `marks.refresh()` and to install keymaps.

**Tech Stack:** Lua, Neovim ≥ 0.10 API (`nvim_buf_set_extmark` with `virt_lines`/`sign_text`/`line_hl_group`, `nvim_open_win`), plenary.nvim busted test harness.

**Spec:** `docs/superpowers/specs/2026-07-31-intent-diff-comments-design.md`

## Global Constraints

- **Neovim ≥ 0.10.** No API newer than that.
- **No new plugin dependencies.** codediff.nvim stays the only one. The popup is built with `nvim_open_win`, not nui.nvim.
- **Every Neovim API call that can fail on user data is `pcall`'d** — a bad line number costs one extmark, not the render.
- **Highlight groups are defined with `default = true`** and re-established from the existing `IntentDiffHighlight` ColorScheme autocmd (`lua/intentdiff/highlight.lua`).
- **Keymaps go through `require("intentdiff.keymaps").install`** so `false` disables an action and a list binds several keys.
- **Tests are plenary busted specs** in `tests/`, run with `tests/run_tests.sh`. Use `tests/helpers.lua` (`make_repo`, `write_file`, `git`) for anything needing a repository.
- **Hunk line ranges are end-exclusive.** `hunk.modified = { start_line, end_line }` where a line `L` is inside iff `L >= start_line and L < end_line`. This is `range()` in `lua/intentdiff/hunks.lua:5-8`. Getting this wrong is the single most likely bug in this feature.
- **Comment types are `note`, `suggestion`, `issue`, `praise`** — this exact spelling, lowercase, everywhere in code and storage; uppercased only for display.
- **Work directly on `master`.** There is unrelated uncommitted work in the tree (`keymap_help.lua` and friends); never `git add -A` or `git commit -a`. Every commit lists its files explicitly.

## File Structure

| File | Responsibility |
|---|---|
| `lua/intentdiff/comments/store.lua` | In-memory comment records. Add, update, delete, query. Writes through to storage. No UI. |
| `lua/intentdiff/comments/storage.lua` | JSON persistence keyed by git root + revision range. Load, save, clear, expiry sweep. |
| `lua/intentdiff/comments/export.lua` | Pure Markdown generation, plus the clipboard and file targets. |
| `lua/intentdiff/comments/marks.lua` | Extmark rendering into pane buffers and the sidebar. |
| `lua/intentdiff/comments/popup.lua` | The type-picker and text-entry float. |
| `lua/intentdiff/comments/init.lua` | Action layer: cursor context resolution, add/edit/delete/navigate/list/export. The only module the rest of the plugin calls. |
| `lua/intentdiff/config.lua` | Modified: `comments` defaults, `keymaps.comments` surface, list-replace semantics for `comments.types`. |
| `lua/intentdiff/highlight.lua` | Modified: eight new highlight links plus a derivation helper for custom types. |
| `lua/intentdiff/view.lua` | Modified: call `marks.refresh()` after each pane rebuild; install comment keymaps on panes. |
| `lua/intentdiff/sidebar.lua` | Modified: install comment keymaps; render intent signs. |
| `lua/intentdiff/init.lua` | Modified: set the storage key on session open; clear it on close. |
| `lua/intentdiff/keymap_help.lua` | Modified: a COMMENTS section. |
| `plugin/intentdiff.lua` | Modified: four new commands. |

---

### Task 1: Config surface and highlights

Comments need a config namespace and highlight groups before anything can render. This task also fixes a latent trap: `vim.tbl_deep_extend` merges lists **by index**, so a user supplying two comment types would silently inherit defaults at indices 3 and 4 — the same bug `merge_keymaps` already exists to avoid for keymap lists (`lua/intentdiff/config.lua:146-168`).

**Files:**
- Modify: `lua/intentdiff/config.lua` (add to `M.defaults`, extend `M.setup`)
- Modify: `lua/intentdiff/highlight.lua` (add to `M.links`, add `M.comment_groups`)
- Test: `tests/config_spec.lua` (extend), `tests/highlight_spec.lua` (extend)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `config.options.comments` = `{ enabled: boolean, types: {key, name, icon}[], expire_days: integer|false, export_path: string }`
  - `config.options.keymaps.comments` = table of action → lhs
  - `highlight.comment_groups(type_key) -> sign_group: string, line_group: string`

- [ ] **Step 1: Write the failing config tests**

Append to `tests/config_spec.lua`, inside the existing top-level `describe`:

```lua
describe("comments config", function()
  it("defaults to enabled with the four built-in types", function()
    config.setup({})
    assert.is_true(config.options.comments.enabled)
    local keys = {}
    for _, t in ipairs(config.options.comments.types) do
      keys[#keys + 1] = t.key
    end
    assert.same({ "note", "suggestion", "issue", "praise" }, keys)
    assert.equals(".intentdiff-review.md", config.options.comments.export_path)
    assert.equals(7, config.options.comments.expire_days)
  end)

  it("replaces the types list outright instead of merging by index", function()
    config.setup({ comments = { types = { { key = "issue", name = "Issue", icon = "!" } } } })
    assert.equals(1, #config.options.comments.types)
    assert.equals("issue", config.options.comments.types[1].key)
  end)

  it("keeps default types when the user overrides another comments field", function()
    config.setup({ comments = { export_path = "review.md" } })
    assert.equals(4, #config.options.comments.types)
    assert.equals("review.md", config.options.comments.export_path)
  end)

  it("exposes a comments keymap surface a user can override per action", function()
    config.setup({ comments = {}, keymaps = { comments = { add_issue = "<leader>i" } } })
    assert.equals("<leader>i", config.options.keymaps.comments.add_issue)
    assert.equals("<localleader>cc", config.options.keymaps.comments.add_comment)
  end)

  it("lets an action be disabled with false", function()
    config.setup({ keymaps = { comments = { add_praise = false } } })
    assert.is_false(config.options.keymaps.comments.add_praise)
  end)
end)
```

Append to `tests/highlight_spec.lua`, inside its top-level `describe`:

```lua
it("derives sign and line groups from a type key", function()
  local sign, line = hl.comment_groups("issue")
  assert.equals("IntentDiffCommentIssue", sign)
  assert.equals("IntentDiffCommentIssueLine", line)
end)

it("derives groups for a custom type key too", function()
  local sign, line = hl.comment_groups("question")
  assert.equals("IntentDiffCommentQuestion", sign)
  assert.equals("IntentDiffCommentQuestionLine", line)
end)

it("defines the four built-in comment groups as default links", function()
  hl.ensure()
  local got = vim.api.nvim_get_hl(0, { name = "IntentDiffCommentIssue" })
  assert.is_true(got.default)
  assert.equals("DiagnosticWarn", got.link)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tests/run_tests.sh 2>&1 | grep -E "Success|Fail|Errors"`
Expected: failures in `config_spec` (`comments` is nil) and `highlight_spec` (`comment_groups` is nil).

- [ ] **Step 3: Add the config defaults**

In `lua/intentdiff/config.lua`, add to `M.defaults` immediately before the `keymaps = {` entry:

```lua
  -- Review comments attached to diff lines and to whole intents, exported as
  -- Markdown for an agent to act on. See :IntentDiffCommentsYank / …Write.
  comments = {
    enabled = true,
    -- The order the popup cycles them in. A type's highlight groups are
    -- derived from its key — see highlight.comment_groups.
    types = {
      { key = "note", name = "Note", icon = "✍" },
      { key = "suggestion", name = "Suggestion", icon = "💡" },
      { key = "issue", name = "Issue", icon = "⚠" },
      { key = "praise", name = "Praise", icon = "✨" },
    },
    -- Days before a stored review is swept. false disables the sweep.
    expire_days = 7,
    -- Default path offered by :IntentDiffCommentsWrite, relative to git root.
    export_path = ".intentdiff-review.md",
  },
```

Add the `comments` surface inside `M.defaults.keymaps`, after the `sidebar` table:

```lua
    -- Review comments. Cross-surface by nature: installed on the diff panes
    -- AND the sidebar, since an intent comment is added from a group row and
    -- a line comment from a pane.
    comments = {
      add_comment = "<localleader>cc", -- pick the type in the popup
      add_note = "<localleader>cn",
      add_suggestion = "<localleader>cs",
      add_issue = "<localleader>ci",
      add_praise = "<localleader>cp",
      add_file_comment = "<localleader>cf",
      edit_comment = "<localleader>ce",
      delete_comment = "<localleader>cd",
      list_comments = "<localleader>cl",
      next_comment = "]n",
      prev_comment = "[n",
      export_clipboard = "<localleader>cy",
      export_file = "<localleader>cw",
      clear_comments = "<localleader>cx",
      -- The review.nvim end-of-review flow: copy, then close. Plain `q` still
      -- closes without touching the clipboard.
      export_and_close = "<localleader>q",
    },
```

In `M.setup`, replace the body between the `opts.keymaps = nil` line and the `if #moved > 0` block with:

```lua
  -- comments.types is a LIST, and vim.tbl_deep_extend merges lists by index:
  -- a user supplying two types would silently inherit defaults at 3 and 4.
  -- Pull it out, deep-extend everything else, then put it back wholesale.
  local types = opts.comments and opts.comments.types
  if types then
    opts.comments = vim.tbl_extend("force", {}, opts.comments)
    opts.comments.types = nil
  end
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  if types then
    M.options.comments.types = vim.deepcopy(types)
  end
  M.options.keymaps = merge_keymaps(M.defaults.keymaps, keymaps)
```

- [ ] **Step 4: Add the highlight groups**

In `lua/intentdiff/highlight.lua`, add to `M.links`:

```lua
  IntentDiffCommentNote = "DiagnosticHint",
  IntentDiffCommentSuggestion = "DiagnosticInfo",
  IntentDiffCommentIssue = "DiagnosticWarn",
  IntentDiffCommentPraise = "DiagnosticOk",
  IntentDiffCommentNoteLine = "CursorLine",
  IntentDiffCommentSuggestionLine = "CursorLine",
  IntentDiffCommentIssueLine = "CursorLine",
  IntentDiffCommentPraiseLine = "CursorLine",
```

Add above `local function define()`:

```lua
--- Sign and line highlight groups for a comment type, derived from its key so
--- a user-configured type needs no extra registration: "issue" →
--- IntentDiffCommentIssue / IntentDiffCommentIssueLine.
--- @return string sign_group, string line_group
function M.comment_groups(type_key)
  local key = tostring(type_key or "note")
  local name = "IntentDiffComment" .. key:sub(1, 1):upper() .. key:sub(2)
  return name, name .. "Line"
end
```

And inside `define()`, after the `M.links` loop, define groups for any configured type that has no link yet, so an unstyled custom type renders instead of erroring:

```lua
  -- A user-configured type beyond the built-in four has no entry in M.links;
  -- point it at the note defaults so it still renders.
  local ok, config = pcall(require, "intentdiff.config")
  local types = ok and config.options and config.options.comments
    and config.options.comments.types or {}
  for _, t in ipairs(types) do
    local sign, line = M.comment_groups(t.key)
    if not M.links[sign] then
      vim.api.nvim_set_hl(0, sign, { link = "DiagnosticHint", default = true })
      vim.api.nvim_set_hl(0, line, { link = "CursorLine", default = true })
    end
  end
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `tests/run_tests.sh 2>&1 | tail -20`
Expected: `Success: N` with no failures or errors across the whole suite (the existing specs must still pass — `merge_keymaps` behaviour is unchanged).

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/config.lua lua/intentdiff/highlight.lua tests/config_spec.lua tests/highlight_spec.lua
git commit -m "feat(comments): config surface and highlight groups"
```

---

### Task 2: The comment store

Pure in-memory records with no disk and no UI, so it can be tested exhaustively without a review tab. Persistence is attached in Task 3.

**Files:**
- Create: `lua/intentdiff/comments/store.lua`
- Test: `tests/comments_store_spec.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `store.add(comment) -> comment|nil, err: string|nil` — stamps `created_at`, returns the stored record
  - `store.update(comment, type, text) -> boolean`
  - `store.delete(comment) -> boolean`
  - `store.get_all() -> Comment[]` (insertion order)
  - `store.get_for_file(file, side) -> Comment[]` — `side` nil means both; file-level comments (`line == 0`) are always included
  - `store.get_at_line(file, line, side) -> Comment|nil` — a range comment matches any line it spans
  - `store.get_for_intent(title) -> Comment[]`
  - `store.count() -> integer`
  - `store.clear()`
  - `store.replace(comments)` — bulk load, used by storage in Task 3
  - `store.on_change(fn)` — register a callback fired after every mutation

Comment record (from the spec):

```lua
--- @class intentdiff.Comment
--- @field file string|nil       repo-relative path; nil for an intent comment
--- @field line integer|nil      1-based; 0 = file-level; nil for an intent comment
--- @field line_end integer|nil  set only for a range comment
--- @field side "old"|"new"|nil  nil for file-level and intent comments
--- @field intent_title string|nil  set only for an intent comment
--- @field type string           note|suggestion|issue|praise
--- @field text string           may contain newlines
--- @field created_at integer    os.time()
```

- [ ] **Step 1: Write the failing tests**

Create `tests/comments_store_spec.lua`:

```lua
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
    local got = store.get_for_file("a.lua", "new")
    assert.equals(2, #got)
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_store_spec.lua" 2>&1 | tail -20`
Expected: FAIL — `module 'intentdiff.comments.store' not found`.

- [ ] **Step 3: Implement the store**

Create `lua/intentdiff/comments/store.lua`:

```lua
-- In-memory review comments for the current review.
--
-- Deliberately knows nothing about intents, buffers or disk: a comment records
-- WHERE it sits, and which intent that turns out to be is recomputed at export
-- time (see comments/export.lua). That is what makes re-classification free —
-- nothing stored ever goes stale.
--
-- Persistence hangs off on_change (wired in comments/storage.lua) rather than
-- being called from here, so this module stays pure and exhaustively testable.
local M = {}

--- @type intentdiff.Comment[]
local comments = {}
local listeners = {}

local function changed()
  for _, fn in ipairs(listeners) do
    pcall(fn)
  end
end

--- Register a callback fired after add/update/delete (not after replace, which
--- IS the load path and would otherwise write straight back out).
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

--- Inclusive last line a comment covers. A file-level comment (line 0) and an
--- intent comment cover nothing addressable.
local function span(c)
  if not c.line or c.line == 0 then
    return nil
  end
  return c.line, c.line_end or c.line
end

--- Does `c` already claim any line `candidate` wants, on the same file+side?
local function collides(c, candidate)
  if c.intent_title or candidate.intent_title then
    return false -- several comments per intent are fine
  end
  if c.file ~= candidate.file then
    return false
  end
  -- File-level: one per file, and never in the way of a line comment.
  if (c.line or 0) == 0 or (candidate.line or 0) == 0 then
    return (c.line or 0) == 0 and (candidate.line or 0) == 0
  end
  if (c.side or "new") ~= (candidate.side or "new") then
    return false
  end
  local a_start, a_end = span(c)
  local b_start, b_end = span(candidate)
  return a_start <= b_end and b_start <= a_end
end

--- @return intentdiff.Comment|nil comment, string|nil err
function M.add(comment)
  for _, existing in ipairs(comments) do
    if collides(existing, comment) then
      return nil, "Comment already exists at this line. Use edit instead."
    end
  end
  comment.created_at = comment.created_at or os.time()
  comments[#comments + 1] = comment
  changed()
  return comment
end

function M.update(comment, comment_type, text)
  for _, c in ipairs(comments) do
    if c == comment then
      c.type = comment_type or c.type
      c.text = text or c.text
      changed()
      return true
    end
  end
  return false
end

function M.delete(comment)
  for i, c in ipairs(comments) do
    if c == comment then
      table.remove(comments, i)
      changed()
      return true
    end
  end
  return false
end

function M.get_all()
  return comments
end

--- Comments to render in one pane. `side` nil means both sides. File-level
--- comments carry no side and belong on every pane showing that file.
function M.get_for_file(file, side)
  local out = {}
  for _, c in ipairs(comments) do
    if c.file == file and not c.intent_title then
      if (c.line or 0) == 0 or not side or (c.side or "new") == side then
        out[#out + 1] = c
      end
    end
  end
  return out
end

--- The comment covering `line`, for edit/delete at the cursor. A range comment
--- matches any line it spans, both endpoints included.
function M.get_at_line(file, line, side)
  for _, c in ipairs(comments) do
    if c.file == file and not c.intent_title and (c.side or "new") == (side or "new") then
      local first, last = span(c)
      if first and line >= first and line <= last then
        return c
      end
    end
  end
  return nil
end

function M.get_for_intent(title)
  local out = {}
  for _, c in ipairs(comments) do
    if c.intent_title == title then
      out[#out + 1] = c
    end
  end
  return out
end

function M.count()
  return #comments
end

function M.clear()
  comments = {}
  changed()
end

--- Bulk load. Does NOT fire on_change: this is the disk→memory direction.
function M.replace(loaded)
  comments = loaded or {}
end

return M
```

- [ ] **Step 4: Run to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_store_spec.lua" 2>&1 | tail -20`
Expected: PASS, `Success: 15`, no failures.

Note the `clear()` fires `changed()` while `replace()` does not — that asymmetry is intentional and the tests pin it. `clear()` is a user action that must persist; `replace()` is the load path and would write straight back out.

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/comments/store.lua tests/comments_store_spec.lua
git commit -m "feat(comments): in-memory comment store"
```

---

### Task 3: Persistence

Comments survive closing Neovim, keyed by repository and what was reviewed. Deliberately **not** keyed by the diff-text hash the classification cache uses: that hash changes the moment a file is edited, which would discard comments exactly when they are still relevant.

**Files:**
- Create: `lua/intentdiff/comments/storage.lua`
- Modify: `lua/intentdiff/comments/store.lua` (attach the key)
- Test: `tests/comments_storage_spec.lua`

**Interfaces:**
- Consumes: `store.replace`, `store.get_all`, `store.on_change` from Task 2; `config.options.cache_dir` and `config.options.comments.expire_days` from Task 1.
- Produces:
  - `storage.key(git_root, base_revision, target_revision) -> string|nil`
  - `storage.path(key) -> string|nil`
  - `storage.load(key) -> Comment[]`
  - `storage.save(key, comments) -> boolean`
  - `storage.clear(key)`
  - `storage.sweep()` — expiry, at most once per Neovim session
  - `store.attach(key)` — load from disk and persist on every later change
  - `store.detach()`

- [ ] **Step 1: Write the failing tests**

Create `tests/comments_storage_spec.lua`:

```lua
local storage = require("intentdiff.comments.storage")
local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")

describe("comments.storage", function()
  local cache

  before_each(function()
    cache = vim.fn.tempname()
    config.setup({ cache_dir = cache })
    store.detach()
    store.clear()
  end)

  it("keys a working-tree review by repo and branch", function()
    local k = storage.key("/repo/a", nil, nil, "feature/x")
    assert.is_truthy(k:match("feature_x$"))
  end)

  it("keys a revision-range review by both revisions", function()
    local k = storage.key("/repo/a", "abc1234567", "def7654321", "main")
    assert.is_truthy(k:match("abc12345_def76543$"))
  end)

  it("gives different repos different keys for the same branch", function()
    assert.are_not.equals(storage.key("/repo/a", nil, nil, "main"),
      storage.key("/repo/b", nil, nil, "main"))
  end)

  it("strips a trailing caret from a revision", function()
    local k = storage.key("/repo/a", "abc1234^", "abc1234", "main")
    assert.is_truthy(k:match("abc1234_abc1234$"))
  end)

  it("round-trips comments through disk", function()
    local given = { { file = "a.lua", line = 3, side = "new", type = "issue", text = "x", created_at = 1 } }
    assert.is_true(storage.save("k1", given))
    assert.same(given, storage.load("k1"))
  end)

  it("returns an empty list for an unknown key", function()
    assert.same({}, storage.load("nope"))
  end)

  it("treats a corrupt file as empty", function()
    storage.save("k2", { { file = "a.lua", line = 1, type = "note", text = "x", created_at = 1 } })
    local f = io.open(storage.path("k2"), "w")
    f:write("{ not json")
    f:close()
    assert.same({}, storage.load("k2"))
  end)

  it("clears a stored review", function()
    storage.save("k3", { { file = "a.lua", line = 1, type = "note", text = "x", created_at = 1 } })
    storage.clear("k3")
    assert.same({}, storage.load("k3"))
  end)

  it("sweeps files older than expire_days and keeps fresh ones", function()
    storage.save("old", { { file = "a.lua", line = 1, type = "note", text = "x", created_at = 1 } })
    storage.save("new", { { file = "b.lua", line = 1, type = "note", text = "y", created_at = 1 } })
    local stale = os.time() - (8 * 24 * 60 * 60)
    vim.loop.fs_utime(storage.path("old"), stale, stale)
    storage.sweep({ force = true })
    assert.same({}, storage.load("old"))
    assert.equals(1, #storage.load("new"))
  end)

  it("does not sweep when expire_days is false", function()
    storage.save("old", { { file = "a.lua", line = 1, type = "note", text = "x", created_at = 1 } })
    local stale = os.time() - (400 * 24 * 60 * 60)
    vim.loop.fs_utime(storage.path("old"), stale, stale)
    config.setup({ cache_dir = cache, comments = { expire_days = false } })
    storage.sweep({ force = true })
    assert.equals(1, #storage.load("old"))
  end)

  it("survives an unwritable cache directory", function()
    config.setup({ cache_dir = "/proc/nonexistent-intentdiff" })
    assert.is_false(storage.save("k4", { { file = "a.lua", line = 1, type = "note", text = "x", created_at = 1 } }))
    assert.same({}, storage.load("k4"))
  end)

  it("attach loads existing comments into the store", function()
    storage.save("k5", { { file = "a.lua", line = 7, side = "new", type = "note", text = "hi", created_at = 1 } })
    store.attach("k5")
    assert.equals(1, store.count())
    assert.equals(7, store.get_all()[1].line)
  end)

  it("attach persists every later change", function()
    store.attach("k6")
    store.add({ file = "a.lua", line = 2, side = "new", type = "issue", text = "z" })
    assert.equals(1, #storage.load("k6"))
    store.clear()
    assert.equals(0, #storage.load("k6"))
  end)

  it("detach stops persisting", function()
    store.attach("k7")
    store.add({ file = "a.lua", line = 2, side = "new", type = "issue", text = "z" })
    store.detach()
    store.clear()
    assert.equals(1, #storage.load("k7"))
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_storage_spec.lua" 2>&1 | tail -20`
Expected: FAIL — `module 'intentdiff.comments.storage' not found`.

- [ ] **Step 3: Implement storage**

Create `lua/intentdiff/comments/storage.lua`:

```lua
-- Disk persistence for review comments, keyed by repository plus what is being
-- reviewed — NOT by the diff-text hash the classification cache uses. That
-- hash changes the moment a file is edited, which would drop comments exactly
-- when they still matter.
local M = {}

local config = require("intentdiff.config")

local function dir()
  return config.options.cache_dir .. "/comments"
end

--- The same cheap string hash review.nvim uses: enough to keep two repos
--- apart in a filename, not a security boundary.
local function hash(str)
  local h = 0
  for i = 1, #str do
    h = ((h * 31) + string.byte(str, i)) % 2147483647
  end
  return string.format("%x", h)
end

local function short_rev(rev)
  return (tostring(rev):gsub("%^+$", "")):sub(1, 8)
end

--- Storage key for a review. A revision range keys by both revisions; a
--- working-tree review keys by branch, so returning to the branch resumes.
--- @return string|nil
function M.key(git_root, base_revision, target_revision, branch)
  if not git_root or git_root == "" then
    return nil
  end
  local project = hash(git_root)
  if base_revision and target_revision then
    return ("%s-%s_%s"):format(project, short_rev(base_revision), short_rev(target_revision))
  end
  if not branch or branch == "" then
    return nil
  end
  return ("%s-%s"):format(project, (branch:gsub("[^%w%-_]", "_")))
end

--- @return string|nil
function M.path(key)
  if not key then
    return nil
  end
  return ("%s/%s.json"):format(dir(), key)
end

local warned = false

--- @return boolean whether the write landed
function M.save(key, comments)
  local path = M.path(key)
  if not path then
    return false
  end
  local ok_dir = pcall(vim.fn.mkdir, dir(), "p")
  local file = ok_dir and io.open(path, "w") or nil
  if not file then
    if not warned then
      warned = true
      vim.notify(
        "intent-diff: cannot write comments to " .. dir() .. " — they will not persist",
        vim.log.levels.WARN
      )
    end
    require("intentdiff.log").write("comments: save failed for " .. tostring(path))
    return false
  end
  local ok, encoded = pcall(vim.json.encode, comments)
  if not ok then
    file:close()
    return false
  end
  file:write(encoded)
  file:close()
  return true
end

--- @return intentdiff.Comment[]
function M.load(key)
  M.sweep()
  local path = M.path(key)
  if not path then
    return {}
  end
  local file = io.open(path, "r")
  if not file then
    return {}
  end
  local content = file:read("*a")
  file:close()
  if not content or content == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    require("intentdiff.log").write("comments: corrupt store at " .. path .. ", ignoring")
    return {}
  end
  return decoded
end

function M.clear(key)
  local path = M.path(key)
  if path then
    os.remove(path)
  end
end

local swept = false

--- Remove stored reviews older than comments.expire_days. Runs at most once
--- per Neovim session; `opts.force` is for tests.
function M.sweep(opts)
  if swept and not (opts and opts.force) then
    return
  end
  swept = true
  local days = config.options.comments and config.options.comments.expire_days
  if not days then
    return
  end
  local cutoff = os.time() - (days * 24 * 60 * 60)
  for _, path in ipairs(vim.fn.glob(dir() .. "/*.json", false, true)) do
    local mtime = vim.fn.getftime(path)
    if mtime > 0 and mtime < cutoff then
      os.remove(path)
    end
  end
end

return M
```

Note `M.load` calls `M.sweep()` with no `force`, so the once-per-session guard makes it a no-op after the first review. The tests pass `force = true` to exercise it directly.

- [ ] **Step 4: Attach the store to storage**

Append to `lua/intentdiff/comments/store.lua`, before `return M`:

```lua
--- Storage key this review persists under, or nil for a non-persisting one.
local key = nil
local hooked = false

--- Load `key`'s stored comments and persist every later change to it.
function M.attach(storage_key)
  local storage = require("intentdiff.comments.storage")
  key = storage_key
  M.replace(storage.load(key))
  if not hooked then
    hooked = true
    M.on_change(function()
      if key then
        storage.save(key, comments)
      end
    end)
  end
end

--- Stop persisting. The in-memory comments are left alone.
function M.detach()
  key = nil
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_storage_spec.lua" 2>&1 | tail -20`
Expected: PASS, `Success: 15`, no failures.

If the unwritable-directory test fails on this machine because `/proc` behaves differently, substitute a path under a file rather than a directory — e.g. create a temp *file* and use `<that file>/sub` as `cache_dir`. Do not delete the test.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/comments/storage.lua lua/intentdiff/comments/store.lua tests/comments_storage_spec.lua
git commit -m "feat(comments): persist reviews per repo and revision range"
```

---

### Task 4: Markdown export

The plugin's contract with the agent, and pure — a comment list plus a model in, a string out — so it gets the most test weight in the feature.

**Files:**
- Create: `lua/intentdiff/comments/export.lua`
- Test: `tests/comments_export_spec.lua`

**Interfaces:**
- Consumes: the `Comment` shape from Task 2. The model shape built by `intentdiff.init`'s `grouped_model`: `{ state, groups = { { title, hunks, files, is_ungrouped } } }`, where a hunk is `{ id, file, status, original = { start_line, end_line }, modified = { start_line, end_line } }` (**end-exclusive**) and a file entry is `{ path, status, hunks }`.
- Produces:
  - `export.generate(comments, model) -> string`
  - `export.to_clipboard(comments, model) -> boolean`
  - `export.to_file(comments, model, path) -> boolean, string|nil err`

- [ ] **Step 1: Write the failing tests**

Create `tests/comments_export_spec.lua`:

```lua
local export = require("intentdiff.comments.export")

--- A model with two groups. Hunk ranges are END-EXCLUSIVE, matching hunks.lua.
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
            original = { start_line = 40, end_line = 50 },
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
            original = { start_line = 40, end_line = 60 },
            modified = { start_line = 40, end_line = 60 } },
        },
        files = { { path = "src/http/client.ts", status = "M" } },
      },
    },
  }
end

describe("comments.export", function()
  it("reports an empty store plainly", function()
    assert.equals("No comments yet.", export.generate({}, model()))
  end)

  it("files each comment under the intent owning its line", function()
    local md = export.generate({
      { file = "src/http/client.ts", line = 44, side = "new", type = "note", text = "No jitter." },
      { file = "src/api/routes.ts", line = 5, side = "new", type = "issue", text = "Old module." },
    }, model())
    assert.is_truthy(md:match("## Rename UserService to AccountService"))
    assert.is_truthy(md:match("## Add retry logic to HTTP client"))
    -- Group order follows the model, not the order comments were added.
    assert.is_true(md:find("## Rename", 1, true) < md:find("## Add retry", 1, true))
  end)

  it("numbers continuously across groups", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "issue", text = "a" },
      { file = "src/http/client.ts", line = 44, side = "new", type = "note", text = "b" },
    }, model())
    assert.is_truthy(md:match("1%. %*%*%[ISSUE%]%*%* `src/api/routes%.ts:5`"))
    assert.is_truthy(md:match("2%. %*%*%[NOTE%]%*%* `src/http/client%.ts:44`"))
  end)

  it("marks an old-side line with ~ and explains it", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "old", type = "suggestion", text = "cleaner" },
    }, model())
    assert.is_truthy(md:match("`src/api/routes%.ts:~5`"))
    assert.is_truthy(md:match("Lines prefixed with ~"))
  end)

  it("omits the ~ legend when no old-side comment exists", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "x" },
    }, model())
    assert.is_nil(md:match("Lines prefixed with ~"))
  end)

  it("renders ranges, old-side ranges and file-level locations", function()
    local md = export.generate({
      { file = "src/http/client.ts", line = 44, line_end = 51, side = "new", type = "note", text = "r" },
      { file = "src/api/routes.ts", line = 4, line_end = 5, side = "old", type = "note", text = "o" },
      { file = "src/http/client.ts", line = 0, type = "praise", text = "f" },
    }, model())
    assert.is_truthy(md:match("`src/http/client%.ts:44%-51`"))
    assert.is_truthy(md:match("`src/api/routes%.ts:~4%-~5`"))
    assert.is_truthy(md:match("`src/http/client%.ts`\n"))
  end)

  it("puts an intent comment as a paragraph before that group's list", function()
    local md = export.generate({
      { intent_title = "Add retry logic to HTTP client", type = "issue", text = "Whole thing is wrong." },
      { file = "src/http/client.ts", line = 44, side = "new", type = "note", text = "detail" },
    }, model())
    local head = md:find("## Add retry logic", 1, true)
    local para = md:find("Whole thing is wrong.", 1, true)
    local item = md:find("**[NOTE]**", 1, true)
    assert.is_true(head < para and para < item)
  end)

  it("indents multi-line comment text instead of breaking the list", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "line one\nline two" },
    }, model())
    assert.is_truthy(md:match("\n   line one\n   line two"))
  end)

  it("always emits the type legend", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "x" },
    }, model())
    assert.is_truthy(md:match("Comment types: ISSUE"))
  end)

  it("falls back to a flat list when there are no groups", function()
    local md = export.generate({
      { file = "a.lua", line = 5, side = "new", type = "note", text = "x" },
    }, { state = "loading", groups = {} })
    assert.is_nil(md:match("\n## "))
    assert.is_truthy(md:match("1%. %*%*%[NOTE%]%*%* `a%.lua:5`"))
  end)

  it("sends a line matching no hunk to Unmatched", function()
    local md = export.generate({
      { file = "src/api/routes.ts", line = 900, side = "new", type = "note", text = "drifted" },
    }, model())
    assert.is_truthy(md:match("## Unmatched comments"))
  end)

  it("sends an intent comment with no matching group to Unmatched", function()
    local md = export.generate({
      { intent_title = "A group that no longer exists", type = "note", text = "orphan" },
    }, model())
    assert.is_truthy(md:match("## Unmatched comments"))
    assert.is_truthy(md:match("orphan"))
  end)

  it("treats hunk ranges as end-exclusive", function()
    -- routes.ts hunk covers modified lines 4 and 5, not 6.
    local inside = export.generate({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "in" },
    }, model())
    assert.is_nil(inside:match("Unmatched"))
    local outside = export.generate({
      { file = "src/api/routes.ts", line = 6, side = "new", type = "note", text = "out" },
    }, model())
    assert.is_truthy(outside:match("Unmatched"))
  end)

  it("resolves an old-side comment against the hunk's original range", function()
    local md = export.generate({
      { file = "src/services/account.ts", line = 45, side = "old", type = "note", text = "x" },
    }, model())
    assert.is_nil(md:match("Unmatched"))
    assert.is_truthy(md:match("## Rename UserService"))
  end)

  it("resolves a file-level comment by file, not by line", function()
    local md = export.generate({
      { file = "src/http/client.ts", line = 0, type = "praise", text = "nice" },
    }, model())
    assert.is_truthy(md:match("## Add retry logic"))
    assert.is_nil(md:match("Unmatched"))
  end)

  it("orders within a group by file then line, file-level first", function()
    local md = export.generate({
      { file = "src/services/account.ts", line = 45, side = "new", type = "note", text = "second-file" },
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "first-file-line" },
      { file = "src/api/routes.ts", line = 0, type = "note", text = "first-file-level" },
    }, model())
    local a = md:find("first-file-level", 1, true)
    local b = md:find("first-file-line", 1, true)
    local c = md:find("second-file", 1, true)
    assert.is_true(a < b and b < c)
  end)

  it("puts Ungrouped last", function()
    local m = model()
    m.groups[#m.groups + 1] = {
      title = "Ungrouped", is_ungrouped = true,
      hunks = { { id = "docs/notes.md:1", file = "docs/notes.md",
        original = { start_line = 1, end_line = 4 },
        modified = { start_line = 1, end_line = 4 } } },
      files = { { path = "docs/notes.md", status = "??" } },
    }
    local md = export.generate({
      { file = "docs/notes.md", line = 2, side = "new", type = "note", text = "u" },
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "g" },
    }, m)
    assert.is_true(md:find("## Rename", 1, true) < md:find("## Ungrouped", 1, true))
  end)

  it("writes a file and creates parent directories", function()
    local path = vim.fn.tempname() .. "/nested/review.md"
    local ok = export.to_file({
      { file = "src/api/routes.ts", line = 5, side = "new", type = "note", text = "x" },
    }, model(), path)
    assert.is_true(ok)
    assert.is_truthy(table.concat(vim.fn.readfile(path), "\n"):match("%[NOTE%]"))
  end)

  it("refuses to write an empty review", function()
    local path = vim.fn.tempname() .. "/review.md"
    local ok, err = export.to_file({}, model(), path)
    assert.is_false(ok)
    assert.is_truthy(err)
    assert.equals(0, vim.fn.filereadable(path))
  end)

  it("refuses to touch the clipboard for an empty review", function()
    vim.fn.setreg("+", "SENTINEL")
    assert.is_false(export.to_clipboard({}, model()))
    assert.equals("SENTINEL", vim.fn.getreg("+"))
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_export_spec.lua" 2>&1 | tail -20`
Expected: FAIL — `module 'intentdiff.comments.export' not found`.

- [ ] **Step 3: Implement export**

Create `lua/intentdiff/comments/export.lua`:

```lua
-- Markdown generation: the plugin's contract with whatever agent reads the
-- review. Pure — comments plus a model in, a string out — so it is tested
-- exhaustively without a running review tab.
--
-- Intent membership is computed HERE, never stored, which is what makes
-- re-classification free: the same comments re-file themselves under whatever
-- groups exist now.
local M = {}

local HEADER = "I reviewed your code and have the following comments. Please address them."
local TYPE_LEGEND = "Comment types: ISSUE (problems to fix), SUGGESTION (improvements),\n"
  .. "NOTE (observations), PRAISE (positive feedback)"
local OLD_SIDE_LEGEND = "Lines prefixed with ~ refer to the old (left) side of the diff."
local UNMATCHED = "Unmatched comments"

--- Does `hunk` cover `line` on `side`? Ranges are END-EXCLUSIVE — see
--- hunks.lua's range(): { start_line = s, end_line = s + len }.
local function hunk_covers(hunk, line, side)
  local r = (side == "old") and hunk.original or hunk.modified
  if not r then
    return false
  end
  return line >= r.start_line and line < r.end_line
end

--- Index of the group a comment belongs to, or nil.
---
--- A line comment resolves through the hunk containing its line; a file-level
--- comment resolves by file (it has no line to place); an intent comment
--- resolves by title, so a group renamed by re-classification surfaces as
--- unattached rather than being silently misfiled onto whatever group now
--- occupies that position.
local function group_index(comment, model)
  local groups = (model and model.groups) or {}
  if comment.intent_title then
    for gi, g in ipairs(groups) do
      if g.title == comment.intent_title then
        return gi
      end
    end
    return nil
  end
  local side = comment.side or "new"
  for gi, g in ipairs(groups) do
    if (comment.line or 0) == 0 then
      for _, f in ipairs(g.files or {}) do
        if f.path == comment.file then
          return gi
        end
      end
    else
      for _, h in ipairs(g.hunks or {}) do
        if h.file == comment.file and hunk_covers(h, comment.line, side) then
          return gi
        end
      end
    end
  end
  return nil
end

--- `src/a.ts:12`, `src/a.ts:12-18`, `src/a.ts:~12`, `src/a.ts:~12-~18`, or a
--- bare path for a file-level comment.
local function location(c)
  if (c.line or 0) == 0 then
    return c.file
  end
  local mark = (c.side == "old") and "~" or ""
  if c.line_end and c.line_end ~= c.line then
    return ("%s:%s%d-%s%d"):format(c.file, mark, c.line, mark, c.line_end)
  end
  return ("%s:%s%d"):format(c.file, mark, c.line)
end

--- Sort key within a group: file path, then line, with the file-level comment
--- for a file ahead of its line comments.
local function before(a, b)
  if a.file ~= b.file then
    return (a.file or "") < (b.file or "")
  end
  return (a.line or 0) < (b.line or 0)
end

local function entry_lines(index, c, out)
  out[#out + 1] = ("%d. **[%s]** `%s`"):format(index, tostring(c.type):upper(), location(c))
  -- Text on its own indented lines, not after a " - " separator: a comment
  -- containing newlines would otherwise corrupt the numbered list.
  for _, line in ipairs(vim.split(c.text or "", "\n")) do
    out[#out + 1] = "   " .. line
  end
  out[#out + 1] = ""
end

--- @return string
function M.generate(comments, model)
  comments = comments or {}
  if #comments == 0 then
    return "No comments yet."
  end

  local groups = (model and model.groups) or {}
  -- Bucket by group index; nil index → unmatched.
  local buckets, unmatched = {}, {}
  for _, c in ipairs(comments) do
    local gi = #groups > 0 and group_index(c, model) or false
    if gi == nil then
      unmatched[#unmatched + 1] = c
    elseif gi == false then
      -- No groups at all (classification running or failed): flat list.
      buckets[0] = buckets[0] or { intents = {}, items = {} }
      table.insert(buckets[0].items, c)
    else
      buckets[gi] = buckets[gi] or { intents = {}, items = {} }
      if c.intent_title then
        table.insert(buckets[gi].intents, c)
      else
        table.insert(buckets[gi].items, c)
      end
    end
  end

  local has_old = false
  for _, c in ipairs(comments) do
    if c.side == "old" and (c.line or 0) ~= 0 then
      has_old = true
      break
    end
  end

  local out = { HEADER, "", TYPE_LEGEND }
  if has_old then
    out[#out + 1] = OLD_SIDE_LEGEND
  end
  out[#out + 1] = ""

  local n = 0
  local function emit(bucket)
    for _, c in ipairs(bucket.intents) do
      for _, line in ipairs(vim.split(c.text or "", "\n")) do
        out[#out + 1] = line
      end
      out[#out + 1] = ""
    end
    table.sort(bucket.items, before)
    for _, c in ipairs(bucket.items) do
      n = n + 1
      entry_lines(n, c, out)
    end
  end

  if buckets[0] then
    emit(buckets[0]) -- flat fallback: no headings
  end
  for gi, g in ipairs(groups) do
    local bucket = buckets[gi]
    if bucket then
      out[#out + 1] = "## " .. g.title
      out[#out + 1] = ""
      emit(bucket)
    end
  end
  if #unmatched > 0 then
    out[#out + 1] = "## " .. UNMATCHED
    out[#out + 1] = ""
    local bucket = { intents = {}, items = {} }
    for _, c in ipairs(unmatched) do
      if c.intent_title then
        table.insert(bucket.intents, c)
      else
        table.insert(bucket.items, c)
      end
    end
    emit(bucket)
  end

  -- Trim the trailing blank line an entry always emits.
  while out[#out] == "" do
    table.remove(out)
  end
  return table.concat(out, "\n")
end

--- @return boolean
function M.to_clipboard(comments, model)
  if #(comments or {}) == 0 then
    vim.notify("intent-diff: no comments to export", vim.log.levels.WARN)
    return false
  end
  local markdown = M.generate(comments, model)
  vim.fn.setreg("+", markdown)
  vim.fn.setreg("*", markdown)
  vim.notify(("intent-diff: copied %d comment(s)"):format(#comments), vim.log.levels.INFO)
  return true
end

--- @return boolean ok, string|nil err
function M.to_file(comments, model, path)
  if #(comments or {}) == 0 then
    return false, "no comments to export"
  end
  if not path or path == "" then
    return false, "no path given"
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    local ok = pcall(vim.fn.mkdir, dir, "p")
    if not ok then
      return false, "cannot create " .. dir
    end
  end
  local file = io.open(path, "w")
  if not file then
    return false, "cannot write " .. path
  end
  file:write(M.generate(comments, model))
  file:write("\n")
  file:close()
  return true
end

return M
```

- [ ] **Step 4: Run to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_export_spec.lua" 2>&1 | tail -20`
Expected: PASS, `Success: 21`, no failures.

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/comments/export.lua tests/comments_export_spec.lua
git commit -m "feat(comments): Markdown export grouped by intent"
```

---

### Task 5: Extmark rendering

Comments become visible: a sign, a highlighted line, and a boxed body below.

**Files:**
- Create: `lua/intentdiff/comments/marks.lua`
- Test: `tests/comments_marks_spec.lua`

**Interfaces:**
- Consumes: `store.get_for_file`, `store.get_for_intent` (Task 2); `highlight.comment_groups` (Task 1); `config.options.comments.types` (Task 1).
- Produces:
  - `marks.build_box(text, type_name, hl_group) -> virt_lines` (exposed for testing)
  - `marks.render_buffer(bufnr, file, side)` — clears and re-renders one pane
  - `marks.align(orig_buf, mod_buf, file)` — padding so boxes don't desync side-by-side scroll
  - `marks.render_sidebar(bufnr, rows)` — `rows` is `{ { lnum, title } }` for group head rows
  - `marks.refresh(tabpage)` — re-render every surface of a review tab
  - `marks.clear_all()`
  - `marks.ns` — the extmark namespace, for tests

- [ ] **Step 1: Write the failing tests**

Create `tests/comments_marks_spec.lua`:

```lua
local marks = require("intentdiff.comments.marks")
local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")

local function scratch(nlines)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, nlines do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local function extmarks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, marks.ns, 0, -1, { details = true })
end

describe("comments.marks", function()
  before_each(function()
    config.setup({})
    store.detach()
    store.clear()
  end)

  it("draws a box sized to the widest line with a minimum width", function()
    local box = marks.build_box("hi", "Issue", "IntentDiffCommentIssue")
    assert.equals(3, #box) -- top border, one text line, bottom border
    assert.is_truthy(box[1][1][1]:match("^╭─%[ISSUE%]"))
    assert.is_truthy(box[#box][1][1]:match("^╰"))
    -- Minimum content width of 20 keeps a one-word comment from being a sliver.
    assert.is_true(vim.fn.strdisplaywidth(box[1][1][1]) >= 22)
  end)

  it("keeps every box line the same display width", function()
    local box = marks.build_box("short\na much longer line here", "Note", "IntentDiffCommentNote")
    local width = vim.fn.strdisplaywidth(box[1][1][1])
    for _, line in ipairs(box) do
      assert.equals(width, vim.fn.strdisplaywidth(line[1][1]))
    end
  end)

  it("places a sign, a line highlight and a box for a single-line comment", function()
    local buf = scratch(10)
    store.add({ file = "a.lua", line = 3, side = "new", type = "issue", text = "bad" })
    marks.render_buffer(buf, "a.lua", "new")
    local got = extmarks(buf)
    assert.equals(1, #got)
    assert.equals(2, got[1][2]) -- 0-indexed row for line 3
    assert.equals("⚠", got[1][4].sign_text:gsub("%s+$", ""))
    assert.equals("IntentDiffCommentIssue", got[1][4].sign_hl_group)
    assert.equals("IntentDiffCommentIssueLine", got[1][4].line_hl_group)
    assert.is_truthy(got[1][4].virt_lines)
  end)

  it("highlights every line of a range and boxes only the last", function()
    local buf = scratch(10)
    store.add({ file = "a.lua", line = 3, line_end = 6, side = "new", type = "note", text = "r" })
    marks.render_buffer(buf, "a.lua", "new")
    local got = extmarks(buf)
    assert.equals(4, #got) -- rows 3,4,5,6
    assert.is_truthy(got[1][4].sign_text)
    assert.is_nil(got[1][4].virt_lines)
    assert.is_truthy(got[#got][4].virt_lines)
    for _, m in ipairs(got) do
      assert.equals("IntentDiffCommentNoteLine", m[4].line_hl_group)
    end
  end)

  it("anchors a file-level comment above the first line", function()
    local buf = scratch(5)
    store.add({ file = "a.lua", line = 0, type = "praise", text = "nice" })
    marks.render_buffer(buf, "a.lua", "new")
    local got = extmarks(buf)
    assert.equals(1, #got)
    assert.equals(0, got[1][2])
    assert.is_true(got[1][4].virt_lines_above)
  end)

  it("renders a file-level comment on both sides", function()
    local old_buf, new_buf = scratch(5), scratch(5)
    store.add({ file = "a.lua", line = 0, type = "praise", text = "nice" })
    marks.render_buffer(old_buf, "a.lua", "old")
    marks.render_buffer(new_buf, "a.lua", "new")
    assert.equals(1, #extmarks(old_buf))
    assert.equals(1, #extmarks(new_buf))
  end)

  it("keeps an old-side comment off the new-side pane", function()
    local buf = scratch(10)
    store.add({ file = "a.lua", line = 3, side = "old", type = "note", text = "o" })
    marks.render_buffer(buf, "a.lua", "new")
    assert.equals(0, #extmarks(buf))
    marks.render_buffer(buf, "a.lua", "old")
    assert.equals(1, #extmarks(buf))
  end)

  it("clears previous marks before re-rendering", function()
    local buf = scratch(10)
    local c = store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
    marks.render_buffer(buf, "a.lua", "new")
    store.delete(c)
    marks.render_buffer(buf, "a.lua", "new")
    assert.equals(0, #extmarks(buf))
  end)

  it("survives a line number past the end of the buffer", function()
    local buf = scratch(3)
    store.add({ file = "a.lua", line = 99, side = "new", type = "note", text = "drifted" })
    assert.has_no.errors(function()
      marks.render_buffer(buf, "a.lua", "new")
    end)
  end)

  it("pads the shorter side so boxes do not desync the panes", function()
    local old_buf, new_buf = scratch(10), scratch(10)
    store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "one\ntwo" })
    marks.render_buffer(old_buf, "a.lua", "old")
    marks.render_buffer(new_buf, "a.lua", "new")
    marks.align(old_buf, new_buf, "a.lua")
    local pad = vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, { details = true })
    assert.equals(1, #pad)
    assert.equals(4, #pad[1][4].virt_lines) -- 2 text lines + 2 borders
  end)

  it("adds no padding when both sides carry the same box height", function()
    local old_buf, new_buf = scratch(10), scratch(10)
    store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
    store.add({ file = "a.lua", line = 3, side = "old", type = "note", text = "y" })
    marks.render_buffer(old_buf, "a.lua", "old")
    marks.render_buffer(new_buf, "a.lua", "new")
    marks.align(old_buf, new_buf, "a.lua")
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(old_buf, marks.ns_padding, 0, -1, {}))
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(new_buf, marks.ns_padding, 0, -1, {}))
  end)

  it("signs a sidebar group row that has an intent comment", function()
    local buf = scratch(6)
    store.add({ intent_title = "Rename things", type = "issue", text = "wrong" })
    marks.render_sidebar(buf, { { lnum = 1, title = "Rename things" }, { lnum = 4, title = "Other" } })
    local got = extmarks(buf)
    assert.equals(1, #got)
    assert.equals(0, got[1][2])
    assert.is_nil(got[1][4].virt_lines) -- no box in the sidebar
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_marks_spec.lua" 2>&1 | tail -20`
Expected: FAIL — `module 'intentdiff.comments.marks' not found`.

- [ ] **Step 3: Implement marks**

Create `lua/intentdiff/comments/marks.lua`:

```lua
-- Rendering comments into the diff panes and the sidebar.
--
-- Two namespaces: `ns` for the comments themselves, `ns_padding` for the blank
-- virt_lines that keep the two panes the same height. A box on one side makes
-- that side taller, and codediff's scroll sync aligns by filler count — without
-- the padding the panes drift apart as soon as you comment on one side.
local M = {}

local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")
local hl = require("intentdiff.highlight")

M.ns = vim.api.nvim_create_namespace("intentdiff_comments")
M.ns_padding = vim.api.nvim_create_namespace("intentdiff_comments_padding")

local MIN_BOX_WIDTH = 20

--- Type metadata by key, from the configured list.
local function type_info(key)
  for _, t in ipairs((config.options.comments or {}).types or {}) do
    if t.key == key then
      return t
    end
  end
  return { key = key, name = tostring(key), icon = "●" }
end

--- The bordered comment body, as `virt_lines`. Every line is padded to the
--- same DISPLAY width — a box padded by byte count misaligns the moment the
--- text contains anything non-ASCII.
--- @return table[] virt_lines
function M.build_box(text, type_name, hl_group)
  local lines = vim.split(text or "", "\n")
  local width = MIN_BOX_WIDTH
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local header = ("[%s]"):format(tostring(type_name):upper())
  local out = {}
  out[#out + 1] = { { "╭─" .. header .. string.rep("─", width - vim.fn.strdisplaywidth(header) + 1) .. "╮", hl_group } }
  for _, line in ipairs(lines) do
    local pad = width - vim.fn.strdisplaywidth(line)
    out[#out + 1] = { { "│ " .. line .. string.rep(" ", pad) .. " │", hl_group } }
  end
  out[#out + 1] = { { "╰" .. string.rep("─", width + 2) .. "╯", hl_group } }
  return out
end

--- Rendered height of a comment's box, and the 0-indexed row it hangs from.
local function box_height(c)
  return #vim.split(c.text or "", "\n") + 2, math.max((c.line_end or c.line or 1) - 1, 0)
end

--- Clear and re-render every comment for `file` on `side` into `bufnr`.
function M.render_buffer(bufnr, file, side)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and file) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  local last = vim.api.nvim_buf_line_count(bufnr)

  for _, c in ipairs(store.get_for_file(file, side)) do
    local info = type_info(c.type)
    local sign_hl, line_hl = hl.comment_groups(c.type)
    local box = M.build_box(c.text, info.name, sign_hl)

    if (c.line or 0) == 0 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, 0, 0, {
        sign_text = info.icon,
        sign_hl_group = sign_hl,
        virt_lines = box,
        virt_lines_above = true,
      })
    else
      local first = c.line - 1
      local final = (c.line_end or c.line) - 1
      -- A persisted comment can outlive the lines it pointed at; clamp rather
      -- than dropping it, so it stays visible and exportable.
      if first < last then
        final = math.min(final, last - 1)
        if final == first then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, first, 0, {
            sign_text = info.icon,
            sign_hl_group = sign_hl,
            line_hl_group = line_hl,
            virt_lines = box,
          })
        else
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, first, 0, {
            sign_text = info.icon,
            sign_hl_group = sign_hl,
            line_hl_group = line_hl,
          })
          for row = first + 1, final - 1 do
            pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row, 0, { line_hl_group = line_hl })
          end
          pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, final, 0, {
            line_hl_group = line_hl,
            virt_lines = box,
          })
        end
      end
    end
  end
end

--- Blank-line padding so a box on one side does not make the panes drift.
function M.align(orig_buf, mod_buf, file)
  for _, buf in ipairs({ orig_buf, mod_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ns_padding, 0, -1)
    end
  end
  if not (orig_buf and mod_buf and file
    and vim.api.nvim_buf_is_valid(orig_buf) and vim.api.nvim_buf_is_valid(mod_buf)) then
    return
  end

  --- row → total box height on that side. File-level comments render
  --- identically on both sides, so they never contribute a difference.
  local function heights(side)
    local map = {}
    for _, c in ipairs(store.get_for_file(file, side)) do
      if (c.line or 0) ~= 0 and (c.side or "new") == side then
        local h, row = box_height(c)
        map[row] = (map[row] or 0) + h
      end
    end
    return map
  end

  local old_h, new_h = heights("old"), heights("new")
  local rows = {}
  for row in pairs(old_h) do rows[row] = true end
  for row in pairs(new_h) do rows[row] = true end

  for row in pairs(rows) do
    local diff = (old_h[row] or 0) - (new_h[row] or 0)
    if diff ~= 0 then
      local target = diff > 0 and mod_buf or orig_buf
      local padding = {}
      for _ = 1, math.abs(diff) do
        padding[#padding + 1] = { { "", "Normal" } }
      end
      pcall(vim.api.nvim_buf_set_extmark, target, M.ns_padding, row, 0, { virt_lines = padding })
    end
  end
end

--- Sign the sidebar rows whose intent carries a comment. No box: the sidebar
--- is a dense navigation surface and boxes would push rows around.
--- @param rows { lnum: integer, title: string }[] group head rows, 1-indexed
function M.render_sidebar(bufnr, rows)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  for _, row in ipairs(rows or {}) do
    local comments = store.get_for_intent(row.title)
    if #comments > 0 then
      local info = type_info(comments[1].type)
      local sign_hl = hl.comment_groups(comments[1].type)
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row.lnum - 1, 0, {
        sign_text = info.icon,
        sign_hl_group = sign_hl,
      })
    end
  end
end

function M.clear_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
      vim.api.nvim_buf_clear_namespace(buf, M.ns_padding, 0, -1)
    end
  end
end

return M
```

`M.refresh(tabpage)` is deliberately absent here — it needs `view`'s pane/session lookup and is added in Task 7, where the wiring lives.

- [ ] **Step 4: Run to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_marks_spec.lua" 2>&1 | tail -20`
Expected: PASS, `Success: 13`, no failures.

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/comments/marks.lua tests/comments_marks_spec.lua
git commit -m "feat(comments): render comments as signs, highlights and boxes"
```

---

### Task 6: The comment popup

A self-contained float — no nui.nvim — built the same way as `keymap_help.lua`'s.

**Files:**
- Create: `lua/intentdiff/comments/popup.lua`
- Test: `tests/comments_popup_spec.lua`

**Interfaces:**
- Consumes: `config.options.comments.types`, `config.options.keymaps.comments` (Task 1).
- Produces:
  - `popup.type_line(types, index) -> string` — the selector row (exposed for testing)
  - `popup.cycle(index, count) -> integer` — 1-based wrap-around
  - `popup.open(opts, callback)` where `opts = { type: string?, text: string? }` and `callback(type: string|nil, text: string|nil)`; both nil means cancelled
  - `popup.submit()` / `popup.cancel()` — driven by keymaps, exposed so tests can act without synthesizing insert-mode input

- [ ] **Step 1: Write the failing tests**

Create `tests/comments_popup_spec.lua`:

```lua
local popup = require("intentdiff.comments.popup")
local config = require("intentdiff.config")

local TYPES = {
  { key = "note", name = "Note", icon = "✍" },
  { key = "issue", name = "Issue", icon = "⚠" },
}

describe("comments.popup", function()
  before_each(function()
    config.setup({})
  end)

  after_each(function()
    popup.cancel()
  end)

  it("brackets the selected type", function()
    local line = popup.type_line(TYPES, 2)
    assert.is_truthy(line:match("%[⚠ Issue%]"))
    assert.is_nil(line:match("%[✍ Note%]"))
  end)

  it("cycles with wrap-around", function()
    assert.equals(2, popup.cycle(1, 2))
    assert.equals(1, popup.cycle(2, 2))
  end)

  it("opens two floats and focuses the text one", function()
    popup.open({}, function() end)
    assert.is_true(vim.api.nvim_win_is_valid(popup._type_win))
    assert.is_true(vim.api.nvim_win_is_valid(popup._text_win))
    assert.equals(popup._text_win, vim.api.nvim_get_current_win())
  end)

  it("returns the typed text and selected type on submit", function()
    local got_type, got_text
    popup.open({ type = "issue" }, function(t, x)
      got_type, got_text = t, x
    end)
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "first", "second" })
    popup.submit()
    assert.equals("issue", got_type)
    assert.equals("first\nsecond", got_text)
  end)

  it("pre-fills text when editing", function()
    popup.open({ type = "note", text = "existing" }, function() end)
    assert.same({ "existing" }, vim.api.nvim_buf_get_lines(popup._text_buf, 0, -1, false))
  end)

  it("reports a cancel as nil, nil", function()
    local called, got = false, "unset"
    popup.open({}, function(t)
      called, got = true, t
    end)
    popup.cancel()
    assert.is_true(called)
    assert.is_nil(got)
  end)

  it("treats empty text as a cancel", function()
    local got = "unset"
    popup.open({}, function(t)
      got = t
    end)
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "   ", "" })
    popup.submit()
    assert.is_nil(got)
  end)

  it("closes both windows on submit", function()
    local type_win, text_win
    popup.open({}, function() end)
    type_win, text_win = popup._type_win, popup._text_win
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "x" })
    popup.submit()
    assert.is_false(vim.api.nvim_win_is_valid(type_win))
    assert.is_false(vim.api.nvim_win_is_valid(text_win))
  end)

  it("calls back exactly once even if submit is called twice", function()
    local n = 0
    popup.open({}, function() n = n + 1 end)
    vim.api.nvim_buf_set_lines(popup._text_buf, 0, -1, false, { "x" })
    popup.submit()
    popup.submit()
    assert.equals(1, n)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_popup_spec.lua" 2>&1 | tail -20`
Expected: FAIL — `module 'intentdiff.comments.popup' not found`.

- [ ] **Step 3: Implement the popup**

Create `lua/intentdiff/comments/popup.lua`:

```lua
-- The comment entry float: a one-line type selector above a multi-line text
-- area. Built with plain nvim_open_win rather than nui.nvim so the plugin
-- keeps codediff as its only dependency — same approach as keymap_help.lua.
--
-- submit/cancel are module functions rather than closures so they can be
-- driven from a test without synthesizing insert-mode keystrokes.
local M = {}

local config = require("intentdiff.config")

local WIDTH = 60
local TEXT_HEIGHT = 5

M._type_win, M._text_win, M._type_buf, M._text_buf = nil, nil, nil, nil
local state = nil

local function types()
  local list = (config.options.comments or {}).types or {}
  if #list == 0 then
    list = { { key = "note", name = "Note", icon = "✍" } }
  end
  return list
end

--- 1-based index one step forward, wrapping.
function M.cycle(index, count)
  if count <= 0 then
    return 1
  end
  return (index % count) + 1
end

--- The selector row. The selected type is bracketed; the row is truncated
--- with … when the configured types do not fit the float's width.
function M.type_line(list, index)
  local parts = {}
  for i, t in ipairs(list) do
    local label = ("%s %s"):format(t.icon or "●", t.name or t.key)
    parts[#parts + 1] = (i == index) and ("[" .. label .. "]") or (" " .. label .. " ")
  end
  local line = table.concat(parts, " ")
  if vim.fn.strdisplaywidth(line) > WIDTH - 2 then
    line = vim.fn.strcharpart(line, 0, WIDTH - 3) .. "…"
  end
  return line
end

local function render_type()
  if not (state and vim.api.nvim_buf_is_valid(M._type_buf)) then
    return
  end
  vim.bo[M._type_buf].modifiable = true
  vim.api.nvim_buf_set_lines(M._type_buf, 0, -1, false, { M.type_line(state.types, state.index) })
  vim.bo[M._type_buf].modifiable = false
end

local function close_windows()
  for _, win in ipairs({ M._type_win, M._text_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  M._type_win, M._text_win = nil, nil
end

--- Finish the popup exactly once, restoring focus to where it was opened from.
local function finish(comment_type, text)
  if not state then
    return
  end
  local callback, prev_win = state.callback, state.prev_win
  state = nil
  close_windows()
  if prev_win and vim.api.nvim_win_is_valid(prev_win) then
    pcall(vim.api.nvim_set_current_win, prev_win)
  end
  pcall(vim.cmd, "stopinsert")
  callback(comment_type, text)
end

function M.submit()
  if not state then
    return
  end
  local lines = vim.api.nvim_buf_is_valid(M._text_buf)
    and vim.api.nvim_buf_get_lines(M._text_buf, 0, -1, false) or {}
  local text = (table.concat(lines, "\n"):gsub("%s+$", ""))
  if text == "" then
    return finish(nil, nil)
  end
  finish(state.types[state.index].key, text)
end

function M.cancel()
  if state then
    finish(nil, nil)
  end
end

function M.cycle_type()
  if not state then
    return
  end
  state.index = M.cycle(state.index, #state.types)
  render_type()
end

local function float(buf, row, height, title)
  return vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    row = row,
    col = math.max(math.floor((vim.o.columns - WIDTH) / 2), 0),
    width = WIDTH,
    height = height,
    style = "minimal",
    border = "rounded",
    title = title,
    title_pos = "center",
  })
end

--- @param opts { type: string?, text: string? }
--- @param callback fun(comment_type: string|nil, text: string|nil)
function M.open(opts, callback)
  M.cancel()
  opts = opts or {}
  local list = types()
  local index = 1
  for i, t in ipairs(list) do
    if t.key == opts.type then
      index = i
      break
    end
  end

  M._type_buf = vim.api.nvim_create_buf(false, true)
  M._text_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M._type_buf].bufhidden = "wipe"
  vim.bo[M._text_buf].bufhidden = "wipe"

  state = {
    types = list,
    index = index,
    callback = callback,
    prev_win = vim.api.nvim_get_current_win(),
  }

  local total = 3 + TEXT_HEIGHT + 2
  local top = math.max(math.floor((vim.o.lines - total) / 2), 0)
  M._type_win = float(M._type_buf, top, 1, " Type (⇥ to switch) ")
  M._text_win = float(M._text_buf, top + 3, TEXT_HEIGHT, " Comment (^s submit) ")
  render_type()

  if opts.text and opts.text ~= "" then
    vim.api.nvim_buf_set_lines(M._text_buf, 0, -1, false, vim.split(opts.text, "\n"))
  end

  local km = (config.options.keymaps or {}).comments or {}
  local function map(modes, lhs, fn)
    if lhs then
      pcall(vim.keymap.set, modes, lhs, fn, { buffer = M._text_buf, nowait = true })
    end
  end
  map({ "i", "n" }, km.popup_cycle_type or "<Tab>", M.cycle_type)
  map({ "i", "n" }, km.popup_submit or "<C-s>", M.submit)
  map("n", "<CR>", M.submit)
  map("n", "<Esc>", M.cancel)
  map("n", km.popup_cancel or "q", M.cancel)

  vim.api.nvim_set_current_win(M._text_win)
  -- Only enter insert mode for a real interactive session: a headless test
  -- driving submit() directly must not be left in insert mode.
  if not opts.no_insert then
    vim.cmd("startinsert!")
  end
end

return M
```

Add `popup_cycle_type = "<Tab>"`, `popup_submit = "<C-s>"` and `popup_cancel = "q"` to the `keymaps.comments` defaults in `lua/intentdiff/config.lua` so they are configurable rather than hardcoded fallbacks.

- [ ] **Step 4: Run to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_popup_spec.lua" 2>&1 | tail -20`
Expected: PASS, `Success: 9`, no failures.

If `startinsert!` leaves the headless test in insert mode and later assertions hang, pass `no_insert = true` from the specs' `popup.open` calls — the option already exists in the implementation above.

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/comments/popup.lua lua/intentdiff/config.lua tests/comments_popup_spec.lua
git commit -m "feat(comments): dependency-free comment entry popup"
```

---

### Task 7: The action layer

Everything the keymaps call. This is where a cursor position becomes a comment.

**Files:**
- Create: `lua/intentdiff/comments/init.lua`
- Modify: `lua/intentdiff/comments/marks.lua` (add `M.refresh`)
- Test: `tests/comments_actions_spec.lua`

**Interfaces:**
- Consumes: `store` (Task 2), `storage.key` (Task 3), `export` (Task 4), `marks` (Task 5), `popup` (Task 6). From the existing plugin: `view.diff_wins(tabpage)`, `view.get_session(tabpage)`, `view._last_shown[tabpage] = { sess, file_entry }`.
- Produces:
  - `comments.context(tabpage) -> ctx|nil` where `ctx` is `{ file, line, line_end, side }` or `{ intent_title }`
  - `comments.add(tabpage, comment_type)` — `comment_type` nil opens the type picker
  - `comments.add_file(tabpage)`
  - `comments.edit(tabpage)` / `comments.delete(tabpage)`
  - `comments.next(tabpage)` / `comments.prev(tabpage)`
  - `comments.list(tabpage)`
  - `comments.export_clipboard(tabpage)` / `comments.export_file(tabpage, path)`
  - `comments.clear(tabpage)`
  - `comments.attach_session(entry)` / `comments.detach_session()`
  - `comments.sidebar_rows(model) -> { lnum, title }[]` — supplied by the sidebar in Task 8
  - `marks.refresh(tabpage)`

- [ ] **Step 1: Write the failing tests**

Create `tests/comments_actions_spec.lua`. These test the pure decision functions; the keymap wiring gets integration coverage in Task 8.

```lua
local comments = require("intentdiff.comments")
local store = require("intentdiff.comments.store")
local config = require("intentdiff.config")

describe("comments actions", function()
  before_each(function()
    config.setup({ cache_dir = vim.fn.tempname() })
    store.detach()
    store.clear()
  end)

  describe("side_for_win", function()
    it("reads old from the original window and new from the modified one", function()
      assert.equals("old", comments.side_for_win(10, { original_win = 10, modified_win = 11 }))
      assert.equals("new", comments.side_for_win(11, { original_win = 10, modified_win = 11 }))
    end)

    it("defaults to new when the window is neither pane", function()
      assert.equals("new", comments.side_for_win(99, { original_win = 10, modified_win = 11 }))
    end)

    it("is new in inline layout, where there is one pane", function()
      assert.equals("new", comments.side_for_win(11, { original_win = 11, modified_win = 11 }))
    end)
  end)

  describe("visual_range", function()
    it("returns start and end for a multi-line selection", function()
      local first, last = comments.visual_range(7, 3)
      assert.equals(3, first)
      assert.equals(7, last)
    end)

    it("collapses a single-line selection to no range", function()
      local first, last = comments.visual_range(4, 4)
      assert.equals(4, first)
      assert.is_nil(last)
    end)
  end)

  describe("next/prev targets", function()
    it("finds the next comment line after the cursor", function()
      store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
      store.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "y" })
      assert.equals(9, comments.next_line("a.lua", 3, "new"))
      assert.equals(3, comments.next_line("a.lua", 1, "new"))
      assert.is_nil(comments.next_line("a.lua", 9, "new"))
    end)

    it("finds the previous comment line before the cursor", function()
      store.add({ file = "a.lua", line = 3, side = "new", type = "note", text = "x" })
      store.add({ file = "a.lua", line = 9, side = "new", type = "note", text = "y" })
      assert.equals(3, comments.prev_line("a.lua", 9, "new"))
      assert.is_nil(comments.prev_line("a.lua", 3, "new"))
    end)

    it("ignores file-level comments when navigating", function()
      store.add({ file = "a.lua", line = 0, type = "note", text = "f" })
      store.add({ file = "a.lua", line = 5, side = "new", type = "note", text = "x" })
      assert.equals(5, comments.next_line("a.lua", 1, "new"))
    end)
  end)

  describe("list entries", function()
    it("labels each comment with type, location and first text line", function()
      store.add({ file = "a.lua", line = 3, side = "new", type = "issue", text = "bad thing\nmore" })
      store.add({ intent_title = "Rename", type = "note", text = "whole intent" })
      local entries = comments.list_entries()
      assert.equals(2, #entries)
      assert.is_truthy(entries[1].label:match("ISSUE"))
      assert.is_truthy(entries[1].label:match("a%.lua:3"))
      assert.is_truthy(entries[1].label:match("bad thing"))
      assert.is_nil(entries[1].label:match("more"))
      assert.is_truthy(entries[2].label:match("Rename"))
    end)
  end)

  describe("session attach", function()
    it("keys a working-tree session by branch", function()
      local repo = require("tests.helpers").make_repo({ ["a.lua"] = "x" })
      comments.attach_session({ sess = { git_root = repo } })
      store.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "x" })
      -- Re-attaching the same session must find the comment on disk.
      store.replace({})
      comments.attach_session({ sess = { git_root = repo } })
      assert.equals(1, store.count())
    end)

    it("keeps two revision ranges of one repo apart", function()
      local repo = require("tests.helpers").make_repo({ ["a.lua"] = "x" })
      comments.attach_session({ sess = { git_root = repo, base_revision = "aaa", target_revision = "bbb" } })
      store.add({ file = "a.lua", line = 1, side = "new", type = "note", text = "one" })
      comments.attach_session({ sess = { git_root = repo, base_revision = "ccc", target_revision = "ddd" } })
      assert.equals(0, store.count())
    end)
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_actions_spec.lua" 2>&1 | tail -20`
Expected: FAIL — `module 'intentdiff.comments' not found`.

- [ ] **Step 3: Add marks.refresh**

Append to `lua/intentdiff/comments/marks.lua`, before `return M`:

```lua
--- Re-render every surface of a review tab. Called after any pane rebuild and
--- after every store mutation.
function M.refresh(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local view = require("intentdiff.view")
  local shown = view._last_shown[tabpage]
  local session = view.get_session(tabpage)
  if not (shown and shown.file_entry and session) then
    return
  end
  local file = shown.file_entry.path
  -- A preview buffer concatenates many files; comments do not belong there.
  if view._preview_active[tabpage] then
    return
  end
  local orig_buf = session.original_win and vim.api.nvim_win_is_valid(session.original_win)
    and vim.api.nvim_win_get_buf(session.original_win) or nil
  local mod_buf = session.modified_win and vim.api.nvim_win_is_valid(session.modified_win)
    and vim.api.nvim_win_get_buf(session.modified_win) or nil
  -- Inline layout puts one buffer in both windows; render it once, as "new".
  if orig_buf and orig_buf ~= mod_buf then
    M.render_buffer(orig_buf, file, "old")
  end
  if mod_buf then
    M.render_buffer(mod_buf, file, "new")
  end
  if orig_buf and mod_buf and orig_buf ~= mod_buf then
    M.align(orig_buf, mod_buf, file)
  end
end
```

- [ ] **Step 4: Implement the action layer**

Create `lua/intentdiff/comments/init.lua`:

```lua
-- The action layer: everything the keymaps call. Turns a cursor position into
-- a comment, and drives popup → store → marks.
--
-- The pure decision functions (side_for_win, visual_range, next_line,
-- prev_line, list_entries) are separated from the Neovim plumbing so they can
-- be tested without a review tab.
local M = {}

local store = require("intentdiff.comments.store")
local storage = require("intentdiff.comments.storage")
local marks = require("intentdiff.comments.marks")
local popup = require("intentdiff.comments.popup")
local export = require("intentdiff.comments.export")
local config = require("intentdiff.config")

--- Which side of the diff a window shows. Inline layout puts the same window
--- in both roles, and only ever shows the modified file — so "new".
function M.side_for_win(winid, session)
  if not session then
    return "new"
  end
  if session.original_win == winid and session.modified_win ~= winid then
    return "old"
  end
  return "new"
end

--- Normalize a visual selection into (line, line_end). A single-line selection
--- has no end, so it stores as a plain line comment.
--- @return integer first, integer|nil last
function M.visual_range(a, b)
  local first, last = math.min(a, b), math.max(a, b)
  if first == last then
    return first, nil
  end
  return first, last
end

local function line_comments(file, side)
  local out = {}
  for _, c in ipairs(store.get_for_file(file, side)) do
    if (c.line or 0) ~= 0 then
      out[#out + 1] = c
    end
  end
  table.sort(out, function(x, y) return x.line < y.line end)
  return out
end

--- @return integer|nil
function M.next_line(file, from, side)
  for _, c in ipairs(line_comments(file, side)) do
    if c.line > from then
      return c.line
    end
  end
  return nil
end

--- @return integer|nil
function M.prev_line(file, from, side)
  local best
  for _, c in ipairs(line_comments(file, side)) do
    if c.line < from then
      best = c.line
    end
  end
  return best
end

--- One selectable row per comment, for the list picker.
function M.list_entries()
  local out = {}
  for _, c in ipairs(store.get_all()) do
    local first_line = vim.split(c.text or "", "\n")[1] or ""
    local where
    if c.intent_title then
      where = "intent: " .. c.intent_title
    elseif (c.line or 0) == 0 then
      where = c.file
    elseif c.line_end then
      where = ("%s:%d-%d"):format(c.file, c.line, c.line_end)
    else
      where = ("%s:%d"):format(c.file, c.line)
    end
    out[#out + 1] = {
      comment = c,
      label = ("[%s] %s — %s"):format(tostring(c.type):upper(), where, first_line),
    }
  end
  return out
end

--- The intent-diff session entry for a tabpage, via the plugin's own registry.
local function entry_for(tabpage)
  return require("intentdiff")._session(tabpage or vim.api.nvim_get_current_tabpage())
end

--- Current branch of `git_root`, for the storage key of a working-tree review.
local function branch_of(git_root)
  local out = vim.fn.systemlist({ "git", "-C", git_root, "rev-parse", "--abbrev-ref", "HEAD" })[1]
  if vim.v.shell_error ~= 0 or not out or out == "" then
    return nil
  end
  return out
end

--- Point the store at this review's storage key and load what it has.
function M.attach_session(entry)
  local sess = entry and entry.sess
  if not (sess and sess.git_root) then
    return
  end
  local key = storage.key(sess.git_root, sess.base_revision, sess.target_revision,
    branch_of(sess.git_root))
  if key then
    store.attach(key)
  end
end

function M.detach_session()
  store.detach()
  store.replace({})
  marks.clear_all()
end

--- What the cursor is pointing at: a line in a pane, or an intent in the
--- sidebar.
--- @return table|nil ctx, string|nil err
function M.context(tabpage, opts)
  opts = opts or {}
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  local entry = entry_for(tabpage)
  if not entry then
    return nil, "not in a review tab"
  end
  local win = vim.api.nvim_get_current_win()

  -- Sidebar: an intent comment from a group row, a file comment from a file row.
  if entry.sidebar and entry.sidebar.winid == win then
    local meta = entry.sidebar.meta_at(vim.api.nvim_win_get_cursor(win)[1]) or {}
    local group = entry.model and entry.model.groups and entry.model.groups[meta.group_i]
    if meta.kind == "file" then
      local file = group and group.files and group.files[meta.file_i]
      if file then
        return { file = file.path, line = 0 }
      end
    end
    if group then
      return { intent_title = group.title }
    end
    return nil, "no intent under the cursor"
  end

  -- Diff pane.
  local view = require("intentdiff.view")
  local shown = view._last_shown[tabpage]
  if not (shown and shown.file_entry) then
    return nil, "no file open"
  end
  if view._preview_active[tabpage] then
    return nil, "comments cannot be added in an intent preview"
  end
  local session = view.get_session(tabpage)
  local side = M.side_for_win(win, session)
  local ctx = { file = shown.file_entry.path, side = side }
  if opts.file_level then
    ctx.line = 0
    ctx.side = nil
    return ctx
  end
  if opts.visual then
    local first, last = M.visual_range(
      vim.fn.line("'<"), vim.fn.line("'>"))
    ctx.line, ctx.line_end = first, last
  else
    ctx.line = vim.api.nvim_win_get_cursor(win)[1]
  end
  return ctx
end

local function notify(msg, level)
  vim.notify("intent-diff: " .. msg, level or vim.log.levels.INFO)
end

--- Add a comment at the cursor. `comment_type` nil opens the type picker.
function M.add(tabpage, comment_type, opts)
  local ctx, err = M.context(tabpage, opts)
  if not ctx then
    return notify(err, vim.log.levels.WARN)
  end
  popup.open({ type = comment_type }, function(chosen, text)
    if not (chosen and text) then
      return
    end
    ctx.type = chosen
    ctx.text = text
    local added, add_err = store.add(ctx)
    if not added then
      return notify(add_err, vim.log.levels.WARN)
    end
    marks.refresh(tabpage)
    M.refresh_sidebar(tabpage)
    notify(("added %s comment"):format(chosen))
  end)
end

function M.add_file(tabpage)
  return M.add(tabpage, nil, { file_level = true })
end

--- The comment under the cursor, for edit/delete.
local function at_cursor(tabpage)
  local ctx = M.context(tabpage)
  if not ctx then
    return nil
  end
  if ctx.intent_title then
    return store.get_for_intent(ctx.intent_title)[1]
  end
  if (ctx.line or 0) == 0 then
    for _, c in ipairs(store.get_for_file(ctx.file)) do
      if (c.line or 0) == 0 then
        return c
      end
    end
    return nil
  end
  return store.get_at_line(ctx.file, ctx.line, ctx.side)
end

function M.edit(tabpage)
  local comment = at_cursor(tabpage)
  if not comment then
    return notify("no comment here", vim.log.levels.WARN)
  end
  popup.open({ type = comment.type, text = comment.text }, function(chosen, text)
    if not (chosen and text) then
      return
    end
    store.update(comment, chosen, text)
    marks.refresh(tabpage)
    M.refresh_sidebar(tabpage)
  end)
end

function M.delete(tabpage)
  local comment = at_cursor(tabpage)
  if not comment then
    return notify("no comment here", vim.log.levels.WARN)
  end
  store.delete(comment)
  marks.refresh(tabpage)
  M.refresh_sidebar(tabpage)
  notify("deleted comment")
end

local function jump(tabpage, finder)
  local view = require("intentdiff.view")
  local shown = view._last_shown[tabpage or vim.api.nvim_get_current_tabpage()]
  if not (shown and shown.file_entry) then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local session = view.get_session(tabpage)
  local side = M.side_for_win(win, session)
  local cur = vim.api.nvim_win_get_cursor(win)[1]
  local target = finder(shown.file_entry.path, cur, side)
  if not target then
    return notify("no more comments in this file")
  end
  pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
end

function M.next(tabpage)
  jump(tabpage, M.next_line)
end

function M.prev(tabpage)
  jump(tabpage, M.prev_line)
end

function M.list(tabpage)
  local entries = M.list_entries()
  if #entries == 0 then
    return notify("no comments yet")
  end
  vim.ui.select(entries, {
    prompt = "intent-diff comments",
    format_item = function(e) return e.label end,
  }, function(choice)
    if not choice then
      return
    end
    local c = choice.comment
    if c.intent_title or (c.line or 0) == 0 then
      return
    end
    local view = require("intentdiff.view")
    for _, win in ipairs(view.diff_wins(tabpage or vim.api.nvim_get_current_tabpage())) do
      pcall(vim.api.nvim_win_set_cursor, win, { c.line, 0 })
    end
  end)
end

local function model_of(tabpage)
  local entry = entry_for(tabpage)
  return entry and entry.model or { groups = {} }
end

function M.export_clipboard(tabpage)
  export.to_clipboard(store.get_all(), model_of(tabpage))
end

--- Path last used this session, so the prompt is pre-filled with it.
local last_path = nil

function M.export_file(tabpage, path)
  if store.count() == 0 then
    return notify("no comments to export", vim.log.levels.WARN)
  end
  local entry = entry_for(tabpage)
  local root = entry and entry.sess and entry.sess.git_root or vim.fn.getcwd()
  local function write(chosen)
    if not chosen or chosen == "" then
      return
    end
    local abs = chosen:sub(1, 1) == "/" and chosen or (root .. "/" .. chosen)
    local ok, err = export.to_file(store.get_all(), model_of(tabpage), abs)
    if not ok then
      return notify(err, vim.log.levels.ERROR)
    end
    last_path = chosen
    notify(("wrote %d comment(s) to %s"):format(store.count(), abs))
  end
  if path and path ~= "" then
    return write(path)
  end
  local default = last_path or (config.options.comments or {}).export_path or ".intentdiff-review.md"
  vim.ui.input({ prompt = "Write review to: ", default = default }, write)
end

function M.clear(tabpage)
  if store.count() == 0 then
    return notify("no comments to clear")
  end
  local answer = vim.fn.confirm(
    ("Delete all %d comment(s) in this review?"):format(store.count()), "&Yes\n&No", 2)
  if answer ~= 1 then
    return
  end
  store.clear()
  marks.clear_all()
  marks.refresh(tabpage)
  M.refresh_sidebar(tabpage)
  notify("cleared all comments")
end

--- Copy the Markdown, then close the review tab. The review.nvim end-of-review
--- flow. Closes even with no comments — refusing to close would be worse than
--- an empty export.
function M.export_and_close(tabpage)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  if store.count() > 0 then
    M.export_clipboard(tabpage)
  else
    notify("no comments to export")
  end
  require("intentdiff").close(tabpage)
end

--- Re-sign the sidebar's group rows. The row list comes from the sidebar
--- handle, which knows its own layout.
function M.refresh_sidebar(tabpage)
  local entry = entry_for(tabpage)
  if entry and entry.sidebar and entry.sidebar.comment_rows then
    marks.render_sidebar(entry.sidebar.bufnr, entry.sidebar.comment_rows())
  end
end

return M
```

- [ ] **Step 5: Run to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/comments_actions_spec.lua" 2>&1 | tail -20`
Expected: PASS, `Success: 11`, no failures.

`entry.sidebar.comment_rows` and `entry.sidebar.bufnr` do not exist yet — `refresh_sidebar` is written to no-op until Task 8 adds them, and no test in this task exercises it.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/comments/init.lua lua/intentdiff/comments/marks.lua tests/comments_actions_spec.lua
git commit -m "feat(comments): cursor context resolution and comment actions"
```

---

### Task 8: Wire into the review tab

Keymaps, commands, help, session lifecycle, and re-render hooks. After this task the feature is usable.

**Files:**
- Modify: `lua/intentdiff/view.lua` (install keymaps on panes; refresh after rebuilds)
- Modify: `lua/intentdiff/sidebar.lua` (install keymaps; expose `bufnr` and `comment_rows`)
- Modify: `lua/intentdiff/init.lua` (attach/detach the store on open/close)
- Modify: `lua/intentdiff/keymap_help.lua` (COMMENTS section)
- Modify: `plugin/intentdiff.lua` (four commands)
- Test: `tests/integration_spec.lua` (extend)

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces: `:IntentDiffCommentsYank`, `:IntentDiffCommentsWrite [path]`, `:IntentDiffCommentsList`, `:IntentDiffCommentsClear`; `sidebar` handle gains `bufnr` and `comment_rows()`.

- [ ] **Step 1: Write the failing integration tests**

Append to `tests/integration_spec.lua`, as a new `describe` block at the top level:

```lua
describe("comments in a review tab", function()
  local store = require("intentdiff.comments.store")

  before_each(function()
    store.detach()
    store.clear()
  end)

  it("registers the four comment commands", function()
    local cmds = vim.api.nvim_get_commands({})
    assert.is_truthy(cmds.IntentDiffCommentsYank)
    assert.is_truthy(cmds.IntentDiffCommentsWrite)
    assert.is_truthy(cmds.IntentDiffCommentsList)
    assert.is_truthy(cmds.IntentDiffCommentsClear)
  end)

  it("lists comment keys in the g? help", function()
    require("intentdiff.config").setup({})
    local sections = require("intentdiff.keymap_help")._build_sections(
      require("intentdiff.config").options.keymaps)
    local found
    for _, s in ipairs(sections) do
      if s.title == "COMMENTS" then
        found = s
      end
    end
    assert.is_truthy(found)
    local labels = {}
    for _, item in ipairs(found.items) do
      labels[item[1]] = item[2]
    end
    assert.is_truthy(labels["<localleader>ci"])
    assert.is_truthy(labels["<localleader>q"])
  end)

  it("omits a disabled comment action from the help", function()
    require("intentdiff.config").setup({ keymaps = { comments = { add_praise = false } } })
    local sections = require("intentdiff.keymap_help")._build_sections(
      require("intentdiff.config").options.keymaps)
    for _, s in ipairs(sections) do
      if s.title == "COMMENTS" then
        for _, item in ipairs(s.items) do
          assert.are_not.equals("<localleader>cp", item[1])
        end
      end
    end
  end)

  it("installs no comment keys when comments are disabled", function()
    require("intentdiff.config").setup({ comments = { enabled = false } })
    local sections = require("intentdiff.keymap_help")._build_sections(
      require("intentdiff.config").options.keymaps)
    for _, s in ipairs(sections) do
      assert.are_not.equals("COMMENTS", s.title)
    end
  end)

  it("re-files comments under new intents after re-classification", function()
    local export = require("intentdiff.comments.export")
    local before_model = {
      state = "ready",
      groups = { { title = "First pass", files = { { path = "a.lua" } },
        hunks = { { id = "a.lua:1", file = "a.lua",
          original = { start_line = 1, end_line = 5 },
          modified = { start_line = 1, end_line = 5 } } } } },
    }
    local after_model = {
      state = "ready",
      groups = { { title = "Second pass", files = { { path = "a.lua" } },
        hunks = { { id = "a.lua:1", file = "a.lua",
          original = { start_line = 1, end_line = 5 },
          modified = { start_line = 1, end_line = 5 } } } } },
    }
    store.add({ file = "a.lua", line = 2, side = "new", type = "issue", text = "x" })
    assert.is_truthy(export.generate(store.get_all(), before_model):match("## First pass"))
    assert.is_truthy(export.generate(store.get_all(), after_model):match("## Second pass"))
  end)
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/integration_spec.lua" 2>&1 | tail -30`
Expected: FAIL — the commands do not exist and `keymap_help._build_sections` is not exposed.

- [ ] **Step 3: Expose build_sections and add the COMMENTS help section**

In `lua/intentdiff/keymap_help.lua`, add a comments section inside `build_sections`, after the `view` section is appended and before `return sections`:

```lua
  local ckm = keymaps.comments or {}
  local cfg = require("intentdiff.config").options.comments or {}
  if cfg.enabled ~= false then
    local cs = section("COMMENTS", {
      { ckm.add_comment, "Add a comment (pick the type)" },
      { ckm.add_note, "Add a note" },
      { ckm.add_suggestion, "Add a suggestion" },
      { ckm.add_issue, "Add an issue" },
      { ckm.add_praise, "Add praise" },
      { ckm.add_file_comment, "Comment on the file / the intent" },
      { ckm.edit_comment, "Edit the comment at the cursor" },
      { ckm.delete_comment, "Delete the comment at the cursor" },
      { ckm.next_comment, "Next comment" },
      { ckm.prev_comment, "Previous comment" },
      { ckm.list_comments, "List every comment" },
      { ckm.export_clipboard, "Copy the review as Markdown" },
      { ckm.export_file, "Write the review to a file" },
      { ckm.clear_comments, "Delete every comment" },
      { ckm.export_and_close, "Copy the review, then close the tab" },
    })
    if cs then
      sections[#sections + 1] = cs
    end
  end
```

At the bottom of the file, before `return M`, expose it for tests:

```lua
--- Exposed for tests: the section list the float renders.
M._build_sections = build_sections
```

- [ ] **Step 4: Register the commands**

In `plugin/intentdiff.lua`, add alongside the existing command definitions:

```lua
vim.api.nvim_create_user_command("IntentDiffCommentsYank", function()
  require("intentdiff.comments").export_clipboard()
end, { desc = "intent-diff: copy review comments as Markdown" })

vim.api.nvim_create_user_command("IntentDiffCommentsWrite", function(opts)
  require("intentdiff.comments").export_file(nil, opts.args)
end, { nargs = "?", complete = "file", desc = "intent-diff: write review comments to a file" })

vim.api.nvim_create_user_command("IntentDiffCommentsList", function()
  require("intentdiff.comments").list()
end, { desc = "intent-diff: list review comments" })

vim.api.nvim_create_user_command("IntentDiffCommentsClear", function()
  require("intentdiff.comments").clear()
end, { desc = "intent-diff: delete every review comment" })
```

- [ ] **Step 5: Install the keymaps on both surfaces**

Add to `lua/intentdiff/view.lua`, inside `M.install_keymaps(tabpage)`, after the existing per-pane binding loop — and add the same call in `sidebar.lua`'s keymap section, passing the sidebar buffer:

```lua
--- Comment keys, installed on every pane and on the sidebar. Cross-surface by
--- design: an intent comment is added from a group row, a line comment from a
--- pane, and both need the export keys.
function M.install_comment_keymaps(buf, tabpage)
  local cfg = require("intentdiff.config").options.comments or {}
  if cfg.enabled == false then
    return
  end
  local comments = require("intentdiff.comments")
  local handlers = {
    add_comment = function() comments.add(tabpage) end,
    add_note = function() comments.add(tabpage, "note") end,
    add_suggestion = function() comments.add(tabpage, "suggestion") end,
    add_issue = function() comments.add(tabpage, "issue") end,
    add_praise = function() comments.add(tabpage, "praise") end,
    add_file_comment = function() comments.add_file(tabpage) end,
    edit_comment = function() comments.edit(tabpage) end,
    delete_comment = function() comments.delete(tabpage) end,
    list_comments = function() comments.list(tabpage) end,
    next_comment = function() comments.next(tabpage) end,
    prev_comment = function() comments.prev(tabpage) end,
    export_clipboard = function() comments.export_clipboard(tabpage) end,
    export_file = function() comments.export_file(tabpage) end,
    clear_comments = function() comments.clear(tabpage) end,
    export_and_close = function() comments.export_and_close(tabpage) end,
  }
  require("intentdiff.keymaps").install(buf, "comments", handlers)

  -- Visual-mode variants: the same actions over a selected range. <Esc> first
  -- so '< and '> are set before context() reads them.
  local km = (require("intentdiff.config").options.keymaps or {}).comments or {}
  local visual = {
    [km.add_comment] = nil,
    [km.add_note] = "note",
    [km.add_suggestion] = "suggestion",
    [km.add_issue] = "issue",
    [km.add_praise] = "praise",
  }
  for lhs, comment_type in pairs(visual) do
    require("intentdiff.keymaps").each(lhs, function(key)
      pcall(vim.keymap.set, "x", key, function()
        vim.cmd("normal! \27")
        comments.add(tabpage, comment_type, { visual = true })
      end, { buffer = buf, nowait = true })
    end)
  end
  -- add_comment has a nil type, which a table literal cannot express as a key
  -- with a nil value — bind it separately.
  require("intentdiff.keymaps").each(km.add_comment, function(key)
    pcall(vim.keymap.set, "x", key, function()
      vim.cmd("normal! \27")
      comments.add(tabpage, nil, { visual = true })
    end, { buffer = buf, nowait = true })
  end)
end
```

Call `M.install_comment_keymaps(buf, tabpage)` for each pane buffer in `install_keymaps`, and from `sidebar.lua`'s keymap installation for the sidebar buffer.

- [ ] **Step 6: Refresh marks after every pane rebuild**

Add `require("intentdiff.comments.marks").refresh(tabpage)` at the end of each of: `view.show_file`'s completion path, `view.toggle_layout`, `view.apply_group_folds`, and `view.restore`. Guard each with the enabled check:

```lua
  local cfg = require("intentdiff.config").options.comments or {}
  if cfg.enabled ~= false then
    require("intentdiff.comments.marks").refresh(tabpage)
  end
```

- [ ] **Step 7: Expose the sidebar's group rows and buffer**

In `lua/intentdiff/sidebar.lua`, the returned handle gains two fields. `bufnr` is the sidebar buffer it already creates; `comment_rows()` walks the rendered meta table and returns one entry per group head row:

```lua
    --- Group head rows, for signing intents that carry a comment.
    --- @return { lnum: integer, title: string }[]
    comment_rows = function()
      local out = {}
      for lnum, meta in pairs(row_meta) do
        if meta.kind == "group" and meta.group_head then
          local group = last_model and last_model.groups and last_model.groups[meta.group_i]
          if group then
            out[#out + 1] = { lnum = lnum, title = group.title }
          end
        end
      end
      return out
    end,
```

Use the module's existing meta table and last-rendered-model locals — read the file to find their real names rather than assuming `row_meta` / `last_model`, and rename accordingly. Call `require("intentdiff.comments").refresh_sidebar(tabpage)` at the end of the sidebar's render function so signs survive a re-render.

- [ ] **Step 8: Attach and detach the store with the session**

In `lua/intentdiff/init.lua`, call `require("intentdiff.comments").attach_session(entry)` once the session's `git_root` and revisions are known (immediately after `entry.sess` is populated in the open path), and `require("intentdiff.comments").detach_session()` in `forget_entry`. Guard both with the `comments.enabled` check.

- [ ] **Step 9: Run the whole suite**

Run: `tests/run_tests.sh 2>&1 | tail -30`
Expected: every spec passes — the new comment specs and every pre-existing one. If a pre-existing spec breaks, the wiring changed behaviour it depended on; fix the wiring, not the old test.

- [ ] **Step 10: Commit**

```bash
git add lua/intentdiff/view.lua lua/intentdiff/sidebar.lua lua/intentdiff/init.lua \
        lua/intentdiff/keymap_help.lua plugin/intentdiff.lua tests/integration_spec.lua
git commit -m "feat(comments): wire comments into the review tab"
```

---

### Task 9: Manual verification and documentation

The feature is only real once it has been driven by hand. The specs cannot prove that a box renders legibly or that the side-by-side panes stay aligned.

**Files:**
- Modify: `README.md`
- Test: manual, against a real repository

**Interfaces:**
- Consumes: the whole feature.
- Produces: user-facing documentation.

- [ ] **Step 1: Drive it by hand**

In a repository with a dirty, multi-purpose working tree:

1. `:IntentDiff` and wait for grouping.
2. On a line in the right pane, `<localleader>ci`. Confirm the float opens with Issue selected, `<Tab>` cycles, `<C-s>` submits.
3. Confirm the sign, the line highlight and the box all render, and that the two panes stay vertically aligned (scroll both — this is what `marks.align` exists for).
4. Visually select five lines, `<localleader>cs`. Confirm every line highlights and the box hangs off the last.
5. In the left pane, comment a line. Confirm it renders there and not on the right.
6. On a sidebar group row, `<localleader>cf`. Confirm a sign appears on the intent row.
7. `]n` / `[n` between comments; `<localleader>ce` edits; `<localleader>cd` deletes.
8. `<localleader>cy`, then paste. Confirm the Markdown is grouped by intent, numbered continuously, with the `~` legend present only if you commented on the left.
9. `<localleader>cw`, accept the default path, confirm the file.
10. `R` to re-classify. Confirm comments survive and re-file under the new intents.
11. `<localleader>q`. Confirm it copies and closes.
12. Re-open `:IntentDiff` on the same branch. Confirm the comments came back.
13. `g?`. Confirm the COMMENTS section lists your real keys.

Fix anything that misbehaves before continuing. Report what you found.

- [ ] **Step 2: Document it in the README**

Add a `## Review comments` section after `## Previewing an intent`, covering: the four types and how to add each; line, range, file-level and intent comments; the old/new side rule and that old-side comments need side-by-side layout; persistence per repo and branch with the 7-day expiry; both export commands and their Markdown shape (paste a real example); and `<localleader>q`. Add the comment keys to the existing Keymaps tables, the new highlight groups to the Highlights table, and the `comments` block to the Configuration section.

- [ ] **Step 3: Run the whole suite one last time**

Run: `tests/run_tests.sh 2>&1 | tail -20`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: review comments and Markdown export"
```

---

## Self-Review

**Spec coverage.** Every section of the spec maps to a task: anchoring model → Task 4's `group_index`; side/line/file determination → Task 7's `side_for_win` and `context`; comment record → Task 2; modules → Tasks 2-7; persistence → Task 3; rendering → Tasks 5 and 7; highlights → Task 1; popup → Task 6; keymaps and commands → Tasks 1 and 8; export format → Task 4; error handling → distributed, with the notify/pcall/refusal paths tested in Tasks 2-4; testing → the spec's six spec files are Tasks 2-8. `export_on_close` is absent because the spec dropped it in favour of `<localleader>q`.

**Placeholders.** None: every code step carries real code, every test step real assertions, every run step a command and an expected result. Task 8 Step 7 deliberately instructs reading `sidebar.lua` for the real local names rather than inventing them — that is a real instruction, not a placeholder, because guessing an internal name would produce code that silently no-ops.

**Type consistency.** `store.add` returns `(comment|nil, err)` in Tasks 2, 3 and 7. `highlight.comment_groups` returns `(sign, line)` in Tasks 1, 5. `export.generate(comments, model)` keeps that argument order in Tasks 4, 7, 8. `marks.render_buffer(bufnr, file, side)` matches between Tasks 5 and 7. `storage.key` takes four arguments (`git_root, base_revision, target_revision, branch`) in both Tasks 3 and 7. Hunk ranges are treated end-exclusive in Task 4 only, which is the only place they are read.
