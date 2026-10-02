# Installs the agent-capsule script into ~/.local/bin, its Dockerfile into
# ~/.local/share/agent-capsule, and its bash and zsh completions.
#
#   make install      # copy agent-capsule -> ~/.local/bin/agent-capsule (0755)
#                     # copy Dockerfile and entrypoint.sh -> ~/.local/share/agent-capsule/
#   make uninstall    # remove everything install added
#
# Override the destination if needed:
#   make install PREFIX=/usr/local     # -> /usr/local/bin/agent-capsule

PREFIX ?= $(HOME)/.local
BINDIR = $(PREFIX)/bin
SHAREDIR = $(PREFIX)/share/agent-capsule
BASHCOMPDIR = $(PREFIX)/share/bash-completion/completions
ZSHCOMPDIR = $(PREFIX)/share/zsh/site-functions

.PHONY: help test install uninstall

help:
	@echo "test         Run launcher and worklog tests"
	@echo "install      Install agent-capsule, its container files, and completions"
	@echo "uninstall    Remove the installed script, container files, and completions"

test:
	@bash tests/agent-capsule_test.sh
	@bash tests/worklog_test.sh

install:
	@install -d "$(BINDIR)"
	@install -m 0755 agent-capsule "$(BINDIR)/agent-capsule"
	@install -d "$(SHAREDIR)"
	@install -m 0644 Dockerfile "$(SHAREDIR)/Dockerfile"
	@install -m 0755 entrypoint.sh "$(SHAREDIR)/entrypoint.sh"
	@install -d "$(BASHCOMPDIR)" "$(ZSHCOMPDIR)"
	@install -m 0644 completions/agent-capsule.bash "$(BASHCOMPDIR)/agent-capsule"
	@install -m 0644 completions/_agent-capsule "$(ZSHCOMPDIR)/_agent-capsule"
	@echo "Installed $(BINDIR)/agent-capsule"
	@echo "Installed $(SHAREDIR)/Dockerfile"
	@echo "Installed $(SHAREDIR)/entrypoint.sh"
	@echo "Installed $(BASHCOMPDIR)/agent-capsule"
	@echo "Installed $(ZSHCOMPDIR)/_agent-capsule"
	@case ":$$PATH:" in \
	  *":$(BINDIR):"*) ;; \
	  *) echo "WARNING: $(BINDIR) is not on your PATH, add it, e.g.:"; \
	     echo "  export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac

uninstall:
	@rm -f "$(BINDIR)/agent-capsule"
	@rm -f "$(SHAREDIR)/Dockerfile"
	@rm -f "$(SHAREDIR)/entrypoint.sh"
	@rm -f "$(BASHCOMPDIR)/agent-capsule"
	@rm -f "$(ZSHCOMPDIR)/_agent-capsule"
	@rmdir "$(SHAREDIR)" 2>/dev/null || true
	@echo "Removed $(BINDIR)/agent-capsule"
	@echo "Removed $(SHAREDIR)/Dockerfile"
	@echo "Removed $(SHAREDIR)/entrypoint.sh"
	@echo "Removed $(BASHCOMPDIR)/agent-capsule"
	@echo "Removed $(ZSHCOMPDIR)/_agent-capsule"
