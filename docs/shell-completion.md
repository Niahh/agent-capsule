# Shell completion

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

## Bash

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

## Zsh

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

