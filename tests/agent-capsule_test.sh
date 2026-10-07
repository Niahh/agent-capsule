#!/usr/bin/env bash

set -euo pipefail

BASH_BIN="$(command -v bash)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"
SCRIPT="$ROOT_DIR/agent-capsule"
DOCKERFILE="$ROOT_DIR/Dockerfile"
# The script owns its version; asserting a literal here breaks on every bump.
LAUNCHER_VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT")"
# Resolved, or a symlinked temp dir would make the launcher's paths differ from it.
TEST_ROOT="$(cd -P "$(mktemp -d)" >/dev/null && pwd)"
# Session fixtures carry a read-only Go module cache, which plain rm -rf cannot remove.
trap 'chmod -R u+w "$TEST_ROOT" 2>/dev/null; rm -rf "$TEST_ROOT"' EXIT

# The suite is commonly run from inside a capsule, where AGENT_CAPSULE_* and
# HERDR_* are exported. They would reach the script under test and change what
# it does, so drop the whole namespace before the first case.
for leaked_variable in $(
  env | sed -n \
    's/^\(AGENT_CAPSULE_[A-Za-z0-9_]*\)=.*/\1/p;s/^\(HERDR_[A-Za-z0-9_]*\)=.*/\1/p'
); do
  unset "$leaked_variable"
done
unset leaked_variable

# Host settings the launcher or the git calls below would otherwise read.
unset CDPATH GH_CONFIG_DIR GLAB_CONFIG_DIR XDG_CONFIG_HOME GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN \
  GLAB_IS_OAUTH2 ANTHROPIC_API_KEY OPENAI_API_KEY XDG_RUNTIME_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

printf '#!%s\n' "$BASH_BIN" > "$FAKE_BIN/podman"
cat >> "$FAKE_BIN/podman" <<'PODMAN'
set -eu

printf 'CALL=%s\n' "${1:-}" >> "$PODMAN_LOG"
previous=""
bundle_hash=""
refreshed_at=""
selection=""
image_ref=""
for arg in "$@"; do
  printf 'ARG=%s\n' "$arg" >> "$PODMAN_LOG"
  if [[ "$previous" == "--label" && "$arg" == io.agent-capsule.bundle=* ]]; then
    bundle_hash="${arg#*=}"
  fi
  if [[ "$previous" == "--label" && "$arg" == io.agent-capsule.refreshed-at=* ]]; then
    refreshed_at="${arg#*=}"
  fi
  if [[ "$previous" == "--label" && "$arg" == io.agent-capsule.selection=* ]]; then
    selection="${arg#*=}"
  fi
  if [[ "$previous" == "-t" ]]; then
    image_ref="$arg"
  fi
  previous="$arg"
done

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  for arg in "$@"; do image_ref="$arg"; done
  # An ID derived from the bundle, so a test can tell which build a run starts.
  if [[ " $* " == *" {{.Id}} "* ]]; then
    awk -F '\t' -v image="$image_ref" '$1 == image { id = "id-" $2 } END { if (id != "") print id }' \
      "$PODMAN_IMAGE_STATE"
    exit 0
  fi
  awk -F '\t' -v image="$image_ref" '
    $1 == image { hash = $2; refreshed = $3; selection = $4 }
    END { if (hash != "") print hash " " refreshed " " selection }
  ' "$PODMAN_IMAGE_STATE"
  exit 0
fi

if [[ "${1:-}" == "images" ]]; then
  [[ -f "${PODMAN_DANGLING:-}" ]] && cat "$PODMAN_DANGLING"
  exit 0
fi

if [[ "${1:-}" == "ps" ]]; then
  [[ "${PODMAN_PS_FAIL:-0}" == "1" ]] && exit 125
  [[ -f "${PODMAN_RUNNING:-}" ]] && cat "$PODMAN_RUNNING"
  exit 0
fi

if [[ "${1:-}" == "rmi" ]]; then
  if [[ -f "${PODMAN_DANGLING:-}" ]]; then
    grep -vxF "${2:-}" "$PODMAN_DANGLING" > "$PODMAN_DANGLING.tmp" || true
    mv "$PODMAN_DANGLING.tmp" "$PODMAN_DANGLING"
  fi
  exit 0
fi

if [[ "${1:-}" == "build" && -n "$image_ref" && -n "$bundle_hash" ]]; then
  sleep "${PODMAN_BUILD_DELAY:-0}"
  printf '%s\t%s\t%s\t%s\n' "$image_ref" "$bundle_hash" \
    "${PODMAN_BUILD_EPOCH:-$refreshed_at}" "$selection" >> "$PODMAN_IMAGE_STATE"
fi

exit 0
PODMAN
chmod +x "$FAKE_BIN/podman"

# The host gh, kept off FAKE_BIN: only the github cases put it on PATH, and a CI
# runner's real gh must never answer for it.
GH_FAKE_BIN="$TEST_ROOT/gh-bin"
mkdir -p "$GH_FAKE_BIN"
printf '#!%s\n' "$BASH_BIN" > "$GH_FAKE_BIN/gh"
cat >> "$GH_FAKE_BIN/gh" <<'GH'
printf '%s\n' "$*" >> "$GH_LOG"
if [[ "${1:-} ${2:-}" == "auth token" && -n "${FAKE_GH_TOKEN:-}" ]]; then
  printf '%s\n' "$FAKE_GH_TOKEN"
  exit 0
fi
if [[ "$*" == "auth git-credential get" && -n "${FAKE_GH_TOKEN:-}" ]]; then
  printf 'username=x-access-token\npassword=%s\n' "$FAKE_GH_TOKEN"
  exit 0
fi
exit 1
GH
chmod +x "$GH_FAKE_BIN/gh"

# The host glab, kept off FAKE_BIN like gh. Like the real one, a value that is not
# set prints nothing and still succeeds.
GLAB_FAKE_BIN="$TEST_ROOT/glab-bin"
mkdir -p "$GLAB_FAKE_BIN"
printf '#!%s\n' "$BASH_BIN" > "$GLAB_FAKE_BIN/glab"
cat >> "$GLAB_FAKE_BIN/glab" <<'GLAB'
printf '%s\n' "$*" >> "$GLAB_LOG"
fake_host="${FAKE_GLAB_HOST:-gitlab.com}"
# Like the real glab, these variables answer before the stored login, for any host.
env_token="${GITLAB_TOKEN:-${GITLAB_ACCESS_TOKEN:-${OAUTH_TOKEN:-}}}"
if [[ "${1:-} ${2:-} ${3:-}" == "config get token" && -n "$env_token" ]]; then
  printf '%s\n' "$env_token"
  exit 0
fi
if [[ "${1:-} ${2:-} ${3:-}" == "config get is_oauth2" && -n "${GLAB_IS_OAUTH2:-}" ]]; then
  printf '%s\n' "$GLAB_IS_OAUTH2"
  exit 0
fi
if [[ "$*" == "config get token --host $fake_host" && -n "${FAKE_GLAB_TOKEN:-}" ]]; then
  printf '%s\n' "$FAKE_GLAB_TOKEN"
  exit 0
fi
if [[ "$*" == "config get is_oauth2 --host $fake_host" && -n "${FAKE_GLAB_OAUTH:-}" ]]; then
  printf '%s\n' "$FAKE_GLAB_OAUTH"
  exit 0
fi
if [[ "$*" == "auth git-credential get" && -n "${FAKE_GLAB_TOKEN:-}" ]]; then
  printf 'capability[]=authtype\nusername=glab\npassword=%s\n' "$FAKE_GLAB_TOKEN"
  exit 0
fi
[[ "${1:-} ${2:-}" == "config get" ]] && exit 0
exit 1
GLAB
chmod +x "$GLAB_FAKE_BIN/glab"

if command -v sha256sum >/dev/null 2>&1; then
  SHA256_COMMAND=(sha256sum)
else
  SHA256_COMMAND=(shasum -a 256)
fi

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

file_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"
}

days_ago_stamp() {
  date -d "-$1 days" +%Y%m%d%H%M 2>/dev/null || date -v "-$1d" +%Y%m%d%H%M
}

# A claude session home last used DAYS ago, holding both rebuildable caches and
# state that pruning caches must keep.
make_session_home() { # name days-idle
  local home="$CAPSULE_HOME/homes/$1"

  mkdir -p "$home/.claude/projects/p" "$home/.cache/go-build" "$home/.npm/_cacache" \
    "$home/go/pkg/mod/example.com/m@v1" "$home/go/bin"
  printf 'claude\n' > "$home/.agent"
  printf '{}\n' > "$home/.claude.json"
  printf 'x\n' | tee "$home/.claude/projects/p/s.jsonl" "$home/.cache/go-build/o" \
    "$home/.npm/_cacache/o" "$home/go/pkg/mod/example.com/m@v1/go.mod" \
    "$home/go/bin/tool" > /dev/null
  # Go leaves its module cache read-only.
  chmod -R a-w "$home/go/pkg/mod"
  find "$home" -exec touch -t "$(days_ago_stamp "$2")" {} +
}

pass_count=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Otherwise an unexpected non-zero exit ends the suite silently, and the EXIT trap
# deletes the output that explains it. Expected failures use `|| status=$?`.
on_error() { # status line command
  local frame=1

  echo "FAIL: line $2 exited $1: $3" >&2
  while caller "$frame" >&2; do frame=$((frame + 1)); done
  [[ ! -s "${OUTPUT:-}" ]] || tail -n 20 "$OUTPUT" >&2
  exit 1
}
set -E
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -F -- "$expected" "$file" >/dev/null || fail "$file does not contain: $expected"
}

assert_not_contains() {
  local file="$1"
  local unexpected="$2"
  if grep -F -- "$unexpected" "$file" >/dev/null; then
    fail "$file unexpectedly contains: $unexpected"
  fi
}

assert_arg_after() {
  local file="$1"
  local first="ARG=$2"
  local second="ARG=$3"

  awk -v first="$first" -v second="$second" '
    $0 == first { getline; if ($0 == second) found = 1 }
    END { exit !found }
  ' "$file" || fail "$3 does not follow $2 in $file"
}

assert_status_fails() {
  local status="$1"
  [[ "$status" -ne 0 ]] || fail "command unexpectedly succeeded"
}

new_case() {
  CASE_DIR="$TEST_ROOT/case-$pass_count"
  CAPSULE_HOME="$CASE_DIR/capsule"
  HOST_HOME="$CASE_DIR/home"
  PODMAN_LOG="$CASE_DIR/podman.log"
  PODMAN_IMAGE_STATE="$CASE_DIR/podman-images"
  OUTPUT="$CASE_DIR/output"
  GH_LOG="$CASE_DIR/gh.log"
  GLAB_LOG="$CASE_DIR/glab.log"
  export GH_LOG GLAB_LOG
  mkdir -p "$CAPSULE_HOME" "$HOST_HOME"
  : > "$PODMAN_LOG"
  : > "$GH_LOG"
  : > "$GLAB_LOG"
  : > "$PODMAN_IMAGE_STATE"
  PODMAN_DANGLING=""
  ((pass_count += 1))
}

run_capsule() {
  local run_output="${RUN_OUTPUT:-$OUTPUT}"

  # An empty volume option, or an SELinux host would add :z to every mount.
  AGENT_CAPSULE_VOLOPT='' \
    HOME="$HOST_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    PODMAN_LOG="$PODMAN_LOG" \
    PODMAN_IMAGE_STATE="$PODMAN_IMAGE_STATE" \
    PODMAN_DANGLING="${PODMAN_DANGLING:-}" \
    AGENT_CAPSULE_HOME="$CAPSULE_HOME" \
    AGENT_CAPSULE_DOCKERFILE="${AGENT_CAPSULE_DOCKERFILE:-$DOCKERFILE}" \
    XDG_RUNTIME_DIR="$TEST_ROOT/xdg" \
    "$BASH_BIN" "$SCRIPT" "$@" > "$run_output" 2>&1
}

