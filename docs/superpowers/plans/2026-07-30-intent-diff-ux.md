# intent-diff.nvim UX Pass Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give intent-diff a readable sidebar (wrapped group titles with `+N -M`
stats, a diffview-style file tree), make added files render their contents
folded to the open intent, and add a whole-intent diff preview that honours the
inline/side-by-side toggle.

**Architecture:** All rendering logic goes in pure modules returning
`lines, meta, highlights` (or buffer-pair equivalents) so it is asserted
directly without a live UI. `view.lua` stays the only module that requires
codediff; the preview injects buffers into the pane windows codediff already
owns and never creates or closes a window.

**Tech Stack:** Lua, Neovim 0.10+ API, plenary.nvim busted specs, codediff.nvim
(consumed through `lua/intentdiff/view.lua` only), optional nvim-web-devicons.

**Spec:** `docs/superpowers/specs/2026-07-30-intent-diff-ux-design.md`
**Probes (evidence, re-runnable):** `docs/superpowers/specs/2026-07-30-ux-probes/`

## Global Constraints

- Every diff surface must support toggling between side-by-side and inline,
  including the intent preview.
- `lua/intentdiff/view.lua` is the ONLY module permitted to `require` codediff.
- Never create or close a window to render a preview. Inject buffers into the
  pane windows the codediff session already owns.
- The completeness invariant is unchanged: union(groups) + Ungrouped == the
  exact inventory. Added-file sub-hunks ARE inventory hunks.
- Tests never call a real LLM — fake provider functions or `helpers.fake_bin`
  only.
- Hunk ranges are 1-based and end-exclusive; a `,0` side is a zero-width anchor
  `{ start_line = n, end_line = n }`.
- Commits are GPG-signed (`git commit -S`). No `Co-Authored-By` lines.
- Run the full suite with `tests/run_tests.sh`; it must report `failing=0`.
- Work directly on `master`.

---

### Task 1: Per-hunk addition/deletion counts

**Files:**
- Modify: `lua/intentdiff/hunks.lua:41-58` (hunk constructor and body loop), `lua/intentdiff/hunks.lua:63-76` (`M.untracked_hunk`)
- Test: `tests/hunks_parse_spec.lua`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: every hunk table gains `additions: integer` and `deletions: integer`.
  Consumed by `tree.flatten`, `sidebar.layout`, and `preview.render`.

- [ ] **Step 1: Write the failing test**

Append to `tests/hunks_parse_spec.lua`:

```lua
describe("hunks.parse line statistics", function()
  it("counts additions and deletions per hunk", function()
    local diff = table.concat({
      "diff --git a/a.lua b/a.lua",
      "index 1111111..2222222 100644",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,3 +1,4 @@",
      " keep",
      "-gone",
      "-also gone",
      "+new one",
      "+new two",
      "+new three",
      "",
    }, "\n")
    local parsed = require("intentdiff.hunks").parse(diff)
    assert.equals(1, #parsed)
    assert.equals(3, parsed[1].additions)
    assert.equals(2, parsed[1].deletions)
  end)

  it("does not count the --- / +++ file header lines", function()
    -- These precede the first @@, so `current` is nil and they must be
    -- skipped. A naive counter that runs before the @@ check would report
    -- one extra addition and one extra deletion here.
    local diff = table.concat({
      "diff --git a/a.lua b/a.lua",
      "--- a/a.lua",
      "+++ b/a.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
      "",
    }, "\n")
    local parsed = require("intentdiff.hunks").parse(diff)
    assert.equals(1, parsed[1].additions)
    assert.equals(1, parsed[1].deletions)
  end)

  it("does not count the no-newline marker", function()
    local diff = table.concat({
      "diff --git a/a.lua b/a.lua",
      "@@ -1,1 +1,1 @@",
      "-old",
      "\\ No newline at end of file",
      "+new",
      "",
    }, "\n")
    local parsed = require("intentdiff.hunks").parse(diff)
    assert.equals(1, parsed[1].additions)
    assert.equals(1, parsed[1].deletions)
  end)

  it("counts every added line for an untracked file", function()
    local h = require("intentdiff.hunks").untracked_hunk("new.lua", { "a", "b", "c" })
    assert.equals(3, h.additions)
    assert.equals(0, h.deletions)
  end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/hunks_parse_spec.lua"`
Expected: FAIL — `additions` is nil, so `assert.equals(3, nil)` errors.

- [ ] **Step 3: Implement the counters**

In `lua/intentdiff/hunks.lua`, add the two fields to the hunk constructor (the
table assigned to `current` inside the `^@@` branch), directly after `text`:

```lua
        text = line .. "\n",
        additions = 0,
        deletions = 0,
      }
```

Replace the body-accumulating branch:

```lua
    elseif current then
      current.text = current.text .. line .. "\n"
    end
```

with:

```lua
    elseif current then
      current.text = current.text .. line .. "\n"
      -- Body lines only: `diff --git`, `index`, `---` and `+++` all land here
      -- with `current == nil` (flush() runs at `diff --git`), so the file
      -- header can never be miscounted. "\ No newline at end of file" starts
      -- with a backslash and counts as neither.
      local kind = line:sub(1, 1)
      if kind == "+" then
        current.additions = current.additions + 1
      elseif kind == "-" then
        current.deletions = current.deletions + 1
      end
    end
```

In `M.untracked_hunk`, add to the returned table, after `text = text,`:

```lua
    additions = #lines,
    deletions = 0,
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/hunks_parse_spec.lua"`
Expected: PASS, `failing=0`.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0`.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/hunks.lua tests/hunks_parse_spec.lua
git commit -S -m "feat: count additions and deletions per hunk"
```

---

### Task 2: Split added files into sub-hunks

**Files:**
- Modify: `lua/intentdiff/hunks.lua` (add `M.split_added`, apply it in `M.collect`), `lua/intentdiff/config.lua` (add `added_file_split`, raise `max_hunks`)
- Test: `tests/hunks_split_spec.lua` (create), `tests/config_spec.lua`

**Interfaces:**
- Consumes: `additions`/`deletions` from Task 1.
- Produces: `hunks.split_added(hunk, opts) -> Hunk[]` where
  `opts = { min_lines: integer, target_lines: integer }`. `M.collect` returns
  inventories whose added-file hunks are already split and whose ids are
  renumbered `<path>:1`, `<path>:2`, … in file order.

- [ ] **Step 1: Write the failing test**

Create `tests/hunks_split_spec.lua`:

```lua
local hunks = require("intentdiff.hunks")
local helpers = require("tests.helpers")

--- Build a whole-file addition hunk from `lines`, the shape git emits for a
--- new file and `untracked_hunk` synthesises.
local function added_hunk(path, lines)
  return hunks.untracked_hunk(path, lines)
end

--- 90 lines: three blank-line-separated blocks of 30 lines each.
local function three_blocks()
  local lines = {}
  for block = 1, 3 do
    for i = 1, 29 do
      lines[#lines + 1] = ("block%d line%d"):format(block, i)
    end
    lines[#lines + 1] = ""
  end
  return lines
end

describe("hunks.split_added", function()
  it("leaves a hunk shorter than min_lines whole", function()
    local h = added_hunk("small.lua", { "a", "b", "c" })
    local out = hunks.split_added(h, { min_lines = 60, target_lines = 40 })
    assert.equals(1, #out)
    assert.equals(h, out[1])
  end)

  it("splits a long addition at blank-line boundaries", function()
    local h = added_hunk("big.lua", three_blocks())
    local out = hunks.split_added(h, { min_lines = 60, target_lines = 40 })
    assert.is_true(#out > 1)
    -- every cut lands immediately after a blank line, never mid-block
    for _, piece in ipairs(out) do
      local body = {}
      for line in piece.text:gmatch("(.-)\n") do
        if not line:match("^@@") then body[#body + 1] = line end
      end
      assert.equals("+", body[#body], "chunk must end on a blank source line")
    end
  end)

  it("produces contiguous, gapless, end-exclusive modified ranges", function()
    local h = added_hunk("big.lua", three_blocks())
    local out = hunks.split_added(h, { min_lines = 60, target_lines = 40 })
    assert.equals(1, out[1].modified.start_line)
    for i = 2, #out do
      assert.equals(out[i - 1].modified.end_line, out[i].modified.start_line)
    end
    assert.equals(#three_blocks() + 1, out[#out].modified.end_line)
  end)

  it("preserves every source line across the split", function()
    local source = three_blocks()
    local out = hunks.split_added(added_hunk("big.lua", source),
      { min_lines = 60, target_lines = 40 })
    local seen = {}
    for _, piece in ipairs(out) do
      for line in piece.text:gmatch("(.-)\n") do
        if not line:match("^@@") then seen[#seen + 1] = line:sub(2) end
      end
    end
    assert.same(source, seen)
  end)

  it("sets additions, zero deletions and a zero-width original anchor", function()
    local source = added_hunk("big.lua", three_blocks())
    local out = hunks.split_added(source, { min_lines = 60, target_lines = 40 })
    for _, piece in ipairs(out) do
      assert.equals(0, piece.deletions)
      assert.equals(piece.modified.end_line - piece.modified.start_line, piece.additions)
      assert.equals(1, piece.original.start_line)
      assert.equals(1, piece.original.end_line)
      assert.equals(source.status, piece.status)
      assert.equals(source.file, piece.file)
      assert.is_string(piece.content_hash)
    end
  end)

  it("gives each sub-hunk a distinct content hash", function()
    local out = hunks.split_added(added_hunk("big.lua", three_blocks()),
      { min_lines = 60, target_lines = 40 })
    local seen = {}
    for _, piece in ipairs(out) do
      assert.is_nil(seen[piece.content_hash], "sub-hunk hashes must differ")
      seen[piece.content_hash] = true
    end
  end)

  it("returns a modification hunk unchanged", function()
    local diff = table.concat({
      "diff --git a/a.lua b/a.lua",
      "@@ -1,2 +1,2 @@",
      " keep",
      "-old",
      "+new",
      "",
    }, "\n")
    local parsed = require("intentdiff.hunks").parse(diff)
    local out = hunks.split_added(parsed[1], { min_lines = 1, target_lines = 1 })
    assert.equals(1, #out)
    assert.equals(parsed[1], out[1])
  end)

  it("returns one chunk when the file has no blank lines", function()
    local lines = {}
    for i = 1, 100 do lines[i] = "line " .. i end
    local out = hunks.split_added(added_hunk("dense.lua", lines),
      { min_lines = 60, target_lines = 40 })
    assert.equals(1, #out)
  end)
end)

describe("hunks.collect with added-file splitting", function()
  it("splits a staged new file and renumbers ids per file", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local lines = {}
    for block = 1, 3 do
      for i = 1, 29 do lines[#lines + 1] = ("block%d line%d"):format(block, i) end
      lines[#lines + 1] = ""
    end
    helpers.write_file(repo, "added.lua", table.concat(lines, "\n"))
    helpers.git(repo, "add", "added.lua")

    require("intentdiff.config").setup({
      added_file_split = { enabled = true, min_lines = 60, target_lines = 40 },
    })
    local inv
    hunks.collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)

    local added = vim.tbl_filter(function(h) return h.file == "added.lua" end, inv.hunks)
    assert.is_true(#added > 1)
    for i, h in ipairs(added) do
      assert.equals("added.lua:" .. i, h.id)
    end
  end)

  it("keeps one hunk per added file when splitting is disabled", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local lines = {}
    for block = 1, 3 do
      for i = 1, 29 do lines[#lines + 1] = ("block%d line%d"):format(block, i) end
      lines[#lines + 1] = ""
    end
    helpers.write_file(repo, "added.lua", table.concat(lines, "\n"))
    helpers.git(repo, "add", "added.lua")

    require("intentdiff.config").setup({ added_file_split = { enabled = false } })
    local inv
    hunks.collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)

    local added = vim.tbl_filter(function(h) return h.file == "added.lua" end, inv.hunks)
    assert.equals(1, #added)
  end)
end)
```

Append to `tests/config_spec.lua`:

