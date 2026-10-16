# Upgrading

## Upgrading from 0.3

0.4 splits what the image holds from what a run turns on: the CLIs you list in
`AGENT_CAPSULE_TOOLS` are built in, and `--with` only switches integrations, so it never
rebuilds the image. A typical profile goes from

```sh
export AGENT_CAPSULE_WITH=superpowers,mcpvault,worklog,github,kubernetes
export AGENT_CAPSULE_MOUNT_VAULT=1
export AGENT_CAPSULE_VAULT="$HOME/Notes"
```

to

```sh
export AGENT_CAPSULE_TOOLS=gh,kubernetes
export AGENT_CAPSULE_WITH=superpowers,vault,worklog,github
export AGENT_CAPSULE_VAULT="$HOME/Notes"
```

- `kubernetes` and `talos` are tools now, not integrations. Move them from
  `AGENT_CAPSULE_WITH` to `AGENT_CAPSULE_TOOLS`; in `--with` they fail and say so.
- `github` and `gitlab` need their CLI in the image: add `gh` or `glab` to
  `AGENT_CAPSULE_TOOLS`.
- Each agent has its own image tag, `agent-capsule-dev:<agent>`. Remove the old one with
  `podman rmi agent-capsule-dev:latest`.
- `vault` and `ca` are integrations. Replace `AGENT_CAPSULE_MOUNT_VAULT=1` and
  `mcpvault` with `vault` in `AGENT_CAPSULE_WITH`: `mcpvault` fails as unknown, and the
  variable only prints a notice. `--vault`, `--no-vault` and `--ca` still work for one
  run, and now add to the list instead of replacing it.
- anydoc works with every agent: its skill is linked like explain-diff's instead of
  being loaded as a Claude plugin. `AGENT_CAPSULE_SKILLS_VERSION` is no longer read.
- `--with` errors say "integration" instead of "extra tool": `Unknown integration: NAME`.
- New, nothing to change: your own skills and Claude plugins under `~/.agent-capsule/`
  ([Integrations](integrations.md#your-own-skills-and-plugins)), and `AGENT_CAPSULE_GH_USER`
  for [profiles](profiles.md).

## Upgrading from 0.2

- The config file is gone. `~/.agent-capsule/config` is no longer read, and
  `AGENT_CAPSULE_CONFIG` no longer selects one. Move its contents into `export`
  lines in `~/.bashrc` or `~/.zshrc`, see [Persistent defaults](configuration.md#persistent-defaults).
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

