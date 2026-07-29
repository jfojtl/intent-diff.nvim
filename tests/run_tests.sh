#!/usr/bin/env bash
set -e
cd "$(dirname "$0")/.."
nvim --headless -u tests/init.lua \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/init.lua', sequential = true }"
