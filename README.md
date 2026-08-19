<p align="center">
  <img src="logo.png" alt="agent-capsule logo" width="200">
</p>

# agent-capsule

 [![lint](https://github.com/Niahh/agent-capsule/actions/workflows/lint.yml/badge.svg)](https://github.com/Niahh/agent-capsule/actions/workflows/lint.yml)

Run a coding agent, [Claude Code](https://docs.anthropic.com/en/docs/claude-code) by
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
- One reusable image: every supported agent and integration is bundled once.
  `--agent` selects the CLI, and `--with` activates only the requested integrations.
- Defaults you keep: a config file holds your usual add-ons so they are not retyped
  on every run.

## Requirements

- Linux with rootless Podman configured, **or** macOS with Podman (see below)
- `make` for `make install` (or copy the two files manually)

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
                                #    ~/.local/share/agent-capsule/Dockerfile
make install PREFIX=/usr/local  # alternative destination
```

The container image builds automatically on first run and when its Dockerfile, base
tags, or tool version pins change. Agent and integration selection never rebuild it.
Use `--build` to pull the base image and reproduce the selected pins without cache.

## Upgrading from 0.1

Version 0.2 does not change legacy configuration or state automatically. If the
launcher detects a known setting or state path from an earlier release, it stops
before changing files and identifies the item to update. Back up
`~/.agent-capsule` before upgrading.

Update the old configuration and state before launching version 0.2:

- Replace `superclaude` with `superpowers` in `AGENT_CAPSULE_WITH` and `--with`.
  They provide different features, so review the Superpowers workflow before enabling it.
- Remove `hunkdiff` from configuration. It is no longer included.
- Replace `AGENT_CAPSULE_SHARED_CLAUDE_MD` or `AGENT_CAPSULE_SHARED_AGENTS_MD`
  with `AGENT_CAPSULE_SHARED_RULES`. Rename the related `_ENABLED` and `_READONLY`
  variables in the same way.
- Replace the `--shared-claude-md*` flags with their `--shared-rules*` equivalents.
- The launcher now uses one image, `<AGENT_CAPSULE_IMAGE>:latest`. Older `:base`,
  hashed integration, and agent-specific images are not selected or removed automatically.
- Tools are pinned. `--build` reproduces the configured versions instead of selecting
  newer package releases.
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

Bundled tools are pinned, and agent-capsule does not check for newer releases at
startup. Check the configured bundle against the latest stable releases with:

```sh
agent-capsule --check-updates
```

This command needs `curl` and network access. It only prints results. It does not
change configuration or rebuild the image. To use another version, set its version
variable in `~/.agent-capsule/config` and rebuild the image:

```text
AGENT_CAPSULE_CLAUDE_CODE_VERSION=2.1.234
```

```sh
agent-capsule --build .
```

An exported environment variable works too, but it must remain set on later runs or
the configured default becomes the selected pin again. The available variables are:

```text
AGENT_CAPSULE_CLAUDE_CODE_VERSION
AGENT_CAPSULE_CODEX_VERSION
AGENT_CAPSULE_OPENCODE_VERSION
AGENT_CAPSULE_ANYDOC_VERSION
AGENT_CAPSULE_MCPVAULT_VERSION
AGENT_CAPSULE_SKILLS_VERSION
AGENT_CAPSULE_SUPERPOWERS_VERSION
AGENT_CAPSULE_GOLANGCI_LINT_VERSION
```

Superpowers and golangci-lint use Git tags, including the leading `v`.
Removing an override returns that package to the version shipped by the installed
agent-capsule release. Use `agent-capsule --versions` to inspect the selected pins.

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
agent-capsule . -- -p "explain this repo"       # args after -- go to the agent
agent-capsule --agent codex --auth-login        # once: log in to Codex instead
agent-capsule --agent codex ~/code/myapp        # run Codex CLI in a capsule on a project
```

## Agents

Claude Code is the default. `--agent codex` runs the OpenAI Codex CLI and `--agent
opencode` runs [opencode](https://opencode.ai); `AGENT_CAPSULE_AGENT` sets the same
default from the config file, and `--agent list` prints the known agents.

All agents use one image. Each gets its own default session per project and its own
login: run `agent-capsule --agent NAME --auth-login` once. Credentials live under
separate agent directories, and only the selected agent's credential file is mounted
into a session. The global rules file is the same for every agent, mounted as `CLAUDE.md`
for claude and `AGENTS.md` for Codex and opencode. A session home stays bound to the
agent that created it.

The `superpowers` integration activates the bundled
[Superpowers](https://github.com/obra/superpowers) checkout through each agent's
plugin mechanism. It does not need network access to load after the image is built.

The `explain-diff` integration activates Geoffrey Litt's
[HTML diff explanation skill](https://gist.github.com/geoffreylitt/a29df1b5f9865506e8952488eac3d524)
for Claude Code, Codex, and OpenCode. The skill writes a self-contained interactive
HTML explanation to `/tmp`.

The launcher forwards `SUPERPOWERS_DISABLE_TELEMETRY`, `DISABLE_TELEMETRY`, and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` when those variables are set on the host.
Their values are not placed in the Podman command line.

Differences under opencode: per-project memory is unavailable (it is a Claude Code
mechanism), Superpowers and MCP servers use invocation-scoped configuration, and the
claude-only `anydoc` integration is rejected. User-owned OpenCode configuration files
are left untouched. A config marker created by agent-capsule 0.2.0 triggers the legacy
preflight and must be handled using the upgrade instructions above.

Codex also has no shared Claude memory. Its `--auth-login` defaults to device-code
authentication because its browser callback stays inside the container. Custom login
arguments after `--` replace that default, and mcpvault uses Codex configuration
overrides.

## Flags at a glance

| Flag                                             | Effect                                                                             |
|--------------------------------------------------|------------------------------------------------------------------------------------|
| `--build`                                        | rebuild without cache and pull the configured base image                           |
| `--check-updates`                                | compare configured tool versions with upstream stable releases                     |
| `--shell`                                        | start bash instead of the agent                                                    |
| `--keep-id`                                      | run as your UID inside too (needed for `--dangerously-skip-permissions`)           |
| `--offline`                                      | no network inside the container                                                    |
| `--auth-login`                                   | authenticate the selected agent in its isolated auth home                          |
| `--agent NAME`                                   | pick the agent (`claude` default, `codex`, `opencode`); `list` prints them         |
| `--session NAME`                                 | named per-session home, for parallel agents on one repo                            |
| `--with TOOL[,TOOL]`                             | activate bundled integrations (`superpowers`, `explain-diff`, `mcpvault`, `anydoc`); `list`, `none` |
| `--mount SRC[:DEST][:ro]`                        | extra file or directory bind mounts (repeatable)                                   |
| `--vault[=PATH]`                                 | mount a configured vault read-write; `=PATH` picks it for one run                    |
| `--no-vault`                                     | skip the vault (and mcpvault) for one run, overriding the config file              |
| `--shared-memory-ro`, `--no-shared-memory`       | restrict or disable pooled per-project memory (claude only)                        |
| `--shared-rules PATH`                            | use a specific global rules file                                                   |
| `--shared-rules-rw`, `--no-shared-rules`         | writable or disabled global rules file                                              |
| `--version`                                      | print the version and exit                                                         |
| `--versions`                                     | print the pinned tool bundle and exit                                              |

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

Or set it once in `~/.agent-capsule/config`, after which plain `agent-capsule .`
does it all with no flags:

```
AGENT_CAPSULE_WITH=mcpvault
AGENT_CAPSULE_MOUNT_VAULT=1
AGENT_CAPSULE_VAULT=/home/you/Documents/Obsidian/MyVault
```

Notes:

- Only the `=` form takes a path: a bare `--vault` requires `AGENT_CAPSULE_VAULT`,
  and `--vault ~/dir` reads `~/dir` as the project. The shell does not expand `~`
  after `=`, so write `--vault="$HOME/Work"`.
- The generated config goes to the session home and reaches Claude Code through
  `--mcp-config`, so a project's own `.mcp.json` still loads. OpenCode receives the
  server through invocation-scoped configuration, so user config files stay intact.
  Codex receives configuration overrides layered over its existing `config.toml`.

## Configuration file

`~/.agent-capsule/config` (or `AGENT_CAPSULE_CONFIG=/some/path`) holds defaults, so the
integrations you always want are not retyped on every run:

```
# ~/.agent-capsule/config
AGENT_CAPSULE_WITH=superpowers,mcpvault
AGENT_CAPSULE_MOUNT_VAULT=1
AGENT_CAPSULE_VAULT=/home/you/Documents/Obsidian/MyVault
AGENT_CAPSULE_KEEPID=1
```

One `KEY=value` per line, `#` comments and blank lines ignored. Values may use matching
single or double quotes. Only `AGENT_CAPSULE_*` keys are accepted, and the file is
parsed rather than sourced, so it cannot run commands.

Precedence is command-line flag > environment > config file > built-in default. A
command-line `--with` replaces the configured list instead of adding to it,
`--with none` selects nothing, and `--no-vault` skips the vault for a single run.

## State layout

Everything lives under `~/.agent-capsule/`:

```
config                   optional defaults for the AGENT_CAPSULE_* settings
auth-home/<agent>/       isolated login home for each agent
homes/<session>/         one isolated /home/dev per session
project-memory/<hash>/   per-project memory pooled across sessions (claude only)
CLAUDE.md                global rules mounted into every session, for every agent
build/                   image build context
```

Session names may contain letters, digits, dots, underscores, and hyphens. Other
characters are rejected to prevent different names from sharing the same home.

Linked Git worktrees keep the same absolute working-directory path inside and outside
the container. The repository's common Git directory is mounted at its host path when
it is outside the selected worktree. `/workspace` remains a second project mount for
existing scripts, but worktree commands should run from the default working directory.

## Command help

`agent-capsule --help` prints a short option summary. This README is the detailed
reference. Defaults can be overridden with `AGENT_CAPSULE_*` environment variables,
including image name, base tags, resource limits, paths, and volume options.

## License

MIT, see [LICENSE](LICENSE).

## Contributors

| Name                                               | Contribution                                                                  |
|----------------------------------------------------|-------------------------------------------------------------------------------|
| [@linouxis9](https://github.com/linouxis9)         | Original script concept                                                       |
| [@Niahh](https://github.com/Niahh)                 | Core launcher, multi-agent support, universal image, integrations, and tests |
| [@alcelafranque](https://github.com/alcelafranque) | Nix flake, dev shell, and CI check                                            |
| [@citizen8](https://github.com/citizen8)           | macOS support in the Nix flake                                                |
