PLENARY := rtps/plenary.nvim

test-deps: $(PLENARY)

$(PLENARY):
	mkdir -p rtps
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $@

test: $(PLENARY)
	nvim --headless --clean -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/plenary/ {minimal_init = 'tests/minimal_init.lua'}"

.PHONY: test test-deps
