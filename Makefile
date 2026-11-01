# Builds and installs macvm. Tart and the VM are handled by `macvm setup`.
PREFIX ?= $(HOME)/.local
SHARE = $(PREFIX)/share/macvm
# The helper runs in the guest, whose OS can be older than the build host's.
SWIFTFLAGS = -O -target arm64-apple-macos13

.PHONY: all build install uninstall clean test
all: build
build: build/macvm-helper
build/macvm-helper: $(wildcard helper/*.swift)
	mkdir -p build
	swiftc $(SWIFTFLAGS) $^ -o $@
install: build
	install -d $(PREFIX)/bin $(SHARE)/skill/claude $(SHARE)/lib
	install -m 755 bin/macvm $(PREFIX)/bin/macvm
	install -m 644 lib/*.sh $(SHARE)/lib/
	install -m 755 build/macvm-helper $(SHARE)/macvm-helper
	install -m 644 skill/claude/SKILL.md $(SHARE)/skill/claude/SKILL.md
# Removes only the program. User data and the VM: macvm teardown.
uninstall:
	rm -f $(PREFIX)/bin/macvm
	rm -rf $(SHARE)
clean:
	rm -rf build
test:
	test/verify.sh
