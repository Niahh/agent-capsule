# Installs the agent-capsule script into ~/.local/bin and its Dockerfile into
# ~/.local/share/agent-capsule.
#
#   make install      # copy agent-capsule -> ~/.local/bin/agent-capsule (0755)
#                     # copy Dockerfile and entrypoint.sh -> ~/.local/share/agent-capsule/
#   make uninstall    # remove both
#
# Override the destination if needed:
#   make install PREFIX=/usr/local     # -> /usr/local/bin/agent-capsule

PREFIX ?= $(HOME)/.local
BINDIR = $(PREFIX)/bin
SHAREDIR = $(PREFIX)/share/agent-capsule

.PHONY: help test install uninstall

help:
	@echo "test         Run launcher behavior tests"
	@echo "install      Install agent-capsule and its container files"
	@echo "uninstall    Remove the installed script and container files"

test:
	@bash tests/agent-capsule_test.sh

install:
	@install -d "$(BINDIR)"
	@install -m 0755 agent-capsule "$(BINDIR)/agent-capsule"
	@install -d "$(SHAREDIR)"
	@install -m 0644 Dockerfile "$(SHAREDIR)/Dockerfile"
	@install -m 0755 entrypoint.sh "$(SHAREDIR)/entrypoint.sh"
	@echo "Installed $(BINDIR)/agent-capsule"
	@echo "Installed $(SHAREDIR)/Dockerfile"
	@echo "Installed $(SHAREDIR)/entrypoint.sh"
	@case ":$$PATH:" in \
	  *":$(BINDIR):"*) ;; \
	  *) echo "WARNING: $(BINDIR) is not on your PATH, add it, e.g.:"; \
	     echo "  export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac

uninstall:
	@rm -f "$(BINDIR)/agent-capsule"
	@rm -f "$(SHAREDIR)/Dockerfile"
	@rm -f "$(SHAREDIR)/entrypoint.sh"
	@rmdir "$(SHAREDIR)" 2>/dev/null || true
	@echo "Removed $(BINDIR)/agent-capsule"
	@echo "Removed $(SHAREDIR)/Dockerfile"
	@echo "Removed $(SHAREDIR)/entrypoint.sh"
