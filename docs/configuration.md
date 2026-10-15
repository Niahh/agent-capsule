# Configuration

## Persistent defaults

Most settings are `AGENT_CAPSULE_*` environment variables. To stop retyping the
tools and integrations you always want, export them from `~/.bashrc` or `~/.zshrc`:

```sh
export AGENT_CAPSULE_TOOLS=gh,kubernetes
export AGENT_CAPSULE_WITH=superpowers,vault
export AGENT_CAPSULE_VAULT="$HOME/Documents/Obsidian/MyVault"
export AGENT_CAPSULE_KEEPID=1
```

Precedence is command-line flag > environment > built-in default. A command-line
`--with` replaces the exported list instead of adding to it, `--with none` selects
nothing. `--vault`, `--no-vault` and `--ca` add or remove one integration without
replacing the list.

A one-off run does not need an export: `AGENT_CAPSULE_AGENT=codex agent-capsule .`
works, because the launcher reads the variable from its own environment.

### Environment reference

Selection and image lifecycle:

- `AGENT_CAPSULE_AGENT=claude`: default agent (`claude`, `codex`, or `opencode`).
- `AGENT_CAPSULE_WITH=`: comma-separated default integrations.
- `AGENT_CAPSULE_TOOLS=`: comma-separated tools built into the image: `gh`, `glab`,
  `kubernetes`, `talos`. A change rebuilds the image once.
- `AGENT_CAPSULE_IMAGE=agent-capsule-dev`: image name, tagged with the agent's name; a
  full tagged reference is one image that every agent shares.
- `AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS=7`: days between full refreshes; `0` disables
  refreshes based on age.
- `AGENT_CAPSULE_PRUNE=1`: prune superseded capsule images after a build.
- `AGENT_CAPSULE_NODE_TAG=trixie-slim`: Node base image tag.
- `AGENT_CAPSULE_GO_TAG=trixie`: Go toolchain image tag.
- `AGENT_CAPSULE_DOCKERFILE=`: explicit path to the installed Dockerfile.
  `entrypoint.sh` and `plugins/worklog/` must sit beside it.
