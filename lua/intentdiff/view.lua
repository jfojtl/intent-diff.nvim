-- The review tab: two windows, one render plan, one painted generation.
--
-- HOW a diff looks lives entirely in render/{plan,paint,content}.lua. This
-- module owns the tab, the two pane windows, the buffer-local keys, and the
-- bookkeeping that says which plan is currently on screen.
--
-- A single file and a whole intent are the SAME render: `M.show` takes a list
-- of file entries and a set of visible hunk ids, and they differ only in how
-- many entries that list has. There is no preview mode, no codediff session,
-- and no second code path for either.
--
-- codediff is still a runtime dependency, but only through `codediff.core.git`
-- here (revision resolution) and the two leaf modules render/paint.lua
-- pcall-requires for syntax and character refinement. Everything is guarded:
-- on any mismatch the plugin degrades instead of erroring.
local M = {}

M.available = false
local cd = {} -- loaded codediff modules

local function try(name)
  local ok, mod = pcall(require, name)
  if ok then
    return mod
  end
  return nil
end

--- Load and verify the codediff internals we still depend on. Call once at
--- :IntentDiff time.
---
--- Narrowed to `codediff.core.git`: that is the only piece intent-diff cannot
--- work without (git root, revision resolution, merge base). The renderer's own
--- optional users of `codediff.core.diff` and `codediff.ui.inline` degrade on
--- their own — a missing one costs character refinement or syntax highlighting,
--- not the review.
function M.load()
  cd.git = try("codediff.core.git")
  M.available = cd.git ~= nil
    and type(cd.git.get_git_root_sync) == "function"
    and type(cd.git.resolve_revision) == "function"
    and type(cd.git.get_merge_base) == "function"
  if not M.available then
    vim.notify("intent-diff: codediff API mismatch — cannot resolve revisions", vim.log.levels.ERROR)
  end
  return M.available
end

function M.git()
  return cd.git
end

-- ------------------------------------------------------------ tab state ----

--- The painted generation per tabpage:
--- `{ bufs = { original, modified }, plan, sess, files, visible }`.
---
--- This single table replaces the four `_preview_*` tables (and `_last_shown`)
--- the two-path renderer needed: there is one kind of render now, so there is
--- one record of what is on screen.
M._painted = {}

--- The pane WINDOWS per tabpage, `{ original = win|nil, modified = win }`.
--- Created by M.open_tab and reconciled to the requested layout by
--- `ensure_pane_wins` — inline closes the original window, side-by-side
--- re-creates it.
M._wins = {}

--- The layout each tabpage was last rendered in ("side-by-side" | "inline").
M._layout = {}

-- Forward-declared: M.open_tab (right below) arms the on-disk-write watcher on
-- every review it opens, but the watcher calls back into `render_now`, which
-- is defined further down this file. Kept together with its call site here.
local ensure_write_watch

--- The one augroup id `ensure_write_watch` creates, or nil until the first
--- review tab opens. Guards it against being created twice.
local write_augroup

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Bring `tabpage`'s pane windows in line with `layout`, creating or closing
--- the original-side window as needed.
---
--- Restores focus to whatever window had it, so a repaint driven by the sidebar
--- (a hover, a classification landing) never steals the cursor out of the panel
--- the user is actually in.
--- @return table|nil wins { original = win|nil, modified = win }
local function ensure_pane_wins(tabpage, layout)
  local wins = M._wins[tabpage]
  if not wins then
    return nil
  end
  -- A window can be closed behind our back (`:q` in a pane). Promote whichever
  -- side survives rather than answering with a dead id.
  if not win_valid(wins.modified) then
    if win_valid(wins.original) then
      wins.modified = wins.original
    else
      return nil
    end
  end
  if not win_valid(wins.original) then
    wins.original = nil
  end

  local prev = vim.api.nvim_get_current_win()
  if layout == "inline" then
    if wins.original and wins.original ~= wins.modified then
      pcall(vim.api.nvim_win_close, wins.original, true)
    end
    wins.original = nil
  elseif not wins.original or wins.original == wins.modified then
    -- `leftabove vsplit` puts the NEW window on the left and leaves the window
    -- it split as the right-hand one, so the original side ends up left of the
    -- modified side without either being moved.
    local ok = pcall(function()
      vim.api.nvim_set_current_win(wins.modified)
      vim.cmd("leftabove vsplit")
      wins.original = vim.api.nvim_get_current_win()
    end)
    if not ok then
      wins.original = nil
    end
  end
  if win_valid(prev) then
    pcall(vim.api.nvim_set_current_win, prev)
  end
  if not win_valid(wins.modified) then
    return nil
  end
  return wins