```lua
describe("config UX pass defaults", function()
  it("defaults added_file_split and raises max_hunks", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.is_true(config.options.added_file_split.enabled)
    assert.equals(60, config.options.added_file_split.min_lines)
    assert.equals(40, config.options.added_file_split.target_lines)
    assert.equals(600, config.options.max_hunks)
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/hunks_split_spec.lua"`
Expected: FAIL — `attempt to call field 'split_added' (a nil value)`.

- [ ] **Step 3: Implement `M.split_added`**

Add to `lua/intentdiff/hunks.lua`, after `M.untracked_hunk`:

```lua
--- Split a whole-file addition into sub-hunks at blank-line boundaries.
---
--- Applies only to pure additions — `@@ -0,0 +1,N @@`, which is what git emits
--- for status "A" and what M.untracked_hunk synthesises for "??". Anything with
--- a non-empty original side is returned unchanged, so this is safe to run over
--- every hunk in an inventory.
---
--- Blocks are delimited by blank source lines (a body line of exactly "+").
--- Whole blocks accumulate until the chunk reaches `target_lines`, so a cut
--- never lands inside a block. A trailing remainder shorter than half the
--- target is folded back into the previous chunk rather than left as a stub.
--- @return Hunk[] one or more hunks; the original table when no split applies
function M.split_added(hunk, opts)
  opts = opts or {}
  local min_lines = opts.min_lines or 60
  local target_lines = opts.target_lines or 40

  local body = {}
  for line in hunk.text:gmatch("(.-)\n") do
    if not line:match("^@@") and line:sub(1, 1) ~= "\\" then
      if line:sub(1, 1) ~= "+" then
        return { hunk } -- not a pure addition
      end
      body[#body + 1] = line
    end
  end
  if #body < min_lines then
    return { hunk }
  end

  local blocks, block = {}, {}
  for _, line in ipairs(body) do
    block[#block + 1] = line
    if line == "+" then -- blank source line closes a block
      blocks[#blocks + 1] = block
      block = {}
    end
  end
  if #block > 0 then
    blocks[#blocks + 1] = block
  end

  local chunks, acc = {}, {}
  for _, b in ipairs(blocks) do
    vim.list_extend(acc, b)
    if #acc >= target_lines then
      chunks[#chunks + 1] = acc
      acc = {}
    end
  end
  if #acc > 0 then
    if #chunks > 0 and #acc < math.floor(target_lines / 2) then
      vim.list_extend(chunks[#chunks], acc)
    else
      chunks[#chunks + 1] = acc
    end
  end
  if #chunks <= 1 then
    return { hunk }
  end

  local out, line_no = {}, hunk.modified.start_line
  for i, chunk in ipairs(chunks) do
    local header = ("@@ -0,0 +%d,%d @@"):format(line_no, #chunk)
    local text = header .. "\n" .. table.concat(chunk, "\n") .. "\n"
    out[i] = {
      id = hunk.file .. ":" .. i, -- re-derived by M.collect below
      file = hunk.file,
      old_path = hunk.old_path,
      status = hunk.status,
      header = header,
      original = { start_line = 1, end_line = 1 },
      modified = { start_line = line_no, end_line = line_no + #chunk },
      text = text,
      additions = #chunk,
      deletions = 0,
      content_hash = vim.fn.sha256(text),
    }
    line_no = line_no + #chunk
  end
  return out
end

--- Expand added-file hunks in place and renumber every id per file, so ids stay
--- `<path>:1`, `<path>:2`, … in modified-line order regardless of splitting.
--- Non-added hunks pass through untouched and keep the id parse() gave them.
local function apply_added_split(hunks)
  local cfg = require("intentdiff.config").options.added_file_split or {}
  local out, per_file = {}, {}
  for _, h in ipairs(hunks) do
    local pieces = (cfg.enabled == false) and { h } or M.split_added(h, cfg)
    for _, piece in ipairs(pieces) do
      per_file[piece.file] = (per_file[piece.file] or 0) + 1
      piece.id = piece.file .. ":" .. per_file[piece.file]
      out[#out + 1] = piece
    end
  end
  return out
end
```

In `M.collect`'s `finish_with`, replace the hash block:

```lua
      local hashes = {}
      for i, h in ipairs(hunks) do hashes[i] = h.content_hash end
```

with:

```lua
      -- Split BEFORE hashing: the inventory hash must describe the hunks the
      -- classifier and the cache actually see.
      hunks = apply_added_split(hunks)
      local hashes = {}
      for i, h in ipairs(hunks) do hashes[i] = h.content_hash end
```

- [ ] **Step 4: Add the config keys**

In `lua/intentdiff/config.lua`, change `max_hunks` and add `added_file_split`:

```lua
  max_hunks = 600, -- above this, skip classification with a notice
  -- Added and untracked files arrive from git as a single whole-file hunk, so
  -- they could only ever belong to one intent. Splitting them at blank-line
  -- boundaries lets different parts of one new file land in different intents,
  -- and makes the group fold filter meaningful for them. Set enabled = false
  -- to restore one-hunk-per-added-file.
  added_file_split = { enabled = true, min_lines = 60, target_lines = 40 },
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/hunks_split_spec.lua"`
Then: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/config_spec.lua"`
Expected: PASS both, `failing=0`.

- [ ] **Step 6: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0`. Existing `hunks_collect_spec.lua` and
`integration_spec.lua` assertions on hunk counts must still hold — their
fixtures are far below `min_lines = 60`.

- [ ] **Step 7: Commit**

```bash
git add lua/intentdiff/hunks.lua lua/intentdiff/config.lua tests/hunks_split_spec.lua tests/config_spec.lua
git commit -S -m "feat: split added files into sub-hunks at blank-line boundaries"
```

---

### Task 3: Render added-file contents and fold them to the group

**Files:**
- Modify: `lua/intentdiff/view.lua:307-324` (`show_whole_file`), `lua/intentdiff/view.lua:363-386` (`show_whole_file_inline`), `lua/intentdiff/view.lua:461-517` (`show_whole_file_in_layout`, `M.show_file`)
- Test: `tests/view_added_file_spec.lua` (create)

**Interfaces:**
- Consumes: sub-hunks from Task 2.
- Produces: no new public functions. `M.show_file` now applies group folds for
  `??`/`A`/`D` statuses too.

**Background — the bug.** `show_whole_file` passes
`sess.target_revision or "WORKING"` into codediff's
`show_added_virtual_file`, which builds `codediff:///<root>///WORKING/<path>`
and runs `git show WORKING:<path>`. That always fails and codediff renders a
single empty line (`codediff/core/virtual_file.lua:22-30`). codediff's own
explorer only uses the virtual-file path when `target_revision ~= "WORKING"`
(`codediff/ui/explorer/render.lua:273`), and otherwise loads the real file.

- [ ] **Step 1: Write the failing test**

Create `tests/view_added_file_spec.lua`:

```lua
local helpers = require("tests.helpers")

describe("view: added files", function()
  local view

  before_each(function()
    package.loaded["intentdiff.view"] = nil
    view = require("intentdiff.view")
    assert.is_true(view.load())
    require("intentdiff.config").setup({})
  end)

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      pcall(vim.cmd, "tabclose $")
    end
  end)

  --- Repo with a staged-new file of `n` numbered lines (status "A" vs HEAD,
  --- content only on disk and in the index — never in a commit).
  local function repo_with_added(n)
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local lines = {}
    for i = 1, n do lines[i] = "added line " .. i end
    helpers.write_file(repo, "added.lua", table.concat(lines, "\n"))
    helpers.git(repo, "add", "added.lua")
    return repo
  end

  local function base_of(repo)
    local base
    require("codediff.core.git").resolve_revision("HEAD", repo, function(_, h) base = h end)
    helpers.wait_for(function() return base end)
    return base
  end

  it("shows the real contents of a staged new file in working-tree mode", function()
    local repo = repo_with_added(20)
    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)
    local added = vim.tbl_filter(function(h) return h.file == "added.lua" end, inv.hunks)
    assert.equals(1, #added) -- 20 lines is below min_lines, so still whole

    local sess = { tabpage = view.open_tab(), git_root = repo,
      base_revision = base_of(repo), target_revision = "WORKING" }
    local ready = false
    view.show_file(sess, { path = "added.lua", status = "A", hunks = added },
      { on_ready = function() ready = true end })
    helpers.wait_for(function() return ready end, 10000)

    local session = view.get_session(sess.tabpage)
    local lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    assert.equals(20, #lines)
    assert.equals("added line 1", lines[1])
    assert.equals("added line 20", lines[20])
  end)

  it("folds a split added file down to the open group's sub-hunks", function()
    local repo = helpers.make_repo({ ["a.lua"] = "one" })
    local src = {}
    for block = 1, 3 do
      for i = 1, 29 do src[#src + 1] = ("block%d line%d"):format(block, i) end
      src[#src + 1] = ""
    end
    helpers.write_file(repo, "added.lua", table.concat(src, "\n"))
    helpers.git(repo, "add", "added.lua")

    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)
    local added = vim.tbl_filter(function(h) return h.file == "added.lua" end, inv.hunks)
    assert.is_true(#added > 1)

    local sess = { tabpage = view.open_tab(), git_root = repo,
      base_revision = base_of(repo), target_revision = "WORKING" }
    local ready = false
    -- group owns ONLY the first sub-hunk
    view.show_file(sess, { path = "added.lua", status = "A", hunks = { added[1] } },
      { on_ready = function() ready = true end })
    helpers.wait_for(function() return ready end, 10000)

    local session = view.get_session(sess.tabpage)
    local win = session.modified_win
    assert.equals("expr", vim.wo[win].foldmethod)
    local function foldclosed(l)
      return vim.api.nvim_win_call(win, function() return vim.fn.foldclosed(l) end)
    end
    -- first sub-hunk visible, a line from the last sub-hunk folded away
    assert.equals(-1, foldclosed(added[1].modified.start_line))
    assert.is_true(foldclosed(added[#added].modified.start_line) > 0)
  end)

  it("still uses the virtual-file path for a two-revision target", function()
    local repo = repo_with_added(20)
    helpers.git(repo, "commit", "-q", "-m", "add file")
    local sess = { tabpage = view.open_tab(), git_root = repo,
      base_revision = "HEAD~1", target_revision = "HEAD" }
    local ready = false
    view.show_file(sess, { path = "added.lua", status = "A", hunks = {} },
      { on_ready = function() ready = true end })
    helpers.wait_for(function() return ready end, 10000)

    local session = view.get_session(sess.tabpage)
    local lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    assert.equals(20, #lines)
    assert.equals("added line 1", lines[1])
  end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/view_added_file_spec.lua"`
Expected: FAIL — the first test reports `1` line (empty) instead of `20`.

- [ ] **Step 3: Add the target predicate and rewrite the dispatch**

In `lua/intentdiff/view.lua`, add above `show_whole_file`:

```lua
--- True when this session's target side is the working tree rather than a
--- named revision.
---
--- codediff loads an "A" pane through `git show <revision>:<path>`; the
--- sentinel "WORKING" is not a revision, so that lookup always fails and
--- codediff renders a single empty line (core/virtual_file.lua). codediff's own
--- explorer sidesteps this the same way, taking the virtual-file branch only
--- when target_revision ~= "WORKING" (ui/explorer/render.lua:273) and reading
--- the file off disk otherwise.
local function targets_worktree(sess)
  return sess.target_revision == nil or sess.target_revision == "WORKING"
end

--- True when `file_entry`'s pane content comes from a real file on disk, which
--- codediff loads synchronously — as opposed to a `codediff://` virtual file,
--- whose content arrives asynchronously (see wait_for_virtual_file).
local function loads_from_disk(sess, file_entry)
  return file_entry.status == "??"
    or (file_entry.status == "A" and targets_worktree(sess))
end
```

Replace `show_whole_file` with:

```lua
local function show_whole_file(tabpage, sess, file_entry, abs_path)
  if loads_from_disk(sess, file_entry) then
    cd.side_by_side.show_untracked_file(tabpage, abs_path)
  elseif file_entry.status == "A" then
    cd.side_by_side.show_added_virtual_file(
      tabpage, sess.git_root, file_entry.path, sess.target_revision)
  elseif file_entry.status == "D" then
    cd.side_by_side.show_deleted_virtual_file(tabpage, sess.git_root, file_entry.path, sess.base_revision)
  end
