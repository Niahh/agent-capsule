# bash completion for agent-capsule
#
# Enumerable values come from the launcher itself (`--agent list`, `--with list`),
# so nothing here duplicates a list the script already owns. Both are local, need
# no podman, and exit before any state is touched.
#
# The launcher is always invoked through PATH: under Nix the installed script is
# a wrapper, so reading the file directly would get the wrong thing.

_agent_capsule_sessions() {
  local homes="${AGENT_CAPSULE_HOME:-$HOME/.agent-capsule}/homes"
  local home

  [[ -d "$homes" ]] || return 0
  for home in "$homes"/*/; do
    home="${home%/}"
    home="${home##*/}"
    [[ "$home" == "*" ]] || printf '%s\n' "$home"
  done
}

_agent_capsule_extras() {
  local selected_agent="$1"
  local extra

  while IFS= read -r extra; do
    # anydoc and worklog are Claude Code plugins; the launcher rejects them for other agents.
    if [[ "$extra" == "anydoc" || "$extra" == "worklog" ]]; then
      if [[ -n "$selected_agent" && "$selected_agent" != "claude" ]]; then
        continue
      fi
    fi
    printf '%s\n' "$extra"
  done < <(agent-capsule --with list 2>/dev/null)
  printf '%s\n' none list
}

# Complete a comma-separated list in place: only the segment after the last comma
# is a candidate, the segments before it come back as a prefix, and anything
# already chosen drops out. none and list are only valid on their own.
_agent_capsule_comma_list() {
  local word="$1"
  local candidates="$2"
  local prefix="" chosen="" remaining="" candidate

  if [[ "$word" == *,* ]]; then
    prefix="${word%,*},"
    chosen=",${word%,*},"
  fi

  while IFS= read -r candidate; do
    if [[ -n "$chosen" ]]; then
      [[ "$candidate" == "none" || "$candidate" == "list" ]] && continue
      [[ "$chosen" == *",$candidate,"* ]] && continue
    fi
    remaining+=" $candidate"
  done <<<"$candidates"

  mapfile -t COMPREPLY < <(compgen -W "$remaining" -- "${word##*,}")
  if [[ -n "$prefix" && "${#COMPREPLY[@]}" -gt 0 ]]; then
    COMPREPLY=("${COMPREPLY[@]/#/$prefix}")
  fi
  compopt -o nospace 2>/dev/null
}

_agent_capsule() {
  local cur prev words cword line
  local flags flag agent word index

  if declare -F _init_completion >/dev/null; then
    # Keep = and : attached: --vault=PATH and SRC:DEST:ro are single words here.
    _init_completion -n := || return
  else
    # Same shape without bash-completion loaded: split on spaces only.
    line="${COMP_LINE:0:COMP_POINT}"
    read -ra words <<<"$line"
    [[ "$line" == *" " ]] && words+=("")
    cword=$((${#words[@]} - 1))
    cur="${words[cword]}"
    prev=""
    [[ "$cword" -gt 0 ]] && prev="${words[cword - 1]}"
    COMPREPLY=()
  fi

  # Everything after -- belongs to the agent, not to us.
  for ((index = 1; index < cword; index++)); do
    [[ "${words[index]}" == "--" ]] && return 0
  done

  # --with filters on the agent the launcher will run: --agent on the line, else AGENT_CAPSULE_AGENT.
  agent="${AGENT_CAPSULE_AGENT:-}"
  for ((index = 1; index < cword; index++)); do
    word="${words[index]}"
    case "$word" in
      --agent) agent="${words[index + 1]}" ;;
      --agent=*) agent="${word#--agent=}" ;;
    esac
  done

  # = is in COMP_WORDBREAKS, so readline replaces only the text after it: --opt=VALUE
  # completes the bare VALUE, as --opt VALUE does.
  flag="$prev"
  if [[ "$cur" == --*=* ]]; then
    flag="${cur%%=*}"
    cur="${cur#*=}"
  fi

  case "$flag" in
    --agent)
      mapfile -t COMPREPLY < <(compgen -W "$(agent-capsule --agent list 2>/dev/null) list" -- "$cur")
      return 0
      ;;
    --session)
      mapfile -t COMPREPLY < <(compgen -W "$(_agent_capsule_sessions)" -- "$cur")
      return 0
      ;;
    --shared-rules | -m | --mount)
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      return 0
      ;;
    --with)
      _agent_capsule_comma_list "$cur" "$(_agent_capsule_extras "$agent")"
      return 0
      ;;
    --prune-caches | --prune-sessions)
      # DAYS after =, nothing to offer; a flag may still follow.
      [[ "$cur" == -* ]] || return 0
      ;;
  esac

  if [[ "$cur" == -* ]]; then
    flags="$(agent-capsule --help 2>/dev/null | grep -oE -- '--[a-z][a-z-]*' | sort -u)"
    mapfile -t COMPREPLY < <(compgen -W "$flags" -- "$cur")
    return 0
  fi

  # A bare --vault takes no value of its own, so the word after it is the project.
  mapfile -t COMPREPLY < <(compgen -d -- "$cur")
}

complete -F _agent_capsule agent-capsule