new_case
for agent_and_skills_dir in \
  'claude|/home/dev/.claude/skills' \
  'codex|/home/dev/.codex/skills' \
  'opencode|/home/dev/.config/opencode/skills'; do
  IFS='|' read -r agent skills_dir <<<"$agent_and_skills_dir"
  run_capsule --agent "$agent" --with explain-diff --shell \
    --session "explain-diff-$agent" "$ROOT_DIR"
  assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_WITH=explain-diff'
  assert_contains "$PODMAN_LOG" "ARG=AGENT_CAPSULE_SKILLS_DIR=$skills_dir"
  : > "$PODMAN_LOG"
done

new_case
rules_file="$CASE_DIR/rules.md"
touch "$rules_file"
chmod 0644 "$rules_file"
run_capsule --shell --session rules-mode --shared-rules "$rules_file" "$ROOT_DIR"
[[ "$(file_mode "$rules_file")" == "644" ]] || fail "shared rules mode changed"

new_case
vault_dir="$CASE_DIR/vault"
config_dir="$CAPSULE_HOME/homes/opencode-state/.config/opencode"
mkdir -p "$vault_dir"
run_capsule --agent opencode --shell --session opencode-state \
  --with superpowers,mcpvault --vault="$vault_dir" "$ROOT_DIR"
opencode_mcp='"mcp":{"obsidian":{"type":"local","command":["mcpvault","/vault"]}}'
assert_contains "$PODMAN_LOG" \
  "OPENCODE_CONFIG_CONTENT={\"plugin\":[\"/opt/superpowers/source\"],$opencode_mcp}"

: > "$PODMAN_LOG"
run_capsule --agent opencode --shell --session opencode-state \
  --with superpowers,mcpvault --no-vault "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT={"plugin":["/opt/superpowers/source"]}'
assert_not_contains "$PODMAN_LOG" 'obsidian'

user_config="$config_dir/opencode.json"
mkdir -p "$config_dir"
printf '%s\n' '{"theme":"user-owned"}' > "$user_config"
: > "$PODMAN_LOG"
run_capsule --agent opencode --shell --session opencode-state \
  --with mcpvault --vault="$vault_dir" "$ROOT_DIR"
[[ "$(<"$user_config")" == '{"theme":"user-owned"}' ]] || fail "user OpenCode config changed"
assert_contains "$PODMAN_LOG" "OPENCODE_CONFIG_CONTENT={$opencode_mcp}"

: > "$PODMAN_LOG"
run_capsule --agent opencode --shell --session opencode-state --with none "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT='
[[ "$(<"$user_config")" == '{"theme":"user-owned"}' ]] || fail "user OpenCode config changed"

# Vault flags are last-one-wins, in both directions.
: > "$PODMAN_LOG"
run_capsule --agent opencode --shell --session opencode-state \
  --with mcpvault --no-vault --vault="$vault_dir" "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "OPENCODE_CONFIG_CONTENT={$opencode_mcp}"

: > "$PODMAN_LOG"
run_capsule --agent opencode --shell --session opencode-state \
  --with mcpvault --vault="$vault_dir" --no-vault "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'obsidian'

# The agent runs as the host UID under --keep-id, so the image files must not inherit a private umask.
new_case
(umask 077; run_capsule --shell --session worklog-umask "$ROOT_DIR")
plugin_mode="$(file_mode "$CAPSULE_HOME/build/context/plugins/worklog/hooks/worklog.mjs")"
[[ "${plugin_mode: -1}" -ge 4 ]] || fail "plugin file is not world-readable: $plugin_mode"

# The project is the vault itself, inside it, or a sibling whose name only starts like the vault's.
new_case
vault_dir="$CASE_DIR/notes"
mkdir -p "$vault_dir/sub" "$CASE_DIR/notes2"
run_capsule --with mcpvault,worklog --vault="$vault_dir" --session worklog-in-vault "$vault_dir"
assert_contains "$OUTPUT" '>> Worklog : disabled for this run (the project is inside the vault)'
assert_not_contains "$PODMAN_LOG" 'ARG=/opt/worklog/plugin'
assert_not_contains "$PODMAN_LOG" 'AGENT_CAPSULE_VAULT_DEST'
: > "$PODMAN_LOG"
run_capsule --with mcpvault,worklog --vault="$vault_dir" --session worklog-in-vault "$vault_dir/sub"
assert_contains "$OUTPUT" '>> Worklog : disabled for this run (the project is inside the vault)'
assert_not_contains "$PODMAN_LOG" 'ARG=/opt/worklog/plugin'
: > "$PODMAN_LOG"
run_capsule --with mcpvault,worklog --vault="$vault_dir" --session worklog-in-vault "$CASE_DIR/notes2"
assert_arg_after "$PODMAN_LOG" --plugin-dir /opt/worklog/plugin

# A shell does not load the plugin, so the banner says how to.
new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
run_capsule --with mcpvault,worklog --vault="$vault_dir" --shell --session worklog-shell "$ROOT_DIR"
assert_contains "$OUTPUT" '(start claude with: --plugin-dir /opt/worklog/plugin)'

new_case
run_capsule --help
assert_contains "$OUTPUT" 'Usage:'
assert_contains "$OUTPUT" '--versions'
assert_contains "$OUTPUT" '--shared-rules PATH'
assert_contains "$OUTPUT" '--prune-sessions[=DAYS]'
assert_contains "$OUTPUT" 'explain-diff'
assert_contains "$OUTPUT" 'kubernetes'
assert_contains "$OUTPUT" 'talos'
assert_not_contains "$PODMAN_LOG" 'CALL='
run_capsule --version
assert_contains "$OUTPUT" "agent-capsule $LAUNCHER_VERSION"

# A config file left over from 0.2 is inert: never read, never an error.
new_case
printf '%s\n' 'AGENT_CAPSULE_AGENT=codex' 'accidentally-pasted-secret' \
  > "$CAPSULE_HOME/config"
run_capsule --shell --session leftover-config "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Agent   : claude'
assert_not_contains "$OUTPUT" 'accidentally-pasted-secret'
assert_not_contains "$OUTPUT" '>> Config'
assert_contains "$PODMAN_LOG" 'CALL=run'

new_case
AGENT_CAPSULE_CLAUDE_CODE_VERSION=9.8.7 AGENT_CAPSULE_CODEX_VERSION=6.5.4 run_capsule --versions
assert_contains "$OUTPUT" 'claude-code 9.8.7'
assert_contains "$OUTPUT" 'codex 6.5.4'
# Everything without an override tracks the latest release at build time.
assert_contains "$OUTPUT" 'opencode latest'
assert_contains "$OUTPUT" 'superpowers latest'
assert_contains "$OUTPUT" 'kubectl latest'
assert_contains "$OUTPUT" 'helm latest'
assert_contains "$OUTPUT" 'talosctl latest'
assert_contains "$OUTPUT" 'gh latest'
assert_contains "$OUTPUT" 'glab latest'
assert_not_contains "$PODMAN_LOG" 'CALL='

# An unset pin reaches the build as an empty arg, which the Dockerfile reads as
# "latest"; an override carries its value through.
new_case
run_capsule --shell --session unpinned-build "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'CLAUDE_CODE_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'SUPERPOWERS_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'KUBECTL_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'HELM_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'TALOSCTL_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'GH_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'GLAB_VERSION='
: > "$PODMAN_LOG"
AGENT_CAPSULE_CLAUDE_CODE_VERSION=9.8.7 \
  run_capsule --shell --session pinned-build "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'CLAUDE_CODE_VERSION=9.8.7'

# Each CLI pin must be part of the bundle hash, or pinning it after an
# unpinned build would keep the old image.
new_case
for cluster_pin in KUBECTL_VERSION=v1.2.3 HELM_VERSION=v4.5.6 TALOSCTL_VERSION=v7.8.9 \
  GH_VERSION=v2.3.4 GLAB_VERSION=v1.2.3; do
  run_capsule --shell --session cluster-pins "$ROOT_DIR"
  : > "$PODMAN_LOG"
  (export "AGENT_CAPSULE_$cluster_pin" && run_capsule --shell --session cluster-pins "$ROOT_DIR")
  assert_contains "$PODMAN_LOG" 'CALL=build'
  assert_arg_after "$PODMAN_LOG" --build-arg "$cluster_pin"
done

# An image older than the age limit is refreshed without the layer cache, or an
# unpinned install would reproduce exactly what is already there.
new_case
PODMAN_BUILD_EPOCH=1000000000 run_capsule --shell --session stale-image "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
: > "$PODMAN_LOG"
run_capsule --shell --session stale-image "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_contains "$PODMAN_LOG" 'ARG=--no-cache'
assert_contains "$OUTPUT" 'days old, refreshing'

# The first build establishes the refresh epoch and cannot trust old builder
# cache left behind after an earlier tag was removed.
new_case
run_capsule --shell --session first-refresh "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=--pull=always'
assert_contains "$PODMAN_LOG" 'ARG=--no-cache'
assert_contains "$PODMAN_LOG" 'ARG=io.agent-capsule.refreshed-at='

# Selection and freshness are independent. A stale image must refresh even when
# the requested agent also changes its bundle hash.
new_case
PODMAN_BUILD_EPOCH=1000000000 run_capsule --shell --session stale-selection "$ROOT_DIR"
: > "$PODMAN_LOG"
run_capsule --agent codex --shell --session stale-selection-codex "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_contains "$PODMAN_LOG" 'ARG=--pull=always'
assert_contains "$PODMAN_LOG" 'ARG=--no-cache'

new_case
PODMAN_BUILD_EPOCH=1000000000 run_capsule --shell --session age-disabled "$ROOT_DIR"
: > "$PODMAN_LOG"
AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS=0 \
  run_capsule --shell --session age-disabled "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'

new_case
status=0
AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS=weekly run_capsule --shell "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" 'Invalid AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS: weekly'
assert_not_contains "$PODMAN_LOG" 'CALL='

new_case
AGENT_CAPSULE_CLAUDE_CODE_VERSION=1.2.3-beta.1+build.7 run_capsule --versions
assert_contains "$OUTPUT" 'claude-code 1.2.3-beta.1+build.7'

new_case
AGENT_CAPSULE_SUPERPOWERS_VERSION=v1.2.3-beta.1+build.7 run_capsule --versions
assert_contains "$OUTPUT" 'superpowers v1.2.3-beta.1+build.7'

new_case
status=0
AGENT_CAPSULE_CLAUDE_CODE_VERSION=invalid run_capsule --shell "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" 'Invalid pinned package version: invalid'
assert_not_contains "$PODMAN_LOG" 'CALL='

# Cluster CLI releases are tagged with a leading v, which the download URLs need.
new_case
status=0
AGENT_CAPSULE_KUBECTL_VERSION=1.37.1 run_capsule --shell "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" 'Invalid pinned tagged version: 1.37.1'
assert_not_contains "$PODMAN_LOG" 'CALL='

# A session from the environment is an ambient default; only an
# explicit --session conflicts with the dedicated auth home.
new_case
AGENT_CAPSULE_SESSION=configured-session run_capsule --auth-login
assert_contains "$OUTPUT" '>> Session : _auth'

new_case
status=0
run_capsule --auth-login --session explicit-session || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" '--auth-login uses its own session'

for agent in claude codex opencode; do
  new_case
  status=0
  run_capsule --agent "$agent" --auth-login --offline || status=$?
  assert_status_fails "$status"
  assert_contains "$OUTPUT" '--auth-login cannot be combined with --offline'
done

