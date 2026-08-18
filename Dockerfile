# Base image tags are injected by agent-capsule via --build-arg
# (defaults mirror AGENT_CAPSULE_NODE_TAG / AGENT_CAPSULE_GO_TAG).
ARG NODE_TAG=26-trixie-slim
ARG GO_TAG=1.26.4-trixie
ARG GOLANGCI_LINT_VERSION=v2.12.2
ARG SUPERPOWERS_VERSION=v6.3.0
ARG CLAUDE_CODE_VERSION=2.1.234
ARG CODEX_VERSION=0.147.0
ARG OPENCODE_VERSION=1.18.18
ARG ANYDOC_VERSION=0.1.9
ARG MCPVAULT_VERSION=0.16.0
ARG SKILLS_VERSION=1.5.22

FROM golang:${GO_TAG} AS go-toolchain

FROM node:${NODE_TAG}

# Re-declare after FROM so the build arg is visible to the RUN step below.
ARG GOLANGCI_LINT_VERSION
ARG SUPERPOWERS_VERSION
ARG CLAUDE_CODE_VERSION
ARG CODEX_VERSION
ARG OPENCODE_VERSION
ARG ANYDOC_VERSION
ARG MCPVAULT_VERSION
ARG SKILLS_VERSION

# pipefail so a failing curl cannot feed an empty script to sh (DL4006).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=go-toolchain /usr/local/go /usr/local/go

# gcc and libc6-dev complete the Go toolchain: node:*-slim ships no C compiler,
# so without them cgo is disabled and `go test -race` (external linking) and
# any cgo package fail.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates ripgrep less procps openssh-client bash \
      gcc libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# Agent selection is runtime-only. One image supports every launcher profile.
RUN npm install -g \
      "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION" \
      "@openai/codex@$CODEX_VERSION" \
      "opencode-ai@$OPENCODE_VERSION" \
    && npm cache clean --force

# Install golangci-lint from the official prebuilt binary (the project advises
# against `go install`). Land it in /usr/local/bin, not $GOPATH/bin: /home/dev is
# bind-mounted at runtime and would mask /home/dev/go/bin. Pin install.sh to the
# release tag (not HEAD) so the installer matches the version it installs.
RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/${GOLANGCI_LINT_VERSION}/install.sh \
      | sh -s -- -b /usr/local/bin "${GOLANGCI_LINT_VERSION}"

# Bundled integrations are activated per run with `agent-capsule --with`.
# Files that become agent state stay under /opt because /home/dev is
# bind-mounted from the host session home at runtime.
# Codex activates superpowers by cloning /opt/superpowers/source at startup, so
# its .git must survive and HEAD must sit on a real branch: a shallow --branch
# clone leaves HEAD detached, and cloning a branchless repo yields an empty one.
RUN npm install -g \
      "@firecrawl/anydoc@$ANYDOC_VERSION" \
      "@bitbonsai/mcpvault@$MCPVAULT_VERSION" \
    && HOME=/opt/anydoc npx -y "skills@$SKILLS_VERSION" \
      add "https://github.com/firecrawl/anydoc/tree/v$ANYDOC_VERSION" \
      -g -a claude-code -y \
    && rm -rf /opt/anydoc/.npm /opt/anydoc/.agents \
    && mkdir -p /opt/anydoc/plugin/.claude-plugin \
    && cp -a /opt/anydoc/.claude/skills /opt/anydoc/plugin/skills \
    && printf '%s\n' \
      "{\"name\":\"anydoc\",\"version\":\"$ANYDOC_VERSION\",\"description\":\"Convert documents to Markdown\"}" \
      > /opt/anydoc/plugin/.claude-plugin/plugin.json \
    && git clone --depth 1 --branch "$SUPERPOWERS_VERSION" \
      https://github.com/obra/superpowers.git /opt/superpowers/source \
    && git -C /opt/superpowers/source checkout -B main \
    && npm cache clean --force

# Codex has no invocation-only local plugin flag, so the entrypoint reconciles
# only the capsule-managed plugin before starting Codex.
# Written via printf (single-quoted lines stay literal) so it works on builders
# without Dockerfile heredoc support.
RUN printf '%s\n' \
      '#!/usr/bin/env bash' \
      'set -e' \
      'if [[ "${AGENT_CAPSULE_AGENT:-}" == codex ]]; then' \
      '      codex_home="${CODEX_HOME:-${HOME:-/home/dev}/.codex}"' \
      '      marker="$codex_home/.superpowers-capsule-managed"' \
      '      case ",${AGENT_CAPSULE_WITH:-}," in' \
      '        *,superpowers,*)' \
      '          mkdir -p "$codex_home"' \
      '          CODEX_HOME="$codex_home" codex plugin marketplace add /opt/superpowers/source >/dev/null' \
      '          CODEX_HOME="$codex_home" codex plugin add superpowers@superpowers-dev >/dev/null' \
      '          touch "$marker" ;;' \
      '        *)' \
      '          if [[ -e "$marker" ]]; then' \
      '            CODEX_HOME="$codex_home" codex plugin remove superpowers@superpowers-dev >/dev/null' \
      '            rm -f "$marker"' \
      '          fi ;;' \
      '      esac' \
      'fi' \
      'exec "$@"' \
      > /usr/local/bin/agent-capsule-entrypoint.sh \
    && chmod +x /usr/local/bin/agent-capsule-entrypoint.sh

ENV HOME=/home/dev \
    GOPATH=/home/dev/go \
    PATH=/usr/local/go/bin:/home/dev/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/agent-capsule-entrypoint.sh"]
# Manual-run fallback only: agent-capsule always passes the command explicitly.
CMD ["claude"]
