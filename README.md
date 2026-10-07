<p align="center">
  <img src="logo.png" alt="agent-capsule logo" width="200">
</p>

# agent-capsule

[![lint][lint-badge]][lint-workflow]

Run a coding agent, [Claude Code](https://code.claude.com/docs) by
default, [OpenAI Codex CLI](https://github.com/openai/codex), or
[opencode](https://opencode.ai), inside a rootless
[Podman](https://podman.io/) container that shares a single project directory with the host.

One shell script, one Dockerfile. The container uses the project's resolved host path
as its working directory and also exposes it at `/workspace` for compatibility. It
gets an isolated home at `/home/dev`, a Node and Go toolchain, and hard resource
limits. Everything else on the host stays out of reach.

## What you get

- Rootless containment: container root maps to your host UID, so files written in
  the project are owned by you. All capabilities dropped, no-new-privileges,
  memory/CPU/pids limits.
- One login for all sessions: authenticate once per agent with `--auth-login`
  (`--agent codex --auth-login` for Codex); the selected credentials file is
  live-shared into every session for that agent, token refreshes included.
- Isolated sessions: each project or named session gets its own `/home/dev`, so
  parallel agents do not trample each other's transcripts or settings.
- Shared knowledge: one global rules file (`~/.agent-capsule/CLAUDE.md`) is mounted
  into every session at the agent's expected path, and Claude's per-project memory
  is pooled across sessions and linked worktrees of the same repo.
- Nothing you did not ask for: the image holds the agent `--agent` picked and the
  integrations `--with` activated, and rebuilds when that selection changes.
- Defaults you keep: exported `AGENT_CAPSULE_*` variables hold your usual add-ons
  so they are not retyped on every run.

## Requirements

- Linux with rootless Podman configured, **or** macOS with Podman (see below)
- `make` for `make install` (or copy `agent-capsule`, `Dockerfile`,
  `entrypoint.sh`, and the `plugins/` directory manually)

### macOS

Podman on macOS runs containers inside a Linux VM, so every host path
agent-capsule bind-mounts has to actually be visible inside that VM. A plain
init covers the common case, since `podman machine init` already mounts
`$HOME:$HOME` by default, which is where agent-capsule keeps everything
(project checkouts, `~/.agent-capsule/`, credentials):

```sh
podman machine init
podman machine start
```

If `agent-capsule` was installed via Nix (nix-darwin, `nix profile install`,
`nix build`, etc.), also mount `/nix/store`. The closures of any Nix-built
tools bind-mounted into the container with `--mount` need to be visible to the
VM. Passing any `--volume` at all replaces Podman's implicit
default instead of adding to it, so `$HOME:$HOME` must be listed explicitly
too. `--volume` also can't be added to an already-created machine, so get
both in from the start:

```sh
podman machine init --volume $HOME:$HOME --volume /nix/store:/nix/store:ro
podman machine start
```

Leaving out `$HOME:$HOME` breaks the launch, since agent-capsule bind-mounts
`PROJECT_DIR` itself (plus `~/.agent-capsule/` and the auth home) under
`$HOME`: `Error: statfs /Users/.../your-project: no such file or directory`.

## Install

```sh
make install                    # -> ~/.local/bin/agent-capsule
                                #    ~/.local/share/agent-capsule/{Dockerfile,entrypoint.sh,plugins/}
make install PREFIX=/usr/local  # alternative destination
```

The image builds on first run and again whenever the selection changes, because it
contains only the agent and integrations the run asked for. Switching back is
usually seconds: the layers of a combination you have built before are cached, so
only the first build of each is slow. Each rebuild also removes the untagged image
it replaced, which `AGENT_CAPSULE_PRUNE=0` disables. Podman keeps shared layers and
cannot remove an old image while a running container still uses it, so the guarantee
is one tagged runnable image rather than one physical object in container storage.

It also performs a full rebuild once the last no-cache refresh is more than seven
days old, to pick up new tool releases. See
[Tool versions and upgrades](#tool-versions-and-upgrades). Use `--build` to rebuild
from scratch at any time.

## Upgrading from 0.2

- The config file is gone. `~/.agent-capsule/config` is no longer read, and
  `AGENT_CAPSULE_CONFIG` no longer selects one. Move its contents into `export`
  lines in `~/.bashrc` or `~/.zshrc`, see [Persistent defaults](#persistent-defaults).
  A leftover file is inert, not an error.
- `--check-updates` is removed. Nothing is pinned to compare against.
- Tools are no longer pinned by default. Every tool tracks its latest release and
  the image refreshes weekly; `AGENT_CAPSULE_*_VERSION` pins one if needed.
- The image is built for one agent and one set of integrations, so `--agent` and
  `--with` now rebuild it. Each rebuild prunes the image it replaced.
- The legacy `--shared-claude-md*` flags and the `superclaude` and `hunkdiff`
  integrations are no longer recognised by name; they fail as an unknown option
  and an unknown extra.
- Session names may no longer begin with a dot.

## Upgrading from 0.1

Version 0.3 does not change legacy configuration or state automatically. The
launcher stops before changing files if it finds the 0.1 shared authentication
home at `auth-home/.claude`, which would otherwise mix two agents' credentials.
Every other item below is inert rather than detected, so work through the list.
Back up `~/.agent-capsule` before upgrading.

Update the old configuration and state before launching version 0.3:

- Replace `superclaude` with `superpowers` in `AGENT_CAPSULE_WITH` and `--with`.
  They provide different features, so review the Superpowers workflow before enabling it.
- Remove `hunkdiff` from configuration. It is no longer included.
- Replace `AGENT_CAPSULE_SHARED_CLAUDE_MD` or `AGENT_CAPSULE_SHARED_AGENTS_MD`
  with `AGENT_CAPSULE_SHARED_RULES`. Rename the related `_ENABLED` and `_READONLY`
  variables in the same way.
- Replace the `--shared-claude-md*` flags with their `--shared-rules*` equivalents.
- The launcher uses one tag, `<AGENT_CAPSULE_IMAGE>:latest`, rebuilt per selection.
  Older `:base` and hashed integration images are never selected again; remove them
  with `podman rmi`.
- Credentials now live in `auth-home/<agent>/`. Move the legacy root entries
  (`.claude`, `.claude.json`, `.codex`, and `.local/share/opencode/auth.json`)
  out of `auth-home/`, then authenticate each agent again with
  `--agent NAME --auth-login`.
- Session homes now carry an agent marker. Move unmarked 0.1 homes out of `homes/`,
  or choose a new `--session` name. Unnamed Codex sessions use a `-codex` suffix.
- Move any capsule-managed OpenCode `opencode.json` and its
  `.opencode.json.capsule` marker out of the old session home.
- `CLAUDE.md` is now the default global rules file for every agent. Merge an existing
  `~/.agent-capsule/AGENTS.md` into it, then move the old file out of the config directory.
- The container starts in the project's resolved host path. `/workspace` remains
  available for scripts that require the old path.

## Tool versions and upgrades

Every bundled tool tracks its latest release by default. No version updates are
required in agent-capsule itself.

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
AGENT_CAPSULE_SKILLS_VERSION
AGENT_CAPSULE_SUPERPOWERS_VERSION
AGENT_CAPSULE_GOLANGCI_LINT_VERSION
AGENT_CAPSULE_KUBECTL_VERSION
AGENT_CAPSULE_HELM_VERSION
AGENT_CAPSULE_TALOSCTL_VERSION
AGENT_CAPSULE_GH_VERSION
```

Superpowers, golangci-lint, kubectl, Helm, talosctl, and gh use Git tags, including the
leading `v`.
`agent-capsule --versions` prints `latest` for everything unpinned.
The default base tags are the floating `node:trixie-slim` and `golang:trixie` tags.
Set `AGENT_CAPSULE_NODE_TAG` or `AGENT_CAPSULE_GO_TAG` to override them.

## Quick start

```sh
agent-capsule --auth-login          # once: log in, credentials are shared afterwards
agent-capsule ~/code/myapp          # run Claude Code in a capsule on a project
agent-capsule --shell .             # a shell inside the capsule instead of the agent
agent-capsule --agent opencode .    # run opencode instead of Claude Code
agent-capsule --session fix-auth ~/code/myapp   # named session for parallel agents
agent-capsule --with superpowers .              # activate bundled development skills
agent-capsule --with explain-diff .             # explain a change as interactive HTML
agent-capsule --with mcpvault --vault="$HOME/Notes" .  # Obsidian vault over MCP
agent-capsule --with mcpvault,worklog --vault="$HOME/Notes" .   # log significant work
agent-capsule --with kubernetes,talos .         # add kubectl, helm, and talosctl
agent-capsule --with github .                   # gh with the host gh login, git over HTTPS
agent-capsule . -- -p "explain this repo"       # args after -- go to the agent
agent-capsule --agent codex --auth-login        # once: log in to Codex instead
agent-capsule --agent codex ~/code/myapp        # run Codex CLI in a capsule on a project
```

## Agents

Claude Code is the default. `--agent codex` runs the OpenAI Codex CLI and `--agent
opencode` runs [opencode](https://opencode.ai); `AGENT_CAPSULE_AGENT` sets the same
default, and `--agent list` prints the known agents.

Only the selected agent's CLI is installed, so `--agent` rebuilds the image. Each
agent gets its own default session per project and its own
login: run `agent-capsule --agent NAME --auth-login` once. Credentials live under
separate agent directories, and only the selected agent's credential file is mounted
into a session. The global rules file is the same for every agent, mounted as `CLAUDE.md`
for claude and `AGENTS.md` for Codex and opencode. A session home stays bound to the
agent that created it.

The `superpowers` integration activates the [Superpowers](https://github.com/obra/superpowers)
checkout through each agent's plugin mechanism. It is cloned into the image when
selected, so it needs no network access to load afterwards.

The `explain-diff` integration activates Geoffrey Litt's
[HTML diff explanation skill](https://gist.github.com/geoffreylitt/a29df1b5f9865506e8952488eac3d524)
for Claude Code, Codex, and OpenCode. The skill writes a self-contained interactive
HTML explanation to `/tmp`.

The launcher forwards `SUPERPOWERS_DISABLE_TELEMETRY`, `DISABLE_TELEMETRY`, and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` when those variables are set on the host.
Their values are not placed in the Podman command line.

Differences under opencode: per-project memory is unavailable (it is a Claude Code
mechanism), Superpowers and MCP servers use invocation-scoped configuration, and the
claude-only `anydoc` and `worklog` integrations are rejected. User-owned OpenCode
configuration files are left untouched.

Codex also has no shared Claude memory. Its `--auth-login` defaults to device-code
authentication because its browser callback stays inside the container. Custom login
arguments after `--` replace that default, and mcpvault uses Codex configuration
overrides.

## Flags at a glance

- `--agent NAME`: use `claude`, `codex`, or `opencode`; `list` prints the choices.
- `--session NAME`: use a named per-session home.
- `--auth-login`: authenticate the selected agent in its isolated auth home.
- `--shell`: start Bash instead of the agent.
- `--offline`: disable container networking.
- `--keep-id`: use the host UID and GID inside the container.
- `--with TOOL[,TOOL]`: activate integrations; `list` prints them and `none` clears
  the selection.
- `--mount SRC[:DEST][:ro]`: add a file or directory bind mount; repeat as needed.
- `--ca`: trust the private CAs in `AGENT_CAPSULE_CA_CERTS` for this run.
- `--vault[=PATH]`: mount the configured vault read-write, or select one with
  `=PATH`.
- `--no-vault`: disable the vault and mcpvault for one run.
- `--shared-memory-ro`: mount Claude project memory read-only.
- `--no-shared-memory`: disable Claude project memory.
- `--shared-rules PATH`: select the global rules file.
- `--shared-rules-rw`: mount the global rules file read-write.
- `--no-shared-rules`: disable the global rules file.
- `--build`: pull the base image and rebuild without the layer cache.
- `--prune-caches[=DAYS]`: list caches of sessions idle 30+ days, or `DAYS`.
- `--prune-sessions[=DAYS]`: list whole sessions idle 30+ days, or `DAYS`.
- `--yes`: remove what the prune flag lists.
- `--version`: print the launcher version.
- `--versions`: print each configured tool pin, or `latest` when unpinned.

## Obsidian vault over MCP

`--vault` mounts your Obsidian vault at `/vault` by default. Adding
`--with mcpvault` registers the bundled
[mcpvault](https://github.com/bitbonsai/mcpvault) as the MCP server
`obsidian`, so the selected agent searches and edits notes through tools rather than
raw file reads.

mcpvault requires the vault path to be chosen explicitly, since the server gets
read-write access to everything under it:

```sh
agent-capsule --with mcpvault --vault="$HOME/Work" .   # for one run
```

Or export it once from your shell profile, after which plain `agent-capsule .`
does it all with no flags:

```sh
export AGENT_CAPSULE_WITH=mcpvault
export AGENT_CAPSULE_MOUNT_VAULT=1
export AGENT_CAPSULE_VAULT="$HOME/Documents/Obsidian/MyVault"
```

Notes:

- Only the `=` form takes a path: a bare `--vault` requires `AGENT_CAPSULE_VAULT`,
  and `--vault ~/dir` reads `~/dir` as the project. The shell does not expand `~`
  after `=`, so write `--vault="$HOME/Work"`.
- The generated config goes to the session home and reaches Claude Code through
  `--mcp-config`, so a project's own `.mcp.json` still loads. OpenCode receives the
  server through invocation-scoped configuration, so user config files stay intact.
  Codex receives configuration overrides layered over its existing `config.toml`.

## Work log in Obsidian

`--with mcpvault,worklog` makes Claude Code write up significant work in your vault.
After each turn that changes files in a git repository, the session gets one extra turn
to update the note that documents the work and to tick an entry in today's note.
It needs `mcpvault`, and so a vault, and it is available only with claude.

```sh
agent-capsule --with mcpvault,worklog --vault="$HOME/Notes" .   # for one run
export AGENT_CAPSULE_WITH=mcpvault,worklog                      # or by default
```

The built-in procedure learns your vault's conventions from its README or index notes.
To use your own, write `~/.agent-capsule/log-work.md`, or point the variable at a file:

```sh
export AGENT_CAPSULE_WORKLOG_PROCEDURE="$HOME/notes/log-work.md"
```

The file is mounted read-only at `/etc/agent-capsule/log-work.md`. A path set in the
variable must exist. The default path is used only when the file exists, and is never
created. The startup banner shows which procedure is active.

- `/worklog:log-work [what]` logs by hand, whatever the last turn changed.
- Put `#no-doc` in a prompt to skip logging for that turn.
- The hook sees changed files only. It does not see ops commands that change no file,
  other repositories, or directories that are not in git.
- Its worktree snapshots live in `~/.cache/worklog/` in the session home, not in the
  repository.
- In non-interactive `-p` runs the printed result can be the log reply rather than
  the answer, so leave `worklog` out of `--with` for those runs.

## Kubernetes and Talos

`--with kubernetes` installs `kubectl` and `helm`, and `--with talos` installs
`talosctl`. Both work with every agent. Their configuration stays on the host until
you mount it:

```sh
agent-capsule --with kubernetes,talos \
  -m ~/.kube/config:/home/dev/.kube/config:ro \
  -m ~/.talos/config:/home/dev/.talos/config:ro .
```

To keep them in every session, add them to `AGENT_CAPSULE_WITH`, see
[Persistent defaults](#persistent-defaults).

The cluster must be reachable from the container, so these commands fail under
`--offline`. A kubeconfig that calls an exec credential plugin also needs that plugin
inside the image.

## GitHub

`--with github` installs `gh` and lends it the host's `gh` login. Log in once on the
host, where `gh` keeps the token in the system keyring:

```sh
gh auth login --scopes workflow      # on the host
agent-capsule --with github .
```

- The launcher reads the token with `gh auth token` and passes it through a file in
  `$XDG_RUNTIME_DIR`, which is in memory. The entrypoint moves it into `GH_TOKEN` and
  deletes the file before the agent starts. If the container never starts, the next
  launch deletes it. Without `$XDG_RUNTIME_DIR`, as on macOS, the file is in `$TMPDIR`
  instead, which is on disk.
- It is not passed with `-e`, because podman stores those values in the container
  config on disk.
- Inside the capsule, `git@github.com:` and `ssh://git@github.com/` remotes go over
  HTTPS, with `gh` as the credential helper. This is set per run through
  `GIT_CONFIG_*` variables. The repository and the session home are not changed.
- `workflow` lets pushes change `.github/workflows/`. GitHub rejects them without it.
- Without `github`, the session gets no token, no `gh` and no git rewrite.

The agent can read `GH_TOKEN`, and the token can reach every repository your account
can. Protect the branches that matter. The launcher warns when the host `gh` stores
its token in plain text, which it does when no keyring is available.

## Private CA

To reach self-hosted resources whose certificates come from a private CA, name the CA
in PEM form and pass `--ca` to the runs that need it:

```sh
export AGENT_CAPSULE_CA_CERTS=/usr/local/share/ca-certificates/corp-root.crt
agent-capsule --ca .
```

- The variable alone mounts nothing, so it is safe to export from a shell profile.
  Only a run started with `--ca` gets the certificates, and only it trusts the CA.
- The file can hold several certificates. Only the certificate blocks cross over, so
  a private key kept in the same file stays on the host.
- The certificates are copied to `$XDG_RUNTIME_DIR`, which is in memory, and mounted
  into the capsule. They are never built into the image. The first launch after the
  session ends deletes the copy. Without `$XDG_RUNTIME_DIR`, as on macOS, the copy is
  in `$TMPDIR` instead, which is on disk.
- The entrypoint writes a bundle of the system CAs plus yours next to them, and
  points `SSL_CERT_FILE` (curl, and Go tools such as `gh` and `kubectl`),
  `GIT_SSL_CAINFO` (git) and `NODE_EXTRA_CA_CERTS` (Node) at it. `/etc` is not
  changed, so this works as root and under `--keep-id`.
- A client that reads none of these, or ships its own CA list, does not trust the CA.

## Persistent defaults

Every setting is an `AGENT_CAPSULE_*` environment variable. To stop retyping the
integrations you always want, export them from `~/.bashrc` or `~/.zshrc`:

```sh
export AGENT_CAPSULE_WITH=superpowers,mcpvault
export AGENT_CAPSULE_MOUNT_VAULT=1
export AGENT_CAPSULE_VAULT="$HOME/Documents/Obsidian/MyVault"
export AGENT_CAPSULE_KEEPID=1
```

Precedence is command-line flag > environment > built-in default. A command-line
`--with` replaces the exported list instead of adding to it, `--with none` selects
nothing, and `--no-vault` skips the vault for a single run.

A one-off run does not need an export: `AGENT_CAPSULE_AGENT=codex agent-capsule .`
works, because the launcher reads the variable from its own environment.

### Environment reference

Selection and image lifecycle:

- `AGENT_CAPSULE_AGENT=claude`: default agent (`claude`, `codex`, or `opencode`).
- `AGENT_CAPSULE_WITH=`: comma-separated default integrations.
- `AGENT_CAPSULE_IMAGE=agent-capsule-dev`: image name or full tagged reference.
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
  `/etc/localtime` link, so dates and commit times match the host.

Shared state and mounts:

- `AGENT_CAPSULE_SHARED_RULES=~/.agent-capsule/CLAUDE.md`: global rules file.
- `AGENT_CAPSULE_SHARED_RULES_ENABLED=1`: set to `0` to disable global rules.
- `AGENT_CAPSULE_SHARED_RULES_READONLY=1`: set to `0` for a writable rules mount.
- `AGENT_CAPSULE_WORKLOG_PROCEDURE=~/.agent-capsule/log-work.md`: worklog
  procedure. The default file is used only when it exists; a path set here must
  exist.
- `AGENT_CAPSULE_SHARED_MEMORY_ENABLED=1`: set to `0` to disable Claude project
  memory sharing.
- `AGENT_CAPSULE_SHARED_MEMORY_READONLY=0`: set to `1` for read-only shared memory.
- `AGENT_CAPSULE_SHARE_AUTH=1`: set to `0` to stop sharing the selected credentials
  file across sessions.
- `AGENT_CAPSULE_VAULT=`: default host vault directory.
- `AGENT_CAPSULE_VAULT_DEST=/vault`: vault path inside the container.
- `AGENT_CAPSULE_MOUNT_VAULT=0`: set to `1` to mount the configured vault by default.
- `AGENT_CAPSULE_VOLOPT=`: explicit Podman volume option, normally detected from
  SELinux support.
- `AGENT_CAPSULE_CA_CERTS=`: PEM file of private CAs that `--ca` trusts inside the
  capsule. See [Private CA](#private-ca).

## State layout

Everything lives under `~/.agent-capsule/`:

```
auth-home/<agent>/       isolated login home for each agent
homes/<session>/         one isolated /home/dev per session
project-memory/<hash>/   per-project memory pooled across sessions (claude only)
CLAUDE.md                global rules mounted into every session, for every agent
log-work.md              worklog procedure, when you write one
build/                   image build context
```

Session names may contain letters, digits, dots, underscores, and hyphens. Other
characters are rejected to prevent different names from sharing the same home.

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

## Shell completion

Completion applies to the host shell where `agent-capsule` is invoked. It runs
before the container starts.

`make install` places both completion files under the selected prefix:

```
$PREFIX/share/bash-completion/completions/agent-capsule
$PREFIX/share/zsh/site-functions/_agent-capsule
```

The installer checks the configured shell in `$SHELL`. It reports whether the
installed completion is active and prints the relevant setup commands when it
is not.

### Bash

Bash completion frameworks normally discover the installed file. If completion
is not active, add this to `~/.bashrc` with the default `PREFIX`:

```sh
source "$HOME/.local/share/bash-completion/completions/agent-capsule"
```

Start a new shell and verify registration:

```sh
exec bash
complete -p agent-capsule
```

### Zsh

The completion directory must be on `$fpath` before `compinit` runs. Add these
lines to `~/.zshrc` with the default `PREFIX`:

```sh
fpath=("$HOME/.local/share/zsh/site-functions" $fpath)
autoload -Uz compinit && compinit
```

Start a new shell and verify discovery:

```sh
exec zsh
whence -w _agent-capsule
```

Do not source `completions/agent-capsule.bash` from Zsh. If it was loaded in the
current Zsh session, remove its functions before restarting:

```sh
unfunction _agent_capsule _agent_capsule_sessions \
  _agent_capsule_extras _agent_capsule_comma_list 2>/dev/null
```

Agents, integrations and sessions are completed from live data: the first two
come from `agent-capsule --agent list` and `agent-capsule --with list`, the third
from the session homes that exist. `--with` completes one element at a time after
each comma and drops what you have already picked, and `anydoc` and `worklog`
disappear once `--agent codex` or `--agent opencode` is on the line.

## Command help

`agent-capsule --help` prints a short option summary. This README is the detailed
reference. Defaults can be overridden with `AGENT_CAPSULE_*` environment variables,
including image name, base tags, resource limits, paths, and volume options.

## License

MIT, see [LICENSE](LICENSE).

## Contributors

- [@linouxis9](https://github.com/linouxis9): original script concept.
- [@Niahh](https://github.com/Niahh): core launcher, multi-agent support, image,
  integrations, and tests.
- [@alcelafranque](https://github.com/alcelafranque): Nix flake, dev shell, and CI.
- [@citizen8](https://github.com/citizen8): macOS support in the Nix flake.

[lint-badge]: https://github.com/Niahh/agent-capsule/actions/workflows/lint.yml/badge.svg
[lint-workflow]: https://github.com/Niahh/agent-capsule/actions/workflows/lint.yml