# These values must stay aligned when another agent profile is added.
for profile in \
  'claude|claude|.claude/CLAUDE.md' \
  'codex|codex|.codex/AGENTS.md' \
  'opencode|opencode|.config/opencode/AGENTS.md'; do
  IFS='|' read -r agent command rules_path <<< "$profile"
  new_case
  run_capsule --agent "$agent" --session "profile-$agent" "$ROOT_DIR" -- --version
  assert_contains "$PODMAN_LOG" "ARG=ai.agent=$agent"
  assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/CLAUDE.md:/home/dev/$rules_path:ro"
  image_id="id-$(awk -F '\t' 'END { print $2 }' "$PODMAN_IMAGE_STATE")"
  assert_arg_after "$PODMAN_LOG" "$image_id" "$command"
  assert_arg_after "$PODMAN_LOG" "$command" '--version'
done

# The shared 0.1 authentication home stops the launch without changing files.
new_case
legacy_credential="$CAPSULE_HOME/auth-home/.claude/.credentials.json"
mkdir -p "$(dirname "$legacy_credential")"
printf '%s\n' token > "$legacy_credential"
status=0
run_capsule --shell --session legacy-auth-home "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" "Authentication state from agent-capsule 0.1: $CAPSULE_HOME/auth-home/.claude"
[[ "$(<"$legacy_credential")" == token ]] || fail "0.1 credential changed"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
for agent in claude codex opencode; do
  mkdir -p "$CAPSULE_HOME/auth-home/$agent"
done
run_capsule --agent codex --auth-login -- --with-api-key
assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/auth-home/codex:/home/dev"
assert_not_contains "$PODMAN_LOG" "$CAPSULE_HOME/auth-home/claude:/home/dev"
assert_not_contains "$PODMAN_LOG" "$CAPSULE_HOME/auth-home/opencode:/home/dev"

# One tag, rebuilt whenever the selection changes: the image carries only the
# agent and integrations this run asked for.
new_case
# A day old, so a rebuild that reset the refresh time would show.
PODMAN_BUILD_EPOCH="$(($(date +%s) - 86400))" \
  run_capsule --agent claude --shell --session selection-claude "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'AGENT=claude'
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_SUPERPOWERS=0'

: > "$PODMAN_LOG"
run_capsule --agent claude --shell --session selection-claude "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'
selection_refreshed_at="$(awk -F '\t' 'NF == 3 { value = $3 } END { print value }' "$PODMAN_IMAGE_STATE")"

# Switching the agent changes what is installed, so it must rebuild.
: > "$PODMAN_LOG"
run_capsule --agent codex --shell --with superpowers \
  --session selection-codex "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=agent-capsule-dev:latest'
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_AGENT=codex'
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_WITH=superpowers'
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'AGENT=codex'
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_SUPERPOWERS=1'
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_ANYDOC=0'
assert_contains "$PODMAN_LOG" 'ARG=io.agent-capsule.selection=codex:superpowers'
assert_not_contains "$PODMAN_LOG" 'ARG=--no-cache'

# A recent refresh survives a cached selection rebuild instead of being reset.
assert_contains "$PODMAN_LOG" "ARG=io.agent-capsule.refreshed-at=$selection_refreshed_at"

# Changing only the integrations rebuilds too.
: > "$PODMAN_LOG"
run_capsule --agent codex --shell --with none --session selection-codex "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_SUPERPOWERS=0'
assert_contains "$PODMAN_LOG" 'ARG=io.agent-capsule.selection=codex:none'

: > "$PODMAN_LOG"
AGENT_CAPSULE_IMAGE=preexisting:image \
  run_capsule --agent codex --shell --session custom-image "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_contains "$PODMAN_LOG" 'ARG=preexisting:image'

: > "$PODMAN_LOG"
AGENT_CAPSULE_CLAUDE_CODE_VERSION=9.8.7 \
  run_capsule --agent codex --shell --session universal-version-change "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'CLAUDE_CODE_VERSION=9.8.7'

# The cluster CLIs are opt-in and work with every agent.
new_case
run_capsule --shell --session cluster-default "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_KUBERNETES=0'
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_TALOS=0'
for agent in claude codex opencode; do
  : > "$PODMAN_LOG"
  run_capsule --agent "$agent" --with talos,kubernetes --shell \
    --session "cluster-$agent" "$ROOT_DIR"
  assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_KUBERNETES=1'
  assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_TALOS=1'
  assert_contains "$PODMAN_LOG" "ARG=io.agent-capsule.selection=$agent:kubernetes,talos"
done
: > "$PODMAN_LOG"
run_capsule --with talos --shell --session cluster-talos-only "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_KUBERNETES=0'
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_TALOS=1'

# Without github the host gh is never asked, and the capsule gets no token, no
# token mount and no git rewrite.
new_case
PATH="$GH_FAKE_BIN:$PATH" FAKE_GH_TOKEN=gho_offtoken \
  run_capsule --shell --session gh-off "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_GITHUB=0'
[[ ! -s "$GH_LOG" ]] || fail "host gh was called without --with github"
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/gh'
assert_not_contains "$PODMAN_LOG" 'GIT_CONFIG_'
assert_not_contains "$PODMAN_LOG" 'GH_TOKEN'

# The token reaches the capsule in a file under the runtime dir, never on the
# podman command line: podman keeps that in the container config on disk.
new_case
PATH="$GH_FAKE_BIN:$PATH" FAKE_GH_TOKEN=gho_secret123 \
  run_capsule --with github --shell --session gh-on "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_GITHUB=1'
assert_not_contains "$PODMAN_LOG" 'gho_secret123'
assert_not_contains "$OUTPUT" 'plain text'
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_GH_TOKEN_FILE=/run/agent-capsule/gh/token'
gh_token_dir="$(sed -n 's|^ARG=\(.*\):/run/agent-capsule/gh\(:.*\)\{0,1\}$|\1|p' "$PODMAN_LOG")"
[[ "$gh_token_dir" == "$TEST_ROOT/xdg/"* ]] || fail "token dir is outside the runtime dir: $gh_token_dir"
[[ "$(<"$gh_token_dir/token")" == gho_secret123 ]] || fail "token file does not hold the host token"
[[ "$(file_mode "$gh_token_dir")" == 700 ]] || fail "token dir is not private"
[[ "$(file_mode "$gh_token_dir/token")" == 600 ]] || fail "token file is not private"