end

--- Open the review tab and BOTH its pane windows.
---
--- intent-diff creates its own windows now; nothing is adopted from codediff,
--- which no longer has a session here at all. The modified side is the
--- right-hand window and holds the cursor on return, matching where a reader
--- looks first.
function M.open_tab()
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local original = vim.api.nvim_get_current_win()
  vim.cmd("rightbelow vsplit")
  local modified = vim.api.nvim_get_current_win()
  M._wins[tabpage] = { original = original, modified = modified }
  M._layout[tabpage] = "side-by-side"
  ensure_write_watch()
  return tabpage
end

--- Forget every piece of per-tab state we keep for `tabpage`. Called from
--- M.close_tab and from init.lua's TabClosed handler (a tab closed behind our
--- back, e.g. `:tabclose` in the review tab).
function M.cleanup_tab_state(tabpage)
  if not tabpage then
    return
  end
  local painted = M._painted[tabpage]
  M._painted[tabpage] = nil
  M._wins[tabpage] = nil
  M._layout[tabpage] = nil
  -- Unconditional, and before the early return a missing `painted` would make:
  -- the pane-alignment autocommands are the one piece of per-tab state that
  -- lives outside `_painted`, and leaving them behind leaks a group that keeps
  -- firing for a tab that no longer exists.
  pcall(function()
    require("intentdiff.render.paint").unsync(tabpage)
  end)
  if painted then
    require("intentdiff.render.paint").retire(painted.bufs)
  end
end

function M.close_tab(sess)
  M.cleanup_tab_state(sess.tabpage)
  -- The content cache is scoped to the review's (repo, revisions) triple, so
  -- dropping it here is what keeps a second review of the same range from
  -- reading a worktree side that has moved on since.
  pcall(function()
    require("intentdiff.render.content").reset(sess)
  end)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if tab == sess.tabpage then
      -- `tabclose` on the last tab is an error ("cannot close last tab page")
      -- — the session tab would stay open with a half-torn-down session. Open a
      -- scratch tab to land on first.
      if #vim.api.nvim_list_tabpages() == 1 then
        vim.cmd("tabnew")
      end
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose")
      return
    end
  end
end

-- -------------------------------------------------------------- rendering --

--- Filetype for a path, without loading the file.
local function filetype_of(path)
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  if ok and ft then
    return ft
  end
  return ""
end

--- Re-render the comment marks of `tabpage` after a pane rebuild. Extmarks live
--- on the buffer, and every render paints fresh buffers, so the boxes have to be
--- re-drawn on each one.
---
--- No-op when comments are disabled, and pcall'd: a failure to draw a comment
--- box must never break the render it is hanging off.
local function refresh_comments(tabpage)
  if not require("intentdiff.config").comments_enabled() then
    return
  end
  pcall(function()
    require("intentdiff.comments.marks").refresh(tabpage)
  end)
end

--- What each pane window's cursor currently ADDRESSES, as a real
--- `(file, line, side)` rather than a row number.
---
--- A repaint replaces both buffers, and the row a coordinate lands on moves
--- with the plan: content arriving turns a hunks-only render into a whole-file
--- one, a layout toggle re-pairs every changed run. Restoring a raw row would
--- put the cursor on an unrelated line; restoring the coordinate puts it back on
--- the line the user was reading.
local function capture_cursors(tabpage)
  local painted = M._painted[tabpage]
  if not painted then
    return {}
  end
  local out = {}
  for _, win in ipairs(M.diff_wins(tabpage)) do
    local ok, bufnr = pcall(vim.api.nvim_win_get_buf, win)
    if ok then
      local pane = M.pane_for_buf(tabpage, bufnr)
      if pane then
        local row = vim.api.nvim_win_get_cursor(win)[1]
        out[win] = pane.map[row]
      end
    end
  end
  return out
end

--- Put each captured coordinate back on the row the NEW plan puts it on.
local function restore_cursors(tabpage, captured)
  for win, target in pairs(captured or {}) do
    if win_valid(win) and target then
      local ok, bufnr = pcall(vim.api.nvim_win_get_buf, win)
      local pane = ok and M.pane_for_buf(tabpage, bufnr)
      if pane then
        for row = 1, #pane.lines do
          local t = pane.map[row]
          if t and t.file == target.file and t.side == target.side and t.line == target.line then
            pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
            break
          end
        end
      end
    end
  end
