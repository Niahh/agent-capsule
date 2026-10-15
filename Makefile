# Override the destination if needed: make install PREFIX=/usr/local

PREFIX ?= $(HOME)/.local
BINDIR = $(PREFIX)/bin
SHAREDIR = $(PREFIX)/share/agent-capsule
BASHCOMPDIR = $(PREFIX)/share/bash-completion/completions
ZSHCOMPDIR = $(PREFIX)/share/zsh/site-functions

.PHONY: help test install uninstall

help:
	@echo "test         Run launcher, worklog, and install tests"
	@echo "install      Install agent-capsule, its container files, and completions"
	@echo "uninstall    Remove the installed script, container files, and completions"

test:
	@bash tests/agent-capsule_test.sh
	@bash tests/worklog_test.sh
	@bash tests/install_test.sh

install:
	@install -d "$(BINDIR)" "$(SHAREDIR)/plugins" "$(BASHCOMPDIR)" "$(ZSHCOMPDIR)"
	@install -m 0755 agent-capsule "$(BINDIR)/agent-capsule"
	@install -m 0644 Dockerfile "$(SHAREDIR)/Dockerfile"
	@install -m 0755 entrypoint.sh "$(SHAREDIR)/entrypoint.sh"
	@rm -rf "$(SHAREDIR)/plugins/worklog"
	@cp -R plugins/worklog "$(SHAREDIR)/plugins/worklog"
	@chmod -R u+w,go-w,a+rX "$(SHAREDIR)/plugins/worklog"
	@install -m 0644 completions/agent-capsule.bash "$(BASHCOMPDIR)/agent-capsule"
	@install -m 0644 completions/_agent-capsule "$(ZSHCOMPDIR)/_agent-capsule"
	@echo "Installed $(BINDIR)/agent-capsule"
	@echo "Installed $(SHAREDIR)/: Dockerfile, entrypoint.sh, plugins/worklog/"
	@echo "Installed $(BASHCOMPDIR)/agent-capsule"
	@echo "Installed $(ZSHCOMPDIR)/_agent-capsule"
	@case ":$$PATH:" in \
	  *":$(BINDIR):"*) ;; \
	  *) echo "WARNING: $(BINDIR) is not on your PATH, add it, e.g.:"; \
	     echo "  export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac
	@SHELL="$$SHELL" scripts/check-shell-completion "$(BASHCOMPDIR)" "$(ZSHCOMPDIR)"

uninstall:
	@rm -f "$(BINDIR)/agent-capsule" "$(SHAREDIR)/Dockerfile" "$(SHAREDIR)/entrypoint.sh"
	@rm -rf "$(SHAREDIR)/plugins"
	@rm -f "$(BASHCOMPDIR)/agent-capsule" "$(ZSHCOMPDIR)/_agent-capsule"
	@rmdir "$(SHAREDIR)" 2>/dev/null || true
	@echo "Removed $(BINDIR)/agent-capsule"
	@echo "Removed $(SHAREDIR)/"
	@echo "Removed $(BASHCOMPDIR)/agent-capsule"
	@echo "Removed $(ZSHCOMPDIR)/_agent-capsule"