# Inside the capsule, git reaches GitHub over HTTPS with gh's credentials, whatever
# form the remote takes.
mapfile -t git_env < <(sed -n 's/^ARG=\(GIT_CONFIG_.*\)$/\1/p' "$PODMAN_LOG")
for remote in git@github.com:o/r ssh://git@github.com/o/r; do
  rewritten="$(env "${git_env[@]}" HOME="$CASE_DIR" GIT_CONFIG_NOSYSTEM=1 \
    git ls-remote --get-url "$remote")"
  [[ "$rewritten" == https://github.com/o/r ]] || fail "$remote became $rewritten"
done
credential="$(printf 'protocol=https\nhost=github.com\npath=o/r\n\n' |
  env "${git_env[@]}" PATH="$GH_FAKE_BIN:$PATH" HOME="$CASE_DIR" GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 FAKE_GH_TOKEN=gho_secret123 git credential fill)"
[[ "$credential" == *password=gho_secret123* ]] || fail "git does not ask gh for GitHub credentials"

# A host without a gh login still starts the capsule, and says how to log in.
new_case
PATH="$GH_FAKE_BIN:$PATH" FAKE_GH_TOKEN='' \
  run_capsule --with github --shell --session gh-logged-out "$ROOT_DIR"
assert_contains "$OUTPUT" 'gh auth login'
assert_contains "$PODMAN_LOG" 'CALL=run'
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/gh'

# A host gh without a keyring keeps its token in plain text, which defeats the point.
new_case
mkdir -p "$CASE_DIR/gh-config"
printf 'github.com:\n    oauth_token: gho_plain\n' > "$CASE_DIR/gh-config/hosts.yml"
PATH="$GH_FAKE_BIN:$PATH" FAKE_GH_TOKEN=gho_plain GH_CONFIG_DIR="$CASE_DIR/gh-config" \
  run_capsule --with github --shell --session gh-plain "$ROOT_DIR"
assert_contains "$OUTPUT" 'plain text'
assert_not_contains "$OUTPUT" 'gho_plain'

# Token dirs of finished launches are removed. A live launch keeps its own.
new_case
runtime_root="$TEST_ROOT/xdg/agent-capsule-$UID"
mkdir -p "$runtime_root/gh-999999999" "$runtime_root/gh-$$"
touch "$runtime_root/gh-999999999/token" "$runtime_root/gh-$$/token"
run_capsule --shell --session gh-sweep "$ROOT_DIR"
[[ ! -e "$runtime_root/gh-999999999" ]] || fail "a finished launch's token dir survived"
[[ -e "$runtime_root/gh-$$/token" ]] || fail "a live launch's token dir was removed"
rm -rf "$runtime_root/gh-$$"

# The entrypoint moves the token into GH_TOKEN and deletes the file before the
# command starts.
new_case
printf 'gho_entry' > "$CASE_DIR/token"
# shellcheck disable=SC2016
AGENT_CAPSULE_GH_TOKEN_FILE="$CASE_DIR/token" "$BASH_BIN" "$ROOT_DIR/entrypoint.sh" \
  "$BASH_BIN" -c 'printf "%s" "$GH_TOKEN"; [[ ! -e "$AGENT_CAPSULE_GH_TOKEN_FILE" ]]' > "$OUTPUT"
[[ "$(<"$OUTPUT")" == gho_entry ]] || fail "entrypoint did not export GH_TOKEN"

# Without a private CA the capsule gets no CA mount and no CA variable.
new_case
run_capsule --shell --session ca-off "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/ca'
assert_not_contains "$PODMAN_LOG" 'AGENT_CAPSULE_CA_DIR'

# A configured CA file alone exposes nothing, so it is safe to export from a shell
# profile: only --ca mounts it. Nor is the file checked, so a stale path blocks no run.
new_case
printf -- '-----BEGIN CERTIFICATE-----\nMIIBcapsuleRootOne\n-----END CERTIFICATE-----\n' > "$CASE_DIR/corp.pem"
for configured_ca in "$CASE_DIR/corp.pem" "$CASE_DIR/missing.pem"; do
  : > "$PODMAN_LOG"
  AGENT_CAPSULE_CA_CERTS="$configured_ca" run_capsule --shell --session ca-configured "$ROOT_DIR"
  assert_contains "$PODMAN_LOG" 'CALL=run'
  assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/ca'
  assert_not_contains "$PODMAN_LOG" 'AGENT_CAPSULE_CA_DIR'
done

# --ca without a file to trust stops the launch before podman runs.
new_case
status=0
run_capsule --ca --shell --session ca-unset "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" 'AGENT_CAPSULE_CA_CERTS'
assert_not_contains "$PODMAN_LOG" 'CALL='

# Only certificates cross over, in a private file under the runtime dir: a key
# kept in the same PEM must never reach the capsule. Windows exports use CRLF.
new_case
{
  printf 'subject=CN = Corp Root\n'
  printf -- '-----BEGIN CERTIFICATE-----\nMIIBcapsuleRootOne\n-----END CERTIFICATE-----\n'
  printf -- '-----BEGIN PRIVATE KEY-----\nMIGHcapsuleSecretKey\n-----END PRIVATE KEY-----\n'
  printf -- '-----BEGIN CERTIFICATE-----\r\nMIIBcapsuleRootTwo\r\n-----END CERTIFICATE-----\r\n'
} > "$CASE_DIR/corp.pem"
AGENT_CAPSULE_CA_CERTS="$CASE_DIR/corp.pem" run_capsule --ca --shell --session ca-on "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_CA_DIR=/run/agent-capsule/ca'
assert_not_contains "$PODMAN_LOG" 'MIIBcapsuleRoot'
assert_contains "$OUTPUT" '2 certificates'
ca_dir="$(sed -n 's|^ARG=\(.*\):/run/agent-capsule/ca\(:.*\)\{0,1\}$|\1|p' "$PODMAN_LOG")"
[[ "$ca_dir" == "$TEST_ROOT/xdg/"* ]] || fail "CA dir is outside the runtime dir: $ca_dir"
expected_ca="$(printf -- '%s\n' '-----BEGIN CERTIFICATE-----' MIIBcapsuleRootOne \
  '-----END CERTIFICATE-----' '-----BEGIN CERTIFICATE-----' MIIBcapsuleRootTwo \
  '-----END CERTIFICATE-----')"
[[ "$(<"$ca_dir/extra.pem")" == "$expected_ca" ]] || fail "extra.pem does not hold exactly the certificates"
[[ "$(file_mode "$ca_dir")" == 700 ]] || fail "CA dir is not private"
[[ "$(file_mode "$ca_dir/extra.pem")" == 600 ]] || fail "extra.pem is not private"

# A CA file that is missing or holds no certificate stops the launch before podman runs.
new_case
printf -- '-----BEGIN PRIVATE KEY-----\nMIGHcapsuleSecretKey\n-----END PRIVATE KEY-----\n' \
  > "$CASE_DIR/key-only.pem"
for bad_ca in "$CASE_DIR/missing.pem" "$CASE_DIR/key-only.pem"; do
  status=0
  AGENT_CAPSULE_CA_CERTS="$bad_ca" run_capsule --ca --shell --session ca-bad "$ROOT_DIR" || status=$?
  assert_status_fails "$status"
  assert_contains "$OUTPUT" "$bad_ca"
  assert_not_contains "$PODMAN_LOG" 'CALL='
done

# The entrypoint points TLS clients at the CA, so its dir lives as long as the
# session. The next launch removes those of finished launches, never a live one's.
new_case
runtime_root="$TEST_ROOT/xdg/agent-capsule-$UID"
mkdir -p "$runtime_root/ca-999999999" "$runtime_root/ca-$$"
touch "$runtime_root/ca-999999999/extra.pem" "$runtime_root/ca-$$/extra.pem"
run_capsule --shell --session ca-sweep "$ROOT_DIR"
[[ ! -e "$runtime_root/ca-999999999" ]] || fail "a finished launch's CA dir survived"
[[ -e "$runtime_root/ca-$$/extra.pem" ]] || fail "a live launch's CA dir was removed"
rm -rf "$runtime_root/ca-$$"

# The entrypoint adds the CA to what the capsule already trusts. git and Node read
# neither SSL_CERT_FILE nor each other's variable, so each gets its own.
new_case
mkdir -p "$CASE_DIR/ca"
printf 'BASE ROOTS\n' > "$CASE_DIR/base.pem"
printf 'EXTRA ROOT\n' > "$CASE_DIR/ca/extra.pem"
# shellcheck disable=SC2016
SSL_CERT_FILE="$CASE_DIR/base.pem" AGENT_CAPSULE_CA_DIR="$CASE_DIR/ca" \
  "$BASH_BIN" "$ROOT_DIR/entrypoint.sh" "$BASH_BIN" -c \
  'printf "%s\n" "$SSL_CERT_FILE" "$GIT_SSL_CAINFO" "$NODE_EXTRA_CA_CERTS"; cat "$SSL_CERT_FILE"' \
  > "$OUTPUT"
expected_trust="$(printf '%s\n' "$CASE_DIR/ca/bundle.pem" "$CASE_DIR/ca/bundle.pem" \
  "$CASE_DIR/ca/extra.pem" 'BASE ROOTS' 'EXTRA ROOT')"
[[ "$(<"$OUTPUT")" == "$expected_trust" ]] || fail "entrypoint did not extend the trust store: $(<"$OUTPUT")"
# shellcheck disable=SC2016
env -u SSL_CERT_FILE -u GIT_SSL_CAINFO -u NODE_EXTRA_CA_CERTS \
  "$BASH_BIN" "$ROOT_DIR/entrypoint.sh" "$BASH_BIN" -c \
  'printf "%s" "${SSL_CERT_FILE-}${GIT_SSL_CAINFO-}${NODE_EXTRA_CA_CERTS-}"' > "$OUTPUT"
[[ ! -s "$OUTPUT" ]] || fail "entrypoint changed TLS trust without a CA: $(<"$OUTPUT")"

# Without gitlab the host glab is never asked, and the capsule gets no token, no
# token mount, no GitLab variable and no git rewrite.
new_case
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN=glpat-offtoken \
  run_capsule --shell --session glab-off "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_GITLAB=0'
[[ ! -s "$GLAB_LOG" ]] || fail "host glab was called without --with gitlab"
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/glab'
assert_not_contains "$PODMAN_LOG" 'GITLAB_'
assert_not_contains "$PODMAN_LOG" 'GLAB_CONFIG_DIR'
assert_not_contains "$PODMAN_LOG" 'GIT_CONFIG_'

# The token crosses over in a host-bound glab config under the runtime dir, never on the
# podman command line. A keyring login leaves an empty token in the host's config.yml.
new_case
mkdir -p "$CASE_DIR/glab-config"
printf 'hosts:\n    gitlab.com:\n        token: ""\n        use_keyring: "true"\n' \
  > "$CASE_DIR/glab-config/config.yml"
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN=glpat-secret123 GLAB_CONFIG_DIR="$CASE_DIR/glab-config" \
  run_capsule --with gitlab --shell --session glab-on "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_GITLAB=1'
assert_not_contains "$PODMAN_LOG" 'glpat-secret123'
assert_not_contains "$OUTPUT" 'plain text'
assert_contains "$PODMAN_LOG" 'ARG=GLAB_CONFIG_DIR=/run/agent-capsule/glab'
assert_not_contains "$PODMAN_LOG" 'GITLAB_TOKEN'
assert_contains "$PODMAN_LOG" 'ARG=GITLAB_HOST=gitlab.com'
glab_dir="$(sed -n 's|^ARG=\(.*\):/run/agent-capsule/glab\(:.*\)\{0,1\}$|\1|p' "$PODMAN_LOG")"
[[ "$glab_dir" == "$TEST_ROOT/xdg/"* ]] || fail "glab dir is outside the runtime dir: $glab_dir"
expected_glab_config="$(printf '%s\n' 'hosts:' '    gitlab.com:' "        token: 'glpat-secret123'")"
[[ "$(<"$glab_dir/config.yml")" == "$expected_glab_config" ]] ||
  fail "the glab config does not bind the token to gitlab.com: $(<"$glab_dir/config.yml")"
[[ "$(file_mode "$glab_dir")" == 700 ]] || fail "glab dir is not private"
[[ "$(file_mode "$glab_dir/config.yml")" == 600 ]] || fail "glab config is not private"

# A self-managed instance: its remotes go over HTTPS with glab's credentials,
# whatever form they take, and glab targets it outside a repository too.
new_case
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_HOST=gitlab.corp.example FAKE_GLAB_TOKEN=glpat-corp \
  AGENT_CAPSULE_GITLAB_HOST=gitlab.corp.example \
  run_capsule --with gitlab --shell --session glab-corp "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=GITLAB_HOST=gitlab.corp.example'
glab_dir="$(sed -n 's|^ARG=\(.*\):/run/agent-capsule/glab\(:.*\)\{0,1\}$|\1|p' "$PODMAN_LOG")"
expected_glab_config="$(printf '%s\n' 'hosts:' '    gitlab.corp.example:' "        token: 'glpat-corp'")"
[[ "$(<"$glab_dir/config.yml")" == "$expected_glab_config" ]] ||
  fail "the glab config does not bind the token to the instance: $(<"$glab_dir/config.yml")"
mapfile -t git_env < <(sed -n 's/^ARG=\(GIT_CONFIG_.*\)$/\1/p' "$PODMAN_LOG")
for remote in git@gitlab.corp.example:g/r ssh://git@gitlab.corp.example/g/r; do
  rewritten="$(env "${git_env[@]}" HOME="$CASE_DIR" GIT_CONFIG_NOSYSTEM=1 \
    git ls-remote --get-url "$remote")"
  [[ "$rewritten" == https://gitlab.corp.example/g/r ]] || fail "$remote became $rewritten"
done
credential="$(printf 'protocol=https\nhost=gitlab.corp.example\npath=g/r\n\n' |
  env "${git_env[@]}" PATH="$GLAB_FAKE_BIN:$PATH" HOME="$CASE_DIR" GIT_CONFIG_NOSYSTEM=1 \
    GIT_TERMINAL_PROMPT=0 FAKE_GLAB_TOKEN=glpat-corp git credential fill)"
[[ "$credential" == *password=glpat-corp* ]] || fail "git does not ask glab for GitLab credentials"

# With both forges, each keeps its own rewrite and credential helper.
new_case
PATH="$GH_FAKE_BIN:$GLAB_FAKE_BIN:$PATH" FAKE_GH_TOKEN=gho_both FAKE_GLAB_TOKEN=glpat-both \
  run_capsule --with github,gitlab --shell --session forges "$ROOT_DIR"
mapfile -t git_env < <(sed -n 's/^ARG=\(GIT_CONFIG_.*\)$/\1/p' "$PODMAN_LOG")
for host_and_token in github.com=gho_both gitlab.com=glpat-both; do
  host="${host_and_token%%=*}"
  rewritten="$(env "${git_env[@]}" HOME="$CASE_DIR" GIT_CONFIG_NOSYSTEM=1 \
    git ls-remote --get-url "git@$host:o/r")"
  [[ "$rewritten" == "https://$host/o/r" ]] || fail "git@$host:o/r became $rewritten"
  credential="$(printf 'protocol=https\nhost=%s\npath=o/r\n\n' "$host" |
    env "${git_env[@]}" PATH="$GH_FAKE_BIN:$GLAB_FAKE_BIN:$PATH" HOME="$CASE_DIR" \
      GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 FAKE_GH_TOKEN=gho_both \
      FAKE_GLAB_TOKEN=glpat-both git credential fill)"
  [[ "$credential" == *"password=${host_and_token#*=}"* ]] || fail "wrong credentials for $host"
done

# A host without a glab login for the instance still starts the capsule, and says how to log in.
new_case
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN='' \
  run_capsule --with gitlab --shell --session glab-logged-out "$ROOT_DIR"
assert_contains "$OUTPUT" 'glab auth login --hostname gitlab.com'
assert_contains "$PODMAN_LOG" 'CALL=run'
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/glab'

# An OAuth token expires within hours, and refreshing it in the capsule would log
# the host out, so only a personal access token crosses over.
new_case
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN=oauth-access-token FAKE_GLAB_OAUTH=true \
  run_capsule --with gitlab --shell --session glab-oauth "$ROOT_DIR"
assert_contains "$OUTPUT" 'personal access token'
assert_contains "$PODMAN_LOG" 'CALL=run'
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/glab'

# A host glab without a keyring keeps its token in plain text.
new_case
mkdir -p "$CASE_DIR/glab-config"
printf 'hosts:\n    gitlab.com:\n        token: glpat-plain\n' > "$CASE_DIR/glab-config/config.yml"
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN=glpat-plain GLAB_CONFIG_DIR="$CASE_DIR/glab-config" \
  run_capsule --with gitlab --shell --session glab-plain "$ROOT_DIR"
assert_contains "$OUTPUT" 'plain text'
assert_not_contains "$OUTPUT" 'glpat-plain'

# The host ends up in git config keys and URLs, so only a bare hostname passes.
new_case
for bad_host in https://gitlab.corp.example gitlab.corp.example:8443 gitlab.corp.example/sub \
  -gitlab.corp.example; do
  status=0
  PATH="$GLAB_FAKE_BIN:$PATH" AGENT_CAPSULE_GITLAB_HOST="$bad_host" \
    run_capsule --with gitlab --shell --session glab-bad-host "$ROOT_DIR" || status=$?
  assert_status_fails "$status"
  assert_contains "$OUTPUT" "$bad_host"
  assert_not_contains "$PODMAN_LOG" 'CALL='
done
# A launch without gitlab never uses the host, so a bad one does not stop it.
PATH="$GLAB_FAKE_BIN:$PATH" AGENT_CAPSULE_GITLAB_HOST=gitlab.corp.example:8443 \
  run_capsule --shell --session glab-unused-host "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=run'

# A token exported on the host would answer for any instance, so only the stored
# login for the instance crosses over, and only a stored OAuth flag counts.
new_case
for env_token in GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN; do
  : > "$PODMAN_LOG"
  (export "$env_token=glpat-from-env" &&
    PATH="$GLAB_FAKE_BIN:$PATH" run_capsule --with gitlab --shell --session glab-env-token "$ROOT_DIR")
  assert_contains "$OUTPUT" 'glab auth login --hostname gitlab.com'
  assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/glab'
done
: > "$PODMAN_LOG"
GITLAB_TOKEN=glpat-from-env GLAB_IS_OAUTH2=false FAKE_GLAB_OAUTH=true PATH="$GLAB_FAKE_BIN:$PATH" \
  FAKE_GLAB_TOKEN=oauth-stored run_capsule --with gitlab --shell --session glab-env-token "$ROOT_DIR"
assert_contains "$OUTPUT" 'personal access token'
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/glab'
: > "$PODMAN_LOG"
GITLAB_TOKEN=glpat-from-env PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN=glpat-stored \
  run_capsule --with gitlab --shell --session glab-env-token "$ROOT_DIR"
glab_dir="$(sed -n 's|^ARG=\(.*\):/run/agent-capsule/glab\(:.*\)\{0,1\}$|\1|p' "$PODMAN_LOG")"
expected_glab_config="$(printf '%s\n' 'hosts:' '    gitlab.com:' "        token: 'glpat-stored'")"
[[ "$(<"$glab_dir/config.yml")" == "$expected_glab_config" ]] ||
  fail "the host's GITLAB_TOKEN replaced the stored login: $(<"$glab_dir/config.yml")"

# glab reads its config for the whole session, so the next launch removes the dirs
# of finished sessions, never a live one's.
new_case
runtime_root="$TEST_ROOT/xdg/agent-capsule-$UID"
mkdir -p "$runtime_root/glab-999999999" "$runtime_root/glab-$$"
touch "$runtime_root/glab-999999999/config.yml" "$runtime_root/glab-$$/config.yml"
run_capsule --shell --session glab-sweep "$ROOT_DIR"
[[ ! -e "$runtime_root/glab-999999999" ]] || fail "a finished session's glab dir survived"
[[ -e "$runtime_root/glab-$$/config.yml" ]] || fail "a live session's glab dir was removed"
rm -rf "$runtime_root/glab-$$"

# Every capsule runs without capabilities or privilege escalation, within limits,
# and --offline takes the network away.
new_case
run_capsule --shell --session hardening "$ROOT_DIR"
for flag in --security-opt=no-new-privileges --cap-drop=ALL --pids-limit=512 --memory=8g --cpus=4; do
  assert_contains "$PODMAN_LOG" "ARG=$flag"
done
assert_not_contains "$PODMAN_LOG" 'ARG=--network=none'
: > "$PODMAN_LOG"
run_capsule --offline --shell --session hardening "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=--network=none'

# One login serves every session: a new session copies the agent's state from the
# auth home, but the token only through a read-write mount of the shared file.
new_case
auth_home="$CAPSULE_HOME/auth-home/claude"
mkdir -p "$auth_home/.claude"
printf '{}\n' > "$auth_home/.claude.json"
printf 'oauth-token\n' > "$auth_home/.claude/.credentials.json"
run_capsule --shell --session shared-auth "$ROOT_DIR"
[[ -f "$CAPSULE_HOME/homes/shared-auth/.claude.json" ]] || fail "the agent state was not copied"
[[ ! -e "$CAPSULE_HOME/homes/shared-auth/.claude/.credentials.json" ]] || fail "the token was copied"
assert_contains "$PODMAN_LOG" \
  "ARG=$auth_home/.claude/.credentials.json:/home/dev/.claude/.credentials.json"
: > "$PODMAN_LOG"
AGENT_CAPSULE_SHARE_AUTH=0 run_capsule --shell --session unshared-auth "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" '.credentials.json'
[[ ! -e "$CAPSULE_HOME/homes/unshared-auth/.claude.json" ]] || fail "unshared auth was copied"

# mcpvault reaches each agent its own way: a config file for claude, -c for codex.
new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
run_capsule --with mcpvault --vault="$vault_dir" --session mcp-claude "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --mcp-config /home/dev/.mcp-servers.json
assert_contains "$CAPSULE_HOME/homes/mcp-claude/.mcp-servers.json" '"args": ["/vault"]'
: > "$PODMAN_LOG"
run_capsule --agent codex --with mcpvault --vault="$vault_dir" --session mcp-codex "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" -c 'mcp_servers.obsidian.command="mcpvault"'
assert_arg_after "$PODMAN_LOG" -c 'mcp_servers.obsidian.args=["/vault"]'

new_case
run_capsule --agent claude --with superpowers,anydoc \
  --session claude-integrations "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" claude --plugin-dir
assert_arg_after "$PODMAN_LOG" --plugin-dir /opt/superpowers/source
assert_contains "$PODMAN_LOG" 'ARG=/opt/anydoc/plugin'

: > "$PODMAN_LOG"
run_capsule --agent claude --with none --session claude-no-integrations "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'ARG=/opt/superpowers/source'
assert_not_contains "$PODMAN_LOG" 'ARG=/opt/anydoc/plugin'

new_case
status=0
run_capsule --with hunkdiff --session removed-hunkdiff "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" 'Unknown extra tool: hunkdiff'

new_case
run_capsule --agent codex --auth-login
assert_arg_after "$PODMAN_LOG" codex login
assert_arg_after "$PODMAN_LOG" login --device-auth

new_case
run_capsule --agent opencode --auth-login -- provider
assert_arg_after "$PODMAN_LOG" opencode auth
assert_arg_after "$PODMAN_LOG" auth login
assert_arg_after "$PODMAN_LOG" login provider

new_case
AGENT_CAPSULE_WITH=superpowers run_capsule --agent opencode --auth-login
assert_arg_after "$PODMAN_LOG" -e 'AGENT_CAPSULE_WITH='
assert_not_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT='
assert_not_contains "$PODMAN_LOG" '/opt/superpowers/source'
assert_contains "$OUTPUT" '>> Extras  : none'

# API keys cross over like the gh token, as files under the runtime dir: podman would
# store `-e NAME` values in the container config on disk.
new_case
ANTHROPIC_API_KEY=anthropic-secret OPENAI_API_KEY=openai-secret \
  run_capsule --agent opencode --session opencode-env "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'ARG=ANTHROPIC_API_KEY'
assert_not_contains "$PODMAN_LOG" 'ARG=OPENAI_API_KEY'
assert_not_contains "$PODMAN_LOG" 'anthropic-secret'
assert_not_contains "$PODMAN_LOG" 'openai-secret'
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_KEYS_DIR=/run/agent-capsule/keys'
keys_dir="$(sed -n 's|^ARG=\(.*\):/run/agent-capsule/keys\(:.*\)\{0,1\}$|\1|p' "$PODMAN_LOG")"
[[ "$keys_dir" == "$TEST_ROOT/xdg/"* ]] || fail "keys dir is outside the runtime dir: $keys_dir"
[[ "$(<"$keys_dir/ANTHROPIC_API_KEY")" == anthropic-secret ]] || fail "the Anthropic key was not handed over"
[[ "$(<"$keys_dir/OPENAI_API_KEY")" == openai-secret ]] || fail "the OpenAI key was not handed over"
[[ "$(file_mode "$keys_dir")" == 700 ]] || fail "keys dir is not private"
[[ "$(file_mode "$keys_dir/OPENAI_API_KEY")" == 600 ]] || fail "key file is not private"
# Each agent gets only its own provider's key, and no key means no handoff at all.
: > "$PODMAN_LOG"
ANTHROPIC_API_KEY=anthropic-secret OPENAI_API_KEY=openai-secret \
  run_capsule --agent claude --shell --session claude-env "$ROOT_DIR"
keys_dir="$(sed -n 's|^ARG=\(.*\):/run/agent-capsule/keys\(:.*\)\{0,1\}$|\1|p' "$PODMAN_LOG")"
[[ -f "$keys_dir/ANTHROPIC_API_KEY" && ! -e "$keys_dir/OPENAI_API_KEY" ]] || fail "claude got the wrong keys"
: > "$PODMAN_LOG"
run_capsule --agent claude --shell --session claude-env "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/keys'

# The entrypoint moves each key into the environment and deletes its file first thing.
new_case
mkdir -p "$CASE_DIR/keys"
printf 'sk-entry' > "$CASE_DIR/keys/ANTHROPIC_API_KEY"
# shellcheck disable=SC2016
AGENT_CAPSULE_KEYS_DIR="$CASE_DIR/keys" "$BASH_BIN" "$ROOT_DIR/entrypoint.sh" \
  "$BASH_BIN" -c 'printf "%s" "$ANTHROPIC_API_KEY"; [[ ! -e "$AGENT_CAPSULE_KEYS_DIR/ANTHROPIC_API_KEY" ]]' \
  > "$OUTPUT"
[[ "$(<"$OUTPUT")" == sk-entry ]] || fail "entrypoint did not export ANTHROPIC_API_KEY"

# Key dirs of launches that died before their entrypoint ran are removed, never a live one's.
new_case
runtime_root="$TEST_ROOT/xdg/agent-capsule-$UID"
mkdir -p "$runtime_root/keys-999999999" "$runtime_root/keys-$$"
touch "$runtime_root/keys-999999999/ANTHROPIC_API_KEY" "$runtime_root/keys-$$/ANTHROPIC_API_KEY"
run_capsule --shell --session keys-sweep "$ROOT_DIR"
[[ ! -e "$runtime_root/keys-999999999" ]] || fail "a finished launch's keys dir survived"
[[ -e "$runtime_root/keys-$$/ANTHROPIC_API_KEY" ]] || fail "a live launch's keys dir was removed"
rm -rf "$runtime_root/keys-$$"

new_case
status=0
run_capsule --agent codex --with anydoc --session unsupported-extra "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" "Extra 'anydoc' is not available with --agent codex"

new_case
status=0
run_capsule --with= --shell --session empty-extra "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" '--with requires a tool list'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
mount_file="$CASE_DIR/tool.conf"
printf '%s\n' setting > "$mount_file"
run_capsule --shell --session file-mount --mount "$mount_file:/etc/tool.conf:ro" "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$mount_file:/etc/tool.conf:ro"

new_case
status=0
run_capsule --shell --session missing-vault --vault "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" 'No vault configured. Use --vault=PATH or set AGENT_CAPSULE_VAULT.'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
AGENT_CAPSULE_VAULT="$vault_dir" \
  run_capsule --shell --session configured-vault --vault "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$vault_dir:/vault"

new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
status=0
AGENT_CAPSULE_VAULT_DEST=relative \
  run_capsule --shell --session invalid-vault-destination --vault="$vault_dir" "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" 'Invalid vault destination: relative'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
long_session="$(printf 'a%.0s' {1..121})"
status=0
run_capsule --shell --session "$long_session" "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" 'not starting with a dot'

new_case
status=0
run_capsule --shell --session 'fix/auth' "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" "Invalid session name: 'fix/auth'."
[[ ! -e "$CAPSULE_HOME/homes/fixauth" ]] || fail "invalid session name was normalized"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
status=0
run_capsule --shell --session= "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" '--session requires a name.'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
hidden_project="$CASE_DIR/.dotfiles"
mkdir -p "$hidden_project"
run_capsule --shell "$hidden_project"
assert_contains "$OUTPUT" '>> Session : dotfiles-'
assert_not_contains "$OUTPUT" 'Invalid session name'

for invalid_session in . ..; do
  new_case
  status=0
  run_capsule --shell --session "$invalid_session" "$ROOT_DIR" || status=$?
  assert_status_fails "$status"
  assert_contains "$OUTPUT" "Invalid session name: '$invalid_session'"
  assert_not_contains "$PODMAN_LOG" 'CALL=run'
done


# Editing the entrypoint must invalidate the image, or a fix to it never ships.
new_case
entrypoint_copy="$CASE_DIR/entrypoint.sh"
cp "$ROOT_DIR/entrypoint.sh" "$entrypoint_copy"
# Nix store sources are read-only, but this case intentionally mutates its copy.
chmod u+w "$entrypoint_copy"
dockerfile_copy="$CASE_DIR/Dockerfile"
cp "$ROOT_DIR/Dockerfile" "$dockerfile_copy"
mkdir -p "$CASE_DIR/plugins"
cp -R "$ROOT_DIR/plugins/worklog" "$CASE_DIR/plugins/worklog"
AGENT_CAPSULE_DOCKERFILE="$dockerfile_copy" run_capsule --shell --session entrypoint-hash "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
: > "$PODMAN_LOG"
AGENT_CAPSULE_DOCKERFILE="$dockerfile_copy" run_capsule --shell --session entrypoint-hash "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'
printf '\n' >> "$entrypoint_copy"
: > "$PODMAN_LOG"
AGENT_CAPSULE_DOCKERFILE="$dockerfile_copy" run_capsule --shell --session entrypoint-hash "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
run_capsule --with mcpvault,worklog --vault="$vault_dir" --session worklog-on "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --plugin-dir /opt/worklog/plugin
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_VAULT_DEST=/vault'
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_WORKLOG=1'
assert_contains "$OUTPUT" '>> Worklog : built-in procedure'
assert_not_contains "$PODMAN_LOG" '/etc/agent-capsule/log-work.md'
[[ ! -e "$CAPSULE_HOME/log-work.md" ]] || fail "the default procedure file was created"

printf 'steps\n' > "$CAPSULE_HOME/log-work.md"
: > "$PODMAN_LOG"
run_capsule --with mcpvault,worklog --vault="$vault_dir" --session worklog-on "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/log-work.md:/etc/agent-capsule/log-work.md:ro"
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_WORKLOG_PROCEDURE=/etc/agent-capsule/log-work.md'
assert_contains "$OUTPUT" ">> Worklog : $CAPSULE_HOME/log-work.md -> /etc/agent-capsule/log-work.md"

new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
printf 'mine\n' > "$CASE_DIR/mine.md"
AGENT_CAPSULE_WORKLOG_PROCEDURE="$CASE_DIR/mine.md" \
  run_capsule --with mcpvault,worklog --vault="$vault_dir" --session worklog-explicit "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$CASE_DIR/mine.md:/etc/agent-capsule/log-work.md:ro"
assert_contains "$OUTPUT" ">> Worklog : $CASE_DIR/mine.md -> /etc/agent-capsule/log-work.md"

new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
status=0
AGENT_CAPSULE_WORKLOG_PROCEDURE="$CASE_DIR/missing.md" \
  run_capsule --with mcpvault,worklog --vault="$vault_dir" --session worklog-missing "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" "File not found: $CASE_DIR/missing.md"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

# A symlinked default is a user-managed file, not a missing one.
new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir" "$CASE_DIR/notes"
printf 'linked\n' > "$CASE_DIR/notes/log-work.md"
ln -s "$CASE_DIR/notes/log-work.md" "$CAPSULE_HOME/log-work.md"
run_capsule --with mcpvault,worklog --vault="$vault_dir" --session worklog-link "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/log-work.md:/etc/agent-capsule/log-work.md:ro"
assert_contains "$OUTPUT" ">> Worklog : $CAPSULE_HOME/log-work.md -> /etc/agent-capsule/log-work.md"
# A broken one fails loudly instead of falling back to the built-in procedure.
rm "$CASE_DIR/notes/log-work.md"
: > "$PODMAN_LOG"
status=0
run_capsule --with mcpvault,worklog --vault="$vault_dir" --session worklog-link "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" "File not found: $CAPSULE_HOME/log-work.md"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
status=0
run_capsule --with worklog --vault="$vault_dir" --session worklog-no-mcp "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" '--with worklog needs mcpvault.'
assert_contains "$OUTPUT" 'Add mcpvault to --with or AGENT_CAPSULE_WITH.'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
status=0
AGENT_CAPSULE_WITH=mcpvault \
  run_capsule --with worklog --vault="$vault_dir" --session worklog-flag-only "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" '--with worklog needs mcpvault.'
assert_contains "$OUTPUT" 'Add mcpvault to --with or AGENT_CAPSULE_WITH.'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
run_capsule --with mcpvault,worklog --no-vault --session worklog-no-vault "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Worklog : disabled for this run (--no-vault)'
assert_not_contains "$PODMAN_LOG" 'ARG=/opt/worklog/plugin'
assert_not_contains "$PODMAN_LOG" 'AGENT_CAPSULE_VAULT_DEST'

new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
status=0
run_capsule --agent codex --with mcpvault,worklog --vault="$vault_dir" --session worklog-codex "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" "Extra 'worklog' is not available with --agent codex"

new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir"
AGENT_CAPSULE_WITH=mcpvault,worklog \
  run_capsule --agent codex --vault="$vault_dir" --shell --session worklog-drop "$ROOT_DIR"
assert_contains "$OUTPUT" ">> Extras  : dropping 'worklog' (unsupported by agent codex)"

# The plugin ships in the image, so editing it has to invalidate the image.
new_case
vault_dir="$CASE_DIR/vault"
mkdir -p "$vault_dir" "$CASE_DIR/plugins"
cp "$ROOT_DIR/Dockerfile" "$CASE_DIR/Dockerfile"
cp "$ROOT_DIR/entrypoint.sh" "$CASE_DIR/entrypoint.sh"
cp -R "$ROOT_DIR/plugins/worklog" "$CASE_DIR/plugins/worklog"
chmod -R u+w "$CASE_DIR/plugins/worklog"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" \
  run_capsule --with mcpvault,worklog --vault="$vault_dir" --shell --session worklog-hash "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
: > "$PODMAN_LOG"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" \
  run_capsule --with mcpvault,worklog --vault="$vault_dir" --shell --session worklog-hash "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'
printf '\n' >> "$CASE_DIR/plugins/worklog/procedure.md"
: > "$PODMAN_LOG"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" \
  run_capsule --with mcpvault,worklog --vault="$vault_dir" --shell --session worklog-hash "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'

# Unselected, the plugin is inert, so editing it rebuilds nothing.
: > "$PODMAN_LOG"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" \
  run_capsule --with none --shell --session worklog-unselected "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
printf '\n' >> "$CASE_DIR/plugins/worklog/procedure.md"
: > "$PODMAN_LOG"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" \
  run_capsule --with none --shell --session worklog-unselected "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'

# Nix store sources are read-only, and a copy of them must still be replaceable.
new_case
mkdir -p "$CASE_DIR/plugins"
cp "$ROOT_DIR/Dockerfile" "$CASE_DIR/Dockerfile"
cp "$ROOT_DIR/entrypoint.sh" "$CASE_DIR/entrypoint.sh"
cp -R "$ROOT_DIR/plugins/worklog" "$CASE_DIR/plugins/worklog"
chmod -R a-w "$CASE_DIR/plugins/worklog"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" \
  run_capsule --build --shell --session worklog-readonly "$ROOT_DIR"
chmod -R a-w "$CAPSULE_HOME/build/context/plugins/worklog"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" \
  run_capsule --build --shell --session worklog-readonly "$ROOT_DIR"
[[ -w "$CAPSULE_HOME/build/context/plugins/worklog/procedure.md" ]] || fail "the context copy is read-only"

new_case
cp "$ROOT_DIR/Dockerfile" "$CASE_DIR/Dockerfile"
cp "$ROOT_DIR/entrypoint.sh" "$CASE_DIR/entrypoint.sh"
status=0
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" run_capsule --shell --session worklog-noplugin "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" 'Container plugin not found:'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
run_capsule --help
assert_contains "$OUTPUT" 'worklog'

new_case
run_capsule --build --shell --session forced-build "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=--pull=always'
assert_contains "$PODMAN_LOG" 'ARG=--no-cache'
assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/build/context"

new_case
SUPERPOWERS_DISABLE_TELEMETRY=superpowers-secret \
  DISABLE_TELEMETRY=general-secret \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=traffic-secret \
  run_capsule --shell --session telemetry-env --with superpowers "$ROOT_DIR"
for variable in \
  SUPERPOWERS_DISABLE_TELEMETRY \
  DISABLE_TELEMETRY \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC; do
  assert_contains "$PODMAN_LOG" "ARG=$variable"
done
assert_not_contains "$PODMAN_LOG" 'superpowers-secret'
assert_not_contains "$PODMAN_LOG" 'general-secret'
assert_not_contains "$PODMAN_LOG" 'traffic-secret'

# Containers default to UTC; the host zone keeps dates and commit times aligned.
for tz_value in Asia/Kathmandu :Asia/Kathmandu /usr/share/zoneinfo/Asia/Kathmandu \
  :/usr/share/zoneinfo/Asia/Kathmandu; do
  new_case
  TZ="$tz_value" run_capsule --shell --session tz-env "$ROOT_DIR"
  assert_arg_after "$PODMAN_LOG" -e 'TZ=Asia/Kathmandu'
done

# Empty, or naming a file with a leading colon: fall back to the /etc/localtime link.
localtime_target="$(readlink /etc/localtime 2>/dev/null || true)"
for tz_value in '' ':/etc/localtime' '/etc/localtime'; do
  new_case
  TZ="$tz_value" run_capsule --shell --session tz-fallback "$ROOT_DIR"
  if [[ "$localtime_target" == *zoneinfo/* ]]; then
    assert_arg_after "$PODMAN_LOG" -e "TZ=${localtime_target#*zoneinfo/}"
  else
    assert_not_contains "$PODMAN_LOG" 'ARG=TZ='
  fi
done

# An exported CDPATH makes cd print where it went, which would double every resolved path.
new_case
mkdir -p "$CASE_DIR/proj"
(cd "$CASE_DIR" && CDPATH=".:/nonexistent" run_capsule --shell --session cdpath proj)
assert_arg_after "$PODMAN_LOG" -w "$CASE_DIR/proj"

# Status goes to stderr, so `agent-capsule . -- -p q > out` captures only the agent.
new_case
HOME="$HOST_HOME" PATH="$FAKE_BIN:$PATH" PODMAN_LOG="$PODMAN_LOG" \
  PODMAN_IMAGE_STATE="$PODMAN_IMAGE_STATE" AGENT_CAPSULE_HOME="$CAPSULE_HOME" \
  AGENT_CAPSULE_DOCKERFILE="$DOCKERFILE" XDG_RUNTIME_DIR="$TEST_ROOT/xdg" \
  "$BASH_BIN" "$SCRIPT" --session piped "$ROOT_DIR" -- -p question > "$OUTPUT" 2> "$CASE_DIR/stderr"
[[ ! -s "$OUTPUT" ]] || fail "status reached stdout: $(head -n 3 "$OUTPUT")"
assert_contains "$CASE_DIR/stderr" '>> Project :'

# --auth-login only needs the agent CLI, so any image of that agent will do: rebuilding
# without the integrations would only make the next normal run rebuild them.
new_case
run_capsule --with superpowers --shell --session auth-reuse "$ROOT_DIR"
: > "$PODMAN_LOG"
run_capsule --auth-login --shell
assert_not_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" -e 'AGENT_CAPSULE_WITH='
: > "$PODMAN_LOG"
run_capsule --with superpowers --shell --session auth-reuse "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'
: > "$PODMAN_LOG"
run_capsule --agent codex --auth-login --shell
assert_contains "$PODMAN_LOG" 'CALL=build'

# The run starts the image this launch checked under the build lock, not the tag:
# another launch with a different selection can move the tag right after the lock.
new_case
run_capsule --session image-id "$ROOT_DIR" -- --version
image_id="id-$(awk -F '\t' 'END { print $2 }' "$PODMAN_IMAGE_STATE")"
assert_arg_after "$PODMAN_LOG" "$image_id" claude

# The image age limit is a decimal count of days, whatever leading zeros it has.
for age_and_refresh in 08:yes 010:no 00:no; do
  new_case
  PODMAN_BUILD_EPOCH="$(($(date +%s) - 9 * 86400))" run_capsule --shell --session age-digits "$ROOT_DIR"
  : > "$PODMAN_LOG"
  AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS="${age_and_refresh%%:*}" \
    run_capsule --shell --session age-digits "$ROOT_DIR"
  if [[ "${age_and_refresh#*:}" == yes ]]; then
    assert_contains "$PODMAN_LOG" 'ARG=--no-cache'
  else
    assert_not_contains "$PODMAN_LOG" 'ARG=--no-cache'
  fi
  assert_not_contains "$OUTPUT" 'value too great'
done

# A configured rules file that does not exist is a typo, not a file to create.
new_case
status=0
AGENT_CAPSULE_SHARED_RULES="$CASE_DIR/typo/CLAUDE.md" \
  run_capsule --shell --session rules-typo "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" "$CASE_DIR/typo/CLAUDE.md"
[[ ! -e "$CASE_DIR/typo" ]] || fail "the mistyped rules path was created"

# A lone dash is not a project: cd would read it as $OLDPWD.
new_case
status=0
OLDPWD=/etc run_capsule --shell - || status=$?
assert_status_fails "$status"
assert_not_contains "$PODMAN_LOG" 'CALL='

# Handoff files are only in memory under XDG_RUNTIME_DIR; the status must not claim it otherwise.
new_case
printf -- '-----BEGIN CERTIFICATE-----\nMIIBcapsuleRootOne\n-----END CERTIFICATE-----\n' > "$CASE_DIR/corp.pem"
mkdir -p "$CASE_DIR/tmp"
HOME="$HOST_HOME" PATH="$FAKE_BIN:$PATH" PODMAN_LOG="$PODMAN_LOG" \
  PODMAN_IMAGE_STATE="$PODMAN_IMAGE_STATE" AGENT_CAPSULE_HOME="$CAPSULE_HOME" \
  AGENT_CAPSULE_DOCKERFILE="$DOCKERFILE" TMPDIR="$CASE_DIR/tmp" AGENT_CAPSULE_CA_CERTS="$CASE_DIR/corp.pem" \
  "$BASH_BIN" "$SCRIPT" --ca --shell --session on-disk "$ROOT_DIR" > "$OUTPUT" 2>&1
assert_not_contains "$OUTPUT" 'kept in memory'
assert_contains "$OUTPUT" "$CASE_DIR/tmp/agent-capsule-$UID"
rm -rf "$CASE_DIR/tmp"

# A project path too long to name a memory folder skips shared memory instead of failing.
new_case
long_project="$CASE_DIR/$(printf 'p%.0s' {1..130})/$(printf 'q%.0s' {1..130})"
mkdir -p "$long_project"
run_capsule --shell --session long-path "$long_project"
assert_contains "$PODMAN_LOG" 'CALL=run'
assert_not_contains "$PODMAN_LOG" '/home/dev/.claude/projects/'
assert_contains "$OUTPUT" 'project memory'

new_case
portable_bin="$CASE_DIR/portable-bin"
mkdir -p "$portable_bin"
command -v shasum >/dev/null || fail "this case needs shasum, the fallback it checks"
for tool in bash awk tr mkdir chmod touch cp cat date dirname basename shasum rm sleep; do
  ln -s "$(command -v "$tool")" "$portable_bin/$tool"
done
HOME="$HOST_HOME" \
  PATH="$portable_bin:$FAKE_BIN" \
  PODMAN_LOG="$PODMAN_LOG" \
  PODMAN_IMAGE_STATE="$PODMAN_IMAGE_STATE" \
  AGENT_CAPSULE_HOME="$CAPSULE_HOME" \
  AGENT_CAPSULE_DOCKERFILE="$DOCKERFILE" \
  XDG_RUNTIME_DIR="$TEST_ROOT/xdg" \
  "$BASH_BIN" "$SCRIPT" --shell --session shasum-fallback "$ROOT_DIR" > "$OUTPUT" 2>&1
assert_contains "$PODMAN_LOG" 'CALL=run'
[[ "$(file_mode "$CAPSULE_HOME/CLAUDE.md")" == "600" ]] || fail "default rules mode is not private"

new_case
codex_home="$CAPSULE_HOME/homes/codex-owned"
mkdir -p "$codex_home/.codex"
printf '%s\n' codex > "$codex_home/.agent"
status=0
run_capsule --shell --session codex-owned "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" "was created by agent 'codex'"

new_case
HERDR_AGENT=codex run_capsule --shell --session herdr-divergence "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Agent   : claude (HERDR_AGENT=codex)'

new_case
status=0
run_capsule --shared-claude-md "$CASE_DIR/x.md" --shell --session removed-flag "$ROOT_DIR" || status=$?
assert_status_fails "$status"
assert_contains "$OUTPUT" 'Unknown option: --shared-claude-md'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
repo_root="$CASE_DIR/repositories"
main_repo="$repo_root/main"
linked_repo="$repo_root/linked"
mkdir -p "$main_repo"
git -C "$main_repo" init -q
git -C "$main_repo" -c user.name=test -c user.email=test@example.com \
  commit --allow-empty -qm init
git -C "$main_repo" worktree add -qb linked "$linked_repo"
run_capsule --shell --session linked-worktree "$linked_repo"
assert_contains "$PODMAN_LOG" "ARG=$linked_repo:$linked_repo"
assert_contains "$PODMAN_LOG" "ARG=$linked_repo:/workspace"
assert_contains "$PODMAN_LOG" "ARG=$main_repo/.git:$main_repo/.git"
assert_contains "$OUTPUT" ">> Git     : $main_repo/.git (linked-worktree metadata)"
assert_arg_after "$PODMAN_LOG" -w "$linked_repo"
# The host memory dir pools on the main worktree; the container path must
# match the slug claude derives from its cwd, here the linked worktree.
memory_hash="$(printf '%s' "$main_repo" | "${SHA256_COMMAND[@]}" | cut -c1-12)"
memory_slug="$(printf '%s' "$linked_repo" | tr -c 'a-zA-Z0-9' '-')"
assert_contains "$PODMAN_LOG" \
  "ARG=$CAPSULE_HOME/project-memory/$memory_hash:/home/dev/.claude/projects/$memory_slug/memory"

# Launching from a plain subdirectory must not mount the repository .git:
# without its worktree around it, git in the container would report the
# whole repo as deleted.
: > "$PODMAN_LOG"
sub_dir="$main_repo/pkg"
mkdir -p "$sub_dir"
run_capsule --shell --session subdir-launch "$sub_dir"
assert_contains "$PODMAN_LOG" 'CALL=run'
assert_not_contains "$PODMAN_LOG" "ARG=$main_repo/.git:"
assert_not_contains "$OUTPUT" 'linked-worktree metadata'
sub_slug="$(printf '%s' "$sub_dir" | tr -c 'a-zA-Z0-9' '-')"
assert_contains "$PODMAN_LOG" \
  "ARG=$CAPSULE_HOME/project-memory/$memory_hash:/home/dev/.claude/projects/$sub_slug/memory"

new_case
(
  RUN_OUTPUT="$CASE_DIR/first.output" PODMAN_BUILD_DELAY=0.2 \
    run_capsule --shell --session concurrent-first "$ROOT_DIR"
) &
first_pid=$!
(
  RUN_OUTPUT="$CASE_DIR/second.output" PODMAN_BUILD_DELAY=0.2 \
    run_capsule --shell --session concurrent-second "$ROOT_DIR"
) &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
[[ "$(grep -c '^CALL=build$' "$PODMAN_LOG")" == "1" ]] ||
  fail "concurrent launches built the image more than once"
[[ ! -e "$TEST_ROOT/xdg/agent-capsule-$UID/image.lock" ]] ||
  fail "image build lock was not removed"

# A process killed before its EXIT trap leaves a stale lock. The next launch
# must reclaim it instead of waiting forever.
new_case
stale_lock_root="$TEST_ROOT/xdg/agent-capsule-$UID"
mkdir -p "$stale_lock_root"
printf '%s\n' 999999999 > "$stale_lock_root/image.lock"
status=0
timeout 2 env \
  HOME="$HOST_HOME" \
  PATH="$FAKE_BIN:$PATH" \
  PODMAN_LOG="$PODMAN_LOG" \
  PODMAN_IMAGE_STATE="$PODMAN_IMAGE_STATE" \
  AGENT_CAPSULE_HOME="$CAPSULE_HOME" \
  AGENT_CAPSULE_DOCKERFILE="$DOCKERFILE" \
  XDG_RUNTIME_DIR="$TEST_ROOT/xdg" \
  "$BASH_BIN" "$SCRIPT" --shell --session stale-lock "$ROOT_DIR" > "$OUTPUT" 2>&1 || status=$?
[[ "$status" == "0" ]] || fail "stale image lock was not reclaimed"
assert_contains "$PODMAN_LOG" 'CALL=build'

# A directory at the lock path is reported and left alone, never waited on.
new_case
legacy_lock_root="$TEST_ROOT/xdg/agent-capsule-$UID"
mkdir -p "$legacy_lock_root/image.lock"
status=0
timeout 2 env \
  HOME="$HOST_HOME" \
  PATH="$FAKE_BIN:$PATH" \
  PODMAN_LOG="$PODMAN_LOG" \
  PODMAN_IMAGE_STATE="$PODMAN_IMAGE_STATE" \
  AGENT_CAPSULE_HOME="$CAPSULE_HOME" \
  AGENT_CAPSULE_DOCKERFILE="$DOCKERFILE" \
  XDG_RUNTIME_DIR="$TEST_ROOT/xdg" \
  "$BASH_BIN" "$SCRIPT" --shell --session legacy-lock "$ROOT_DIR" > "$OUTPUT" 2>&1 || status=$?
assert_status_fails "$status"
[[ -d "$legacy_lock_root/image.lock" ]] || fail "legacy image lock was removed"
assert_contains "$OUTPUT" 'Not a lock file'
rmdir "$legacy_lock_root/image.lock"

# Shell completion asks the launcher for these two lists, so the contract is
# one value per line, exit 0, and no podman anywhere near it.
new_case
run_capsule --agent list
[[ "$(cat "$OUTPUT")" == "$(printf 'claude\ncodex\nopencode')" ]] ||
  fail "--agent list is not one agent per line"
assert_not_contains "$PODMAN_LOG" 'CALL='
run_capsule --with list
expected_extras="$(printf '%s\n' anydoc explain-diff github gitlab kubernetes mcpvault superpowers talos \
  worklog)"
[[ "$(cat "$OUTPUT")" == "$expected_extras" ]] ||
  fail "--with list is not one integration per line"
assert_not_contains "$PODMAN_LOG" 'CALL='

# The completion script reads the extras from the launcher on PATH.
new_case
completion_bin="$CASE_DIR/completion-bin"
mkdir -p "$completion_bin"
printf '#!%s\nexec %s %s "$@"\n' "$BASH_BIN" "$BASH_BIN" "$SCRIPT" > "$completion_bin/agent-capsule"
chmod +x "$completion_bin/agent-capsule"
claude_extras="$(
  PATH="$completion_bin:$PATH" HOME="$HOST_HOME" AGENT_CAPSULE_HOME="$CAPSULE_HOME" "$BASH_BIN" -c \
    "source '$ROOT_DIR/completions/agent-capsule.bash'; _agent_capsule_extras claude"
)"
codex_extras="$(
  PATH="$completion_bin:$PATH" HOME="$HOST_HOME" AGENT_CAPSULE_HOME="$CAPSULE_HOME" "$BASH_BIN" -c \
    "source '$ROOT_DIR/completions/agent-capsule.bash'; _agent_capsule_extras codex"
)"
opencode_extras="$(
  PATH="$completion_bin:$PATH" HOME="$HOST_HOME" AGENT_CAPSULE_HOME="$CAPSULE_HOME" "$BASH_BIN" -c \
    "source '$ROOT_DIR/completions/agent-capsule.bash'; _agent_capsule_extras opencode"
)"
grep -qx worklog <<<"$claude_extras" || fail "claude completion does not offer worklog"
if grep -qx worklog <<<"$codex_extras"; then fail "codex completion offers worklog"; fi
if grep -qx worklog <<<"$opencode_extras"; then fail "opencode completion offers worklog"; fi

# Both must work with no podman on PATH at all: completion runs in shells that
# have never launched a capsule.
new_case
nopodman_bin="$CASE_DIR/nopodman-bin"
mkdir -p "$nopodman_bin"
for tool in bash awk tr cat; do
  ln -s "$(command -v "$tool")" "$nopodman_bin/$tool"
done
for subcommand in '--agent list' '--with list'; do
  # shellcheck disable=SC2086
  HOME="$HOST_HOME" PATH="$nopodman_bin" AGENT_CAPSULE_HOME="$CAPSULE_HOME" \
    "$BASH_BIN" "$SCRIPT" $subcommand > "$OUTPUT" 2>&1 ||
    fail "$subcommand failed with no podman on PATH"
  [[ -s "$OUTPUT" ]] || fail "$subcommand printed nothing"
done

# Rebuilding strands the image it replaced, so a build prunes what it superseded.
new_case
PODMAN_DANGLING="$CASE_DIR/dangling"
printf '%s\n' aaaa1111 bbbb2222 > "$PODMAN_DANGLING"
run_capsule --shell --session prune-after-build "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_contains "$PODMAN_LOG" 'CALL=images'
assert_arg_after "$PODMAN_LOG" rmi aaaa1111
assert_arg_after "$PODMAN_LOG" rmi bbbb2222
assert_contains "$OUTPUT" '>> Pruned  : 2 superseded image(s)'
# The filters are all that keep rmi off images this tool did not build or still tags.
assert_arg_after "$PODMAN_LOG" --filter 'label=io.agent-capsule.bundle'
assert_arg_after "$PODMAN_LOG" --filter 'dangling=true'
[[ ! -s "$PODMAN_DANGLING" ]] || fail "superseded images were not removed"

# A launch that does not build leaves them alone.
new_case
PODMAN_DANGLING="$CASE_DIR/dangling"
: > "$PODMAN_DANGLING"
run_capsule --shell --session prune-no-build "$ROOT_DIR"
printf '%s\n' cccc3333 > "$PODMAN_DANGLING"
: > "$PODMAN_LOG"
run_capsule --shell --session prune-no-build "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'
assert_not_contains "$PODMAN_LOG" 'CALL=rmi'

new_case
PODMAN_DANGLING="$CASE_DIR/dangling"
printf '%s\n' dddd4444 > "$PODMAN_DANGLING"
AGENT_CAPSULE_PRUNE=0 run_capsule --shell --session prune-disabled "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_not_contains "$PODMAN_LOG" 'CALL=rmi'
assert_not_contains "$OUTPUT" '>> Pruned'

# Removing caches rewrites directory times, which must not make an idle home look used.
new_case
make_session_home idle-home 40
run_capsule --prune-caches --yes
run_capsule --prune-sessions
assert_contains "$OUTPUT" 'idle-home'

# Without --yes, prune only reports. Homes with nothing to free are not listed.
new_case
make_session_home idle-home 40
make_session_home recent-home 1
mkdir -p "$CAPSULE_HOME/homes/no-caches"
printf 'claude\n' > "$CAPSULE_HOME/homes/no-caches/.agent"
find "$CAPSULE_HOME/homes/no-caches" -maxdepth 1 -exec touch -t "$(days_ago_stamp 40)" {} +
run_capsule --prune-caches
assert_contains "$OUTPUT" 'idle-home'
assert_not_contains "$OUTPUT" 'recent-home'
assert_not_contains "$OUTPUT" 'no-caches'
[[ -d "$CAPSULE_HOME/homes/idle-home/.cache" ]] || fail "dry run removed caches"
assert_not_contains "$PODMAN_LOG" 'CALL=build'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

# Pruning caches keeps what does not rebuild itself: transcripts, settings and
# tools the session installed.
run_capsule --prune-caches --yes
idle_home="$CAPSULE_HOME/homes/idle-home"
for removed in .cache .npm go/pkg; do
  [[ ! -e "$idle_home/$removed" ]] || fail "$removed survived --prune-caches"
done
for kept in .agent .claude.json .claude/projects/p/s.jsonl go/bin/tool; do
  [[ -e "$idle_home/$kept" ]] || fail "--prune-caches removed $kept"
done
[[ -d "$CAPSULE_HOME/homes/recent-home/.cache" ]] || fail "--prune-caches touched a recent home"

# Whole homes go, except recent, running and symlinked ones. State outside homes/
# is never a candidate.
new_case
make_session_home idle-home 40
make_session_home recent-home 1
make_session_home running-home 40
outside_home="$CASE_DIR/outside-home"
mkdir -p "$outside_home"
printf 'claude\n' > "$outside_home/.agent"
find "$outside_home" -maxdepth 1 -exec touch -t "$(days_ago_stamp 40)" {} +
ln -s "$outside_home" "$CAPSULE_HOME/homes/linked-home"
touch -h -t "$(days_ago_stamp 40)" "$CAPSULE_HOME/homes/linked-home"
mkdir -p "$CAPSULE_HOME/auth-home/claude" "$CAPSULE_HOME/project-memory/abc"
touch "$CAPSULE_HOME/auth-home/claude/.credentials.json" "$CAPSULE_HOME/project-memory/abc/MEMORY.md"
printf '%s\n' running-home > "$CASE_DIR/running"
PODMAN_RUNNING="$CASE_DIR/running" run_capsule --prune-sessions --yes
[[ ! -e "$CAPSULE_HOME/homes/idle-home" ]] || fail "idle home survived --prune-sessions"
for kept in homes/recent-home homes/running-home homes/linked-home \
  auth-home/claude/.credentials.json project-memory/abc/MEMORY.md; do
  [[ -e "$CAPSULE_HOME/$kept" ]] || fail "--prune-sessions removed $kept"
done
[[ -f "$outside_home/.agent" ]] || fail "--prune-sessions followed a symlinked home"

# Homes from before the marker refresh still count as used when the agent wrote
# to them recently.
new_case
make_session_home legacy-home 40
touch "$CAPSULE_HOME/homes/legacy-home/.claude.json"
run_capsule --prune-sessions
assert_not_contains "$OUTPUT" 'legacy-home'

# A write below the top level still counts as use.
new_case
make_session_home deep-write 40
touch "$CAPSULE_HOME/homes/deep-write/.claude/projects/p/s.jsonl"
run_capsule --prune-sessions
assert_not_contains "$OUTPUT" 'deep-write'

# A symlinked go/ must not lead --prune-caches out of the home.
new_case
make_session_home linked-go 40
linked_go_home="$CAPSULE_HOME/homes/linked-go"
outside_go="$CASE_DIR/outside-go"
mkdir -p "$outside_go/pkg"
touch "$outside_go/pkg/keep"
chmod -R u+w "$linked_go_home/go"
rm -rf "$linked_go_home/go"
ln -s "$outside_go" "$linked_go_home/go"
find "$linked_go_home" -maxdepth 1 -exec touch -h -t "$(days_ago_stamp 40)" {} +
run_capsule --prune-caches --yes
[[ -e "$outside_go/pkg/keep" ]] || fail "--prune-caches followed a symlinked go/"
[[ ! -e "$linked_go_home/.cache" ]] || fail "--prune-caches skipped the rest of a home with a symlinked go/"

new_case
make_session_home ten-days 10
run_capsule --prune-sessions
assert_not_contains "$OUTPUT" 'ten-days'
run_capsule --prune-sessions=7
assert_contains "$OUTPUT" 'ten-days'
[[ -d "$CAPSULE_HOME/homes/ten-days" ]] || fail "dry run removed a home"

# Without podman's answer nothing proves a home is not in use, so prune stops.
new_case
make_session_home idle-home 40
status=0
PODMAN_PS_FAIL=1 run_capsule --prune-sessions --yes || status=$?
assert_status_fails "$status"
[[ -d "$CAPSULE_HOME/homes/idle-home" ]] || fail "prune removed a home without checking podman"

new_case
for prune_args in '--prune-caches=soon' '--prune-sessions=-1' '--yes' \
  '--prune-caches --prune-sessions' '--prune-sessions=100000' \
  '--prune-sessions --session x' '--prune-sessions .' '--prune-sessions --'; do
  status=0
  # shellcheck disable=SC2086
  run_capsule $prune_args || status=$?
  assert_status_fails "$status"
  assert_not_contains "$OUTPUT" 'Unknown option'
done
assert_not_contains "$PODMAN_LOG" 'CALL='

# Every launch records last use on the session marker.
new_case
make_session_home relaunched 40
run_capsule --shell --session relaunched "$ROOT_DIR"
(($(date +%s) - $(file_mtime "$CAPSULE_HOME/homes/relaunched/.agent") < 3600)) ||
  fail "launch did not refresh the session marker"

# The image lives in podman's store, not under AGENT_CAPSULE_HOME, so a second
# capsule home reuses it rather than building its own.
new_case
other_capsule_home="$CASE_DIR/other-capsule"
mkdir -p "$other_capsule_home"
run_capsule --shell --session first-home "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
: > "$PODMAN_LOG"
CAPSULE_HOME="$other_capsule_home" run_capsule --shell --session second-home "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'

# Floating distro tags keep both toolchains on their latest upstream release.
assert_contains "$SCRIPT" "NODE_TAG=\"\${AGENT_CAPSULE_NODE_TAG:-trixie-slim}\""
assert_contains "$SCRIPT" "GO_TAG=\"\${AGENT_CAPSULE_GO_TAG:-trixie}\""
assert_contains "$DOCKERFILE" 'ARG NODE_TAG=trixie-slim'
assert_contains "$DOCKERFILE" 'ARG GO_TAG=trixie'
assert_contains "$DOCKERFILE" 'SUPERPOWERS_VERSION:-latest'
assert_contains "$DOCKERFILE" "tree/v\$anydoc_installed"
for version_variable in \
  ANYDOC_VERSION \
  MCPVAULT_VERSION \
  SKILLS_VERSION \
  CLAUDE_CODE_VERSION \
  CODEX_VERSION \
  OPENCODE_VERSION; do
  assert_contains "$DOCKERFILE" "\${$version_variable:-latest}"
done
# An undeclared build arg is dropped with only a warning, so a pin would be ignored.
for version_variable in KUBECTL_VERSION HELM_VERSION TALOSCTL_VERSION GH_VERSION GLAB_VERSION; do
  awk -v arg="ARG $version_variable" '
    /^FROM / { stage = 1; found = 0 }
    stage && ($0 == arg || index($0, arg "=") == 1) { found = 1 }
    END { exit !found }
  ' "$DOCKERFILE" || fail "$version_variable is not declared after FROM"
done
# A bare `docker build .` must leave the optional CLIs out, like the launcher does.
assert_contains "$DOCKERFILE" 'ARG WITH_KUBERNETES=0'
assert_contains "$DOCKERFILE" 'ARG WITH_TALOS=0'
assert_contains "$DOCKERFILE" 'ARG WITH_GITHUB=0'
assert_contains "$DOCKERFILE" 'ARG WITH_GITLAB=0'

echo "PASS: $pass_count launcher scenarios"
