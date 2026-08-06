#!/usr/bin/env bash
#
# The whole suite. Sequential and in ONE nvim instance, so anything a spec
# creates (tabs, windows, autocommands) must be cleaned up by that spec.
#
# TO RUN A SINGLE SPEC, pass the file to PlenaryBustedDirectory — NOT to
# PlenaryBustedFile:
#
#   nvim --headless -u tests/init.lua \
#     -c "PlenaryBustedDirectory tests/render_paint_spec.lua { minimal_init = 'tests/init.lua' }"
#
# PlenaryBustedFile runs the spec IN THE CURRENT PROCESS, which has already
# loaded modules and set options the spec expects to configure for itself.
# That is a FALSE RED: render_paint_spec is 27/7/0 under PlenaryBustedFile and
# 34/0/0 under the line above. `minimal_init` is what gives each spec its own
# clean child nvim.
#
# IF YOU CHANGED paint.lua's ALIGNMENT BLOCK (the WinScrolled / CursorMoved
# handlers, bind_sync / unsync / resync), also run the manual harness. Headless
# Neovim raises neither event, so this suite invokes the callbacks through
# `doautocmd` — it would stay green even if paint.lua listened for the wrong
# event entirely, and tests/manual/pane_alignment.lua is the only thing that
# proves Neovim actually delivers them:
#
#   script -q /dev/null nvim -u tests/init.lua \
#     -c "luafile tests/manual/pane_alignment.lua" </dev/null >/dev/null
#   cat /tmp/intentdiff-pane-alignment.txt
#
# Every line must read PASS. See that file's own header for what it checks.
set -e
cd "$(dirname "$0")/.."
nvim --headless -u tests/init.lua \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/init.lua', sequential = true }"
