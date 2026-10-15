# Agents

Each image holds one agent's CLI and is tagged with the agent's name, so switching
agents rebuilds nothing once each image exists. Each agent gets its own default
session per project and its own login: run `agent-capsule --agent NAME --auth-login`
once. Credentials live under separate agent directories, and only the selected
agent's credential file is mounted into a session. The global rules file is the same
for every agent, mounted as `CLAUDE.md` for claude and `AGENTS.md` for Codex and
opencode. A session home stays bound to the agent that created it.

API keys set on the host reach the agent that uses them: `ANTHROPIC_API_KEY` for
claude, `OPENAI_API_KEY` for codex, both for opencode. Like the GitHub token, each
crosses over as a file in `$XDG_RUNTIME_DIR`, which the entrypoint moves into the
environment and deletes. The agent can read them.

The launcher forwards `SUPERPOWERS_DISABLE_TELEMETRY`, `DISABLE_TELEMETRY`, and
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` when those variables are set on the host.
Their values are not placed in the Podman command line.

Differences under opencode: per-project memory is unavailable (it is a Claude Code
mechanism), Superpowers and MCP servers use invocation-scoped configuration, and the
claude-only `anydoc` and `worklog` integrations are rejected on the command line and
dropped with a notice when they come from `AGENT_CAPSULE_WITH`. User-owned OpenCode
configuration files are left untouched.

Codex also has no shared Claude memory. Its `--auth-login` defaults to device-code
authentication because its browser callback stays inside the container. Custom login
arguments after `--` replace that default, and mcpvault uses Codex configuration
overrides.

Status lines and build output go to stderr, and a TTY is allocated only when stdin
and stdout are both terminals. So `agent-capsule . -- -p "question" > answer.md`
captures only the answer.
