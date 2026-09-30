# Base image tags are injected by agent-capsule via --build-arg
# (defaults mirror AGENT_CAPSULE_NODE_TAG / AGENT_CAPSULE_GO_TAG).
ARG NODE_TAG=trixie-slim
ARG GO_TAG=trixie

# Tool versions are empty by default, which means latest at build time.
# agent-capsule passes a value only when AGENT_CAPSULE_*_VERSION pins one, so
# there is no second set of defaults here to drift out of step with the script.
ARG GOLANGCI_LINT_VERSION=""
ARG KUBECTL_VERSION=""
ARG HELM_VERSION=""
ARG TALOSCTL_VERSION=""
ARG SUPERPOWERS_VERSION=""
ARG CLAUDE_CODE_VERSION=""
ARG CODEX_VERSION=""
ARG OPENCODE_VERSION=""
ARG ANYDOC_VERSION=""
ARG MCPVAULT_VERSION=""
ARG SKILLS_VERSION=""

FROM golang:${GO_TAG} AS go-toolchain

FROM node:${NODE_TAG}

# Re-declare after FROM so the build arg is visible to the RUN step below.
ARG GOLANGCI_LINT_VERSION
ARG KUBECTL_VERSION
ARG HELM_VERSION
ARG TALOSCTL_VERSION
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

# Install golangci-lint from the official prebuilt binary (the project advises
# against `go install`). Land it in /usr/local/bin, not $GOPATH/bin: /home/dev is
# bind-mounted at runtime and would mask /home/dev/go/bin. When pinned, install.sh
# comes from the same release tag so the installer matches what it installs.
RUN if [ -n "$GOLANGCI_LINT_VERSION" ]; then \
      curl -sSfL "https://raw.githubusercontent.com/golangci/golangci-lint/$GOLANGCI_LINT_VERSION/install.sh" \
        | sh -s -- -b /usr/local/bin "$GOLANGCI_LINT_VERSION"; \
    else \
      curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh \
        | sh -s -- -b /usr/local/bin; \
    fi

# Cluster CLIs come as release binaries, checked against the SHA-256 sums
# published beside them. The upstream install scripts are not used: helm's
# needs openssl, and talos's checks every version against the latest sums.
RUN kubectl_version="${KUBECTL_VERSION:-$(curl -sSfL https://dl.k8s.io/release/stable.txt)}" \
    && kubectl_url="https://dl.k8s.io/release/$kubectl_version/bin/linux/$(dpkg --print-architecture)/kubectl" \
    && curl -sSfL "$kubectl_url" -o /usr/local/bin/kubectl \
    && printf '%s  /usr/local/bin/kubectl\n' "$(curl -sSfL "$kubectl_url.sha256")" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/kubectl

RUN helm_version="${HELM_VERSION:-$(curl -sSfL https://get.helm.sh/helm-latest-version)}" \
    && helm_arch="$(dpkg --print-architecture)" \
    && helm_url="https://get.helm.sh/helm-$helm_version-linux-$helm_arch.tar.gz" \
    && curl -sSfL "$helm_url" -o /tmp/helm.tar.gz \
    && printf '%s  /tmp/helm.tar.gz\n' "$(curl -sSfL "$helm_url.sha256sum" | awk '{print $1}')" \
      | sha256sum -c - \
    && tar -xzf /tmp/helm.tar.gz -C /usr/local/bin --strip-components=1 --no-same-owner \
      "linux-$helm_arch/helm" \
    && rm /tmp/helm.tar.gz

RUN talos_release=https://github.com/siderolabs/talos/releases \
    && talosctl_version="${TALOSCTL_VERSION:-latest}" \
    && if [ "$talosctl_version" = latest ]; then \
      talosctl_version="$(curl -sSfL -o /dev/null -w '%{url_effective}' "$talos_release/latest")" \
      && talosctl_version="${talosctl_version##*/}"; \
    fi \
    && talosctl_file="talosctl-linux-$(dpkg --print-architecture)" \
    && talosctl_url="$talos_release/download/$talosctl_version" \
    && curl -sSfL "$talosctl_url/$talosctl_file" -o /usr/local/bin/talosctl \
    && printf '%s  /usr/local/bin/talosctl\n' \
      "$(curl -sSfL "$talosctl_url/sha256sum.txt" | awk -v file="$talosctl_file" '$2 == file {print $1}')" \
      | sha256sum -c - \
    && chmod 0755 /usr/local/bin/talosctl

