# Integrations

## Superpowers

The `superpowers` integration activates the [Superpowers](https://github.com/obra/superpowers)
checkout through each agent's plugin mechanism. It is cloned into the image when
selected, so it needs no network access to load afterwards.

## explain-diff

The `explain-diff` integration activates Geoffrey Litt's
[HTML diff explanation skill](https://gist.github.com/geoffreylitt/a29df1b5f9865506e8952488eac3d524)
for Claude Code, Codex, and OpenCode. The skill writes a self-contained interactive
HTML explanation to `/tmp`.

## anydoc

The `anydoc` integration links the
[document conversion skill](https://github.com/firecrawl/anydoc/tree/main/skills/convert-documents-to-markdown)
of firecrawl's anydoc into the agent's skills dir, for every agent. It converts Word,
PowerPoint, Excel, OpenDocument, RTF, EPUB, CSV and PDF files to Markdown. The image
also holds the `anydoc` CLI, but the skill calls `npx -y @firecrawl/anydoc`, which
fetches its own copy on first use, so the skill needs the network.

## Obsidian vault over MCP

The `vault` integration mounts your Obsidian vault at `/vault` and registers the bundled
[mcpvault](https://github.com/bitbonsai/mcpvault) as the MCP server `obsidian`, so the
selected agent searches and edits notes through tools rather than raw file reads.

The vault path is chosen explicitly, since the server gets read-write access to
everything under it. For one run, `--vault=PATH` names it and turns the vault on:

```sh
agent-capsule --vault="$HOME/Work" .
```

Or export it once from your shell profile, after which plain `agent-capsule .`
does it all with no flags:

```sh
export AGENT_CAPSULE_WITH=vault
export AGENT_CAPSULE_VAULT="$HOME/Documents/Obsidian/MyVault"
```

Notes:

- `--vault` and `--vault=PATH` add `vault` to the run, and `--no-vault` takes it out,
  without replacing the rest of the list. Only the `=` form takes a path: a bare
  `--vault` requires `AGENT_CAPSULE_VAULT`, and `--vault ~/dir` reads `~/dir` as the
  project. The shell does not expand `~`
  after `=`, so write `--vault="$HOME/Work"`.
- The generated config goes to the session home and reaches Claude Code through
  `--mcp-config`, so a project's own `.mcp.json` still loads. OpenCode receives the
  server through invocation-scoped configuration, so user config files stay intact.
  Codex receives configuration overrides layered over its existing `config.toml`.

## Work log in Obsidian

`--with worklog` makes Claude Code write up significant work in your vault.
After each turn that changes files in a git repository, the session gets one extra turn
to update the note that documents the work and to tick an entry in today's note.
It needs `vault`, and it is available only with claude.

```sh
agent-capsule --with worklog --vault="$HOME/Notes" .   # for one run
export AGENT_CAPSULE_WITH=vault,worklog                 # or by default
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
  repository. Those of sessions idle for a week are removed by the next snapshot.
- Uncommitted edits inside git submodules are not seen; a new submodule commit is.
- When HEAD moves during a turn, as after a pull, merge or checkout, the request says
  so, so that work brought in by git is left out.
- In non-interactive `-p` runs the printed result can be the log reply rather than
  the answer, so leave `worklog` out of `--with` for those runs.

## Kubernetes and Talos

The `kubernetes` tool installs `kubectl` and `helm`, and the `talos` tool installs
`talosctl`. List them in `AGENT_CAPSULE_TOOLS`; the next launch rebuilds the image once.
Both work with every agent. Their configuration stays on the host until you mount it:

```sh
export AGENT_CAPSULE_TOOLS=kubernetes,talos
agent-capsule -m ~/.kube/config:/home/dev/.kube/config:ro \
  -m ~/.talos/config:/home/dev/.talos/config:ro .
```

To mount the configs in every session as well, see
[Persistent defaults](configuration.md#persistent-defaults).

The cluster must be reachable from the container, so these commands fail under
`--offline`. A kubeconfig that calls an exec credential plugin also needs that plugin
inside the image.

## GitHub

`--with github` lends `gh` the host's `gh` login, so it needs the `gh` tool in the image.
Log in once on the host, where `gh` keeps the token in the system keyring:

```sh
gh auth login --scopes workflow      # on the host
export AGENT_CAPSULE_TOOLS=gh
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
- Without `github`, the session gets no token and no git rewrite. The `gh` tool alone is
  logged out.

The agent can read `GH_TOKEN`, and the token can reach every repository your account
can. Protect the branches that matter. The launcher warns when the host `gh` stores
its token in plain text, which it does when no keyring is available.

## GitLab

`--with gitlab` lends `glab` the host's `glab` login for one instance, so it needs the
`glab` tool in the image. The instance is `gitlab.com`, or the one
`AGENT_CAPSULE_GITLAB_HOST` names. Log in once on the host with a personal access token
that has the `api` and `write_repository` scopes:

```sh
glab auth login --hostname gitlab.example.com      # on the host, paste the token
export AGENT_CAPSULE_TOOLS=glab
export AGENT_CAPSULE_GITLAB_HOST=gitlab.example.com
agent-capsule --with gitlab .
```

- The launcher reads the token with `glab config get token`, which also reads the
  system keyring. It writes it into a `glab` config in `$XDG_RUNTIME_DIR`, which is in
  memory, mounted at `/run/agent-capsule/glab` with `GLAB_CONFIG_DIR` pointing there.
  The first launch after the session ends deletes it. Without `$XDG_RUNTIME_DIR`, as
  on macOS, the config is in `$TMPDIR` instead, which is on disk.
- The config binds the token to the instance. It is not passed as `GITLAB_TOKEN`,
  because `glab` sends that variable to any host a command names, such as
  `--hostname gitlab.com` or `-R https://gitlab.com/group/project`. For the same
  reason, a `GITLAB_TOKEN` exported on the host is never handed over: only the stored
  login for the instance is.
- An OAuth login (`--web` or `--device`) is not passed on. Its token expires within
  two hours, and refreshing it in the capsule would log the host out.
- `GITLAB_HOST` points `glab` at the instance outside a repository. Inside one whose
  remotes are on another host, `glab` refuses to run.
- Remotes on the instance go over HTTPS with `glab` as the credential helper, set per
  run like the GitHub ones.
- A private CA for self-hosted resources is trusted with `ca`: see [Private CA](#private-ca).
- Without `gitlab`, the session gets no token and no git rewrite. The `glab` tool alone is
  logged out.
- When the host login is handed over, `glab` settings changed inside the capsule last
  only for the session.
- The image sets `GLAB_SEND_TELEMETRY=false`, so `glab` does not report each command
  to the instance.

The agent can read the token in `/run/agent-capsule/glab/config.yml`, and the token can
reach every project your account can. A project or group access token limits that.
The launcher warns when the host `glab` keeps a token in plain text, which it does
when no keyring is available.

## Private CA

To reach self-hosted resources whose certificates come from a private CA, name the CA
in PEM form and turn on the `ca` integration for the runs that need it, with `--ca` for
one run or `ca` in `AGENT_CAPSULE_WITH` for every run:

```sh
export AGENT_CAPSULE_CA_CERTS=/usr/local/share/ca-certificates/corp-root.crt
agent-capsule --ca .
```

- The variable alone mounts nothing, so it is safe to export from a shell profile.
  Only a run with `ca` gets the certificates, and only it trusts the CA. A login with
  `--auth-login` keeps `ca`, since it may have to reach a server behind the CA.
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