end
```

Replace `show_whole_file_inline`'s body with:

```lua
local function show_whole_file_inline(tabpage, sess, file_entry, abs_path)
  normalize_for_inline(tabpage)
  if loads_from_disk(sess, file_entry) then
    cd.inline_view.show_single_file(tabpage, abs_path, { side = "modified" })
  elseif file_entry.status == "A" then
    cd.inline_view.show_single_file(tabpage, file_entry.path, {
      revision = sess.target_revision,
      git_root = sess.git_root,
      rel_path = file_entry.path,
      side = "modified",
    })
  elseif file_entry.status == "D" then
    cd.inline_view.show_single_file(tabpage, file_entry.path, {
      revision = sess.base_revision,
      git_root = sess.git_root,
      rel_path = file_entry.path,
      side = "original",
    })
  end
end
```

In `show_whole_file_in_layout`, replace the readiness dispatch:

```lua
  if file_entry.status == "??" then
    -- Real file, loaded synchronously by show_untracked_file /
    -- show_single_file.
    vim.schedule(ready)
  else
```

with:

```lua
  if loads_from_disk(sess, file_entry) then
    -- Real file, loaded synchronously by show_untracked_file /
    -- show_single_file.
    vim.schedule(ready)
  else
```

- [ ] **Step 4: Apply group folds to whole-file statuses**

In `M.show_file`, replace the whole-file early return:

```lua
  -- Whole-file statuses: the entire file is the change — no folds needed.
  if file_entry.status == "??" or file_entry.status == "A" or file_entry.status == "D" then
    show_whole_file_in_layout(tabpage, sess, file_entry, abs_path, "side-by-side", opts.on_ready)
    return
  end
```

with:

```lua
  -- Whole-file statuses render a single pane. Added and untracked files are
  -- split into sub-hunks (hunks.split_added), so a group may own only part of
  -- one — fold the rest away exactly as for modified files. Deleted files and
  -- unsplit additions have a single hunk spanning everything, making this a
  -- no-op for them.
  if file_entry.status == "??" or file_entry.status == "A" or file_entry.status == "D" then
    show_whole_file_in_layout(tabpage, sess, file_entry, abs_path, "side-by-side", function()
      M.apply_group_folds(tabpage, file_entry.hunks)
      if opts.on_ready then
        opts.on_ready()
      end
    end)
    return
  end
```

Apply the same wrapping in `M.toggle_layout`'s whole-file branch, replacing:

```lua
      show_whole_file_in_layout(tabpage, shown.sess, shown.file_entry, abs_path, target_layout)
      return true
```

with:

```lua
      show_whole_file_in_layout(tabpage, shown.sess, shown.file_entry, abs_path, target_layout,
        function()
          M.apply_group_folds(tabpage, shown.file_entry.hunks)
        end)
      return true
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/view_added_file_spec.lua"`
Expected: PASS, `failing=0`.

