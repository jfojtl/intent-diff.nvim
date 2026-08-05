# Attribution

intent-diff.nvim builds on other people's work. This file records what, and
under which licence. We are grateful to all of them.

---

## codediff.nvim

**License:** MIT
**Copyright:** Copyright (c) 2025 Yanuo Ma
**Source:** https://github.com/esmuellert/codediff.nvim
**Purpose:** intent-diff depends on codediff.nvim at runtime for revision
resolution, and — optionally — for two rendering helpers.

Specifically, intent-diff `require`s:

- `codediff.core.git` — git root, revision resolution and merge-base lookup.
  This is the one piece intent-diff cannot function without; everything else,
  including fetching the file content itself, is intent-diff's own git
  plumbing.
- `codediff.core.diff` — the LuaJIT FFI binding to `libvscode-diff`. This is
  what gives intent-diff character-level highlighting inside a changed line.
  Optional: guarded with `pcall`, so a missing binary (the platform build
  didn't install, or codediff isn't present) degrades to whole-line
  highlighting only, never an error.
- `codediff.ui.inline.compute_syntax_highlights` — treesitter highlights for
  an arbitrary array of lines, which is what lets intent-diff syntax-highlight
  the synthetic multi-file buffers it builds. Also optional, same guard.
- `codediff.config` — read (optionally) so intent-diff's own layout-toggle key
  stays whatever the user configured for codediff's own
  `keymaps.view.toggle_layout`, instead of drifting out of sync with it.

**If you want a general-purpose diff, merge and git-history tool for Neovim,
install codediff.nvim directly — it is excellent, and intent-diff is not a
replacement for it.** intent-diff does one narrow thing: it groups a diff by
*intent* and gives you a review surface over those groups.

---

## Microsoft Visual Studio Code

**License:** MIT
**Copyright:** Copyright (c) Microsoft Corporation
**Source:** https://github.com/microsoft/vscode
**Purpose:** `libvscode-diff`, which intent-diff reaches through codediff.nvim,
is a C port of VSCode's `defaultLinesDiffComputer` — the Myers diff
implementation, its line-level optimisation heuristics, and the character-level
refinement that produces intra-line highlighting.

See codediff.nvim's own `ATTRIBUTION.md` for the full component list and
licence text.

---

## utf8proc

**License:** MIT
**Copyright:** Copyright (c) 2014-2021 Steven G. Johnson, Jiahao Chen, Tony
Kelman, Jonas Fonseca, and other contributors
**Source:** https://github.com/JuliaStrings/utf8proc
**Purpose:** Bundled inside the `libvscode-diff` binary for Unicode string
processing.

---

## plenary.nvim

**License:** MIT
**Maintainers:** nvim-lua community
**Source:** https://github.com/nvim-lua/plenary.nvim
**Purpose:** Test framework (development only).

---

## Acknowledgments

- **Yanuo Ma** and the codediff.nvim contributors, whose C port of VSCode's
  diff algorithm is what makes intent-diff's character-level rendering
  possible at all, and whose conventions this plugin deliberately mirrors —
  keymap namespacing (`keymaps.view` / `.sidebar` / …), the `default = true`
  highlight-link pattern, and the shape of its derived add/delete word colors
  — so the two tools share muscle memory even where intent-diff's own code
  reimplements the idea rather than calling into codediff for it.
- **Microsoft Corporation** and the VSCode team for open-sourcing that
  algorithm.
- **review.nvim** by georgeguimaraes, whose review-comment UX intent-diff's
  comments are modelled on.

---

*intent-diff.nvim's own licensing is not yet formalized in this repository —
this file covers only its dependencies.*