- `AGENT_CAPSULE_*_VERSION=`: optional tool pins listed under
  [Tool versions and upgrades](#tool-versions-and-upgrades).

Sessions and runtime limits:

- `AGENT_CAPSULE_HOME=~/.agent-capsule`: persistent state root.
- `AGENT_CAPSULE_SESSION=`: default named session.
- `AGENT_CAPSULE_MEMORY=8g`: container memory limit.
- `AGENT_CAPSULE_CPUS=4`: container CPU limit.
- `AGENT_CAPSULE_PIDS_LIMIT=512`: container process limit.
- `AGENT_CAPSULE_KEEPID=0`: set to `1` to use the host UID and GID inside.
- `AGENT_CAPSULE_OFFLINE=0`: set to `1` to disable container networking.
- `TZ=`: forwarded to the container; when unset, the zone comes from the
  `/etc/localtime` link, so dates and commit times match the host. A path into a
  zoneinfo tree is forwarded as its zone; any other path falls back to the link.

Shared state and mounts:

- `AGENT_CAPSULE_SHARED_RULES=$AGENT_CAPSULE_HOME/CLAUDE.md`: global rules file. Only
  the default is created when missing; any other path must exist.
- `AGENT_CAPSULE_SHARED_RULES_ENABLED=1`: set to `0` to disable global rules.
- `AGENT_CAPSULE_SHARED_RULES_READONLY=1`: set to `0` for a writable rules mount.
- `AGENT_CAPSULE_WORKLOG_PROCEDURE=$AGENT_CAPSULE_HOME/log-work.md`: worklog
  procedure. The default file is used only when it exists; a path set here must
  exist.
- `AGENT_CAPSULE_SHARED_MEMORY_ENABLED=1`: set to `0` to disable Claude project
  memory sharing.
- `AGENT_CAPSULE_SHARED_MEMORY_READONLY=0`: set to `1` for read-only shared memory.
- `AGENT_CAPSULE_SHARE_AUTH=1`: set to `0` to stop sharing the selected credentials
  file across sessions.
- `AGENT_CAPSULE_VAULT=`: the host vault directory that `vault` mounts.
- `AGENT_CAPSULE_VAULT_DEST=/vault`: vault path inside the container.
- `AGENT_CAPSULE_VOLOPT=`: explicit Podman volume option, normally detected from
  SELinux support.
- `AGENT_CAPSULE_CA_CERTS=`: PEM file of private CAs that `ca` trusts inside the
  capsule. See [Private CA](integrations.md#private-ca).
- `AGENT_CAPSULE_GH_USER=`: the host `gh` account whose token `github` hands over; empty
  means `gh`'s active account. See [Profiles](profiles.md).
- `AGENT_CAPSULE_GITLAB_HOST=gitlab.com`: the GitLab instance `--with gitlab` reaches.

## Tool versions and upgrades

Every bundled tool tracks its latest release by default, except the explain-diff
skill, which is pinned to a gist revision. No version updates are required in
agent-capsule itself.

Because "latest" is only true as of a full refresh, the image records when it last
pulled the base image and bypassed the layer cache. It repeats that refresh after
seven days. Cached agent or integration changes preserve the earlier refresh time,
so changing the selection cannot postpone an overdue update. Change the window or
switch it off:

```sh
export AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS=14   # refresh fortnightly
export AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS=0    # never refresh on age alone
```

`agent-capsule --build .` refreshes immediately, whatever the setting.

If an upstream release breaks something, pin that one tool and rebuild:

```sh
export AGENT_CAPSULE_CLAUDE_CODE_VERSION=2.1.234
agent-capsule --build .
```

The variable must stay set on later runs, or the tool goes back to tracking
latest. The available variables are:

```text
AGENT_CAPSULE_CLAUDE_CODE_VERSION
AGENT_CAPSULE_CODEX_VERSION
AGENT_CAPSULE_OPENCODE_VERSION
AGENT_CAPSULE_ANYDOC_VERSION
AGENT_CAPSULE_MCPVAULT_VERSION
AGENT_CAPSULE_SUPERPOWERS_VERSION
AGENT_CAPSULE_GOLANGCI_LINT_VERSION
AGENT_CAPSULE_KUBECTL_VERSION
AGENT_CAPSULE_HELM_VERSION
AGENT_CAPSULE_TALOSCTL_VERSION
AGENT_CAPSULE_GH_VERSION
AGENT_CAPSULE_GLAB_VERSION
```

Superpowers, golangci-lint, kubectl, Helm, talosctl, gh, and glab use Git tags, including
the leading `v`.
`agent-capsule --versions` prints `latest` for everything unpinned.
The default base tags are the floating `node:trixie-slim` and `golang:trixie` tags.
Set `AGENT_CAPSULE_NODE_TAG` or `AGENT_CAPSULE_GO_TAG` to override them.

## State layout

Everything lives under `~/.agent-capsule/`:

```
auth-home/<agent>/       isolated login home for each agent
homes/<session>/         one isolated /home/dev per session
project-memory/<hash>/   per-project memory pooled across sessions (claude only)
CLAUDE.md                global rules mounted into every session, for every agent
log-work.md              worklog procedure, when you write one
skills/<name>/           your own skills, mounted into every session for every agent
plugins/claude/<name>/   your own Claude Code plugins, loaded with --plugin-dir
build/                   image build context
```

Session names may contain letters, digits, dots, underscores, and hyphens, are 1 to
120 characters long, and may not begin with a dot. Other characters are rejected to
prevent different names from sharing the same home.

Linked Git worktrees keep the same absolute working-directory path inside and outside
the container. The repository's common Git directory is mounted at its host path when
it is outside the selected worktree. `/workspace` remains a second project mount for
existing scripts, but worktree commands should run from the default working directory.

### Pruning idle sessions

Session homes are never removed automatically, and each one keeps its own Go and npm
caches. Prune the ones you no longer use:

```sh
agent-capsule --prune-caches              # list caches of sessions idle 30+ days
agent-capsule --prune-caches=7 --yes      # remove them, threshold 7 days
agent-capsule --prune-sessions --yes      # remove whole idle session homes
```

- Without `--yes`, nothing is removed.
- `--prune-caches` removes `.cache`, `.npm` and `go/pkg`. Transcripts, settings and
  `go/bin` stay, so the session can still be resumed.
- `--prune-sessions` removes the whole `homes/<session>/`.
- A session is idle when nothing in its home changed in that many days.
- The prune flags cover every session, so they take no `--session` or project path.
- Sessions with a running container are skipped. If `podman ps` fails, nothing is
  removed.
- `auth-home/`, `project-memory/` and the rules file are never touched.

