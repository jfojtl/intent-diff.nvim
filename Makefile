# Tests always go through PlenaryBustedDirectory, never PlenaryBustedFile.
#
# PlenaryBustedFile accepts no minimal_init. It spawns a child nvim carrying a
# minimal init of its own, so tests/init.lua never runs there and neither
# plenary nor codediff reaches the child's runtimepath. Every test that needs
# codediff -- all the syntax and character highlighting ones -- then degrades
# silently to no highlights and fails, which reads as a broken suite rather
# than a broken command. It cannot be made to work: the command takes no opts.
#
# PlenaryBustedDirectory does take minimal_init, and it accepts a single file
# path as happily as a directory (it shells out to `find`), so one recipe
# covers both:
#
#   make test
#   make test TEST=tests/render_paint_spec.lua
#
# Exits 1 when any test fails, which is what CI keys off.

NVIM ?= nvim
TEST ?= tests

.PHONY: test
test:
	$(NVIM) --headless -u tests/init.lua \
	  -c "PlenaryBustedDirectory $(TEST) {minimal_init='tests/init.lua'}"