- [ ] **Step 6: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0`.

- [ ] **Step 7: Commit**

```bash
git add lua/intentdiff/view.lua tests/view_added_file_spec.lua
git commit -S -m "fix: render added-file contents in working-tree mode and fold them to the group"
```

---

### Task 4: Highlight group definitions

**Files:**
- Create: `lua/intentdiff/highlight.lua`
- Test: `tests/highlight_spec.lua` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `highlight.ensure()` — idempotent; defines every `IntentDiff*`
  group as a `default = true` link and re-applies on `ColorScheme`.
  `highlight.links` is the name → target table. Consumed by Tasks 6 and 7.

- [ ] **Step 1: Write the failing test**

Create `tests/highlight_spec.lua`:

```lua
describe("highlight", function()
  it("defines every documented group as a link", function()
    local hl = require("intentdiff.highlight")
    hl.ensure()
    for name, target in pairs(hl.links) do
      local def = vim.api.nvim_get_hl(0, { name = name })
      assert.equals(target, def.link, name .. " must link to " .. target)
    end
  end)

  it("covers the groups the sidebar and preview use", function()
    local hl = require("intentdiff.highlight")
    for _, name in ipairs({
      "IntentDiffGroupTitle", "IntentDiffGroupStats", "IntentDiffAdd",
      "IntentDiffDelete", "IntentDiffDirectory", "IntentDiffIndent",
      "IntentDiffStatusA", "IntentDiffStatusM", "IntentDiffStatusD",
      "IntentDiffStatusUntracked", "IntentDiffPreviewFile",
      "IntentDiffPreviewHunk", "IntentDiffFiller",
    }) do
      assert.is_string(hl.links[name], name .. " must be defined")
    end
  end)

  it("does not clobber a user override", function()
    local hl = require("intentdiff.highlight")
    vim.api.nvim_set_hl(0, "IntentDiffAdd", { fg = "#ff0000" })
    hl.ensure()
    local def = vim.api.nvim_get_hl(0, { name = "IntentDiffAdd" })
    assert.is_nil(def.link)
    vim.api.nvim_set_hl(0, "IntentDiffAdd", {}) -- reset for later specs
  end)

  it("is idempotent", function()
    local hl = require("intentdiff.highlight")
    hl.ensure()
    hl.ensure()
    assert.equals(1, #vim.api.nvim_get_autocmds({ group = "IntentDiffHighlight" }))
  end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/highlight_spec.lua"`
Expected: FAIL — `module 'intentdiff.highlight' not found`.

- [ ] **Step 3: Implement the module**

Create `lua/intentdiff/highlight.lua`:

```lua
-- Highlight groups for the sidebar and the intent preview.
--
-- Every group is defined with `default = true`, so an explicit user definition
-- (before or after setup) always wins. Re-applied on ColorScheme because
-- `:colorscheme` clears user highlight definitions.
local M = {}

M.links = {
  IntentDiffGroupTitle = "Title",
  IntentDiffGroupStats = "Comment",
  IntentDiffAdd = "Added",
  IntentDiffDelete = "Removed",
  IntentDiffDirectory = "Directory",
  IntentDiffIndent = "Comment",
  IntentDiffStatusA = "Added",
  IntentDiffStatusM = "Changed",
  IntentDiffStatusD = "Removed",
  IntentDiffStatusUntracked = "Added",
  IntentDiffPreviewFile = "Title",
  IntentDiffPreviewHunk = "Comment",
  IntentDiffFiller = "Comment",
}

--- Status letter → highlight group, for the sidebar's status gutter and the
--- preview's file separators.
function M.status_group(status)
  if status == "A" then
    return "IntentDiffStatusA"
  elseif status == "D" then
    return "IntentDiffStatusD"
  elseif status == "??" then
    return "IntentDiffStatusUntracked"
  end
  return "IntentDiffStatusM"
end

--- The single character shown in the status gutter.
function M.status_char(status)
  return status == "??" and "?" or (status or "M")
end

local function define()
  for name, target in pairs(M.links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

local augroup

--- Define the groups and keep them defined across colorscheme changes.
function M.ensure()
  define()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("IntentDiffHighlight", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = define })
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/highlight_spec.lua"`
Expected: PASS, `failing=0`.

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/highlight.lua tests/highlight_spec.lua
git commit -S -m "feat: add IntentDiff highlight groups"
```

---

### Task 5: File tree model

**Files:**
- Create: `lua/intentdiff/tree.lua`
- Test: `tests/tree_spec.lua` (create)

**Interfaces:**
- Consumes: `additions`/`deletions` from Task 1; file entries as produced by
  `classify.group_files` — `{ path, status, old_path, hunks }`.
- Produces:
  - `tree.build(files) -> node[]` — roots. Node:
    `{ kind = "dir"|"file", name, path, children?, file?, file_i? }`.
  - `tree.flatten(nodes, collapsed) -> row[]` — row:
    `{ kind, depth, name, path, last, collapsed?, status?, additions?, deletions?, file_i? }`.
  `file_i` is the 1-based index into the group's `files` array, so existing
  `on_select(group_i, file_i)` wiring is unchanged.

- [ ] **Step 1: Write the failing test**

Create `tests/tree_spec.lua`:

```lua
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/tree_spec.lua"`
Expected: FAIL — `module 'intentdiff.tree' not found`.

- [ ] **Step 3: Implement the module**

Create `lua/intentdiff/tree.lua`:

```lua
-- Pure directory-tree model for a single group's files. No Neovim UI state:
-- build() turns a flat file list into nodes, flatten() turns nodes into
-- renderable rows. The sidebar owns all presentation.
local M = {}

--- Collapse chains of single-child directories into one node, so
--- `app/ -> api/ -> integrations/` renders as one `app/api/integrations` row.
--- The synthetic root is never collapsed — its children ARE the top level.
local function compress(node)
  for _, child in ipairs(node.children or {}) do
    if child.kind == "dir" then
      while #child.children == 1 and child.children[1].kind == "dir" do
        local grandchild = child.children[1]
        child.name = child.name .. "/" .. grandchild.name
        child.path = grandchild.path
        child.children = grandchild.children
      end
      compress(child)
    end
  end
end

local function sort_tree(node)
  table.sort(node.children, function(a, b)
    if a.kind ~= b.kind then
      return a.kind == "dir" -- directories first
    end
    return a.name < b.name
  end)
  for _, child in ipairs(node.children) do
    if child.kind == "dir" then
      sort_tree(child)
    end
  end
end

--- Build a directory tree from a group's file entries.
--- @param files table[] { path, status, old_path, hunks }, as classify.group_files returns
--- @return table[] roots
function M.build(files)
  local root = { kind = "dir", name = "", path = "", children = {}, index = {} }
  for file_i, f in ipairs(files) do
    local segments = vim.split(f.path, "/", { plain = true, trimempty = true })
    local node = root
    for i = 1, #segments - 1 do
      local segment = segments[i]
      local child = node.index[segment]
      if not child then
        child = {
          kind = "dir",
          name = segment,
          path = node.path == "" and segment or (node.path .. "/" .. segment),
          children = {},
          index = {},
        }
        node.index[segment] = child
        node.children[#node.children + 1] = child
      end
      node = child
    end
    node.children[#node.children + 1] = {
      kind = "file",
      name = segments[#segments],
      path = f.path,
      file = f,
      file_i = file_i,
    }
  end
  compress(root)
  sort_tree(root)
  return root.children
end

local function file_stats(f)
  local additions, deletions = 0, 0
  for _, h in ipairs(f.hunks or {}) do
    additions = additions + (h.additions or 0)
    deletions = deletions + (h.deletions or 0)
  end
  return additions, deletions
end

--- Flatten nodes into ordered rows, skipping collapsed subtrees.
--- @param nodes table[] roots from M.build
--- @param collapsed table<string, boolean> keyed by directory path
--- @return table[] rows
function M.flatten(nodes, collapsed)
  collapsed = collapsed or {}
  local rows = {}
  local function walk(list, depth)
    for i, node in ipairs(list) do
      local last = i == #list
      if node.kind == "dir" then
        local is_collapsed = collapsed[node.path] == true
        rows[#rows + 1] = {
          kind = "dir",
          depth = depth,
          name = node.name,
          path = node.path,
          collapsed = is_collapsed,
          last = last,
        }
        if not is_collapsed then
          walk(node.children, depth + 1)
        end
      else
        local additions, deletions = file_stats(node.file)
        rows[#rows + 1] = {
          kind = "file",
          depth = depth,
          name = node.name,
          path = node.path,
          status = node.file.status,
          additions = additions,
          deletions = deletions,
          file_i = node.file_i,
          last = last,
        }
      end
    end
  end
  walk(nodes, 0)
  return rows
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/tree_spec.lua"`
Expected: PASS, `failing=0`.

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/tree.lua tests/tree_spec.lua
git commit -S -m "feat: add pure file tree model"
```

---

### Task 6: Sidebar — wrapped titles, stats, tree rows, highlights

**Files:**
- Modify: `lua/intentdiff/sidebar.lua` (whole file), `lua/intentdiff/config.lua` (`sidebar_width`, `icons`), `lua/intentdiff/init.lua:583-589` (`on_toggle_group` callback wiring)
- Test: `tests/sidebar_spec.lua`

**Interfaces:**
- Consumes: `tree.build`/`tree.flatten` (Task 5), `highlight.ensure`,
  `highlight.status_group`, `highlight.status_char` (Task 4), per-hunk
  `additions`/`deletions` (Task 1).
- Produces:
  - `sidebar.layout(model) -> lines, meta, highlights` — third return added.
    Highlight span: `{ line = <1-based>, col_start = <0-based byte>, col_end = <byte, exclusive>, hl = <group> }`.
  - Meta kinds: `"info"`, `"group"` (all wrapped title lines AND the stats
    line), `"dir"` (`{ kind, group_i, dir_path }`), `"file"`
    (`{ kind, group_i, file_i }` — unchanged), `"footer"`.
  - `sidebar.create(callbacks)` gains `callbacks.on_toggle_dir(group_i, dir_path)`
    alongside the existing `on_toggle_group(group_i)`.

- [ ] **Step 1: Write the failing test**

Replace the body of `describe("sidebar.layout", ...)` in `tests/sidebar_spec.lua`
with these tests (keep the `mk_model` helper, adding `additions`/`deletions` to
its hunks so stats are non-zero):

```lua
describe("sidebar.layout", function()
  it("wraps a long group title across lines with shared meta", function()
    local model = mk_model({ groups = { { title =
      "Extract the integration catalog into a shared provider registry" } } })
    local lines, meta = sidebar.layout(model)
    assert.truthy(lines[1]:find("▾ Extract"))
    -- title needs more than one line at the default width
    assert.equals("group", meta[1].kind)
    assert.equals("group", meta[2].kind)
    assert.equals(1, meta[1].group_i)
    assert.equals(1, meta[2].group_i)
    -- the wrap guarantee covers title lines only. File and directory rows are
    -- never wrapped — a long path just runs past the window edge, as in
    -- diffview — so they are excluded here deliberately.
    local title_lines = 0
    for i, line in ipairs(lines) do
      if meta[i].kind == "group" and not line:find("hunks", 1, true) then
        title_lines = title_lines + 1
        assert.is_true(vim.fn.strdisplaywidth(line) <= 40,
          ("title line exceeds sidebar width: %q"):format(line))
      end
    end
    assert.is_true(title_lines >= 2, "long title must occupy more than one line")
  end)

  it("renders a stats line with hunk count, file count and +/- totals", function()
    local model = mk_model()
    model.groups[1].hunks = {
      { additions = 10, deletions = 4 },
      { additions = 3, deletions = 0 },
    }
    local lines, meta = sidebar.layout(model)
    local stats_line, stats_i
    for i, line in ipairs(lines) do
      if line:find("hunks", 1, true) and line:find("+13", 1, true) then
        stats_line, stats_i = line, i
      end
    end
    assert.truthy(stats_line, "expected a stats line")
    assert.truthy(stats_line:find("2 hunks", 1, true))
    assert.truthy(stats_line:find("2 files", 1, true))
    assert.truthy(stats_line:find("+13", 1, true))
    assert.truthy(stats_line:find("-4", 1, true))
    -- the stats line belongs to its group, so hover/toggle treat it as one row
    assert.equals("group", meta[stats_i].kind)
    assert.equals(1, meta[stats_i].group_i)
  end)

  it("renders files as a tree with directory rows", function()
    local model = mk_model()
    local lines, meta = sidebar.layout(model)
    local dir_i, file_i
    for i, m in ipairs(meta) do
      if m.kind == "dir" and not dir_i then dir_i = i end
      if m.kind == "file" and not file_i then file_i = i end
    end
    assert.truthy(dir_i, "expected a directory row")
    assert.truthy(lines[dir_i]:find("src/http", 1, true),
      "single-child chain must be compressed")
    assert.equals("src/http", meta[dir_i].dir_path)
    assert.truthy(file_i > dir_i, "files come after their directory")
    assert.truthy(lines[file_i]:find("backoff.lua", 1, true))
  end)

  it("keeps file meta as group_i/file_i indices into the group's files", function()
    local model = mk_model()
    local _, meta = sidebar.layout(model)
    for _, m in ipairs(meta) do
      if m.kind == "file" then
        assert.is_number(m.group_i)
        assert.is_number(m.file_i)
        assert.truthy(model.groups[m.group_i].files[m.file_i])
      end
    end
  end)

  it("puts the status letter in the leading gutter", function()
    local model = mk_model()
    local lines, meta = sidebar.layout(model)
    for i, m in ipairs(meta) do
      if m.kind == "file" then
        local status = model.groups[m.group_i].files[m.file_i].status
        assert.equals(status == "??" and "?" or status, vim.trim(lines[i]:sub(1, 2)))
      end
    end
  end)

  it("returns highlight spans for stats and status letters", function()
    local model = mk_model()
    model.groups[1].hunks = { { additions = 10, deletions = 4 } }
    local lines, _, highlights = sidebar.layout(model)
    assert.is_table(highlights)
    local groups = {}
    for _, span in ipairs(highlights) do
      groups[span.hl] = true
      -- spans must address real byte ranges on their line
      assert.truthy(lines[span.line], "span points at a missing line")
      assert.is_true(span.col_end <= #lines[span.line])
      assert.is_true(span.col_start < span.col_end)
    end
    assert.is_true(groups.IntentDiffAdd, "expected an IntentDiffAdd span")
    assert.is_true(groups.IntentDiffDelete, "expected an IntentDiffDelete span")
    assert.is_true(groups.IntentDiffGroupTitle, "expected a title span")
  end)

  it("omits a zero side of the stats", function()
    local model = mk_model()
    model.groups[1].hunks = { { additions = 5, deletions = 0 } }
    local lines = sidebar.layout(model)
    local stats = vim.tbl_filter(function(l) return l:find("hunks", 1, true) end, lines)[1]
    assert.truthy(stats:find("+5", 1, true))
    assert.is_nil(stats:find("-0", 1, true))
  end)

  it("hides a collapsed directory's files", function()
    local model = mk_model()
    model.groups[1].collapsed_dirs = { ["src/http"] = true }
    local _, meta = sidebar.layout(model)
    for _, m in ipairs(meta) do
      assert.is_false(m.kind == "file" and m.group_i == 1,
        "collapsed directory must hide its files")
    end
  end)

  it("still renders the loading and footer rows", function()
    local lines, meta = sidebar.layout(mk_model({ state = "loading", elapsed_s = 7 }))
    assert.truthy(lines[1]:find("classifying"))
    assert.equals("info", meta[1].kind)
  end)
end)
```

Update `mk_model` so its hunks carry stats — replace both
`hunks = { {}, {} }` and `hunks = { {} }` occurrences with hunks that have
counts, e.g. `hunks = { { additions = 2, deletions = 1 }, { additions = 1, deletions = 0 } }`
for the group and `hunks = { { additions = 1, deletions = 0 } }` for each file.

Add to `tests/config_spec.lua`:

```lua
describe("config sidebar defaults", function()
  it("widens the sidebar and enables icons", function()
    local config = require("intentdiff.config")
    config.setup({})
    assert.equals(40, config.options.sidebar_width)
    assert.is_true(config.options.icons)
  end)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/sidebar_spec.lua"`
Expected: FAIL — no stats line, no `dir` meta, `highlights` is nil.

- [ ] **Step 3: Rewrite `sidebar.layout`**

Replace `M.layout` in `lua/intentdiff/sidebar.lua` with:

```lua
local tree = require("intentdiff.tree")
local hl = require("intentdiff.highlight")

--- Hard-wrap `text` to `width` display columns on word boundaries, hard-cutting
--- a single word that is longer than the width. The sidebar window keeps
--- `wrap = false` so tree alignment survives; wrapping happens here instead.
local function wrap_text(text, width)
  local out, line = {}, ""
  for word in text:gmatch("%S+") do
    local candidate = line == "" and word or (line .. " " .. word)
    if vim.fn.strdisplaywidth(candidate) <= width then
      line = candidate
    else
      if line ~= "" then
        out[#out + 1] = line
      end
      while vim.fn.strdisplaywidth(word) > width do
        local cut = word
        while vim.fn.strdisplaywidth(cut) > width do
          cut = cut:sub(1, #cut - 1)
        end
        out[#out + 1] = cut
        word = word:sub(#cut + 1)
      end
      line = word
    end
  end
  if line ~= "" then
    out[#out + 1] = line
  end
  if #out == 0 then
    out[1] = ""
  end
  return out
end

--- Devicon for `path`, or "" when nvim-web-devicons is absent or icons are off.
--- Mirrors codediff's own pcall guard (ui/explorer/nodes.lua).
local function file_icon(path)
  if not require("intentdiff.config").options.icons then
    return "", nil
  end
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if not ok then
    return "", nil
  end
  local icon, icon_hl = devicons.get_icon(path, nil, { default = true })
  return icon or "", icon_hl
end

local function stats_text(additions, deletions)
  local parts = {}
  if additions > 0 then
    parts[#parts + 1] = "+" .. additions
  end
  if deletions > 0 then
    parts[#parts + 1] = "-" .. deletions
  end
  return parts
end

--- Pure layout: Model → buffer lines, per-line metadata, highlight spans.
--- @return string[] lines, table[] meta, table[] highlights
---   highlight span: { line, col_start, col_end, hl } — 1-based line,
---   0-based byte columns, col_end exclusive.
function M.layout(model)
  local width = require("intentdiff.config").options.sidebar_width
  local lines, meta, highlights = {}, {}, {}

  local function add(text, m)
    lines[#lines + 1] = text
    meta[#lines] = m
    return #lines
  end
  local function span(line, col_start, col_end, group)
    if col_end > col_start then
      highlights[#highlights + 1] =
        { line = line, col_start = col_start, col_end = col_end, hl = group }
    end
  end

  if model.state == "loading" then
    if type(model.elapsed_s) == "number" then
      add(("⟳ classifying… %ds"):format(model.elapsed_s), { kind = "info" })
    else
      add("⟳ classifying…", { kind = "info" })
    end
  end
  if model.message then
    add("⚠ " .. model.message, { kind = "info" })
  end

  for gi, g in ipairs(model.groups or {}) do
    local group_meta = { kind = "group", group_i = gi }
    local marker = g.collapsed and "▸" or "▾"
    local title_lines = wrap_text(g.title, width - 2)
    for i, text in ipairs(title_lines) do
      local prefix = i == 1 and (marker .. " ") or "  "
      local lnum = add(prefix .. text, group_meta)
      span(lnum, #prefix, #prefix + #text, "IntentDiffGroupTitle")
    end

    local additions, deletions = 0, 0
    for _, h in ipairs(g.hunks or {}) do
      additions = additions + (h.additions or 0)
      deletions = deletions + (h.deletions or 0)
    end
    local counts = ("  %d hunks · %d files"):format(#(g.hunks or {}), #(g.files or {}))
    local stats_line = counts
    local parts = stats_text(additions, deletions)
    local lnum = add(stats_line .. (#parts > 0 and ("  " .. table.concat(parts, " ")) or ""),
      group_meta)
    span(lnum, 0, #counts, "IntentDiffGroupStats")
    local col = #stats_line + 2
    for _, part in ipairs(parts) do
      span(lnum, col, col + #part,
        part:sub(1, 1) == "+" and "IntentDiffAdd" or "IntentDiffDelete")
      col = col + #part + 1
    end

    if not g.collapsed then
      local rows = tree.flatten(tree.build(g.files or {}), g.collapsed_dirs or {})
      for _, row in ipairs(rows) do
        local status = row.kind == "file" and hl.status_char(row.status) or " "
        local gutter = (" %-1s "):format(status)
        local indent = string.rep("  ", row.depth)
        local text, icon_hl
        if row.kind == "dir" then
          text = (row.collapsed and "▸ " or "▾ ") .. row.name
        else
          local icon
          icon, icon_hl = file_icon(row.path)
          text = "  " .. (icon ~= "" and (icon .. " ") or "") .. row.name
        end
        local body = gutter .. indent .. text
        local row_parts = row.kind == "file" and stats_text(row.additions, row.deletions) or {}
        local suffix = #row_parts > 0 and ("  " .. table.concat(row_parts, " ")) or ""
        local row_meta = row.kind == "dir"
            and { kind = "dir", group_i = gi, dir_path = row.path }
          or { kind = "file", group_i = gi, file_i = row.file_i }
        local rnum = add(body .. suffix, row_meta)

        if row.kind == "file" then
          span(rnum, 1, 1 + #status, hl.status_group(row.status))
        end
        if #indent > 0 then
          span(rnum, #gutter, #gutter + #indent, "IntentDiffIndent")
        end
        if row.kind == "dir" then
          span(rnum, #gutter + #indent, #body, "IntentDiffDirectory")
        elseif icon_hl then
          local icon_start = #gutter + #indent + 2
          span(rnum, icon_start, icon_start + #text - 2 - #row.name, icon_hl)
        end
        local scol = #body + 2
        for _, part in ipairs(row_parts) do
          span(rnum, scol, scol + #part,
            part:sub(1, 1) == "+" and "IntentDiffAdd" or "IntentDiffDelete")
          scol = scol + #part + 1
        end
      end
    end
  end

  if model.state == "ready" then
    local stale = (model.stale_count or 0) > 0
        and (" · stale — %d unclassified"):format(model.stale_count) or ""
    -- No provider label ⇒ no provider produced this grouping (flat fallback
    -- after a provider failure). Omit the field entirely; a literal "?" read
    -- like a broken provider name.
    local label = model.provider_label and (" · " .. model.provider_label) or ""
    add(("%d/%d hunks%s%s"):format(model.grouped_hunks, model.total_hunks, label, stale),
      { kind = "footer" })
  end
  return lines, meta, highlights
end
```

- [ ] **Step 4: Apply the spans and wire the directory toggle**

In `M.create`, call `require("intentdiff.highlight").ensure()` as the first
statement, then replace `handle.update`'s highlight loop:

```lua
  function handle.update(model)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local lines, meta, highlights = M.layout(model)
    handle.meta = meta
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    for i, m in ipairs(meta) do
      local line_hl = ({ info = "WarningMsg", footer = "Comment" })[m.kind]
      if line_hl then
        vim.api.nvim_buf_set_extmark(bufnr, M.ns, i - 1, 0, { line_hl_group = line_hl })
      end
    end
    for _, s in ipairs(highlights) do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, s.line - 1, s.col_start,
        { end_col = s.col_end, hl_group = s.hl })
    end
  end
```

Replace the `za`/`h`/`l` mapping so directory rows toggle their own state:

```lua
  for _, key in ipairs({ "za", "h", "l" }) do
    map(key, function()
      local m = cursor_meta()
      if m.kind == "dir" then
        callbacks.on_toggle_dir(m.group_i, m.dir_path)
      elseif m.group_i then
        callbacks.on_toggle_group(m.group_i)
      end
    end)
  end
```

And in the `<CR>` mapping, add the directory case:

```lua
  map("<CR>", function()
    local m = cursor_meta()
    if m.kind == "file" then
      callbacks.on_select(m.group_i, m.file_i)
    elseif m.kind == "dir" then
      callbacks.on_toggle_dir(m.group_i, m.dir_path)
    elseif m.kind == "group" then
      callbacks.on_toggle_group(m.group_i)
    end
  end)
```

In `lua/intentdiff/init.lua`, add the `on_toggle_dir` callback next to
`on_toggle_group` in the `sidebar.create` call:

```lua
    on_toggle_dir = function(gi, dir_path)
      local entry = sessions[token]
      local g = entry and entry.model.groups[gi]
      if g then
        g.collapsed_dirs = g.collapsed_dirs or {}
        g.collapsed_dirs[dir_path] = not g.collapsed_dirs[dir_path] or nil
        entry.sidebar.update(entry.model)
      end
    end,
```

- [ ] **Step 5: Update the config defaults**

In `lua/intentdiff/config.lua`:

```lua
  sidebar_width = 40,
  icons = true, -- file icons from nvim-web-devicons when it is installed
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/sidebar_spec.lua"`
Then: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/config_spec.lua"`
Expected: PASS both, `failing=0`.

- [ ] **Step 7: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0`. `integration_spec.lua` selects files by walking meta for
`kind == "file"`, which still works.

- [ ] **Step 8: Commit**

```bash
git add lua/intentdiff/sidebar.lua lua/intentdiff/config.lua lua/intentdiff/init.lua tests/sidebar_spec.lua tests/config_spec.lua
git commit -S -m "feat: wrapped group titles, +/- stats and a file tree in the sidebar"
```

---

### Task 7: Whole-intent preview rendering

**Files:**
- Create: `lua/intentdiff/preview.lua`
- Test: `tests/preview_spec.lua` (create)

**Interfaces:**
- Consumes: `tree.build`/`tree.flatten` (Task 5) for file ordering, hunk
  `additions`/`deletions` (Task 1), highlight group names (Task 4).
- Produces: `preview.render(group, layout, opts) -> rendered` where
  `layout` is `"inline"` or `"side-by-side"`, `opts = { max_lines: integer }`,
  and `rendered` is:
  - inline: `{ layout = "inline", modified = { lines, highlights }, hunk_lines }`
  - side-by-side: `{ layout = "side-by-side", original = { lines, highlights }, modified = { lines, highlights }, hunk_lines }`
  `hunk_lines` is a sorted array of 1-based line numbers carrying a `@@`
  header, used by the preview's `]c`/`[c`. Highlight spans use the same
  `{ line, col_start, col_end, hl }` shape as the sidebar; a span with
  `col_start = 0, col_end = -1` means "whole line".

- [ ] **Step 1: Write the failing test**

Create `tests/preview_spec.lua`:

```lua
local preview = require("intentdiff.preview")

local function hunk(header, body, additions, deletions)
  return {
    header = header,
    text = header .. "\n" .. table.concat(body, "\n") .. "\n",
    additions = additions,
    deletions = deletions,
    modified = { start_line = 1, end_line = 2 },
    original = { start_line = 1, end_line = 2 },
  }
end

local function group()
  local h1 = hunk("@@ -1,2 +1,3 @@", { " keep", "-old", "+new", "+extra" }, 2, 1)
  local h2 = hunk("@@ -10,1 +11,1 @@", { "-gone", "+arrived" }, 1, 1)
  return {
    title = "Auth",
    hunks = { h1, h2 },
    files = {
      { path = "src/auth.lua", status = "M", hunks = { h1 } },
      { path = "new.lua", status = "A", hunks = { h2 } },
    },
  }
end

describe("preview.render inline", function()
  it("emits a separator per file followed by its hunks", function()
    local r = preview.render(group(), "inline", {})
    assert.equals("inline", r.layout)
    local text = table.concat(r.modified.lines, "\n")
    assert.truthy(text:find("src/auth.lua", 1, true))
    assert.truthy(text:find("new.lua", 1, true))
    assert.truthy(text:find("@@ -1,2 +1,3 @@", 1, true))
    assert.truthy(text:find("+new", 1, true))
  end)

  it("shows the status and +/- totals on each separator", function()
    local r = preview.render(group(), "inline", {})
    local sep = vim.tbl_filter(function(l)
      return l:find("src/auth.lua", 1, true)
    end, r.modified.lines)[1]
    assert.truthy(sep:find("M", 1, true))
    assert.truthy(sep:find("+2", 1, true))
    assert.truthy(sep:find("-1", 1, true))
  end)

  it("orders files the same way the sidebar tree does", function()
    local r = preview.render(group(), "inline", {})
    local auth_i, new_i
    for i, l in ipairs(r.modified.lines) do
      if l:find("src/auth.lua", 1, true) then auth_i = i end
      if l:find("new.lua", 1, true) then new_i = i end
    end
    -- tree order puts the src/ directory before the root-level file
    assert.is_true(auth_i < new_i)
  end)

  it("reports the lines carrying hunk headers", function()
    local r = preview.render(group(), "inline", {})
    assert.equals(2, #r.hunk_lines)
    for _, lnum in ipairs(r.hunk_lines) do
      assert.truthy(r.modified.lines[lnum]:find("^@@"))
    end
  end)

  it("highlights added, deleted, header and separator lines", function()
    local r = preview.render(group(), "inline", {})
    local seen = {}
    for _, s in ipairs(r.modified.highlights) do seen[s.hl] = true end
    assert.is_true(seen.IntentDiffAdd)
    assert.is_true(seen.IntentDiffDelete)
    assert.is_true(seen.IntentDiffPreviewHunk)
    assert.is_true(seen.IntentDiffPreviewFile)
  end)
end)

describe("preview.render side-by-side", function()
  it("returns two panes of equal length", function()
    local r = preview.render(group(), "side-by-side", {})
    assert.equals("side-by-side", r.layout)
    assert.equals(#r.original.lines, #r.modified.lines)
  end)

  it("pairs a deletion run with the following addition run", function()
    local h = hunk("@@ -1,2 +1,3 @@", { "-a", "-b", "+x", "+y", "+z" }, 3, 2)
    local g = { title = "T", hunks = { h },
      files = { { path = "f.lua", status = "M", hunks = { h } } } }
    local r = preview.render(g, "side-by-side", {})
    -- find the row where the first deletion sits
    local row
    for i, l in ipairs(r.original.lines) do
      if l == "a" then row = i end
    end
    assert.truthy(row)
    assert.equals("x", r.modified.lines[row])
    assert.equals("b", r.original.lines[row + 1])
    assert.equals("y", r.modified.lines[row + 1])
    -- third addition has no counterpart: filler on the original side
    assert.equals("", r.original.lines[row + 2])
    assert.equals("z", r.modified.lines[row + 2])
  end)

  it("marks filler rows so they read as absent, not empty", function()
    local h = hunk("@@ -1,1 +1,2 @@", { "-a", "+x", "+y" }, 2, 1)
    local g = { title = "T", hunks = { h },
      files = { { path = "f.lua", status = "M", hunks = { h } } } }
    local r = preview.render(g, "side-by-side", {})
    local filler = vim.tbl_filter(function(s) return s.hl == "IntentDiffFiller" end,
      r.original.highlights)
    assert.is_true(#filler > 0)
  end)

  it("emits context lines on both sides", function()
    local r = preview.render(group(), "side-by-side", {})
    local o = vim.tbl_filter(function(l) return l == "keep" end, r.original.lines)
    local m = vim.tbl_filter(function(l) return l == "keep" end, r.modified.lines)
    assert.equals(1, #o)
    assert.equals(1, #m)
  end)
end)

describe("preview.render limits", function()
  it("truncates both panes identically and says so", function()
    local body = {}
    for i = 1, 500 do body[#body + 1] = "+line " .. i end
    local h = hunk("@@ -0,0 +1,500 @@", body, 500, 0)
    local g = { title = "T", hunks = { h },
      files = { { path = "f.lua", status = "A", hunks = { h } } } }
    local r = preview.render(g, "side-by-side", { max_lines = 50 })
    assert.equals(50, #r.modified.lines)
    assert.equals(50, #r.original.lines)
    assert.truthy(r.modified.lines[50]:find("more line", 1, true),
      "truncation must be stated, not silent")
  end)

  it("renders an empty group as a single explanatory line", function()
    local r = preview.render({ title = "T", hunks = {}, files = {} }, "inline", {})
    assert.equals(1, #r.modified.lines)
    assert.truthy(r.modified.lines[1]:find("no changes", 1, true))
  end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/preview_spec.lua"`
Expected: FAIL — `module 'intentdiff.preview' not found`.

- [ ] **Step 3: Implement the module**

Create `lua/intentdiff/preview.lua`:

```lua
-- Pure renderer for the whole-intent preview: a group's complete diff with
-- visible file boundaries, in either layout. No Neovim UI state — view.lua puts
-- the result into buffers.
local M = {}

local tree = require("intentdiff.tree")

local WHOLE_LINE = -1

--- Body lines of a hunk, without its @@ header and without the
--- "\ No newline at end of file" marker (metadata, not content).
local function body_of(hunk)
  local body = {}
  for line in hunk.text:gmatch("(.-)\n") do
    if not line:match("^@@") and line:sub(1, 1) ~= "\\" then
      body[#body + 1] = line
    end
  end
  return body
end

local function file_stats(file)
  local additions, deletions = 0, 0
  for _, h in ipairs(file.hunks or {}) do
    additions = additions + (h.additions or 0)
    deletions = deletions + (h.deletions or 0)
  end
  return additions, deletions
end

local function separator(file)
  local additions, deletions = file_stats(file)
  return ("── %s   %s   +%d -%d")
    :format(file.path, file.status or "M", additions, deletions)
end

--- Files in the same order the sidebar tree shows them, so the preview and the
--- sidebar always agree about ordering.
local function ordered_files(group)
  local files, seen = {}, {}
  for _, row in ipairs(tree.flatten(tree.build(group.files or {}), {})) do
    if row.kind == "file" and not seen[row.file_i] then
      seen[row.file_i] = true
      files[#files + 1] = group.files[row.file_i]
    end
  end
  return files
end

--- A pane under construction: lines plus highlight spans.
local function new_pane()
  local pane = { lines = {}, highlights = {} }
  function pane.add(text, group)
    pane.lines[#pane.lines + 1] = text
    if group then
      pane.highlights[#pane.highlights + 1] =
        { line = #pane.lines, col_start = 0, col_end = WHOLE_LINE, hl = group }
    end
    return #pane.lines
  end
  return pane
end

local function line_group(line)
  local kind = line:sub(1, 1)
  if kind == "+" then
    return "IntentDiffAdd"
  elseif kind == "-" then
    return "IntentDiffDelete"
  end
  return nil
end

local function render_inline(group)
  local pane, hunk_lines = new_pane(), {}
  for _, file in ipairs(ordered_files(group)) do
    pane.add(separator(file), "IntentDiffPreviewFile")
    for _, hunk in ipairs(file.hunks or {}) do
      hunk_lines[#hunk_lines + 1] = pane.add(hunk.header, "IntentDiffPreviewHunk")
      for _, line in ipairs(body_of(hunk)) do
        pane.add(line, line_group(line))
      end
    end
  end
  return pane, hunk_lines
end

--- Pair a hunk body into aligned original/modified rows. A context line emits
--- on both sides; a run of deletions and the addition run that follows it emit
--- max(#deletions, #additions) rows, paired by index, with a filler row on the
--- shorter side. `false` marks a filler.
local function pair_body(body)
  local original, modified = {}, {}
  local minus, plus = {}, {}
  local function flush()
    for i = 1, math.max(#minus, #plus) do
      original[#original + 1] = minus[i] or false
      modified[#modified + 1] = plus[i] or false
    end
    minus, plus = {}, {}
  end
  for _, line in ipairs(body) do
    local kind = line:sub(1, 1)
    if kind == "-" then
      minus[#minus + 1] = line:sub(2)
    elseif kind == "+" then
      plus[#plus + 1] = line:sub(2)
    else
      flush()
      original[#original + 1] = line:sub(2)
      modified[#modified + 1] = line:sub(2)
    end
  end
  flush()
  return original, modified
end

local function render_side_by_side(group)
  local original, modified, hunk_lines = new_pane(), new_pane(), {}
  for _, file in ipairs(ordered_files(group)) do
    local text = separator(file)
    original.add(text, "IntentDiffPreviewFile")
    modified.add(text, "IntentDiffPreviewFile")
    for _, hunk in ipairs(file.hunks or {}) do
      original.add(hunk.header, "IntentDiffPreviewHunk")
      hunk_lines[#hunk_lines + 1] = modified.add(hunk.header, "IntentDiffPreviewHunk")
      local left, right = pair_body(body_of(hunk))
      for i = 1, #left do
        original.add(left[i] or "", left[i] == false and "IntentDiffFiller"
          or (right[i] == false and "IntentDiffDelete" or nil))
        modified.add(right[i] or "", right[i] == false and "IntentDiffFiller"
          or (left[i] == false and "IntentDiffAdd" or nil))
      end
    end
  end
  return original, modified, hunk_lines
end

--- Drop everything past `max_lines`, replacing the last line with a stated
--- count. Truncation is applied identically to every pane so the two sides stay
--- aligned; highlight spans pointing past the cut are dropped.
local function truncate(panes, max_lines)
  local total = #panes[1].lines
  if max_lines and max_lines > 1 and total > max_lines then
    local omitted = total - max_lines + 1
    for _, pane in ipairs(panes) do
      for i = total, max_lines, -1 do
        pane.lines[i] = nil
      end
      pane.lines[max_lines] = ("── %d more line%s not shown (preview.max_lines)")
        :format(omitted, omitted == 1 and "" or "s")
      pane.highlights = vim.tbl_filter(function(s)
        return s.line < max_lines
      end, pane.highlights)
      pane.highlights[#pane.highlights + 1] =
        { line = max_lines, col_start = 0, col_end = WHOLE_LINE, hl = "IntentDiffPreviewFile" }
    end
  end
end

local function empty_pane()
  local pane = new_pane()
  pane.add("no changes in this intent", "IntentDiffPreviewHunk")
  return pane
end

--- Render `group`'s complete diff.
--- @param group table { title, hunks, files }
--- @param layout string "inline" | "side-by-side"
--- @param opts table|nil { max_lines }
--- @return table rendered — see the plan's Interfaces block for the shape
function M.render(group, layout, opts)
  opts = opts or {}
  local has_files = #(group.files or {}) > 0
  if layout == "inline" then
    local pane, hunk_lines = render_inline(group)
    if not has_files then
      pane, hunk_lines = empty_pane(), {}
    end
    truncate({ pane }, opts.max_lines)
    return { layout = "inline", modified = pane, hunk_lines = hunk_lines }
  end
  local original, modified, hunk_lines = render_side_by_side(group)
  if not has_files then
    original, modified, hunk_lines = empty_pane(), empty_pane(), {}
  end
  truncate({ original, modified }, opts.max_lines)
  return {
    layout = "side-by-side",
    original = original,
    modified = modified,
    hunk_lines = hunk_lines,
  }
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/preview_spec.lua"`
Expected: PASS, `failing=0`.

- [ ] **Step 5: Commit**

```bash
git add lua/intentdiff/preview.lua tests/preview_spec.lua
git commit -S -m "feat: render a group's whole diff with file boundaries"
```

---

### Task 8: Drive the preview into the codediff panes

**Files:**
- Modify: `lua/intentdiff/view.lua` (add `M.show_preview`, `M.restore`,
  `M.toggle_preview_layout`, `M._preview_active`; extend `M.toggle_layout` with
  `opts.on_done`; extend `M.install_keymaps`), `lua/intentdiff/config.lua`
  (`preview` block)
- Test: `tests/view_preview_spec.lua` (create)

**Interfaces:**
- Consumes: `preview.render` (Task 7).
- Produces:
  - `view.show_preview(sess, group) -> boolean` — injects preview buffers into
    the session's existing pane windows.
  - `view.restore(sess) -> boolean` — re-renders the last shown file.
  - `view._preview_active[tabpage]` — the group being previewed, or nil.
  - `view.toggle_layout(tabpage, opts)` — `opts.on_done` fires after the new
    layout has rendered.
  Consumed by Task 9.

**Background — the constraint.** Probe 2
(`docs/superpowers/specs/2026-07-30-ux-probes/probe_preview2.lua`) shows that
creating a pane window by hand leaves an orphan and restores into four windows
with a duplicated buffer. Probe 3 shows that injecting buffers into the windows
the session already owns survives a full round trip in both layouts. Inject
only; never create or close a window.

- [ ] **Step 1: Write the failing test**

Create `tests/view_preview_spec.lua`:

```lua
local helpers = require("tests.helpers")

describe("view: intent preview", function()
  local view

  before_each(function()
    package.loaded["intentdiff.view"] = nil
    view = require("intentdiff.view")
    assert.is_true(view.load())
    require("intentdiff.config").setup({})
  end)

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      pcall(vim.cmd, "tabclose $")
    end
  end)

  --- 60-line file with two distant edits → two hunks.
  local function fixture()
    local lines = {}
    for i = 1, 60 do lines[i] = "line " .. i end
    local repo = helpers.make_repo({ ["big.lua"] = table.concat(lines, "\n") })
    lines[5] = "CHANGED 5"
    lines[55] = "CHANGED 55"
    helpers.write_file(repo, "big.lua", table.concat(lines, "\n"))

    local inv
    require("intentdiff.hunks").collect({ git_root = repo }, function(i) inv = i end)
    helpers.wait_for(function() return inv end)

    local base
    require("codediff.core.git").resolve_revision("HEAD", repo, function(_, h) base = h end)
    helpers.wait_for(function() return base end)

    local sess = { tabpage = view.open_tab(), git_root = repo, base_revision = base,
      target_revision = "WORKING" }
    local file_entry = { path = "big.lua", status = "M", hunks = inv.hunks }
    local group = { title = "All", hunks = inv.hunks, files = { file_entry } }
    return sess, file_entry, group
  end

  local function show(sess, file_entry)
    local ready = false
    view.show_file(sess, file_entry, { on_ready = function() ready = true end })
    assert.truthy(helpers.wait_for(function() return ready end, 10000), "show_file timed out")
  end

  it("injects two panes without creating or closing a window", function()
    local sess, file_entry, group = fixture()
    show(sess, file_entry)
    local before = #vim.api.nvim_tabpage_list_wins(sess.tabpage)

    assert.is_true(view.show_preview(sess, group))
    assert.equals(before, #vim.api.nvim_tabpage_list_wins(sess.tabpage))

    local session = view.get_session(sess.tabpage)
    local modified = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    assert.truthy(table.concat(modified, "\n"):find("big.lua", 1, true))
    assert.equals(vim.api.nvim_buf_line_count(session.original_bufnr),
      vim.api.nvim_buf_line_count(session.modified_bufnr))
  end)

  it("does not leave group folds applied to the preview buffers", function()
    local sess, file_entry, group = fixture()
    show(sess, { path = "big.lua", status = "M", hunks = { file_entry.hunks[1] } })
    view.show_preview(sess, group)
    local session = view.get_session(sess.tabpage)
    assert.not_equals("expr", vim.wo[session.modified_win].foldmethod)
    assert.is_nil(view._active_folds[sess.tabpage])
  end)

  it("restores the last shown file with its folds", function()
    local sess, file_entry, group = fixture()
    local partial = { path = "big.lua", status = "M", hunks = { file_entry.hunks[1] } }
    show(sess, partial)
    view.show_preview(sess, group)
    assert.is_true(view.restore(sess))
    assert.truthy(helpers.wait_for(function()
      local s = view.get_session(sess.tabpage)
      return s and vim.api.nvim_buf_line_count(s.modified_bufnr) == 60 or nil
    end, 10000))
    local session = view.get_session(sess.tabpage)
    assert.equals("expr", vim.wo[session.modified_win].foldmethod)
    assert.is_nil(view._preview_active[sess.tabpage])
  end)

  it("survives the probe-3 round trip across both layouts", function()
    local sess, file_entry, group = fixture()
    show(sess, file_entry)
    local function wins() return #vim.api.nvim_tabpage_list_wins(sess.tabpage) end
    local function session() return view.get_session(sess.tabpage) end

    assert.is_true(view.show_preview(sess, group))
    assert.equals(2, wins())
    assert.is_nil(session().single_pane)

    view.restore(sess)
    assert.truthy(helpers.wait_for(function()
      return vim.api.nvim_buf_line_count(session().modified_bufnr) == 60 or nil
    end, 10000))

    local toggled = false
    view.toggle_layout(sess.tabpage, { on_done = function() toggled = true end })
    assert.truthy(helpers.wait_for(function() return toggled end, 10000))
    assert.equals("inline", session().layout)
    assert.equals(1, wins())

    assert.is_true(view.show_preview(sess, group))
    assert.equals(1, wins())
    assert.equals("inline", session().layout)

    view.restore(sess)
    assert.truthy(helpers.wait_for(function()
      return vim.api.nvim_buf_line_count(session().modified_bufnr) == 60 or nil
    end, 10000))
    assert.equals("inline", session().layout)
  end)

  it("toggles layout from inside a preview and comes back previewing", function()
    local sess, file_entry, group = fixture()
    show(sess, file_entry)
    view.show_preview(sess, group)
    local before = view.get_session(sess.tabpage).layout

    view.toggle_preview_layout(sess.tabpage)
    assert.truthy(helpers.wait_for(function()
      local s = view.get_session(sess.tabpage)
      return (s.layout ~= before and view._preview_active[sess.tabpage]) and true or nil
    end, 15000), "layout must flip and the preview must return")

    local session = view.get_session(sess.tabpage)
    local lines = vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false)
    assert.truthy(table.concat(lines, "\n"):find("big.lua", 1, true))
  end)
end)
```

Note: `wins()` counts only this tab's windows; `view.open_tab()` creates a bare
tab, so a side-by-side session has 2 windows and inline has 1 — there is no
sidebar in these specs.

- [ ] **Step 2: Run the test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/view_preview_spec.lua"`
Expected: FAIL — `attempt to call field 'show_preview' (a nil value)`.

- [ ] **Step 3: Add the preview state and the injection**

In `lua/intentdiff/view.lua`, add next to `M._last_shown`:

```lua
--- Group currently previewed per tabpage, or nil. Set by M.show_preview,
--- cleared by M.restore. The TabEnter re-assert and the fold machinery both
--- consult it: preview buffers must never be folded to a group filter.
M._preview_active = {}

--- The session behind each tabpage's active preview, so the preview's own
--- keymaps (which only capture a tabpage) can restore and re-render.
M._preview_sess = {}
```

Add after `M.show_file`:

```lua
--- Put `lines` into a fresh scratch buffer and apply `highlights`.
--- A span with col_end == -1 covers the whole line.
local function preview_buf(pane)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, pane.lines)
  vim.bo[buf].modifiable = false
  local ns = vim.api.nvim_create_namespace("intentdiff_preview")
  for _, s in ipairs(pane.highlights) do
    if s.col_end == -1 then
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, s.line - 1, 0,
        { line_hl_group = s.hl })
    else
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, s.line - 1, s.col_start,
        { end_col = s.col_end, hl_group = s.hl })
    end
  end
  return buf
end

--- Drop any group-fold state for `tabpage`'s panes, so a preview buffer is
--- never filtered through a foldexpr computed for a different buffer.
local function clear_folds(tabpage)
  M._active_folds[tabpage] = nil
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return
  end
  for _, win in ipairs({ session.original_win, session.modified_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      visible_by_win[win] = nil
      vim.wo[win].foldenable = false
      vim.wo[win].foldmethod = "manual"
    end
  end
end

--- Show `group`'s whole diff in the session's diff panes.
---
--- Injects buffers into the windows the session ALREADY owns — one in inline
--- layout, two in side-by-side — and never creates or closes a window. Probe 2
--- (docs/superpowers/specs/2026-07-30-ux-probes/probe_preview2.lua) shows that
--- building a pane by hand leaves an orphan window behind and corrupts the
--- following restore; probe 3 shows this injection surviving a full round trip
--- in both layouts.
--- @return boolean whether the preview was rendered
function M.show_preview(sess, group)
  local tabpage = sess.tabpage
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return false
  end
  local original_win, modified_win = session.original_win, session.modified_win
  local single = original_win == modified_win
    or not (original_win and vim.api.nvim_win_is_valid(original_win))
    or not (modified_win and vim.api.nvim_win_is_valid(modified_win))
  local layout = single and "inline" or "side-by-side"
  local rendered = require("intentdiff.preview").render(group, layout,
    { max_lines = require("intentdiff.config").options.preview.max_lines })

  clear_folds(tabpage)
  if single then
    local win = (modified_win and vim.api.nvim_win_is_valid(modified_win))
      and modified_win or original_win
    if not (win and vim.api.nvim_win_is_valid(win)) then
      return false
    end
    local buf = preview_buf(rendered.modified)
    vim.api.nvim_win_set_buf(win, buf)
    vim.wo[win].scrollbind = false
    vim.wo[win].cursorbind = false
    cd.lifecycle.update_buffers(tabpage, buf, buf)
  else
    local original_buf = preview_buf(rendered.original)
    local modified_buf = preview_buf(rendered.modified)
    vim.api.nvim_win_set_buf(original_win, original_buf)
    vim.api.nvim_win_set_buf(modified_win, modified_buf)
    -- Equal line counts by construction (preview.render pads with fillers), so
    -- scrollbind keeps the two sides aligned.
    for _, win in ipairs({ original_win, modified_win }) do
      vim.wo[win].scrollbind = true
      vim.wo[win].cursorbind = true
    end
    cd.lifecycle.update_buffers(tabpage, original_buf, modified_buf)
  end
  cd.lifecycle.update_paths(tabpage, cd.path.empty(), cd.path.empty())
  cd.lifecycle.update_revisions(tabpage, nil, nil)
  cd.lifecycle.update_diff_result(tabpage, { changes = {}, moves = {} })

  M._preview_active[tabpage] = group
  M.install_preview_keymaps(tabpage, sess, rendered.hunk_lines)
  return true
end

--- Leave the preview and re-render the file that was last shown, folds and all.
--- @return boolean whether a file was restored
function M.restore(sess)
  local tabpage = sess.tabpage
  M._preview_active[tabpage] = nil
  local session = cd.lifecycle.get_session(tabpage)
  if session then
    for _, win in ipairs({ session.original_win, session.modified_win }) do
      if win and vim.api.nvim_win_is_valid(win) then
        vim.wo[win].scrollbind = false
        vim.wo[win].cursorbind = false
      end
    end
  end
  local shown = M._last_shown[tabpage]
  if not shown then
    return false
  end
  M.show_file(shown.sess, shown.file_entry)
  return true
end
```

- [ ] **Step 4: Add the preview keymaps and the layout toggle**

Add to `lua/intentdiff/view.lua`:

```lua
--- Buffer-local keymaps for preview buffers. They are fresh scratch buffers, so
--- they inherit nothing from codediff: without this, codediff's toggle key and
--- ]c/[c would fall through to their global meanings.
function M.install_preview_keymaps(tabpage, sess, hunk_lines)
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return
  end
  local cd_config = try("codediff.config")
  local keys = cd_config and cd_config.options and cd_config.options.keymaps
  local toggle_key = keys and keys.view and keys.view.toggle_layout
  local seen = {}
  for _, buf in ipairs({ session.original_bufnr, session.modified_bufnr }) do
    if buf and vim.api.nvim_buf_is_valid(buf) and not seen[buf] then
      seen[buf] = true
      if toggle_key then
        pcall(vim.keymap.set, "n", toggle_key, function()
          M.toggle_preview_layout(tabpage)
        end, { buffer = buf, nowait = true, desc = "intent-diff: toggle preview layout" })
      end
      pcall(vim.keymap.set, "n", "q", function()
        require("intentdiff").close(tabpage)
      end, { buffer = buf, nowait = true, desc = "intent-diff: close" })
      for key, step in pairs({ ["]c"] = 1, ["[c"] = -1 }) do
        pcall(vim.keymap.set, "n", key, function()
          local win = vim.api.nvim_get_current_win()
          local cursor = vim.api.nvim_win_get_cursor(win)[1]
          local target
          if step == 1 then
            for _, lnum in ipairs(hunk_lines) do
              if lnum > cursor then target = lnum break end
            end
          else
            for i = #hunk_lines, 1, -1 do
              if hunk_lines[i] < cursor then target = hunk_lines[i] break end
            end
          end
          if target then
            pcall(vim.api.nvim_win_set_cursor, win, { target, 0 })
          end
        end, { buffer = buf, nowait = true, desc = "intent-diff: hunk in preview" })
      end
    end
  end
  M._preview_sess[tabpage] = sess
end

--- Toggle inline ↔ side-by-side while previewing.
---
--- codediff's toggle re-renders from the session's own path/revision fields,
--- which a preview deliberately blanks — so restore the last file first, toggle
--- on that (the only state codediff supports), then re-render the preview in
--- the new layout. Probe 3 steps 4-8 exercise exactly this sequence.
--- @return boolean whether a toggle was started
function M.toggle_preview_layout(tabpage)
  local group = M._preview_active[tabpage]
  local sess = M._preview_sess[tabpage]
  if not (group and sess) then
    return false
  end
  if not M.restore(sess) then
    return false
  end
  M.toggle_layout(tabpage, {
    on_done = function()
      M.show_preview(sess, group)
    end,
  })
  return true
end
```

Extend `M.toggle_layout` to take `opts` and fire `on_done`. Change its
signature and the three exit points:

```lua
function M.toggle_layout(tabpage, opts)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  opts = opts or {}
  local function done()
    if opts.on_done then
      opts.on_done()
    end
  end
  local shown = M._last_shown[tabpage]
  local session = cd.lifecycle.get_session(tabpage)
  if not session then
    return false
  end

  if shown then
    local status = shown.file_entry.status
    if status == "??" or status == "A" or status == "D" then
      local target_layout = session.layout == "inline" and "side-by-side" or "inline"
      local abs_path = shown.sess.git_root .. "/" .. shown.file_entry.path
      show_whole_file_in_layout(tabpage, shown.sess, shown.file_entry, abs_path, target_layout,
        function()
          M.apply_group_folds(tabpage, shown.file_entry.hunks)
          done()
        end)
      return true
    end
  end

  if not cd.view.toggle_layout(tabpage) then
    return false
  end
  if not shown then
    done()
    return true
  end
  local file_entry = shown.file_entry
  local abs_path = shown.sess.git_root .. "/" .. file_entry.path
  when_diff_ready(tabpage, abs_path, function()
    M.apply_group_folds(tabpage, file_entry.hunks)
    M.install_keymaps(tabpage)
    done()
  end)
  return true
end
```

In `M.cleanup_tab_state`, also drop the preview state:

```lua
  M._preview_active[tabpage] = nil
  M._preview_sess[tabpage] = nil
```

In the `reassert` helper, skip re-folding while a preview is up:

```lua
local function reassert(tab)
  if M._preview_active[tab] then
    return -- preview buffers carry no group folds
  end
  if M._active_folds[tab] then
    M.apply_group_folds(tab, M._active_folds[tab])
  end
  M.install_keymaps(tab)
  require("intentdiff.navigation").reattach_keymaps(tab)
end
```

- [ ] **Step 5: Add the config block**

In `lua/intentdiff/config.lua`:

```lua
  -- Whole-intent preview: putting the cursor on a group or directory row in the
  -- sidebar shows that intent's complete diff in the diff panes, with a
  -- separator per file. debounce_ms keeps scrolling the sidebar from thrashing
  -- the panes; max_lines caps a very large intent, stating what it omitted.
  preview = { enabled = true, debounce_ms = 120, max_lines = 20000 },
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/view_preview_spec.lua"`
Expected: PASS, `failing=0`.

- [ ] **Step 7: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0`.

- [ ] **Step 8: Commit**

```bash
git add lua/intentdiff/view.lua lua/intentdiff/config.lua tests/view_preview_spec.lua
git commit -S -m "feat: drive the intent preview into the codediff panes"
```

---

### Task 9: Hover wiring

**Files:**
- Modify: `lua/intentdiff/init.lua` (hover autocmd, debounce timer, dispatch,
  cleanup)
- Test: `tests/hover_spec.lua` (create)

**Interfaces:**
- Consumes: `view.show_preview`, `view.restore` (Task 8), sidebar meta kinds
  `"group"`/`"dir"`/`"file"` (Task 6).
- Produces: no new public API. `sessions[token]` gains `hover_key` and
  `hover_timer`.

- [ ] **Step 1: Write the failing test**

Create `tests/hover_spec.lua`:

```lua
local helpers = require("tests.helpers")

describe("sidebar hover preview", function()
  local repo

  local function fake_provider(groups)
    return function(_, cb)
      vim.schedule(function() cb({ groups = groups }) end)
      return { cancel = function() end }
    end
  end

  before_each(function()
    repo = helpers.make_repo({
      ["src/a.lua"] = table.concat(vim.fn.range(1, 40), "\n"),
      ["b.lua"] = "x",
    })
    helpers.write_file(repo, "src/a.lua",
      "CHANGED\n" .. table.concat(vim.fn.range(2, 39), "\n") .. "\nCHANGED")
    helpers.write_file(repo, "b.lua", "y")
    vim.cmd("cd " .. repo)
  end)

  after_each(function()
    while #vim.api.nvim_list_tabpages() > 1 do
      pcall(vim.cmd, "tabclose $")
    end
  end)

  local function open_ready(opts)
    require("intentdiff").setup(vim.tbl_extend("force", {
      cache_dir = vim.fn.tempname(),
      log_file = vim.fn.tempname() .. "/l.log",
      provider = fake_provider({ { title = "Everything", ids = "1-99" } }),
    }, opts or {}))
    require("intentdiff").open("")
    local tab = vim.api.nvim_get_current_tabpage()
    local entry = helpers.wait_for(function()
      local s = require("intentdiff")._session(tab)
      return s and s.model and s.model.state == "ready" and s or nil
    end, 15000)
    assert.truthy(entry, "session never became ready")
    return tab, entry
  end

  local function line_of(entry, kind)
    for l = 1, vim.api.nvim_buf_line_count(entry.sidebar.bufnr) do
      local m = entry.sidebar.meta_at(l)
      if m and m.kind == kind then
        return l
      end
    end
  end

  local function hover(entry, lnum)
    vim.api.nvim_set_current_win(entry.sidebar.winid)
    vim.api.nvim_win_set_cursor(entry.sidebar.winid, { lnum, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = entry.sidebar.bufnr })
  end

  it("previews the whole intent when the cursor rests on a group row", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
    hover(entry, line_of(entry, "group"))
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab]
    end, 5000), "preview never activated")

    local session = require("intentdiff.view").get_session(tab)
    local text = table.concat(
      vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("src/a.lua", 1, true))
    assert.truthy(text:find("b.lua", 1, true), "every file of the intent must appear")
  end)

  it("leaves the preview when the cursor moves to a file row", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
    hover(entry, line_of(entry, "group"))
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab]
    end, 5000))

    hover(entry, line_of(entry, "file"))
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab] == nil or nil
    end, 5000), "preview must close on a file row")
  end)

  it("previews only a directory's subtree", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 10 } })
    local dir_line = line_of(entry, "dir")
    assert.truthy(dir_line, "expected a directory row for src/")
    hover(entry, dir_line)
    assert.truthy(helpers.wait_for(function()
      return require("intentdiff.view")._preview_active[tab]
    end, 5000))

    local session = require("intentdiff.view").get_session(tab)
    local text = table.concat(
      vim.api.nvim_buf_get_lines(session.modified_bufnr, 0, -1, false), "\n")
    assert.truthy(text:find("src/a.lua", 1, true))
    assert.is_nil(text:find("b.lua", 1, true),
      "a directory preview must exclude files outside it")
  end)

  it("renders once for a burst of cursor movement", function()
    local tab, entry = open_ready({ preview = { enabled = true, debounce_ms = 60 } })
    local calls = 0
    local view = require("intentdiff.view")
    local real = view.show_preview
    view.show_preview = function(...)
      calls = calls + 1
      return real(...)
    end

    local group_line = line_of(entry, "group")
    for _ = 1, 6 do
      hover(entry, group_line)
    end
    helpers.wait_for(function() return view._preview_active[tab] end, 5000)
    vim.wait(300, function() return false end, 50)
    view.show_preview = real
    assert.equals(1, calls)
  end)

  it("does nothing when the preview is disabled", function()
    local tab, entry = open_ready({ preview = { enabled = false, debounce_ms = 10 } })
    hover(entry, line_of(entry, "group"))
    vim.wait(300, function() return false end, 50)
    assert.is_nil(require("intentdiff.view")._preview_active[tab])
  end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/hover_spec.lua"`
Expected: FAIL — the preview never activates; `_preview_active[tab]` stays nil.

- [ ] **Step 3: Implement the hover dispatch**

In `lua/intentdiff/init.lua`, add above `M.open`:

```lua
--- A group restricted to the files under `dir_path`, so hovering a directory
--- row previews only that subtree. Hunks are recomputed from the kept files so
--- the preview's separators and totals stay consistent.
local function subtree_group(group, dir_path)
  local files, hunks = {}, {}
  local prefix = dir_path .. "/"
  for _, f in ipairs(group.files or {}) do
    if f.path:sub(1, #prefix) == prefix then
      files[#files + 1] = f
      vim.list_extend(hunks, f.hunks or {})
    end
  end
  return { title = dir_path, files = files, hunks = hunks }
end

--- Stop and clear `entry.hover_timer` if one is armed.
local function stop_hover_timer(entry)
  if entry and entry.hover_timer then
    local timer = entry.hover_timer
    entry.hover_timer = nil
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
  end
end

--- Act on the row the cursor has settled on. Identical consecutive targets are
--- a no-op, so cursor jitter inside one wrapped group header costs nothing.
local function apply_hover(token)
  local entry = sessions[token]
  if not entry or not entry.sidebar then
    return
  end
  if not vim.api.nvim_win_is_valid(entry.sidebar.winid) then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(entry.sidebar.winid)[1]
  local m = entry.sidebar.meta_at(lnum)
  if not m then
    return
  end
  local view = require("intentdiff.view")
  local key
  if m.kind == "group" then
    key = "g" .. m.group_i
  elseif m.kind == "dir" then
    key = ("d%d:%s"):format(m.group_i, m.dir_path)
  elseif m.kind == "file" then
    key = "file"
  else
    return
  end
  if entry.hover_key == key then
    return
  end
  entry.hover_key = key

  if m.kind == "file" then
    -- Hovering a file row does NOT open that file: rendering every row the
    -- cursor passes over would re-run codediff's diff for each one. It just
    -- leaves the preview, restoring whatever the user last selected. <CR>
    -- still selects.
    view.restore(entry.sess)
    return
  end
  local group = entry.model and entry.model.groups and entry.model.groups[m.group_i]
  if not group then
    return
  end
  view.show_preview(entry.sess, m.kind == "dir" and subtree_group(group, m.dir_path) or group)
end

--- Debounced CursorMoved handler on the sidebar buffer.
local function schedule_hover(token)
  local entry = sessions[token]
  if not entry then
    return
  end
  local debounce = require("intentdiff.config").options.preview.debounce_ms
  stop_hover_timer(entry)
  local timer = vim.uv.new_timer()
  entry.hover_timer = timer
  timer:start(debounce, 0, vim.schedule_wrap(function()
    local current = sessions[token]
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
    if current and current.hover_timer == timer then
      current.hover_timer = nil
      apply_hover(token)
    end
  end))
end

--- Watch the sidebar's cursor, if previews are enabled.
local function attach_hover(token)
  if not require("intentdiff.config").options.preview.enabled then
    return
  end
  local entry = sessions[token]
  local group = vim.api.nvim_create_augroup("IntentDiffHover_" .. token, { clear = true })
  entry.hover_augroup = group
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = entry.sidebar.bufnr,
    callback = function()
      schedule_hover(token)
    end,
  })
end
```

Call `attach_hover(token)` in `M.open`, immediately after
`sidebar.update(sessions[token].model)`:

```lua
  sessions[token].model = flat_model({ hunks = {} }, "loading")
  sidebar.update(sessions[token].model)
  attach_hover(token)
  vim.cmd("wincmd l") -- focus codediff's panes, right of the sidebar
```

Mark the hover state in `select_file` so a manual selection is not undone by
the next cursor move:

```lua
select_file = function(token, group_i, file_i, opts)
  local entry = sessions[token]
  if entry then
    entry.user_selected = true
    -- The panes now show a file; the next hover onto a file row must be a
    -- no-op rather than a restore of something older.
    entry.hover_key = "file"
  end
  open_file(token, group_i, file_i, opts)
end
```

Tear the hover state down in `forget_entry`, after `stop_elapsed_timer(entry)`:

```lua
  stop_hover_timer(entry)
  if entry.hover_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, entry.hover_augroup)
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nvim --headless -u tests/init.lua -c "PlenaryBustedFile tests/hover_spec.lua"`
Expected: PASS, `failing=0`.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0`.

- [ ] **Step 6: Commit**

```bash
git add lua/intentdiff/init.lua tests/hover_spec.lua
git commit -S -m "feat: preview an intent by hovering its sidebar row"
```

---

### Task 10: Documentation

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: every option and behaviour added by Tasks 1-9.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Update the configuration table**

In `README.md`'s configuration section, add rows for the new options with
their defaults, and correct the changed ones:

| Option | Default | Meaning |
|---|---|---|
| `sidebar_width` | `40` | Width of the group/file sidebar. |
| `icons` | `true` | File icons from nvim-web-devicons when installed. |
| `max_hunks` | `600` | Above this, classification is skipped with a notice. |
| `preview.enabled` | `true` | Preview an intent by hovering its sidebar row. |
| `preview.debounce_ms` | `120` | Cursor settle time before the preview renders. |
| `preview.max_lines` | `20000` | Cap on preview length; the omitted count is stated. |
| `added_file_split.enabled` | `true` | Split added files into sub-hunks. |
| `added_file_split.min_lines` | `60` | Added files shorter than this stay whole. |
| `added_file_split.target_lines` | `40` | Approximate lines per sub-hunk. |

- [ ] **Step 2: Document the sidebar and preview**

Add a "Sidebar" section describing: wrapped group titles, the
`N hunks · M files  +A -B` stats line, the file tree with compressed
single-child directory chains, the status gutter, and that `za`/`h`/`l` toggle
a group or a directory depending on the row under the cursor.

Add a "Previewing an intent" section stating: resting the cursor on a group row
shows that intent's whole diff with a separator per file; a directory row
previews its subtree; a file row returns to the last selected file (hover does
not open files — `<CR>` selects); `]c`/`[c` move between hunks inside the
preview; codediff's layout-toggle key flips the preview between inline and
side-by-side like any other diff.

- [ ] **Step 3: Document the highlight groups**

Add a "Highlights" section listing every group from `lua/intentdiff/highlight.lua`
with its default link, and note they are defined with `default = true` so a
user definition always wins:

```lua
vim.api.nvim_set_hl(0, "IntentDiffGroupTitle", { fg = "#c4a7e7", bold = true })
```

- [ ] **Step 4: Note the added-file behaviour**

In the diff-scope or behaviour section, state that added and untracked files
render their real contents, are split into sub-hunks at blank-line boundaries
when longer than `added_file_split.min_lines`, and therefore fold to just the
open intent's portion — and that `added_file_split.enabled = false` restores
one hunk per added file.

- [ ] **Step 5: Run the full suite**

Run: `tests/run_tests.sh`
Expected: `failing=0`.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -S -m "docs: sidebar tree, intent preview, highlights and added-file splitting"
```

---

## Self-review notes

**Spec coverage.** Spec §1 → Tasks 1-2. §2 → Task 3. §3 → Tasks 4-6. §4 →
Tasks 7-9. §5 (config) → distributed across Tasks 2, 6, 8 with each option
landing beside the feature that reads it, plus the README table in Task 10.
§6 (error handling) → missing devicons and disabled icons in Task 6 (`file_icon`),
empty group and `max_lines` in Task 7, invalidated pane windows in Task 8
(`show_preview` returns false), malformed hunk in Task 2 (`split_added` returns
the hunk unchanged), unreadable added file in Task 3 (`loads_from_disk` falls
through to the virtual-file path). §7 (testing) → the spec list maps
one-to-one onto the specs created in Tasks 1-9.

**Interface consistency.** Highlight span shape
`{ line, col_start, col_end, hl }` is identical in `sidebar.layout` (Task 6) and
`preview.render` (Task 7), with `col_end == -1` meaning whole-line — the only
consumer of that convention is `preview_buf` in Task 8. Tree row fields produced
in Task 5 (`kind`, `depth`, `name`, `path`, `last`, `collapsed`, `status`,
`additions`, `deletions`, `file_i`) are exactly the fields Task 6 reads.
`view.toggle_layout(tabpage, opts)` gains its second parameter in Task 8; the
existing single-argument call sites in `install_keymaps` remain valid.
`file_i` stays an index into the group's `files` array through
`tree.build` → `tree.flatten` → sidebar meta, so `on_select(group_i, file_i)`
and `navigation.plan_move` need no changes.