end

--- Build the plan for `files` and paint it. Everything M.show does EXCEPT
--- fetching content and reporting readiness, so the content-arrived repaint can
--- re-enter here without ever re-entering `content.ensure` — which is what makes
--- a failed fetch a dead end rather than an infinite repaint loop.
--- @return boolean whether anything was painted
local function render_now(tabpage, sess, files, visible, layout)
  -- Strictly BEFORE ensure_pane_wins: toggling to inline closes the original
  -- window, and a cursor sitting in it has to be captured while that window is
  -- still there to read it from.
  local captured = capture_cursors(tabpage)
  local wins = ensure_pane_wins(tabpage, layout)
  if not wins then
    return false
  end
  local content = require("intentdiff.render.content")

  local entries, by_path = {}, {}
  for _, f in ipairs(files) do
    local binary = false
    if f.binary then
      binary = true
    end
    -- A file a write invalidated is rendered hunks-only, on purpose, even once
    -- content.ensure has refetched its worktree side: `f.hunks` still describes
    -- the file as of the last `git diff`, and pairing possibly-shifted fresh
    -- content against those frozen ranges is exactly the silently-inconsistent
    -- diff this renderer must never produce (see content.is_stale's doc
    -- comment). Deliberately not `content.is_stale(...) and nil or
    -- content.get(...)`: the fallback branch of that idiom is nil, so it would
    -- always take the "or" side regardless of staleness — the exact bug shape
    -- this codebase has already shipped four times.
    local stale = content.is_stale(sess, f.path)
    local original, modified
    if not stale then
      original = content.get(sess, f.path, "old")
      modified = content.get(sess, f.path, "new")
    end
    local entry = {
      path = f.path,
      old_path = f.old_path,
      status = f.status,
      filetype = filetype_of(f.path),
      binary = binary,
      hunks = f.hunks or {},
      original = original,
      modified = modified,
      stale = stale,
    }
    entries[#entries + 1] = entry
    by_path[f.path] = { old = entry.original, new = entry.modified }
  end

  local cfg = require("intentdiff.config").options
  local plan = require("intentdiff.render.plan").build(entries, visible, layout, {
    context = cfg.context_lines or 3,
    line_budget = cfg.line_budget or 20000,
  })

  local prior = M._painted[tabpage]
  local painted = require("intentdiff.render.paint").render(plan, wins, by_path)
  M._painted[tabpage] = {
    bufs = painted.bufs,
    plan = plan,
    sess = sess,
    files = files,
    visible = visible,
  }
  if prior then
    require("intentdiff.render.paint").retire(prior.bufs)
  end
  restore_cursors(tabpage, captured)
  -- After the cursors, not before: restoring them moves each pane's view
  -- independently, and this is what leaves the fresh generation aligned instead
  -- of waiting for the reader's first scroll to notice.
  require("intentdiff.render.paint").resync(tabpage)

  M.install_keymaps(tabpage)
  refresh_comments(tabpage)
  return true
end

-- ------------------------------------------------------- stale-on-write ----
--
-- Closes the gap task 11 (`gf` / M.open_real_file) opened: that command hands
-- the reader an ordinary editable buffer on the real file, and until now
-- nothing ever called content.lua's `invalidate` — so review → gf → fix →
-- back to the review showed whatever the worktree held at the moment the
-- review's content cache first read that file, forever.
--
-- BufWritePost is the only trigger wired up. `gf` always opens the real file
-- in an editable buffer inside THIS Neovim, so the edit this gap is about
-- ends in a `:w` this instance sees directly — BufWritePost covers it exactly.
-- FileChangedShellPost (a file changed by something OUTSIDE this Neovim —
-- another process, a second Neovim, `git checkout`) is deliberately not
-- wired up: nothing in the reachable gap needs it, it only fires on an
-- explicit `:checktime`/'autoread' check this plugin does not otherwise
-- perform, and adding it would mean reasoning through a second, harder
-- staleness source for a workflow nobody has asked for yet.

--- One global augroup, not one per review tab: the event this reacts to — "a
--- file changed on disk" — has nothing to do with which tabpage is current,
--- and the callback below re-reads `M._painted` fresh on every write rather
--- than closing over any particular tab's state. Created at most once
--- (`write_augroup` guards it, declared above with the other tab-state
--- locals) and, unlike a per-tab group, never needs tearing down when a
--- review tab closes, because it was never tied to one — so it does not
--- participate in the `IntentDiffSync_<n>` per-tab augroup hygiene
--- paint.lua's alignment tracker follows, and there is nothing here for that
--- hygiene test to catch.

--- Every review tabpage whose CURRENTLY PAINTED plan includes `abs_path`
--- (already an absolute path). See `M._on_file_written`'s doc comment for why
--- "currently painted" — not "anywhere in the review's diff" — is the scope.
--- @return table[] { tabpage, painted, path } — `path` is repo-relative
local function tabs_showing(abs_path)
  local out = {}
  for tabpage, painted in pairs(M._painted) do
    if vim.api.nvim_tabpage_is_valid(tabpage) and painted.sess and painted.sess.git_root then
      local prefix = painted.sess.git_root:gsub("/+$", "") .. "/"
      if abs_path:sub(1, #prefix) == prefix then
        local relpath = abs_path:sub(#prefix + 1)
        for _, f in ipairs(painted.files) do
          if f.path == relpath then
            out[#out + 1] = { tabpage = tabpage, painted = painted, path = relpath }
            break
          end
        end
      end
    end
  end
  return out
end

--- A file was written to disk. Invalidate its cached worktree content in
--- every review tab that currently has it on screen, and repaint those tabs
--- immediately so the reader sees the "changed on disk" note (render/plan.lua's
--- `file.stale` branch) as soon as they return, rather than only on their next
--- navigation.
---
--- Deliberately does NOT try to show the edit itself. `content.is_stale`
--- (checked by render_now, above) forces this file to fall back to its
--- hunks' own frozen text instead of pairing fresh worktree lines against
--- hunk ranges a `git diff` run before the edit produced — those ranges can
--- no longer be trusted to describe the file (a shifted line count misaligns
--- every row after the edit, silently). Actually re-diffing to make a live
--- update SAFE would mean re-parsing hunks and reconciling them against the
--- classifier's existing groups by identity — a real re-classification, out
--- of scope here. Freezing to the hunks-only view is the honest degradation:
--- never wrong, just says so instead of guessing.
---
--- Scoped to `M._painted[tab].files` — what a tab is CURRENTLY showing — not
--- the review's whole diff. `gf` only ever opens a file that is part of the
--- plan on screen at the moment it is pressed, and that plan does not change
--- while the reader is away editing in the other (real-file) tab, so this
--- covers the task 11 workflow exactly. A file that belongs to the review but
--- is showing in neither pane at write time is left alone — reaching it would
--- mean tracking the review's whole file list here too, which nothing this
--- task's interface surface (view.lua/content.lua) exposes, and no described
--- workflow needs it.
function M._on_file_written(abs_path)
  if not abs_path or abs_path == "" then
    return
  end
  local content = require("intentdiff.render.content")
  for _, hit in ipairs(tabs_showing(abs_path)) do
    content.invalidate(hit.painted.sess, hit.path)
    vim.notify(
      ("intent-diff: %s changed on disk — showing it as reviewed; reopen the review for a fresh diff")
        :format(hit.path),
      vim.log.levels.WARN)
    render_now(hit.tabpage, hit.painted.sess, hit.painted.files, hit.painted.visible,
      M._layout[hit.tabpage])
  end
end

--- Arm the write watcher. Idempotent — `write_augroup` guards it against
--- registering twice across repeated `M.open_tab` calls in the same Neovim
--- session, and `nvim_create_augroup`'s `clear = true` means even a forced
--- re-arm (a reloaded module in a test run) replaces rather than stacks the
--- one autocommand it owns.
ensure_write_watch = function()
  if write_augroup then
    return
  end
  write_augroup = vim.api.nvim_create_augroup("IntentDiffWatch", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = write_augroup,
    pattern = "*",
    callback = function(args)
      M._on_file_written(vim.fn.fnamemodify(args.file, ":p"))
    end,
  })
end

--- Render `files` with `visible` hunks left unfolded. THE render entry point: a
--- single file and a whole intent differ only in how many entries `files` has.
---
--- Content that is not cached yet is fetched in the background; what can be
--- drawn now IS drawn now (hunks-only, saying so on each file's separator) and
--- repainted once the real content lands.
---
--- `opts.on_ready` fires exactly ONCE per call, after the first paint. A later
--- content-arrival repaint deliberately does not re-fire it: callers use it to
--- attach navigation and decide focus, and doing either twice undoes a newer
--- caller's decision.
--- @param opts table|nil { layout = "inline"|"side-by-side", on_ready = fun() }
--- @return boolean whether anything was painted
function M.show(sess, files, visible, opts)
  opts = opts or {}
  files = files or {}
  visible = visible or {}
  local tabpage = sess.tabpage
  if not (tabpage and vim.api.nvim_tabpage_is_valid(tabpage)) then
    return false
  end
  local layout = opts.layout or M._layout[tabpage] or "side-by-side"
  M._layout[tabpage] = layout

  local content = require("intentdiff.render.content")
  -- Declared BEFORE the ensure call, not as one of its result locals: Lua does
  -- not bring a `local` into scope until after the statement that declares it,
  -- so a closure written inside the call expression would capture the GLOBAL of
  -- that name — nil — instead of the list of missing paths.
  local missing = {}
  -- `missing` is the whole reason this is not a repaint loop. content.ensure
  -- fires its callback whenever its worker finishes, INCLUDING when a fetch
  -- failed and left a side nil; repainting unconditionally from there would
  -- call ensure again, find the same paths missing, schedule again, and never
  -- stop. Repaint only when something actually arrived — and never call ensure
  -- from the callback, so the fallback render is simply where a failed fetch
  -- comes to rest.
  local _, still_missing = content.ensure(sess, files, function()
    local painted = M._painted[tabpage]
    if not (painted and painted.files == files) then
      return -- a newer generation has taken the panes; this one is history
    end
    local arrived = false
    for _, path in ipairs(missing) do
      if content.get(sess, path, "old") and content.get(sess, path, "new") then
        arrived = true
        break
      end
    end
    if not arrived then
      return
    end
    render_now(tabpage, sess, files, visible, M._layout[tabpage] or layout)
  end)
  missing = still_missing or {}

  local ok = render_now(tabpage, sess, files, visible, layout)
  if ok and opts.on_ready then
    vim.schedule(opts.on_ready)
  end
  return ok
end

--- The plan currently painted in `tabpage`, or nil.
function M.current_plan(tabpage)
  local p = M._painted[tabpage]
  if not p then
    return nil
  end
  return p.plan
end

--- The pane `bufnr` displays, or nil when it is not one of ours.
--- @return table|nil pane
function M.pane_for_buf(tabpage, bufnr)
  local p = M._painted[tabpage]
  if not p then
    return nil
  end
  if p.bufs.modified == bufnr then
    return p.plan.modified
  end
  if p.bufs.original == bufnr then
    return p.plan.original
  end
  return nil
end

--- Open the real file the cursor's row addresses, at that line, in a normal
--- editable window — the escape hatch for the panes being read-only scratch
--- buffers now.
---
--- Resolves through `plan.target_at`, the same map every other cross-surface
--- feature (comments, cursor-preserving repaints) uses, so this behaves
--- IDENTICALLY in a single-file view and a whole-intent one: both are one
--- plan, and a row either addresses a (file, line) or it does not.
---
--- Opens in a NEW TAB rather than reusing the current window or the review
--- tab's own windows: the two diff panes are dedicated, and swapping the real
--- file into one of them would leave that pane no longer showing the diff it
--- was laid out for. A new tab keeps the review's two-pane layout intact —
--- `gt`/`gT` (or closing the file's tab) returns to it exactly as it was.
---
--- Does nothing, rather than erroring, when the cursor's row addresses no
--- line of any file — a separator, a filler, the binary marker.
--- @return boolean whether a file was opened
function M.open_real_file(tabpage)
  local win = vim.api.nvim_get_current_win()
  local ok, bufnr = pcall(vim.api.nvim_win_get_buf, win)
  if not ok then
    return false
  end
  local pane = M.pane_for_buf(tabpage, bufnr)
  if not pane then
    return false
  end
  local ok_cursor, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if not ok_cursor then
    return false
  end
  local t = require("intentdiff.render.plan").target_at(pane, cursor[1])
  if not t then
    return false
  end
  local painted = M._painted[tabpage]
  if not (painted and painted.sess and painted.sess.git_root) then
    return false
  end
  local abs = painted.sess.git_root .. "/" .. t.file
  vim.cmd("tabedit " .. vim.fn.fnameescape(abs))
  pcall(vim.api.nvim_win_set_cursor, 0, { t.line, 0 })
  return true
end

--- The painted panes of `tabpage`, as `{ { bufnr, pane }, ... }`.
---
--- What lets the comment layer treat every surface as one COORDINATE SYSTEM:
--- `pane.map` says which (file, line, side) each row addresses, so a comment is
--- drawn — and read back — through the same map whether the panes hold one file
--- or a whole intent.
--- @return table[] { bufnr, pane }
function M.painted_panes(tabpage)
  local p = M._painted[tabpage]
  if not p then
    return {}
  end
  local out = {}
  if p.bufs.original and p.plan.original and vim.api.nvim_buf_is_valid(p.bufs.original) then
    out[#out + 1] = { bufnr = p.bufs.original, pane = p.plan.original }
  end
  if p.bufs.modified and vim.api.nvim_buf_is_valid(p.bufs.modified) then
    out[#out + 1] = { bufnr = p.bufs.modified, pane = p.plan.modified }
  end
  return out
end

--- The pane windows of `tabpage`, keyed by side — the shape `paint.render`
--- takes. `original` is nil in inline layout, where there is one window.
--- @return table { original = win|nil, modified = win|nil }
function M.pane_wins(tabpage)
  local wins = M._wins[tabpage]
  if not wins then
    return {}
  end
  local out = {}
  if win_valid(wins.original) then
    out.original = wins.original
  end
  if win_valid(wins.modified) then
    out.modified = wins.modified
  end
  return out
end

--- Windows of the current diff panes, as a plain ARRAY with nil entries
--- dropped. Deliberately not the `{ original, modified }` shape `pane_wins`
--- answers with: every caller here (navigation's keymap install, the comment
--- layer's "is the cursor in a pane" checks) wants to iterate the panes that
--- exist, and `ipairs` over a table literal with a nil first element stops
--- before ever reaching the second.
function M.diff_wins(tabpage)
  local w = M.pane_wins(tabpage)
  local out = {}
  if w.original then
    out[#out + 1] = w.original
  end
  if w.modified and w.modified ~= w.original then
    out[#out + 1] = w.modified
  end
  return out
end

--- Re-render the current generation in the other layout.
--- @param opts table|nil { on_done = fun() }
--- @return boolean whether a toggle was performed
function M.toggle_layout(tabpage, opts)
  tabpage = tabpage or vim.api.nvim_get_current_tabpage()
  opts = opts or {}
  local p = M._painted[tabpage]
  if not p then
    return false
  end
  local next_layout = "inline"
  if M._layout[tabpage] == "inline" then
    next_layout = "side-by-side"
  end
  return M.show(p.sess, p.files, p.visible, {
    layout = next_layout,
    on_ready = opts.on_done,
  })
end

--- Fold expression for the panes. Delegates to the renderer, which owns the
--- per-window visible-row sets; kept here because window options set by earlier
--- generations may still name `v:lua.require'intentdiff.view'.foldexpr()`.
function M.foldexpr()
  return require("intentdiff.render.paint").foldexpr()
end

-- --------------------------------------------------------------- keymaps ---

--- Descriptions for the `keymaps.view` actions, shown in :map / which-key.
M.VIEW_DESCS = {
  toggle_sidebar = "intent-diff: show/hide the sidebar",
  show_help = "intent-diff: toggle this help",
  quit = "intent-diff: close",
  next_hunk = "intent-diff: next hunk in group",
  prev_hunk = "intent-diff: previous hunk in group",
  open_file = "intent-diff: open the real file at the cursor's line",
}

--- Install the `keymaps.view` actions named in `handlers` on `buf`.
function M.map_view_keys(buf, handlers)
  require("intentdiff.keymaps").install(buf, "view", handlers, M.VIEW_DESCS)
end

--- Descriptions for the `keymaps.comments` actions, shown in :map / which-key.
M.COMMENT_DESCS = {
  add_comment = "intent-diff: add a comment",
  add_note = "intent-diff: add a note",
  add_suggestion = "intent-diff: add a suggestion",
  add_issue = "intent-diff: add an issue",
  add_praise = "intent-diff: add praise",
  add_file_comment = "intent-diff: comment on the file / the intent",
  edit_comment = "intent-diff: edit the comment at the cursor",
  delete_comment = "intent-diff: delete the comment at the cursor",
  list_comments = "intent-diff: list every comment",
  next_comment = "intent-diff: next comment",
  prev_comment = "intent-diff: previous comment",
  export_clipboard = "intent-diff: copy the review as Markdown",
  export_file = "intent-diff: write the review to a file",
  clear_comments = "intent-diff: delete every comment",
  export_and_close = "intent-diff: copy the review, then close the tab",
}

--- The visual-mode comment actions, in the order the popup's type list uses.
---
--- An ORDERED LIST of records, deliberately not a table keyed by lhs: an entry
--- whose VALUE is nil is simply absent from a table constructor (so
--- `add_comment`, whose type is nil by design, would vanish), `[nil] = ...`
--- RAISES "table index is nil" the moment an action is disabled, and two
--- actions sharing one lhs would silently collapse into a single entry.
local VISUAL_ACTIONS = {
  { action = "add_comment", type = nil },
  { action = "add_note", type = "note" },
  { action = "add_suggestion", type = "suggestion" },
  { action = "add_issue", type = "issue" },
  { action = "add_praise", type = "praise" },
}

--- Comment keys, installed on every diff pane and on the sidebar.
---
--- Cross-surface by design: an intent comment is added from a sidebar group
--- row, a line comment from any painted pane row, and all three surfaces need
--- the export keys.
--- `tabpage` may be nil, in which case the actions resolve the current tabpage
--- when the key is pressed — which is always the right one for a buffer-local
--- mapping.
function M.install_comment_keymaps(buf, tabpage)
  if not require("intentdiff.config").comments_enabled() then
    return
  end
  local comments = require("intentdiff.comments")
  require("intentdiff.keymaps").install(buf, "comments", {
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
  }, M.COMMENT_DESCS)

  -- Visual-mode variants: the same add actions, over the selected range.
  local km = (require("intentdiff.config").options.keymaps or {}).comments or {}
  local each = require("intentdiff.keymaps").each
  for _, record in ipairs(VISUAL_ACTIONS) do
    local comment_type = record.type
    each(km[record.action], function(lhs)
      pcall(vim.keymap.set, "x", lhs, function()
        -- <Esc> FIRST: '< and '> hold the PREVIOUS selection until visual mode
        -- is left, so reading them from within visual mode records the wrong
        -- lines (or none at all, on the very first selection of a session).
        vim.cmd("normal! \27")
        comments.add(tabpage, comment_type, { visual = true })
      end, { buffer = buf, nowait = true, desc = M.COMMENT_DESCS[record.action] })
    end)
  end
end

--- Install our buffer-local keys on `tabpage`'s painted panes.
---
--- Re-run after every render: the panes are fresh scratch buffers each time, so
--- they inherit nothing. ]c/[c go on through `navigation.reattach_keymaps`,
--- which keeps that pair's group-scoped state in one place.
---
--- The layout-toggle key is codediff's (`t` by default) and is read from
--- codediff's config so the two plugins keep agreeing about it; it is bound to
--- OUR toggle, which re-renders the current plan rather than codediff's.
function M.install_keymaps(tabpage)
  local painted = M._painted[tabpage]
  if not painted then
    return
  end
  local bufs, seen = {}, {}
  for _, buf in pairs(painted.bufs) do
    if buf and not seen[buf] and vim.api.nvim_buf_is_valid(buf) then
      seen[buf] = true
      bufs[#bufs + 1] = buf
    end
  end

  local cd_config = try("codediff.config")
  local keys = cd_config and cd_config.options and cd_config.options.keymaps
  local key = keys and keys.view and keys.view.toggle_layout

  for _, buf in ipairs(bufs) do
    if key then
      pcall(vim.keymap.set, "n", key, function()
        M.toggle_layout(tabpage)
      end, { buffer = buf, nowait = true, desc = "intent-diff: toggle layout" })
    end
    M.map_view_keys(buf, {
      toggle_sidebar = function()
        require("intentdiff").toggle_sidebar(tabpage)
      end,
      show_help = function()
        require("intentdiff.keymap_help").toggle()
      end,
      quit = function()
        require("intentdiff").close(tabpage)
      end,
      open_file = function()
        M.open_real_file(tabpage)
      end,
    })
    M.install_comment_keymaps(buf, tabpage)
  end
  require("intentdiff.navigation").reattach_keymaps(tabpage)
end

return M
