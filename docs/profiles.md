# Profiles

A profile is a second `AGENT_CAPSULE_HOME`, with its own logins, sessions and project
memory next to your usual one. Use one to run the same agent with another account, such
as a work and a personal one, at the same time.

Settings stay in the environment, so a profile is a shell function. In zsh:

```zsh
# ~/.zshrc
capsule-work() {
  AGENT_CAPSULE_HOME="$HOME/.agent-capsule-work" \
  AGENT_CAPSULE_SHARED_RULES="$HOME/.agent-capsule/CLAUDE.md" \
  AGENT_CAPSULE_WITH=superpowers,github,gitlab,ca,vault \
  AGENT_CAPSULE_GH_USER=work-login \
  AGENT_CAPSULE_GITLAB_HOST=gitlab.example.com \
    agent-capsule "$@"
}
compdef capsule-work=agent-capsule
```

In bash, with the same function body, load the completion before reusing it, since
bash-completion only loads it when `agent-capsule` is first completed:

```bash
# ~/.bashrc, after the capsule-work function
source "$HOME/.local/share/bash-completion/completions/agent-capsule"
complete -F _agent_capsule capsule-work
```

Then log in once per profile and agent, and run both side by side:

```sh
capsule-work --auth-login     # once per profile and agent
capsule-work ~/code/core      # terminal 1: the work login
agent-capsule ~/code/core     # terminal 2: the usual login, same project, at the same time
```

- Each profile keeps apart its login (`auth-home/`), its sessions (`homes/`), its project
  memory, and its default worklog procedure (`log-work.md`). Project memory stays apart on
  purpose: memory written under one account must not reach another organisation's.
- Shared: the images, and the rules file when the function points
  `AGENT_CAPSULE_SHARED_RULES` back at it. To share the worklog procedure as well, set
  `AGENT_CAPSULE_WORKLOG_PROCEDURE` in the function, or symlink the file.
- Two profiles can run at the same time.
- A profile with a different `AGENT_CAPSULE_TOOLS` also needs its own `AGENT_CAPSULE_IMAGE`,
  such as `agent-capsule-work`, or each one rebuilds the other's image.
- `AGENT_CAPSULE_GH_USER` picks the host `gh` account whose token `github` hands over.
  Unset, it is `gh`'s active account.
- `capsule-work --prune-sessions` prunes that profile only.

Limits:

- `--session` completion for the function lists the main folder's sessions, since
  completion reads `AGENT_CAPSULE_HOME` from the shell, not from the function.
- `glab` keeps one login per instance, so two accounts on one GitLab instance are not
  supported.
