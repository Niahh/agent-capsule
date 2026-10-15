#!/usr/bin/env bash
# Take over the handed-off gh token, trust the private CA, reconcile the
# capsule-managed pieces of /home/dev, then start the agent.
#
# /home/dev is bind-mounted from a persistent host session home, so anything
# this places there outlives the run. Each piece carries a marker file: without
# one there is no way to tell capsule-managed state from the user's own, and no
# safe way to remove it when the integration is deactivated.
set -e

# First, so the token file is gone even if a later step fails.
if [[ -n "${AGENT_CAPSULE_GH_TOKEN_FILE:-}" && -f "$AGENT_CAPSULE_GH_TOKEN_FILE" ]]; then
  GH_TOKEN="$(<"$AGENT_CAPSULE_GH_TOKEN_FILE")"
  export GH_TOKEN
  rm -f "$AGENT_CAPSULE_GH_TOKEN_FILE"
fi
if [[ -n "${AGENT_CAPSULE_KEYS_DIR:-}" ]]; then
  for key_file in "$AGENT_CAPSULE_KEYS_DIR"/*; do
    [[ -f "$key_file" ]] || continue
    key_value="$(<"$key_file")"
    export "${key_file##*/}=$key_value"
    rm -f "$key_file"
  done
fi

# Adds the private CA to what the capsule already trusts. git and Node read
# neither SSL_CERT_FILE nor each other's variable, so each gets its own.
if [[ -n "${AGENT_CAPSULE_CA_DIR:-}" && -f "$AGENT_CAPSULE_CA_DIR/extra.pem" ]]; then
  cat "${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" "$AGENT_CAPSULE_CA_DIR/extra.pem" \
    > "$AGENT_CAPSULE_CA_DIR/bundle.pem"
  export SSL_CERT_FILE="$AGENT_CAPSULE_CA_DIR/bundle.pem"
  export GIT_SSL_CAINFO="$SSL_CERT_FILE"
  export NODE_EXTRA_CA_CERTS="$AGENT_CAPSULE_CA_DIR/extra.pem"
fi

skills_dir="${AGENT_CAPSULE_SKILLS_DIR:-}"
if [[ -n "$skills_dir" ]]; then
  skill="$skills_dir/explain-diff-html"
  marker="$skills_dir/.explain-diff-html-capsule-managed"

  case ",${AGENT_CAPSULE_WITH:-}," in
    *,explain-diff,*)
      mkdir -p "$skills_dir"
      if [[ (-e "$skill" || -L "$skill") && ! -e "$marker" ]]; then
        echo "explain-diff-html already exists and is not capsule-managed: $skill" >&2
        exit 1
      fi
      ln -sfn /opt/explain-diff-html "$skill"
      touch "$marker"
      ;;
    *)
      if [[ -e "$marker" ]]; then
        rm -f "$skill" "$marker"
      fi
      ;;
  esac
fi

# Codex has no invocation-only local plugin flag, so its plugin list is state
# that has to be reconciled rather than passed per run.
if [[ "${AGENT_CAPSULE_AGENT:-}" == codex ]]; then
  codex_home="${CODEX_HOME:-${HOME:-/home/dev}/.codex}"
  marker="$codex_home/.superpowers-capsule-managed"

  case ",${AGENT_CAPSULE_WITH:-}," in
    *,superpowers,*)
      mkdir -p "$codex_home"
      CODEX_HOME="$codex_home" codex plugin marketplace add /opt/superpowers/source >/dev/null
      CODEX_HOME="$codex_home" codex plugin add superpowers@superpowers-dev >/dev/null
      touch "$marker"
      ;;
    *)
      if [[ -e "$marker" ]]; then
        CODEX_HOME="$codex_home" codex plugin remove superpowers@superpowers-dev >/dev/null
        rm -f "$marker"
      fi
      ;;
  esac
fi

exec "$@"
