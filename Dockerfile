# Base image tags are injected by agent-capsule via --build-arg
# (defaults mirror AGENT_CAPSULE_NODE_TAG / AGENT_CAPSULE_GO_TAG).
ARG NODE_TAG=trixie-slim
ARG GO_TAG=trixie

FROM golang:${GO_TAG} AS go-toolchain

FROM node:${NODE_TAG}

# pipefail so a failing curl cannot feed an empty script to sh (DL4006).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=go-toolchain /usr/local/go /usr/local/go

# gcc and libc6-dev complete the Go toolchain: node:*-slim ships no C compiler,
# so without them cgo is disabled and `go test -race` (external linking) and
# any cgo package fail.
# tzdata-legacy keeps old zone names such as US/Eastern, which a forwarded TZ can carry.
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates ripgrep less procps openssh-client \
      gcc libc6-dev tzdata-legacy \
    && rm -rf /var/lib/apt/lists/*

# Every RUN after an ARG has that arg's value in its cache key, so each ARG sits just above the RUN that reads it.
# A *_VERSION left empty, as the launcher passes it unless pinned, means latest.

# Install golangci-lint from the official prebuilt binary (the project advises
# against `go install`). Land it in /usr/local/bin, not $GOPATH/bin: /home/dev is
# bind-mounted at runtime and would mask /home/dev/go/bin. When pinned, install.sh
# comes from the same release tag so the installer matches what it installs.
ARG GOLANGCI_LINT_VERSION=""
RUN if [ -n "$GOLANGCI_LINT_VERSION" ]; then \
      curl -sSfL "https://raw.githubusercontent.com/golangci/golangci-lint/$GOLANGCI_LINT_VERSION/install.sh" \
        | sh -s -- -b /usr/local/bin "$GOLANGCI_LINT_VERSION"; \
    else \
      curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/HEAD/install.sh \
        | sh -s -- -b /usr/local/bin; \
    fi

# Extensions are in every image and stay inert until --with turns them on, so --with
# never rebuilds. Files that become agent state stay under /opt because /home/dev is
# bind-mounted from the host session home at runtime. Bundled skills live under
# /opt/agent-capsule/skills/<integration>/<skill>/, and the entrypoint links those of
# the selected integrations into the agent's skills dir.
ARG ANYDOC_VERSION=""
RUN npm install -g "@firecrawl/anydoc@${ANYDOC_VERSION:-latest}" \
    && anydoc_installed="$(node -p "require('$(npm root -g)/@firecrawl/anydoc/package.json').version")" \
    && anydoc_raw="https://raw.githubusercontent.com/firecrawl/anydoc/v$anydoc_installed" \
    && skill_dir=/opt/agent-capsule/skills/anydoc/convert-documents-to-markdown \
    && mkdir -p "$skill_dir" \
    && curl -sSfL "$anydoc_raw/skills/convert-documents-to-markdown/SKILL.md" -o "$skill_dir/SKILL.md" \
    && npm cache clean --force

# Pinned to a gist revision, so image rebuilds are reproducible.
RUN skill_dir=/opt/agent-capsule/skills/explain-diff/explain-diff-html \
    && mkdir -p "$skill_dir" \
    && explain_diff_url='https://gist.githubusercontent.com/geoffreylitt/a29df1b5f9865506e8952488eac3d524/raw/' \
    && explain_diff_url="${explain_diff_url}e4982a26bc8975dd45eeb96ad8c68f2f25fc42c7/explain-diff-html.md" \
    && curl -sSfL "$explain_diff_url" -o "$skill_dir/SKILL.md"

ARG MCPVAULT_VERSION=""
RUN npm install -g "@bitbonsai/mcpvault@${MCPVAULT_VERSION:-latest}" \
    && npm cache clean --force

# Codex activates Superpowers from /opt/superpowers/source at startup, so its
# .git must survive. Resolve the latest release tag when no version is pinned,
# then put the tagged checkout on a real branch for the local marketplace clone.
# Under --keep-id the user does not own the clone, and git checks a local clone's source at its .git.
ARG SUPERPOWERS_VERSION=""
RUN superpowers_ref="${SUPERPOWERS_VERSION:-latest}" \
    && if [ "$superpowers_ref" = latest ]; then \
      release_url="$(curl -sSfL -o /dev/null -w '%{url_effective}' \
        https://github.com/obra/superpowers/releases/latest)" \
      && superpowers_ref="${release_url##*/}"; \
    fi \
    && git clone --depth 1 --branch "$superpowers_ref" \
      https://github.com/obra/superpowers.git /opt/superpowers/source \
    && git -C /opt/superpowers/source checkout -B main \
    && git config --system --add safe.directory /opt/superpowers/source/.git

# Tools are the CLIs a user lists in AGENT_CAPSULE_TOOLS, one layer each, below the
# extensions so a change to the list reuses their layers. The defaults mirror the
# launcher's, so a bare `docker build .` installs none of them.

