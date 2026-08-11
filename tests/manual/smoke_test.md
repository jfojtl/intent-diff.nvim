# Manual smoke test (real LLM)

The automated suite stubs the provider and runs headless, so nothing below is
covered by `tests/run_tests.sh`. Run this by hand against a real `claude` CLI
before releasing.

1. In a repo with a multi-purpose dirty working tree, run `:IntentDiff`.
2. Sidebar shows flat "All changes" + `⟳ classifying…`, then regroups once the
   provider responds — seconds on a small diff, but expect well over a minute
   on a large one (see the latency notes in the README's "Performance"
   section; not ~5s).
3. Footer shows `N/N hunks` — total must equal the hunk count of
   `git diff HEAD` + untracked files.
4. The first file opens on its own (`auto_open`, default on) as soon as
   there's something to show — no need to select anything: unrelated hunks
   are folded; `zo` peeks at them.
5. `]c` at the last hunk of the open file does nothing (no wraparound, no
   rolling to the next file). Rest the cursor on the group row instead to
   preview the whole intent — now `]c` walks every hunk across all its files,
   in order, because they're all in the one plan that's on screen.
6. Toggle inline view (the key borrowed from codediff) — folds still filter to
   the group, and any old-side comment box is still there, on the removed line
   it was made on.
7. `R` re-classifies; a second `:IntentDiff` on the same diff is instant
   (cache).
8. In a pane, `<localleader>cn` on a changed line: the popup opens **already in
   insert mode** — type without pressing `i`. `<C-s>` submits, a box appears
   under the line, and you are back in normal mode in the pane you came from
   (`<Esc>` cancels and must leave you in normal mode too). The automated
   tests all drive the popup with `no_insert`, so this insert/stopinsert path
   is only ever exercised here.
9. Add a second comment further down the same file, then `]n` / `[n` from a
   pane: the cursor walks between the two boxes and reports "no more comments"
   at the ends. With a whole intent on screen it walks every box the render
   draws, including boxes in its other files. Press `]n` with the cursor in
   the **sidebar**: it must refuse ("comment navigation only works in a diff
   pane") and the sidebar cursor must not move — a sidebar row is not a diff
   line, and a stray jump there re-renders the panes via the hover preview.
10. `<localleader>ce` on a commented line edits it, `<localleader>cd` deletes
    it. Then, in another Neovim (or `:!`), delete most of the file's lines so
    a comment's line number is past the end, and reopen the review: the box
    is clamped onto the last line, and `]n`, `<localleader>ce` and
    `<localleader>cd` must all still reach it there.
11. Open a **second** `:IntentDiff` tab on the same working tree and comment in
    it, then switch back to the first tab: the first tab's boxes reappear on
    `TabEnter` (the two tabs share one underlying buffer and one extmark
    namespace). They should be back the moment you land, not after another
    keypress. This is the unsupported-usage case the README notes under
    "Persistence" — the check is that it self-heals, not that it is isolated.
12. `<localleader>cy` copies the Markdown; paste it somewhere and check the
    headings match the sidebar's intents. `<localleader>q` copies and closes
    the tab in one go.

See also `tests/manual/pane_alignment.lua`, which drives side-by-side pane
alignment under a pty — `WinScrolled`/`CursorMoved` are only raised when a UI
is attached, so headless tests cannot observe them.