# Selection. The launcher passes these from --agent and --with; the defaults
# mirror its own, so a bare `docker build .` still produces a usable image.
ARG AGENT=claude
ARG WITH_ANYDOC=0
ARG WITH_EXPLAIN_DIFF=0
ARG WITH_MCPVAULT=0
ARG WITH_SUPERPOWERS=0

# Integrations are installed only when selected, one layer each: a RUN's cache
# key is its expanded command, so toggling one leaves the others cached.
# Files that become agent state stay under /opt because /home/dev is
# bind-mounted from the host session home at runtime.
RUN if [ "$WITH_ANYDOC" = 1 ]; then \
      npm install -g "@firecrawl/anydoc@${ANYDOC_VERSION:-latest}" \
      && anydoc_root="$(npm root -g)/@firecrawl/anydoc" \
      && anydoc_installed="$(node -p "require('$anydoc_root/package.json').version")" \
      && anydoc_ref="https://github.com/firecrawl/anydoc/tree/v$anydoc_installed" \
      && HOME=/opt/anydoc npx -y "skills@${SKILLS_VERSION:-latest}" \
        add "$anydoc_ref" -g -a claude-code -y \
      && rm -rf /opt/anydoc/.npm /opt/anydoc/.agents \
      && mkdir -p /opt/anydoc/plugin/.claude-plugin \
      && cp -a /opt/anydoc/.claude/skills /opt/anydoc/plugin/skills \
      && printf '%s\n' \
        "{\"name\":\"anydoc\",\"version\":\"$anydoc_installed\",\"description\":\"Convert documents to Markdown\"}" \
        > /opt/anydoc/plugin/.claude-plugin/plugin.json \
      && npm cache clean --force; \
    fi

# Pinned to a gist revision, so image rebuilds are reproducible.
RUN if [ "$WITH_EXPLAIN_DIFF" = 1 ]; then \
      mkdir -p /opt/explain-diff-html \
      && explain_diff_url='https://gist.githubusercontent.com/geoffreylitt/a29df1b5f9865506e8952488eac3d524/raw/' \
      && explain_diff_url="${explain_diff_url}e4982a26bc8975dd45eeb96ad8c68f2f25fc42c7/explain-diff-html.md" \
      && curl -sSfL "$explain_diff_url" -o /opt/explain-diff-html/SKILL.md; \
    fi

RUN if [ "$WITH_MCPVAULT" = 1 ]; then \
      npm install -g "@bitbonsai/mcpvault@${MCPVAULT_VERSION:-latest}" \
      && npm cache clean --force; \
    fi

# Codex activates Superpowers from /opt/superpowers/source at startup, so its
# .git must survive. Resolve the latest release tag when no version is pinned,
# then put the tagged checkout on a real branch for the local marketplace clone.
RUN if [ "$WITH_SUPERPOWERS" = 1 ]; then \
      superpowers_ref="${SUPERPOWERS_VERSION:-latest}" \
      && if [ "$superpowers_ref" = latest ]; then \
        release_url="$(curl -sSfL -o /dev/null -w '%{url_effective}' \
          https://github.com/obra/superpowers/releases/latest)" \
        && superpowers_ref="${release_url##*/}"; \
      fi \
      && git clone --depth 1 --branch "$superpowers_ref" \
        https://github.com/obra/superpowers.git /opt/superpowers/source \
      && git -C /opt/superpowers/source checkout -B main; \
    fi

# One CLI, not three: a run uses exactly one agent and each package is large.
# Last of the selected installs, so switching agents reuses every layer above.
RUN case "$AGENT" in \
      claude) npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}" ;; \
      codex) npm install -g "@openai/codex@${CODEX_VERSION:-latest}" ;; \
      opencode) npm install -g "opencode-ai@${OPENCODE_VERSION:-latest}" ;; \
      *) echo "unknown agent: $AGENT" >&2; exit 1 ;; \
    esac \
    && npm cache clean --force

COPY entrypoint.sh /usr/local/bin/agent-capsule-entrypoint.sh

ENV HOME=/home/dev \
    GOPATH=/home/dev/go \
    PATH=/usr/local/go/bin:/home/dev/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/agent-capsule-entrypoint.sh"]
# Manual-run fallback only: agent-capsule always passes the command explicitly,
# and which agent binary exists now depends on the AGENT build arg.
CMD ["bash"]
