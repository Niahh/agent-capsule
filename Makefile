# Installs the agent-capsule script into ~/.local/bin and its Dockerfile into
# ~/.local/share/agent-capsule.
#
#   make install      # copy agent-capsule -> ~/.local/bin/agent-capsule (0755)
#                     # copy Dockerfile  -> ~/.local/share/agent-capsule/Dockerfile (0644)
#   make uninstall    # remove both
#
# Override the destination if needed:
#   make install PREFIX=/usr/local     # -> /usr/local/bin/agent-capsule

PREFIX ?= $(HOME)/.local
BINDIR = $(PREFIX)/bin
SHAREDIR = $(PREFIX)/share/agent-capsule

.PHONY: help install uninstall

help:
	@echo "install      Install agent-capsule and its Dockerfile"
	@echo "uninstall    Remove the installed script and Dockerfile"

install:
	@install -d "$(BINDIR)"
	@install -m 0755 agent-capsule "$(BINDIR)/agent-capsule"
	@install -d "$(SHAREDIR)"
	@install -m 0644 Dockerfile "$(SHAREDIR)/Dockerfile"
	@echo "Installed $(BINDIR)/agent-capsule"
	@echo "Installed $(SHAREDIR)/Dockerfile"
	@case ":$$PATH:" in \
	  *":$(BINDIR):"*) ;; \
	  *) echo "WARNING: $(BINDIR) is not on your PATH, add it, e.g.:"; \
	     echo "  export PATH=\"$(BINDIR):\$$PATH\"" ;; \
	esac

uninstall:
	@rm -f "$(BINDIR)/agent-capsule"
	@rm -f "$(SHAREDIR)/Dockerfile"
	@rmdir "$(SHAREDIR)" 2>/dev/null || true
	@echo "Removed $(BINDIR)/agent-capsule"
	@echo "Removed $(SHAREDIR)/Dockerfile"