# Release binaries, checked against the SHA-256 sums published beside them.
ARG TOOL_KUBERNETES=0
ARG KUBECTL_VERSION=""
ARG HELM_VERSION=""
RUN if [ "$TOOL_KUBERNETES" = 1 ]; then \
      arch="$(dpkg --print-architecture)" \
      && kubectl_version="${KUBECTL_VERSION:-$(curl -sSfL https://dl.k8s.io/release/stable.txt)}" \
      && kubectl_url="https://dl.k8s.io/release/$kubectl_version/bin/linux/$arch/kubectl" \
      && curl -sSfL "$kubectl_url" -o /usr/local/bin/kubectl \
      && printf '%s  /usr/local/bin/kubectl\n' "$(curl -sSfL "$kubectl_url.sha256")" | sha256sum -c - \
      && chmod 0755 /usr/local/bin/kubectl \
      && helm_version="${HELM_VERSION:-$(curl -sSfL https://get.helm.sh/helm-latest-version)}" \
      && helm_url="https://get.helm.sh/helm-$helm_version-linux-$arch.tar.gz" \
      && curl -sSfL "$helm_url" -o /tmp/helm.tar.gz \
      && printf '%s  /tmp/helm.tar.gz\n' "$(curl -sSfL "$helm_url.sha256sum" | awk '{print $1}')" \
        | sha256sum -c - \
      && tar -xzf /tmp/helm.tar.gz -C /usr/local/bin --strip-components=1 --no-same-owner \
        "linux-$arch/helm" \
      && rm /tmp/helm.tar.gz; \
    fi

# Checked like the kubernetes binaries. talos's install script is not used
# because it checks every version against the latest release's sums.
ARG TOOL_TALOS=0
ARG TALOSCTL_VERSION=""
RUN if [ "$TOOL_TALOS" = 1 ]; then \
      talos_release=https://github.com/siderolabs/talos/releases \
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
      && chmod 0755 /usr/local/bin/talosctl; \
    fi

# Checked against the release's own sums, like talosctl.
ARG TOOL_GH=0
ARG GH_VERSION=""
RUN if [ "$TOOL_GH" = 1 ]; then \
      gh_release=https://github.com/cli/cli/releases \
      && gh_version="${GH_VERSION:-latest}" \
      && if [ "$gh_version" = latest ]; then \
        gh_version="$(curl -sSfL -o /dev/null -w '%{url_effective}' "$gh_release/latest")" \
        && gh_version="${gh_version##*/}"; \
      fi \
      && gh_name="gh_${gh_version#v}_linux_$(dpkg --print-architecture)" \
      && gh_url="$gh_release/download/$gh_version" \
      && curl -sSfL "$gh_url/$gh_name.tar.gz" -o /tmp/gh.tar.gz \
      && printf '%s  /tmp/gh.tar.gz\n' \
        "$(curl -sSfL "$gh_url/gh_${gh_version#v}_checksums.txt" \
          | awk -v file="$gh_name.tar.gz" '$2 == file {print $1}')" \
        | sha256sum -c - \
      && tar -xzf /tmp/gh.tar.gz -C /usr/local/bin --strip-components=2 --no-same-owner \
        "$gh_name/bin/gh" \
      && rm /tmp/gh.tar.gz; \
    fi

# Checked against the release's own sums, like gh.
ARG TOOL_GLAB=0
ARG GLAB_VERSION=""
RUN if [ "$TOOL_GLAB" = 1 ]; then \
      glab_release=https://gitlab.com/gitlab-org/cli/-/releases \
      && glab_version="${GLAB_VERSION:-latest}" \
      && if [ "$glab_version" = latest ]; then \
        glab_version="$(curl -sSfL -o /dev/null -w '%{url_effective}' "$glab_release/permalink/latest")" \
        && glab_version="${glab_version##*/}"; \
      fi \
      && glab_name="glab_${glab_version#v}_linux_$(dpkg --print-architecture)" \
      && glab_url="$glab_release/$glab_version/downloads" \
      && curl -sSfL "$glab_url/$glab_name.tar.gz" -o /tmp/glab.tar.gz \
      && printf '%s  /tmp/glab.tar.gz\n' \
        "$(curl -sSfL "$glab_url/checksums.txt" \
          | awk -v file="$glab_name.tar.gz" '$2 == file {print $1}')" \
        | sha256sum -c - \
      && tar -xzf /tmp/glab.tar.gz -C /usr/local/bin --strip-components=1 --no-same-owner \
        bin/glab \
      && rm /tmp/glab.tar.gz; \
    fi

# One CLI, not three: a run uses exactly one agent and each package is large.
# Last, so switching agents reuses every layer above.
# The default mirrors the launcher's, so a bare `docker build .` still produces a usable image.
ARG AGENT=claude
ARG CLAUDE_CODE_VERSION=""
ARG CODEX_VERSION=""
ARG OPENCODE_VERSION=""
# npm skips a platform package that is not published yet, so make sure the CLI starts.
RUN case "$AGENT" in \
      claude) npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION:-latest}" ;; \
      codex) npm install -g "@openai/codex@${CODEX_VERSION:-latest}" ;; \
      opencode) npm install -g "opencode-ai@${OPENCODE_VERSION:-latest}" ;; \
      *) echo "unknown agent: $AGENT" >&2; exit 1 ;; \
    esac \
    && "$AGENT" --version >/dev/null \
    && npm cache clean --force

COPY entrypoint.sh /usr/local/bin/agent-capsule-entrypoint.sh
# Inert unless --plugin-dir names it.
COPY plugins/worklog /opt/worklog/plugin

ENV HOME=/home/dev \
    GOPATH=/home/dev/go \
    PATH=/usr/local/go/bin:/home/dev/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Otherwise glab reports every command to the GitLab instance. Harmless without glab.
ENV GLAB_SEND_TELEMETRY=false

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/agent-capsule-entrypoint.sh"]
# Manual-run fallback only: agent-capsule always passes the command explicitly,
# and which agent binary exists now depends on the AGENT build arg.
CMD ["bash"]
