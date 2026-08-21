# Record intent-diff reviewing the pull request for the current branch.
#
# Run from the repository root after fetching the PR's base branch. This tape
# is intentionally read-only: it opens and navigates the review, but does not
# create comments or submit anything to GitHub. Rendering does query GitHub
# and sends the reviewed diff/context through your configured Codex CLI.

Output demo/intentdiff-pr.gif

Require nvim
Require codex
Require git

Set Shell "zsh"
Set Theme "Catppuccin Mocha"
Set FontSize 20
Set Width 1920
Set Height 1080
Set Padding 24
Set Framerate 30
Set TypingSpeed 40ms
Set WaitTimeout 3m

# Launch Neovim without recording setup noise.
Hide

# Use the current checkout of intent-diff and select the provider introduced
# by this PR. `-c` runs after the user's Neovim config, when dependencies and
# the local development plugin are available. A fresh cache guarantees the
# recording really invokes Codex rather than replaying an older grouping.
Type `nvim -n -i NONE README.md -c 'lua require("intentdiff").setup({ provider = "codex_cli", cache_dir = vim.fn.tempname(), keymaps = { comments = { add_note = "gc" } } })'`
Enter
Sleep 2s
Show
Sleep 1s

# Review the committed PR range explicitly (PR #3 targets master). Naming HEAD
# keeps this tape and its generated GIF out of the review while they are still
# untracked working-tree files.
Type ":IntentDiff origin/master HEAD"
Sleep 1s
Enter

# Show that classification is happening, but do not make the GIF sit through
# the entire model invocation. The footer can be below the visible part of a
# long sidebar, so poll Neovim's buffers instead of waiting for it on screen.
Sleep 3s
Hide
Type@0ms `:lua assert(vim.wait(180000, function() for _, b in ipairs(vim.api.nvim_list_bufs()) do if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].filetype == "intentdiff" and table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("codex:gpt", 1, true) then return true end end end, 100), "Codex classification timed out"); vim.api.nvim_echo({ { "INTENTDIFF_DEMO_READY" } }, false, {})`
Enter
Wait+Screen /INTENTDIFF_DEMO_READY/
Type@0ms `:echo ""`
Enter
Sleep 4s
Show
Sleep 3s

# Move into the diff, switch its layout, and jump to the next hunk.
Ctrl+w
Type "l"
Sleep 1s
Type "t"
Sleep 3s
Type "]c"
Sleep 2s

# Add a local note to the selected changed line. `gc` is configured above as
# a demo-only shortcut; submitting the popup stores the comment only in the
# temporary review cache and never sends it to GitHub.
Type "gc"
Wait+Screen /✍ Note/
Type "The Codex provider stays read-only and ephemeral."
Sleep 2s
Escape
Enter
Sleep 4s

# Return to the sidebar, browse the next intent, then show the built-in
# keymap reference so the final frame teaches viewers how to continue.
Ctrl+w
Type "h"
Ctrl+w
Type "h"
Tab
Sleep 3s
Type "g?"
Wait+Screen /SIDEBAR/
Sleep 3s
PageDown
Sleep 4s
