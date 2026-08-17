# Base image tags are injected by agent-capsule via --build-arg
# (defaults mirror AGENT_CAPSULE_NODE_TAG / AGENT_CAPSULE_GO_TAG).
ARG NODE_TAG=26-trixie-slim
ARG GO_TAG=1.26.4-trixie
ARG GOLANGCI_LINT_VERSION=v2.12.2

FROM golang:${GO_TAG} AS go-toolchain

FROM node:${NODE_TAG}

# Re-declare after FROM so the build arg is visible to the RUN step below.
ARG GOLANGCI_LINT_VERSION

# pipefail so a failing curl cannot feed an empty script to sh (DL4006).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# When the superclaude extra is selected, the @bifrost_inc/superclaude npm
# postinstall pip-installs SuperClaude from PyPI. Debian's system Python is
# externally managed (PEP 668), so allow the system-wide install inside this
# disposable container image.
ENV PIP_BREAK_SYSTEM_PACKAGES=1

COPY --from=go-toolchain /usr/local/go /usr/local/go

# gcc and libc6-dev complete the Go toolchain: node:*-slim ships no C compiler,
# so without them cgo is disabled and `go test -race` (external linking) and
# any cgo package fail.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates ripgrep less procps openssh-client bash \
      python3 python3-pip \
      gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# Both agents ship in every image; agent-capsule's --agent flag is a purely
# runtime choice, so the --with image-tag scheme (see agent-capsule) is
# untouched by which one a run selects.
RUN npm install -g @anthropic-ai/claude-code @openai/codex

# Install golangci-lint from the official prebuilt binary (the project advises
# against `go install`). Land it in /usr/local/bin, not $GOPATH/bin: /home/dev is
# bind-mounted at runtime and would mask /home/dev/go/bin. Pin install.sh to the
# release tag (not HEAD) so the installer matches the version it installs.
RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/${GOLANGCI_LINT_VERSION}/install.sh \
      | sh -s -- -b /usr/local/bin "${GOLANGCI_LINT_VERSION}"

# Optional extra tools, selected per run with `agent-capsule --with`. Empty by
# default, so the base image stays lean. Keep the case branches in sync with
# KNOWN_EXTRAS in agent-capsule.
# Extras that ship files for ~/.claude (SuperClaude commands, the anydoc skill)
# are baked into a non-masked path: at runtime /home/dev is bind-mounted from
# the host session home, which would hide them; instead they install under
# /opt/<extra> and the entrypoint seeds the session home from there.
ARG EXTRAS=""
RUN set -eu; \
    for extra in $(printf '%s' "$EXTRAS" | tr ',' ' '); do \
      case "$extra" in \
        anydoc) \
          npm install -g @firecrawl/anydoc; \
          HOME=/opt/anydoc npx -y skills add firecrawl/anydoc -g -a claude-code -y; \
          rm -rf /opt/anydoc/.npm /opt/anydoc/.agents ;; \
        superclaude) \
          npm install -g @bifrost_inc/superclaude; \
          HOME=/opt/superclaude superclaude install --force ;; \
        hunkdiff) \
          npm install -g hunkdiff ;; \
        mcpvault) \
          npm install -g @bitbonsai/mcpvault ;; \
        *) \
          echo "unknown extra: $extra" >&2; exit 1 ;; \
      esac; \
    done; \
    npm cache clean --force

# On first start of a session, seed /home/dev/.claude from every /opt/<extra>/.claude
# baked into the image, then exec. One marker per extra keeps steady-state launches
# fast and still seeds a home first used with a smaller image variant. With no seed
# dirs the loop matches nothing, so the same entrypoint serves every variant.
# Written via printf (single-quoted lines stay literal) so it works on builders
# without Dockerfile heredoc support.
RUN printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -e' \
      'DEST="${HOME:-/home/dev}/.claude"' \
      'for seed in /opt/*/.claude; do' \
      '  [[ -d "$seed" ]] || continue' \
      '  name="${seed%/.claude}"; name="${name##*/}"' \
      '  if [[ ! -e "$DEST/.$name-seeded" ]]; then' \
      '    mkdir -p "$DEST"' \
      '    # -n: never clobber user files or the read-only CLAUDE.md/credentials mounts.' \
      '    cp -an "$seed/." "$DEST/" 2>/dev/null || true' \
      '    touch "$DEST/.$name-seeded" 2>/dev/null || true' \
      '  fi' \
      'done' \
      'exec "$@"' \
      > /usr/local/bin/agent-capsule-entrypoint.sh \
    && chmod +x /usr/local/bin/agent-capsule-entrypoint.sh

ENV HOME=/home/dev \
    GOPATH=/home/dev/go \
    PATH=/usr/local/go/bin:/home/dev/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/agent-capsule-entrypoint.sh"]
CMD ["claude"]
