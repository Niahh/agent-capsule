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
agent=""
image_ref=""
for arg in "$@"; do
  printf 'ARG=%s\n' "$arg" >> "$PODMAN_LOG"
  if [[ "$previous" == "--label" && "$arg" == io.agent-capsule.bundle=* ]]; then
    bundle_hash="${arg#*=}"
  fi
  if [[ "$previous" == "--label" && "$arg" == io.agent-capsule.refreshed-at=* ]]; then
    refreshed_at="${arg#*=}"
  fi
  if [[ "$previous" == "--label" && "$arg" == io.agent-capsule.agent=* ]]; then
    agent="${arg#*=}"
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
    $1 == image { hash = $2; refreshed = $3; agent = $4 }
    END { if (hash != "") print hash " " refreshed " " agent }
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
    "${PODMAN_BUILD_EPOCH:-$refreshed_at}" "$agent" >> "$PODMAN_IMAGE_STATE"
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

case_count=0
CASE_NAME=setup

# exit skips the ERR trap, so the call stack is printed here.
fail() {
  local frame=0

  echo "FAIL in $CASE_NAME: $*" >&2
  while caller "$frame" >&2; do frame=$((frame + 1)); done
  exit 1
}

# Otherwise an unexpected non-zero exit ends the suite silently, and the EXIT trap
# deletes the output that explains it. Expected failures use run_capsule_fails.
on_error() { # status line command
  local frame=1

  echo "FAIL in $CASE_NAME: line $2 exited $1: $3" >&2
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

new_case() { # name
  CASE_NAME="${1:?new_case needs a name}"
  CASE_DIR="$TEST_ROOT/case-$case_count"
  CAPSULE_HOME="$CASE_DIR/capsule"
  HOST_HOME="$CASE_DIR/home"
  PODMAN_LOG="$CASE_DIR/podman.log"
  XDG_DIR="$CASE_DIR/xdg"
  PODMAN_IMAGE_STATE="$CASE_DIR/podman-images"
  VAULT_DIR="$CASE_DIR/vault"
  OUTPUT="$CASE_DIR/output"
  GH_LOG="$CASE_DIR/gh.log"
  GLAB_LOG="$CASE_DIR/glab.log"
  export GH_LOG GLAB_LOG
  mkdir -p "$CAPSULE_HOME" "$HOST_HOME" "$VAULT_DIR"
  : > "$PODMAN_LOG"
  : > "$GH_LOG"
  : > "$GLAB_LOG"
  : > "$PODMAN_IMAGE_STATE"
  PODMAN_DANGLING=""
  ((case_count += 1))
}

# Sets CAPSULE_ENV, the launcher's environment in the current case. Built at call
# time, so a case can override CAPSULE_HOME or PATH for one launch.
capsule_env() {
  CAPSULE_ENV=(
    # An empty volume option, or an SELinux host would add :z to every mount.
    AGENT_CAPSULE_VOLOPT=''
    HOME="$HOST_HOME"
    PATH="$FAKE_BIN:$PATH"
    PODMAN_LOG="$PODMAN_LOG"
    PODMAN_IMAGE_STATE="$PODMAN_IMAGE_STATE"
    PODMAN_DANGLING="${PODMAN_DANGLING:-}"
    AGENT_CAPSULE_HOME="$CAPSULE_HOME"
    AGENT_CAPSULE_DOCKERFILE="${AGENT_CAPSULE_DOCKERFILE:-$DOCKERFILE}"
    XDG_RUNTIME_DIR="$XDG_DIR"
  )
}

run_capsule() {
  # Each launch starts a fresh log, unless launches share one on purpose.
  [[ -n "${KEEP_PODMAN_LOG:-}" ]] || : > "$PODMAN_LOG"
  capsule_env
  env "${CAPSULE_ENV[@]}" "$BASH_BIN" "$SCRIPT" "$@" > "${RUN_OUTPUT:-$OUTPUT}" 2>&1
}

run_capsule_fails() {
  if run_capsule "$@"; then fail "the launcher unexpectedly succeeded: $*"; fi
}

# Prints the host side of the mount whose container side is $1.
mount_source() {
  sed -n "s|^ARG=\(.*\):$1\(:.*\)\{0,1\}\$|\1|p" "$PODMAN_LOG"
}

# Copies the image build files into the case, where it may edit them. Nix store
# sources are read-only, so the copies are made writable.
copy_build_context() {
  mkdir -p "$CASE_DIR/plugins"
  cp "$ROOT_DIR/Dockerfile" "$ROOT_DIR/entrypoint.sh" "$CASE_DIR/"
  cp -R "$ROOT_DIR/plugins/worklog" "$CASE_DIR/plugins/worklog"
  chmod -R u+w "$CASE_DIR/entrypoint.sh" "$CASE_DIR/plugins/worklog"
}

# Launches with the copied build files: the first builds, the second reuses the
# image, and after FILE is edited the third builds again.
assert_edit_rebuilds() { # file launcher-args...
  local file="$1"
  shift

  AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" run_capsule "$@"
  assert_contains "$PODMAN_LOG" 'CALL=build'
  AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" run_capsule "$@"
  assert_not_contains "$PODMAN_LOG" 'CALL=build'
  printf '\n' >> "$file"
  AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" run_capsule "$@"
  assert_contains "$PODMAN_LOG" 'CALL=build'
}

# Completion runs the launcher through PATH, as installed. Under Nix it is a wrapper.
COMPLETION_BIN="$TEST_ROOT/completion-bin"
mkdir -p "$COMPLETION_BIN"
printf '#!%s\nexec %s %s "$@"\n' "$BASH_BIN" "$BASH_BIN" "$SCRIPT" > "$COMPLETION_BIN/agent-capsule"
chmod +x "$COMPLETION_BIN/agent-capsule"

# Runs CODE in a bash that sourced the bash completion, against the current case.
in_completion() {
  PATH="$COMPLETION_BIN:$PATH" HOME="$HOST_HOME" AGENT_CAPSULE_HOME="$CAPSULE_HOME" "$BASH_BIN" -c \
    "source '$ROOT_DIR/completions/agent-capsule.bash'; $1"
}

# Prints the bash completion candidates for a line typed up to its end, one per line.
# bash-completion is not loaded, so this runs the fallback word splitting.
complete_line() {
  # shellcheck disable=SC2016 # COMPREPLY expands in the completion shell.
  COMP_LINE="$1" COMP_POINT="${#1}" in_completion '_agent_capsule; printf "%s\n" "${COMPREPLY[@]}"'
}

new_case explain-diff-skills-dir
for agent_and_skills_dir in \
  'claude|/home/dev/.claude/skills' \
  'codex|/home/dev/.codex/skills' \
  'opencode|/home/dev/.config/opencode/skills'; do
  IFS='|' read -r agent skills_dir <<<"$agent_and_skills_dir"
  run_capsule --agent "$agent" --with explain-diff --shell \
    --session "explain-diff-$agent" "$ROOT_DIR"
  assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_WITH=explain-diff'
  assert_contains "$PODMAN_LOG" "ARG=AGENT_CAPSULE_SKILLS_DIR=$skills_dir"
done

new_case rules-mode-kept
rules_file="$CASE_DIR/rules.md"
touch "$rules_file"
chmod 0644 "$rules_file"
run_capsule --shell --session rules-mode --shared-rules "$rules_file" "$ROOT_DIR"
[[ "$(file_mode "$rules_file")" == "644" ]] || fail "shared rules mode changed"

# The default rules file is created, and created private.
new_case rules-default-private
run_capsule --shell --session rules-default "$ROOT_DIR"
[[ "$(file_mode "$CAPSULE_HOME/CLAUDE.md")" == "600" ]] || fail "default rules mode is not private"

# OpenCode gets superpowers and the vault's MCP server through inline configuration.
opencode_mcp='"mcp":{"obsidian":{"type":"local","command":["mcpvault","/vault"]}}'
new_case opencode-runtime-config
run_capsule --agent opencode --shell --session opencode-state --with superpowers --vault="$VAULT_DIR" "$ROOT_DIR"
assert_contains "$PODMAN_LOG" \
  "OPENCODE_CONFIG_CONTENT={\"plugin\":[\"/opt/superpowers/source\"],$opencode_mcp}"
run_capsule --agent opencode --shell --session opencode-state --with superpowers,vault --no-vault "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT={"plugin":["/opt/superpowers/source"]}'
assert_not_contains "$PODMAN_LOG" 'obsidian'
run_capsule --agent opencode --shell --session opencode-state --with none "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT='

# The inline configuration leaves the user's own OpenCode files alone.
new_case opencode-user-config-kept
user_config="$CAPSULE_HOME/homes/opencode-state/.config/opencode/opencode.json"
mkdir -p "${user_config%/*}"
printf '%s\n' '{"theme":"user-owned"}' > "$user_config"
run_capsule --agent opencode --shell --session opencode-state --vault="$VAULT_DIR" "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "OPENCODE_CONFIG_CONTENT={$opencode_mcp}"
[[ "$(<"$user_config")" == '{"theme":"user-owned"}' ]] || fail "user OpenCode config changed"
run_capsule --agent opencode --shell --session opencode-state --with none "$ROOT_DIR"
[[ "$(<"$user_config")" == '{"theme":"user-owned"}' ]] || fail "user OpenCode config changed"

# --vault and --no-vault are last-one-wins, in both directions.
new_case vault-shortcuts-last-wins
run_capsule --shell --session vault-shortcuts --no-vault --vault="$VAULT_DIR" "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$VAULT_DIR:/vault"
run_capsule --shell --session vault-shortcuts --vault="$VAULT_DIR" --no-vault "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" ':/vault'

# The shortcut flags edit the selection, never replace it.
new_case vault-shortcut-keeps-list
AGENT_CAPSULE_WITH=superpowers run_capsule --shell --session shortcut-keeps --vault="$VAULT_DIR" "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Extras  : superpowers, vault'
AGENT_CAPSULE_TOOLS=gh AGENT_CAPSULE_WITH=superpowers \
  run_capsule --shell --session shortcut-keeps --with github --vault="$VAULT_DIR" "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Extras  : github, vault'
AGENT_CAPSULE_WITH=vault,worklog AGENT_CAPSULE_VAULT="$VAULT_DIR" \
  run_capsule --shell --session shortcut-keeps --no-vault "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Extras  : none'
assert_contains "$OUTPUT" '>> Worklog : disabled for this run (--no-vault)'
assert_not_contains "$PODMAN_LOG" ':/vault'

new_case help-and-version
run_capsule --help
assert_contains "$OUTPUT" 'Usage:'
assert_contains "$OUTPUT" '--versions'
assert_contains "$OUTPUT" '--shared-rules PATH'
assert_contains "$OUTPUT" '--prune-sessions[=DAYS]'
assert_contains "$OUTPUT" 'explain-diff'
assert_contains "$OUTPUT" 'worklog'
assert_contains "$OUTPUT" 'AGENT_CAPSULE_TOOLS'
assert_contains "$OUTPUT" 'kubernetes'
assert_contains "$OUTPUT" 'talos'
assert_not_contains "$PODMAN_LOG" 'CALL='
run_capsule --version
assert_contains "$OUTPUT" "agent-capsule $LAUNCHER_VERSION"

# A config file left over from 0.2 is inert: never read, never an error.
new_case leftover-0.2-config
printf '%s\n' 'AGENT_CAPSULE_AGENT=codex' 'accidentally-pasted-secret' \
  > "$CAPSULE_HOME/config"
run_capsule --shell --session leftover-config "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Agent   : claude'
assert_not_contains "$OUTPUT" 'accidentally-pasted-secret'
assert_not_contains "$OUTPUT" '>> Config'
assert_contains "$PODMAN_LOG" 'CALL=run'

new_case versions-pinned-and-latest
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
new_case pins-reach-build-args
run_capsule --shell --session unpinned-build "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'CLAUDE_CODE_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'SUPERPOWERS_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'KUBECTL_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'HELM_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'TALOSCTL_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'GH_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'GLAB_VERSION='
AGENT_CAPSULE_CLAUDE_CODE_VERSION=9.8.7 \
  run_capsule --shell --session pinned-build "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'CLAUDE_CODE_VERSION=9.8.7'

# Each CLI pin must be part of the bundle hash, or pinning it after an
# unpinned build would keep the old image.
new_case cli-pins-in-bundle-hash
for cluster_pin in KUBECTL_VERSION=v1.2.3 HELM_VERSION=v4.5.6 TALOSCTL_VERSION=v7.8.9 \
  GH_VERSION=v2.3.4 GLAB_VERSION=v1.2.3; do
  run_capsule --shell --session cluster-pins "$ROOT_DIR"
  (export "AGENT_CAPSULE_$cluster_pin" && run_capsule --shell --session cluster-pins "$ROOT_DIR")
  assert_contains "$PODMAN_LOG" 'CALL=build'
  assert_arg_after "$PODMAN_LOG" --build-arg "$cluster_pin"
done

# An image older than the age limit is refreshed without the layer cache, or an
# unpinned install would reproduce exactly what is already there.
new_case stale-image-refresh
PODMAN_BUILD_EPOCH=1000000000 run_capsule --shell --session stale-image "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
run_capsule --shell --session stale-image "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_contains "$PODMAN_LOG" 'ARG=--no-cache'
assert_contains "$OUTPUT" 'days old, refreshing'

# The first build establishes the refresh epoch and cannot trust old builder
# cache left behind after an earlier tag was removed.
new_case first-build-refresh
run_capsule --shell --session first-refresh "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=--pull=always'
assert_contains "$PODMAN_LOG" 'ARG=--no-cache'
assert_contains "$PODMAN_LOG" 'ARG=io.agent-capsule.refreshed-at='

# The tool list and freshness are independent. A stale image must refresh even when
# a new tool list also changes its bundle hash.
new_case stale-image-new-tools
PODMAN_BUILD_EPOCH=1000000000 run_capsule --shell --session stale-tools "$ROOT_DIR"
AGENT_CAPSULE_TOOLS=gh run_capsule --shell --session stale-tools "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_contains "$PODMAN_LOG" 'ARG=--pull=always'
assert_contains "$PODMAN_LOG" 'ARG=--no-cache'

# Each agent has its own tag, so switching back and forth rebuilds nothing.
new_case image-per-agent
run_capsule --agent claude --shell --session tag-claude "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" -t agent-capsule-dev:claude
run_capsule --agent codex --shell --session tag-codex "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" -t agent-capsule-dev:codex
run_capsule --agent claude --shell --session tag-claude "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'
# A tagged AGENT_CAPSULE_IMAGE is one image that every agent shares.
for agent in claude codex; do
  AGENT_CAPSULE_IMAGE=foo:bar run_capsule --agent "$agent" --shell --session "tag-custom-$agent" "$ROOT_DIR"
  assert_arg_after "$PODMAN_LOG" -t foo:bar
done

new_case image-age-disabled
PODMAN_BUILD_EPOCH=1000000000 run_capsule --shell --session age-disabled "$ROOT_DIR"
AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS=0 \
  run_capsule --shell --session age-disabled "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'

new_case image-age-invalid
AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS=weekly run_capsule_fails --shell "$ROOT_DIR"
assert_contains "$OUTPUT" 'Invalid AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS: weekly'
assert_not_contains "$PODMAN_LOG" 'CALL='

# The image age limit is a decimal count of days, whatever leading zeros it has.
for age_and_refresh in 08:yes 010:no 00:no; do
  new_case image-age-digits
  PODMAN_BUILD_EPOCH="$(($(date +%s) - 9 * 86400))" run_capsule --shell --session age-digits "$ROOT_DIR"
  AGENT_CAPSULE_MAX_IMAGE_AGE_DAYS="${age_and_refresh%%:*}" \
    run_capsule --shell --session age-digits "$ROOT_DIR"
  if [[ "${age_and_refresh#*:}" == yes ]]; then
    assert_contains "$PODMAN_LOG" 'ARG=--no-cache'
  else
    assert_not_contains "$PODMAN_LOG" 'ARG=--no-cache'
  fi
  assert_not_contains "$OUTPUT" 'value too great'
done

new_case package-pin-prerelease
AGENT_CAPSULE_CLAUDE_CODE_VERSION=1.2.3-beta.1+build.7 run_capsule --versions
assert_contains "$OUTPUT" 'claude-code 1.2.3-beta.1+build.7'

new_case tag-pin-prerelease
AGENT_CAPSULE_SUPERPOWERS_VERSION=v1.2.3-beta.1+build.7 run_capsule --versions
assert_contains "$OUTPUT" 'superpowers v1.2.3-beta.1+build.7'

new_case package-pin-invalid
AGENT_CAPSULE_CLAUDE_CODE_VERSION=invalid run_capsule_fails --shell "$ROOT_DIR"
assert_contains "$OUTPUT" 'Invalid pinned package version: invalid'
assert_not_contains "$PODMAN_LOG" 'CALL='

# Cluster CLI releases are tagged with a leading v, which the download URLs need.
new_case tag-pin-needs-v
AGENT_CAPSULE_KUBECTL_VERSION=1.37.1 run_capsule_fails --shell "$ROOT_DIR"
assert_contains "$OUTPUT" 'Invalid pinned tagged version: 1.37.1'
assert_not_contains "$PODMAN_LOG" 'CALL='

# A session from the environment is an ambient default; only an
# explicit --session conflicts with the dedicated auth home.
new_case auth-login-ambient-session
AGENT_CAPSULE_SESSION=configured-session run_capsule --auth-login
assert_contains "$OUTPUT" '>> Session : _auth'

new_case auth-login-explicit-session
run_capsule_fails --auth-login --session explicit-session
assert_contains "$OUTPUT" '--auth-login uses its own session'

for agent in claude codex opencode; do
  new_case "auth-login-offline-$agent"
  run_capsule_fails --agent "$agent" --auth-login --offline
  assert_contains "$OUTPUT" '--auth-login cannot be combined with --offline'
done

# These values must stay aligned when another agent profile is added.
for profile in \
  'claude|claude|.claude/CLAUDE.md' \
  'codex|codex|.codex/AGENTS.md' \
  'opencode|opencode|.config/opencode/AGENTS.md'; do
  IFS='|' read -r agent command rules_path <<< "$profile"
  new_case "agent-profile-$agent"
  run_capsule --agent "$agent" --session "profile-$agent" "$ROOT_DIR" -- --version
  assert_contains "$PODMAN_LOG" "ARG=ai.agent=$agent"
  assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/CLAUDE.md:/home/dev/$rules_path:ro"
  image_id="id-$(awk -F '\t' 'END { print $2 }' "$PODMAN_IMAGE_STATE")"
  assert_arg_after "$PODMAN_LOG" "$image_id" "$command"
  assert_arg_after "$PODMAN_LOG" "$command" '--version'
done

# The shared 0.1 authentication home stops the launch without changing files.
new_case legacy-auth-home
legacy_credential="$CAPSULE_HOME/auth-home/.claude/.credentials.json"
mkdir -p "$(dirname "$legacy_credential")"
printf '%s\n' token > "$legacy_credential"
run_capsule_fails --shell --session legacy-auth-home "$ROOT_DIR"
assert_contains "$OUTPUT" "Authentication state from agent-capsule 0.1: $CAPSULE_HOME/auth-home/.claude"
[[ "$(<"$legacy_credential")" == token ]] || fail "0.1 credential changed"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case auth-login-own-home
for agent in claude codex opencode; do
  mkdir -p "$CAPSULE_HOME/auth-home/$agent"
done
run_capsule --agent codex --auth-login -- --with-api-key
assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/auth-home/codex:/home/dev"
assert_not_contains "$PODMAN_LOG" "$CAPSULE_HOME/auth-home/claude:/home/dev"
assert_not_contains "$PODMAN_LOG" "$CAPSULE_HOME/auth-home/opencode:/home/dev"

new_case codex-device-login
run_capsule --agent codex --auth-login
assert_arg_after "$PODMAN_LOG" codex login
assert_arg_after "$PODMAN_LOG" login --device-auth

new_case opencode-login-args
run_capsule --agent opencode --auth-login -- provider
assert_arg_after "$PODMAN_LOG" opencode auth
assert_arg_after "$PODMAN_LOG" auth login
assert_arg_after "$PODMAN_LOG" login provider

new_case auth-login-no-extras
AGENT_CAPSULE_WITH=superpowers run_capsule --agent opencode --auth-login
assert_arg_after "$PODMAN_LOG" -e 'AGENT_CAPSULE_WITH='
assert_not_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT='
assert_not_contains "$PODMAN_LOG" '/opt/superpowers/source'
assert_contains "$OUTPUT" '>> Extras  : none'

# --auth-login only needs the agent CLI, so any image of that agent will do, even one
# built with other tools or due a refresh: a rebuild would only cost the next run one.
new_case auth-login-reuses-image
PODMAN_BUILD_EPOCH=1000000000 AGENT_CAPSULE_TOOLS=gh run_capsule --shell --session auth-reuse "$ROOT_DIR"
run_capsule --auth-login --shell
assert_not_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" -e 'AGENT_CAPSULE_WITH='
# Another agent's image will not do.
run_capsule --agent codex --auth-login --shell
assert_contains "$PODMAN_LOG" 'CALL=build'

# The image holds the agent and the user's tools. --with only changes the run,
# so a run with other integrations reuses the image.
new_case with-never-rebuilds
run_capsule --shell --with superpowers --session with-a "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
run_capsule --shell --with explain-diff,anydoc --session with-b "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_WITH=anydoc,explain-diff'
assert_not_contains "$PODMAN_LOG" 'WITH_'

# Tools reach the build as TOOL_* args, read like --with: case folded, deduplicated,
# in a fixed order. Without the variable, none is built in.
new_case tools-build-args
run_capsule --shell --session tools-none "$ROOT_DIR"
for tool_arg in TOOL_GH=0 TOOL_GLAB=0 TOOL_KUBERNETES=0 TOOL_TALOS=0; do
  assert_arg_after "$PODMAN_LOG" --build-arg "$tool_arg"
done
assert_contains "$PODMAN_LOG" 'ARG=io.agent-capsule.tools=none'
assert_contains "$OUTPUT" '>> Tools   : none'
AGENT_CAPSULE_TOOLS=Talos,gh,talos run_capsule --shell --session tools-some "$ROOT_DIR"
for tool_arg in TOOL_GH=1 TOOL_GLAB=0 TOOL_KUBERNETES=0 TOOL_TALOS=1; do
  assert_arg_after "$PODMAN_LOG" --build-arg "$tool_arg"
done
assert_contains "$PODMAN_LOG" 'ARG=io.agent-capsule.tools=gh,talos'
assert_contains "$OUTPUT" '>> Tools   : gh,talos'

# A tool list change rebuilds from cache, so the last refresh survives it.
new_case tools-change-rebuilds
# A day old, so a rebuild that reset the refresh time would show.
PODMAN_BUILD_EPOCH="$(($(date +%s) - 86400))" run_capsule --shell --session tools-change "$ROOT_DIR"
refreshed_at="$(awk -F '\t' 'END { print $3 }' "$PODMAN_IMAGE_STATE")"
[[ -n "$refreshed_at" ]] || fail "the stub recorded no refresh time"
AGENT_CAPSULE_TOOLS=kubernetes run_capsule --shell --session tools-change "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'TOOL_KUBERNETES=1'
assert_not_contains "$PODMAN_LOG" 'ARG=--no-cache'
assert_contains "$PODMAN_LOG" "ARG=io.agent-capsule.refreshed-at=$refreshed_at"

# Switching the agent changes what is installed, so it must rebuild.
new_case agent-change-rebuilds
run_capsule --agent claude --shell --session agent-claude "$ROOT_DIR"
run_capsule --agent codex --shell --session agent-codex "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'AGENT=codex'
assert_contains "$PODMAN_LOG" 'ARG=io.agent-capsule.agent=codex'
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_AGENT=codex'

# A pin of any agent's CLI is part of the hash, whichever agent runs.
new_case version-change-rebuilds
run_capsule --agent codex --shell --session version-change "$ROOT_DIR"
AGENT_CAPSULE_CLAUDE_CODE_VERSION=9.8.7 run_capsule --agent codex --shell --session version-change "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'CLAUDE_CODE_VERSION=9.8.7'

new_case custom-image
AGENT_CAPSULE_IMAGE=preexisting:image run_capsule --agent codex --shell --session custom-image "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_contains "$PODMAN_LOG" 'ARG=preexisting:image'

# kubernetes and talos are tools now, and every tool name in --with says where it goes.
new_case tool-name-in-with
for tool in kubernetes talos gh glab; do
  run_capsule_fails --with "$tool" --shell --session tool-in-with "$ROOT_DIR"
  assert_contains "$OUTPUT" "$tool is a tool: add it to AGENT_CAPSULE_TOOLS, not --with."
  assert_not_contains "$PODMAN_LOG" 'CALL='
done

new_case unknown-tool
AGENT_CAPSULE_TOOLS=gh,terraform run_capsule_fails --shell --session unknown-tool "$ROOT_DIR"
assert_contains "$OUTPUT" 'Unknown tool in AGENT_CAPSULE_TOOLS: terraform (known: gh glab kubernetes talos)'
assert_not_contains "$PODMAN_LOG" 'CALL='

# A forge integration lends its CLI the host login, so the CLI must be a tool, from
# the command line or from the environment.
new_case forge-needs-tool
for forge_and_tool in github:gh gitlab:glab; do
  forge="${forge_and_tool%%:*}"
  tool="${forge_and_tool#*:}"
  run_capsule_fails --with "$forge" --shell --session forge-needs-tool "$ROOT_DIR"
  assert_contains "$OUTPUT" "--with $forge needs $tool in the image: add $tool to AGENT_CAPSULE_TOOLS."
  AGENT_CAPSULE_WITH="$forge" run_capsule_fails --shell --session forge-needs-tool "$ROOT_DIR"
  assert_contains "$OUTPUT" "--with $forge needs $tool in the image"
  assert_not_contains "$PODMAN_LOG" 'CALL='
done

# The cluster CLIs work with every agent.
new_case cluster-tools
for agent in claude codex opencode; do
  AGENT_CAPSULE_TOOLS=talos,kubernetes run_capsule --agent "$agent" --shell --session "cluster-$agent" "$ROOT_DIR"
  assert_arg_after "$PODMAN_LOG" --build-arg 'TOOL_KUBERNETES=1'
  assert_arg_after "$PODMAN_LOG" --build-arg 'TOOL_TALOS=1'
  assert_contains "$PODMAN_LOG" 'ARG=io.agent-capsule.tools=kubernetes,talos'
done

# Without github the host gh is never asked, and the capsule gets no token, no
# token mount and no git rewrite.
new_case github-off
PATH="$GH_FAKE_BIN:$PATH" FAKE_GH_TOKEN=gho_offtoken \
  run_capsule --shell --session gh-off "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'TOOL_GH=0'
[[ ! -s "$GH_LOG" ]] || fail "host gh was called without --with github"
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/keys'
assert_not_contains "$PODMAN_LOG" 'GIT_CONFIG_'
assert_not_contains "$PODMAN_LOG" 'GH_TOKEN'

# The token reaches the capsule as GH_TOKEN in the keys dir under the runtime dir,
# never on the podman command line: podman keeps that in the container config on disk.
new_case github-token-handoff
PATH="$GH_FAKE_BIN:$PATH" FAKE_GH_TOKEN=gho_secret123 \
  AGENT_CAPSULE_TOOLS=gh run_capsule --with github --shell --session gh-on "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'TOOL_GH=1'
assert_not_contains "$PODMAN_LOG" 'gho_secret123'
assert_not_contains "$OUTPUT" 'plain text'
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_KEYS_DIR=/run/agent-capsule/keys'
keys_dir="$(mount_source /run/agent-capsule/keys)"
[[ "$keys_dir" == "$XDG_DIR/"* ]] || fail "keys dir is outside the runtime dir: $keys_dir"
[[ "$(<"$keys_dir/GH_TOKEN")" == gho_secret123 ]] || fail "the token file does not hold the host token"
[[ "$(file_mode "$keys_dir")" == 700 ]] || fail "keys dir is not private"
[[ "$(file_mode "$keys_dir/GH_TOKEN")" == 600 ]] || fail "token file is not private"
assert_contains "$OUTPUT" '>> GitHub  : host gh login (kept in memory); git uses HTTPS'

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
new_case github-logged-out
PATH="$GH_FAKE_BIN:$PATH" FAKE_GH_TOKEN='' \
  AGENT_CAPSULE_TOOLS=gh run_capsule --with github --shell --session gh-logged-out "$ROOT_DIR"
assert_contains "$OUTPUT" 'gh auth login'
assert_contains "$PODMAN_LOG" 'CALL=run'
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/keys'


# A host gh without a keyring keeps its token in plain text, which defeats the point.
new_case github-plain-text-token
mkdir -p "$CASE_DIR/gh-config"
printf 'github.com:\n    oauth_token: gho_plain\n' > "$CASE_DIR/gh-config/hosts.yml"
PATH="$GH_FAKE_BIN:$PATH" FAKE_GH_TOKEN=gho_plain GH_CONFIG_DIR="$CASE_DIR/gh-config" \
  AGENT_CAPSULE_TOOLS=gh run_capsule --with github --shell --session gh-plain "$ROOT_DIR"
assert_contains "$OUTPUT" 'plain text'
assert_not_contains "$OUTPUT" 'gho_plain'

# Handoff dirs of finished launches are removed, never a live one's. A keys dir outlives
# a launch only when it died before its entrypoint ran; glab and CA dirs last the whole
# session, because glab and TLS clients read them until it ends.
for kind_and_file in keys:GH_TOKEN glab:config.yml ca:extra.pem; do
  kind="${kind_and_file%%:*}"
  file="${kind_and_file#*:}"
  new_case "handoff-sweep-$kind"
  runtime_root="$XDG_DIR/agent-capsule-$UID"
  mkdir -p "$runtime_root/$kind-999999999" "$runtime_root/$kind-$$"
  touch "$runtime_root/$kind-999999999/$file" "$runtime_root/$kind-$$/$file"
  run_capsule --shell --session "$kind-sweep" "$ROOT_DIR"
  [[ ! -e "$runtime_root/$kind-999999999" ]] || fail "a finished launch's $kind dir survived"
  [[ -e "$runtime_root/$kind-$$/$file" ]] || fail "a live launch's $kind dir was removed"
done

# Without a private CA the capsule gets no CA mount and no CA variable.
new_case ca-off
run_capsule --shell --session ca-off "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/ca'
assert_not_contains "$PODMAN_LOG" 'AGENT_CAPSULE_CA_DIR'

# A configured CA file alone exposes nothing, so it is safe to export from a shell
# profile: only --ca mounts it. Nor is the file checked, so a stale path blocks no run.
new_case ca-configured-only
printf -- '-----BEGIN CERTIFICATE-----\nMIIBcapsuleRootOne\n-----END CERTIFICATE-----\n' > "$CASE_DIR/corp.pem"
for configured_ca in "$CASE_DIR/corp.pem" "$CASE_DIR/missing.pem"; do
  AGENT_CAPSULE_CA_CERTS="$configured_ca" run_capsule --shell --session ca-configured "$ROOT_DIR"
  assert_contains "$PODMAN_LOG" 'CALL=run'
  assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/ca'
  assert_not_contains "$PODMAN_LOG" 'AGENT_CAPSULE_CA_DIR'
done

# --ca without a file to trust stops the launch before podman runs.
new_case ca-unset
run_capsule_fails --ca --shell --session ca-unset "$ROOT_DIR"
assert_contains "$OUTPUT" 'AGENT_CAPSULE_CA_CERTS'
assert_not_contains "$PODMAN_LOG" 'CALL='

# Only certificates cross over, in a private file under the runtime dir: a key
# kept in the same PEM must never reach the capsule. Windows exports use CRLF.
new_case ca-certificates-only
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
ca_dir="$(mount_source /run/agent-capsule/ca)"
[[ "$ca_dir" == "$XDG_DIR/"* ]] || fail "CA dir is outside the runtime dir: $ca_dir"
expected_ca="$(printf -- '%s\n' '-----BEGIN CERTIFICATE-----' MIIBcapsuleRootOne \
  '-----END CERTIFICATE-----' '-----BEGIN CERTIFICATE-----' MIIBcapsuleRootTwo \
  '-----END CERTIFICATE-----')"
[[ "$(<"$ca_dir/extra.pem")" == "$expected_ca" ]] || fail "extra.pem does not hold exactly the certificates"
[[ "$(file_mode "$ca_dir")" == 700 ]] || fail "CA dir is not private"
[[ "$(file_mode "$ca_dir/extra.pem")" == 600 ]] || fail "extra.pem is not private"

# A CA file that is missing or holds no certificate stops the launch before podman runs.
new_case ca-bad-file
printf -- '-----BEGIN PRIVATE KEY-----\nMIGHcapsuleSecretKey\n-----END PRIVATE KEY-----\n' \
  > "$CASE_DIR/key-only.pem"
for bad_ca in "$CASE_DIR/missing.pem" "$CASE_DIR/key-only.pem"; do
  AGENT_CAPSULE_CA_CERTS="$bad_ca" run_capsule_fails --ca --shell --session ca-bad "$ROOT_DIR"
  assert_contains "$OUTPUT" "$bad_ca"
  assert_not_contains "$PODMAN_LOG" 'CALL='
done

# ca in the list does what --ca does, and --ca adds to the exported list.
new_case ca-in-with
printf -- '-----BEGIN CERTIFICATE-----\nMIIBcapsuleRootOne\n-----END CERTIFICATE-----\n' > "$CASE_DIR/corp.pem"
AGENT_CAPSULE_WITH=ca AGENT_CAPSULE_CA_CERTS="$CASE_DIR/corp.pem" run_capsule --shell --session ca-in-with "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_CA_DIR=/run/agent-capsule/ca'
AGENT_CAPSULE_WITH=superpowers AGENT_CAPSULE_CA_CERTS="$CASE_DIR/corp.pem" \
  run_capsule --ca --shell --session ca-in-with "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Extras  : ca, superpowers'
AGENT_CAPSULE_WITH=ca run_capsule_fails --shell --session ca-in-with "$ROOT_DIR"
assert_contains "$OUTPUT" 'ca needs AGENT_CAPSULE_CA_CERTS'

# A login may need the CA to reach its server, but never the vault.
new_case auth-login-keeps-ca
printf -- '-----BEGIN CERTIFICATE-----\nMIIBcapsuleRootOne\n-----END CERTIFICATE-----\n' > "$CASE_DIR/corp.pem"
AGENT_CAPSULE_WITH=vault AGENT_CAPSULE_VAULT="$VAULT_DIR" AGENT_CAPSULE_CA_CERTS="$CASE_DIR/corp.pem" \
  run_capsule --auth-login --ca --shell
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_CA_DIR=/run/agent-capsule/ca'
assert_not_contains "$PODMAN_LOG" ':/vault'

# The entrypoint adds the CA to what the capsule already trusts. git and Node read
# neither SSL_CERT_FILE nor each other's variable, so each gets its own.
new_case entrypoint-ca-trust
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
new_case gitlab-off
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN=glpat-offtoken \
  run_capsule --shell --session glab-off "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'TOOL_GLAB=0'
[[ ! -s "$GLAB_LOG" ]] || fail "host glab was called without --with gitlab"
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/glab'
assert_not_contains "$PODMAN_LOG" 'GITLAB_'
assert_not_contains "$PODMAN_LOG" 'GLAB_CONFIG_DIR'
assert_not_contains "$PODMAN_LOG" 'GIT_CONFIG_'

# The token crosses over in a host-bound glab config under the runtime dir, never on the
# podman command line. A keyring login leaves an empty token in the host's config.yml.
new_case gitlab-token-handoff
mkdir -p "$CASE_DIR/glab-config"
printf 'hosts:\n    gitlab.com:\n        token: ""\n        use_keyring: "true"\n' \
  > "$CASE_DIR/glab-config/config.yml"
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN=glpat-secret123 GLAB_CONFIG_DIR="$CASE_DIR/glab-config" \
  AGENT_CAPSULE_TOOLS=glab run_capsule --with gitlab --shell --session glab-on "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'TOOL_GLAB=1'
assert_not_contains "$PODMAN_LOG" 'glpat-secret123'
assert_not_contains "$OUTPUT" 'plain text'
assert_contains "$PODMAN_LOG" 'ARG=GLAB_CONFIG_DIR=/run/agent-capsule/glab'
assert_not_contains "$PODMAN_LOG" 'GITLAB_TOKEN'
assert_contains "$PODMAN_LOG" 'ARG=GITLAB_HOST=gitlab.com'
glab_dir="$(mount_source /run/agent-capsule/glab)"
[[ "$glab_dir" == "$XDG_DIR/"* ]] || fail "glab dir is outside the runtime dir: $glab_dir"
expected_glab_config="$(printf '%s\n' 'hosts:' '    gitlab.com:' "        token: 'glpat-secret123'")"
[[ "$(<"$glab_dir/config.yml")" == "$expected_glab_config" ]] ||
  fail "the glab config does not bind the token to gitlab.com: $(<"$glab_dir/config.yml")"
[[ "$(file_mode "$glab_dir")" == 700 ]] || fail "glab dir is not private"
[[ "$(file_mode "$glab_dir/config.yml")" == 600 ]] || fail "glab config is not private"

# A self-managed instance: its remotes go over HTTPS with glab's credentials,
# whatever form they take, and glab targets it outside a repository too.
new_case gitlab-self-managed
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_HOST=gitlab.corp.example FAKE_GLAB_TOKEN=glpat-corp \
  AGENT_CAPSULE_GITLAB_HOST=gitlab.corp.example \
  AGENT_CAPSULE_TOOLS=glab run_capsule --with gitlab --shell --session glab-corp "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=GITLAB_HOST=gitlab.corp.example'
glab_dir="$(mount_source /run/agent-capsule/glab)"
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
new_case both-forges
PATH="$GH_FAKE_BIN:$GLAB_FAKE_BIN:$PATH" FAKE_GH_TOKEN=gho_both FAKE_GLAB_TOKEN=glpat-both \
  AGENT_CAPSULE_TOOLS=gh,glab run_capsule --with github,gitlab --shell --session forges "$ROOT_DIR"
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
new_case gitlab-logged-out
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN='' \
  AGENT_CAPSULE_TOOLS=glab run_capsule --with gitlab --shell --session glab-logged-out "$ROOT_DIR"
assert_contains "$OUTPUT" 'glab auth login --hostname gitlab.com'
assert_contains "$PODMAN_LOG" 'CALL=run'
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/glab'

# An OAuth token expires within hours, and refreshing it in the capsule would log
# the host out, so only a personal access token crosses over.
new_case gitlab-oauth-refused
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN=oauth-access-token FAKE_GLAB_OAUTH=true \
  AGENT_CAPSULE_TOOLS=glab run_capsule --with gitlab --shell --session glab-oauth "$ROOT_DIR"
assert_contains "$OUTPUT" 'personal access token'
assert_contains "$PODMAN_LOG" 'CALL=run'
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/glab'

# A host glab without a keyring keeps its token in plain text.
new_case gitlab-plain-text-token
mkdir -p "$CASE_DIR/glab-config"
printf 'hosts:\n    gitlab.com:\n        token: glpat-plain\n' > "$CASE_DIR/glab-config/config.yml"
PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN=glpat-plain GLAB_CONFIG_DIR="$CASE_DIR/glab-config" \
  AGENT_CAPSULE_TOOLS=glab run_capsule --with gitlab --shell --session glab-plain "$ROOT_DIR"
assert_contains "$OUTPUT" 'plain text'
assert_not_contains "$OUTPUT" 'glpat-plain'

# The host ends up in git config keys and URLs, so only a bare hostname passes.
new_case gitlab-bad-host
for bad_host in https://gitlab.corp.example gitlab.corp.example:8443 gitlab.corp.example/sub \
  -gitlab.corp.example; do
  PATH="$GLAB_FAKE_BIN:$PATH" AGENT_CAPSULE_GITLAB_HOST="$bad_host" \
    AGENT_CAPSULE_TOOLS=glab run_capsule_fails --with gitlab --shell --session glab-bad-host "$ROOT_DIR"
  assert_contains "$OUTPUT" "$bad_host"
  assert_not_contains "$PODMAN_LOG" 'CALL='
done
# A launch without gitlab never uses the host, so a bad one does not stop it.
PATH="$GLAB_FAKE_BIN:$PATH" AGENT_CAPSULE_GITLAB_HOST=gitlab.corp.example:8443 \
  run_capsule --shell --session glab-unused-host "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=run'

# A token exported on the host would answer for any instance, so only the stored
# login for the instance crosses over, and only a stored OAuth flag counts.
new_case gitlab-host-env-token
for env_token in GITLAB_TOKEN GITLAB_ACCESS_TOKEN OAUTH_TOKEN; do
  (export "$env_token=glpat-from-env" &&
    PATH="$GLAB_FAKE_BIN:$PATH" AGENT_CAPSULE_TOOLS=glab \
      run_capsule --with gitlab --shell --session glab-env-token "$ROOT_DIR")
  assert_contains "$OUTPUT" 'glab auth login --hostname gitlab.com'
  assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/glab'
done
GITLAB_TOKEN=glpat-from-env GLAB_IS_OAUTH2=false FAKE_GLAB_OAUTH=true PATH="$GLAB_FAKE_BIN:$PATH" \
  FAKE_GLAB_TOKEN=oauth-stored AGENT_CAPSULE_TOOLS=glab \
  run_capsule --with gitlab --shell --session glab-env-token "$ROOT_DIR"
assert_contains "$OUTPUT" 'personal access token'
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/glab'
GITLAB_TOKEN=glpat-from-env PATH="$GLAB_FAKE_BIN:$PATH" FAKE_GLAB_TOKEN=glpat-stored \
  AGENT_CAPSULE_TOOLS=glab run_capsule --with gitlab --shell --session glab-env-token "$ROOT_DIR"
glab_dir="$(mount_source /run/agent-capsule/glab)"
expected_glab_config="$(printf '%s\n' 'hosts:' '    gitlab.com:' "        token: 'glpat-stored'")"
[[ "$(<"$glab_dir/config.yml")" == "$expected_glab_config" ]] ||
  fail "the host's GITLAB_TOKEN replaced the stored login: $(<"$glab_dir/config.yml")"

# Every capsule runs without capabilities or privilege escalation, within limits,
# and --offline takes the network away.
new_case hardening-and-offline
run_capsule --shell --session hardening "$ROOT_DIR"
for flag in --security-opt=no-new-privileges --cap-drop=ALL --pids-limit=512 --memory=8g --cpus=4; do
  assert_contains "$PODMAN_LOG" "ARG=$flag"
done
assert_not_contains "$PODMAN_LOG" 'ARG=--network=none'
run_capsule --offline --shell --session hardening "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=--network=none'

# One login serves every session: a new session copies the agent's state from the
# auth home, but the token only through a read-write mount of the shared file.
new_case shared-auth
auth_home="$CAPSULE_HOME/auth-home/claude"
mkdir -p "$auth_home/.claude"
printf '{}\n' > "$auth_home/.claude.json"
printf 'oauth-token\n' > "$auth_home/.claude/.credentials.json"
run_capsule --shell --session shared-auth "$ROOT_DIR"
[[ -f "$CAPSULE_HOME/homes/shared-auth/.claude.json" ]] || fail "the agent state was not copied"
[[ ! -e "$CAPSULE_HOME/homes/shared-auth/.claude/.credentials.json" ]] || fail "the token was copied"
assert_contains "$PODMAN_LOG" \
  "ARG=$auth_home/.claude/.credentials.json:/home/dev/.claude/.credentials.json"
AGENT_CAPSULE_SHARE_AUTH=0 run_capsule --shell --session unshared-auth "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" '.credentials.json'
[[ ! -e "$CAPSULE_HOME/homes/unshared-auth/.claude.json" ]] || fail "unshared auth was copied"

# The vault brings its MCP server, which reaches each agent its own way: a config file
# for claude, -c overrides for codex, inline configuration for opencode.
new_case vault-per-agent
for agent in claude codex opencode; do
  AGENT_CAPSULE_WITH=vault AGENT_CAPSULE_VAULT="$VAULT_DIR" \
    run_capsule --agent "$agent" --session "vault-$agent" "$ROOT_DIR"
  assert_contains "$PODMAN_LOG" "ARG=$VAULT_DIR:/vault"
  case "$agent" in
    claude)
      assert_arg_after "$PODMAN_LOG" --mcp-config /home/dev/.mcp-servers.json
      assert_contains "$CAPSULE_HOME/homes/vault-claude/.mcp-servers.json" '"args": ["/vault"]'
      ;;
    codex)
      assert_arg_after "$PODMAN_LOG" -c 'mcp_servers.obsidian.command="mcpvault"'
      assert_arg_after "$PODMAN_LOG" -c 'mcp_servers.obsidian.args=["/vault"]'
      ;;
    opencode) assert_contains "$PODMAN_LOG" "OPENCODE_CONFIG_CONTENT={$opencode_mcp}" ;;
  esac
done

# Without the vault, nothing is mounted and no MCP server is registered.
new_case vault-off
AGENT_CAPSULE_VAULT="$VAULT_DIR" run_capsule --session vault-off "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" ':/vault'
assert_not_contains "$PODMAN_LOG" '--mcp-config'

# mcpvault left --with: the vault brings it. The variable that mounted the vault in 0.3
# is no longer read, and says so.
new_case mcpvault-and-mount-vault-gone
run_capsule_fails --with mcpvault --shell --session mcpvault-gone "$ROOT_DIR"
assert_contains "$OUTPUT" 'Unknown extra tool: mcpvault'
AGENT_CAPSULE_MOUNT_VAULT=1 AGENT_CAPSULE_VAULT="$VAULT_DIR" run_capsule --shell --session mount-vault "$ROOT_DIR"
assert_contains "$OUTPUT" 'AGENT_CAPSULE_MOUNT_VAULT is no longer read; add vault to AGENT_CAPSULE_WITH.'
assert_not_contains "$PODMAN_LOG" ':/vault'

new_case claude-plugin-dirs
run_capsule --agent claude --with superpowers,anydoc \
  --session claude-integrations "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" claude --plugin-dir
assert_arg_after "$PODMAN_LOG" --plugin-dir /opt/superpowers/source
# anydoc is a skill now, linked by the entrypoint, not a plugin.
assert_not_contains "$PODMAN_LOG" '/opt/anydoc'

run_capsule --agent claude --with none --session claude-no-integrations "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'ARG=/opt/superpowers/source'

new_case removed-hunkdiff
run_capsule_fails --with hunkdiff --session removed-hunkdiff "$ROOT_DIR"
assert_contains "$OUTPUT" 'Unknown extra tool: hunkdiff'

# API keys cross over like the gh token, as files under the runtime dir: podman would
# store `-e NAME` values in the container config on disk.
new_case api-key-handoff
ANTHROPIC_API_KEY=anthropic-secret OPENAI_API_KEY=openai-secret \
  run_capsule --agent opencode --session opencode-env "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'ARG=ANTHROPIC_API_KEY'
assert_not_contains "$PODMAN_LOG" 'ARG=OPENAI_API_KEY'
assert_not_contains "$PODMAN_LOG" 'anthropic-secret'
assert_not_contains "$PODMAN_LOG" 'openai-secret'
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_KEYS_DIR=/run/agent-capsule/keys'
keys_dir="$(mount_source /run/agent-capsule/keys)"
[[ "$keys_dir" == "$XDG_DIR/"* ]] || fail "keys dir is outside the runtime dir: $keys_dir"
[[ "$(<"$keys_dir/ANTHROPIC_API_KEY")" == anthropic-secret ]] || fail "the Anthropic key was not handed over"
[[ "$(<"$keys_dir/OPENAI_API_KEY")" == openai-secret ]] || fail "the OpenAI key was not handed over"
[[ "$(file_mode "$keys_dir")" == 700 ]] || fail "keys dir is not private"
[[ "$(file_mode "$keys_dir/OPENAI_API_KEY")" == 600 ]] || fail "key file is not private"
# Each agent gets only its own provider's key, and no key means no handoff at all.
ANTHROPIC_API_KEY=anthropic-secret OPENAI_API_KEY=openai-secret \
  run_capsule --agent claude --shell --session claude-env "$ROOT_DIR"
keys_dir="$(mount_source /run/agent-capsule/keys)"
[[ -f "$keys_dir/ANTHROPIC_API_KEY" && ! -e "$keys_dir/OPENAI_API_KEY" ]] || fail "claude got the wrong keys"
run_capsule --agent claude --shell --session claude-env "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" '/run/agent-capsule/keys'

# The entrypoint moves each key into the environment and deletes its file first thing.
new_case entrypoint-api-keys
mkdir -p "$CASE_DIR/keys"
printf 'sk-entry' > "$CASE_DIR/keys/ANTHROPIC_API_KEY"
# shellcheck disable=SC2016
AGENT_CAPSULE_KEYS_DIR="$CASE_DIR/keys" "$BASH_BIN" "$ROOT_DIR/entrypoint.sh" \
  "$BASH_BIN" -c 'printf "%s" "$ANTHROPIC_API_KEY"; [[ ! -e "$AGENT_CAPSULE_KEYS_DIR/ANTHROPIC_API_KEY" ]]' \
  > "$OUTPUT"
[[ "$(<"$OUTPUT")" == sk-entry ]] || fail "entrypoint did not export ANTHROPIC_API_KEY"

# anydoc is a plain skill, so every agent can use it.
new_case anydoc-for-every-agent
for agent in codex opencode; do
  run_capsule --agent "$agent" --with anydoc --shell --session "anydoc-$agent" "$ROOT_DIR"
  assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_WITH=anydoc'
done

new_case with-empty
run_capsule_fails --with= --shell --session empty-extra "$ROOT_DIR"
assert_contains "$OUTPUT" '--with requires a tool list'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case file-mount
mount_file="$CASE_DIR/tool.conf"
printf '%s\n' setting > "$mount_file"
run_capsule --shell --session file-mount --mount "$mount_file:/etc/tool.conf:ro" "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$mount_file:/etc/tool.conf:ro"

new_case vault-unconfigured
for vault_args in --vault '--with vault'; do
  # shellcheck disable=SC2086
  run_capsule_fails --shell --session missing-vault $vault_args "$ROOT_DIR"
  assert_contains "$OUTPUT" '--with vault needs a vault: set AGENT_CAPSULE_VAULT, or use --vault=PATH.'
  assert_not_contains "$PODMAN_LOG" 'CALL=run'
done

new_case vault-configured
AGENT_CAPSULE_VAULT="$VAULT_DIR" \
  run_capsule --shell --session configured-vault --vault "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$VAULT_DIR:/vault"

new_case vault-destination-invalid
AGENT_CAPSULE_VAULT_DEST=relative \
  run_capsule_fails --shell --session invalid-vault-destination --vault="$VAULT_DIR" "$ROOT_DIR"
assert_contains "$OUTPUT" 'Invalid vault destination: relative'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case session-name-too-long
long_session="$(printf 'a%.0s' {1..121})"
run_capsule_fails --shell --session "$long_session" "$ROOT_DIR"
assert_contains "$OUTPUT" 'not starting with a dot'

new_case session-name-with-slash
run_capsule_fails --shell --session 'fix/auth' "$ROOT_DIR"
assert_contains "$OUTPUT" "Invalid session name: 'fix/auth'."
[[ ! -e "$CAPSULE_HOME/homes/fixauth" ]] || fail "invalid session name was normalized"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case session-name-empty
run_capsule_fails --shell --session= "$ROOT_DIR"
assert_contains "$OUTPUT" '--session requires a name.'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case session-from-hidden-dir
hidden_project="$CASE_DIR/.dotfiles"
mkdir -p "$hidden_project"
run_capsule --shell "$hidden_project"
assert_contains "$OUTPUT" '>> Session : dotfiles-'

for invalid_session in . ..; do
  new_case "session-name-$invalid_session"
  run_capsule_fails --shell --session "$invalid_session" "$ROOT_DIR"
  assert_contains "$OUTPUT" "Invalid session name: '$invalid_session'"
  assert_not_contains "$PODMAN_LOG" 'CALL=run'
done

# Editing the entrypoint must invalidate the image, or a fix to it never ships.
new_case entrypoint-in-bundle-hash
copy_build_context
assert_edit_rebuilds "$CASE_DIR/entrypoint.sh" --shell --session entrypoint-hash "$ROOT_DIR"

new_case worklog-procedure-default
run_capsule --with worklog --vault="$VAULT_DIR" --session worklog-on "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --plugin-dir /opt/worklog/plugin
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_VAULT_DEST=/vault'
assert_contains "$OUTPUT" '>> Worklog : built-in procedure'
assert_not_contains "$PODMAN_LOG" '/etc/agent-capsule/log-work.md'
[[ ! -e "$CAPSULE_HOME/log-work.md" ]] || fail "the default procedure file was created"

printf 'steps\n' > "$CAPSULE_HOME/log-work.md"
run_capsule --with worklog --vault="$VAULT_DIR" --session worklog-on "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/log-work.md:/etc/agent-capsule/log-work.md:ro"
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_WORKLOG_PROCEDURE=/etc/agent-capsule/log-work.md'
assert_contains "$OUTPUT" ">> Worklog : $CAPSULE_HOME/log-work.md -> /etc/agent-capsule/log-work.md"

new_case worklog-procedure-explicit
printf 'mine\n' > "$CASE_DIR/mine.md"
AGENT_CAPSULE_WORKLOG_PROCEDURE="$CASE_DIR/mine.md" \
  run_capsule --with worklog --vault="$VAULT_DIR" --session worklog-explicit "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$CASE_DIR/mine.md:/etc/agent-capsule/log-work.md:ro"
assert_contains "$OUTPUT" ">> Worklog : $CASE_DIR/mine.md -> /etc/agent-capsule/log-work.md"

new_case worklog-procedure-missing
AGENT_CAPSULE_WORKLOG_PROCEDURE="$CASE_DIR/missing.md" \
  run_capsule_fails --with worklog --vault="$VAULT_DIR" --session worklog-missing "$ROOT_DIR"
assert_contains "$OUTPUT" "File not found: $CASE_DIR/missing.md"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

# A symlinked default is a user-managed file, not a missing one.
new_case worklog-procedure-symlink
mkdir -p "$CASE_DIR/notes"
printf 'linked\n' > "$CASE_DIR/notes/log-work.md"
ln -s "$CASE_DIR/notes/log-work.md" "$CAPSULE_HOME/log-work.md"
run_capsule --with worklog --vault="$VAULT_DIR" --session worklog-link "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/log-work.md:/etc/agent-capsule/log-work.md:ro"
assert_contains "$OUTPUT" ">> Worklog : $CAPSULE_HOME/log-work.md -> /etc/agent-capsule/log-work.md"
# A broken one fails loudly instead of falling back to the built-in procedure.
rm "$CASE_DIR/notes/log-work.md"
run_capsule_fails --with worklog --vault="$VAULT_DIR" --session worklog-link "$ROOT_DIR"
assert_contains "$OUTPUT" "File not found: $CAPSULE_HOME/log-work.md"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

# worklog logs through the vault's MCP tools. A command-line --with replaces the
# exported list, so an exported vault does not count.
new_case worklog-needs-vault
for exported in '' vault; do
  AGENT_CAPSULE_WITH="$exported" AGENT_CAPSULE_VAULT="$VAULT_DIR" \
    run_capsule_fails --with worklog --session worklog-needs-vault "$ROOT_DIR"
  assert_contains "$OUTPUT" '--with worklog needs the vault: add vault to --with, or use --vault.'
  assert_not_contains "$PODMAN_LOG" 'CALL=run'
done

new_case worklog-no-vault
run_capsule --with vault,worklog --no-vault --session worklog-no-vault "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Worklog : disabled for this run (--no-vault)'
assert_not_contains "$PODMAN_LOG" 'ARG=/opt/worklog/plugin'
assert_not_contains "$PODMAN_LOG" 'AGENT_CAPSULE_VAULT_DEST'

new_case worklog-codex-rejected
run_capsule_fails --agent codex --with worklog --vault="$VAULT_DIR" --session worklog-codex "$ROOT_DIR"
assert_contains "$OUTPUT" "Extra 'worklog' is not available with --agent codex"

new_case worklog-codex-dropped
AGENT_CAPSULE_WITH=vault,worklog \
  run_capsule --agent codex --vault="$VAULT_DIR" --shell --session worklog-drop "$ROOT_DIR"
assert_contains "$OUTPUT" ">> Extras  : dropping 'worklog' (unsupported by agent codex)"

# The plugin ships in the image, so editing it has to invalidate the image.
new_case worklog-in-bundle-hash
copy_build_context
assert_edit_rebuilds "$CASE_DIR/plugins/worklog/procedure.md" \
  --with worklog --vault="$VAULT_DIR" --shell --session worklog-hash "$ROOT_DIR"

# Every image copies the plugin, so editing it rebuilds a run without worklog too.
printf '\n' >> "$CASE_DIR/plugins/worklog/procedure.md"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" \
  run_capsule --with none --shell --session worklog-unselected "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'

# Nix store sources are read-only, and a copy of them must still be replaceable.
new_case build-context-read-only
copy_build_context
chmod -R a-w "$CASE_DIR/plugins/worklog"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" \
  run_capsule --build --shell --session worklog-readonly "$ROOT_DIR"
chmod -R a-w "$CAPSULE_HOME/build/context/plugins/worklog"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" \
  run_capsule --build --shell --session worklog-readonly "$ROOT_DIR"
[[ -w "$CAPSULE_HOME/build/context/plugins/worklog/procedure.md" ]] || fail "the context copy is read-only"

new_case worklog-plugin-missing
copy_build_context
rm -rf "$CASE_DIR/plugins"
AGENT_CAPSULE_DOCKERFILE="$CASE_DIR/Dockerfile" run_capsule_fails --shell --session worklog-noplugin "$ROOT_DIR"
assert_contains "$OUTPUT" 'Container plugin not found:'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

# The agent runs as the host UID under --keep-id, so the image files must not inherit a private umask.
new_case worklog-umask
(umask 077; run_capsule --shell --session worklog-umask "$ROOT_DIR")
plugin_mode="$(file_mode "$CAPSULE_HOME/build/context/plugins/worklog/hooks/worklog.mjs")"
[[ "${plugin_mode: -1}" -ge 4 ]] || fail "plugin file is not world-readable: $plugin_mode"

# The project is the vault itself, inside it, or a sibling whose name only starts like the vault's.
new_case worklog-in-vault
notes_dir="$CASE_DIR/notes"
mkdir -p "$notes_dir/sub" "$CASE_DIR/notes2"
run_capsule --with worklog --vault="$notes_dir" --session worklog-in-vault "$notes_dir"
assert_contains "$OUTPUT" '>> Worklog : disabled for this run (the project is inside the vault)'
assert_not_contains "$PODMAN_LOG" 'ARG=/opt/worklog/plugin'
assert_not_contains "$PODMAN_LOG" 'AGENT_CAPSULE_VAULT_DEST'
run_capsule --with worklog --vault="$notes_dir" --session worklog-in-vault "$notes_dir/sub"
assert_contains "$OUTPUT" '>> Worklog : disabled for this run (the project is inside the vault)'
assert_not_contains "$PODMAN_LOG" 'ARG=/opt/worklog/plugin'
run_capsule --with worklog --vault="$notes_dir" --session worklog-in-vault "$CASE_DIR/notes2"
assert_arg_after "$PODMAN_LOG" --plugin-dir /opt/worklog/plugin

# A shell does not load the plugin, so the banner says how to.
new_case worklog-shell-hint
run_capsule --with worklog --vault="$VAULT_DIR" --shell --session worklog-shell "$ROOT_DIR"
assert_contains "$OUTPUT" '(start claude with: --plugin-dir /opt/worklog/plugin)'

new_case forced-build
run_capsule --build --shell --session forced-build "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=--pull=always'
assert_contains "$PODMAN_LOG" 'ARG=--no-cache'
assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/build/context"

new_case telemetry-env-by-name
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
  new_case tz-forwarded
  TZ="$tz_value" run_capsule --shell --session tz-env "$ROOT_DIR"
  assert_arg_after "$PODMAN_LOG" -e 'TZ=Asia/Kathmandu'
done

# Empty, or naming a file with a leading colon: fall back to the /etc/localtime link.
localtime_target="$(readlink /etc/localtime 2>/dev/null || true)"
for tz_value in '' ':/etc/localtime' '/etc/localtime'; do
  new_case tz-fallback
  TZ="$tz_value" run_capsule --shell --session tz-fallback "$ROOT_DIR"
  if [[ "$localtime_target" == *zoneinfo/* ]]; then
    assert_arg_after "$PODMAN_LOG" -e "TZ=${localtime_target#*zoneinfo/}"
  else
    assert_not_contains "$PODMAN_LOG" 'ARG=TZ='
  fi
done

# An exported CDPATH makes cd print where it went, which would double every resolved path.
new_case cdpath-exported
mkdir -p "$CASE_DIR/proj"
(cd "$CASE_DIR" && CDPATH=".:/nonexistent" run_capsule --shell --session cdpath proj)
assert_arg_after "$PODMAN_LOG" -w "$CASE_DIR/proj"

# Status goes to stderr, so `agent-capsule . -- -p q > out` captures only the agent.
new_case status-on-stderr
capsule_env
env "${CAPSULE_ENV[@]}" "$BASH_BIN" "$SCRIPT" --session piped "$ROOT_DIR" -- -p question \
  > "$OUTPUT" 2> "$CASE_DIR/stderr"
[[ ! -s "$OUTPUT" ]] || fail "status reached stdout: $(head -n 3 "$OUTPUT")"
assert_contains "$CASE_DIR/stderr" '>> Project :'

# The run starts the image this launch checked under the build lock, not the tag:
# another launch with a different selection can move the tag right after the lock.
new_case run-checked-image-id
run_capsule --session image-id "$ROOT_DIR" -- --version
image_id="id-$(awk -F '\t' 'END { print $2 }' "$PODMAN_IMAGE_STATE")"
assert_arg_after "$PODMAN_LOG" "$image_id" claude

# A configured rules file that does not exist is a typo, not a file to create.
new_case rules-path-typo
AGENT_CAPSULE_SHARED_RULES="$CASE_DIR/typo/CLAUDE.md" \
  run_capsule_fails --shell --session rules-typo "$ROOT_DIR"
assert_contains "$OUTPUT" "$CASE_DIR/typo/CLAUDE.md"
[[ ! -e "$CASE_DIR/typo" ]] || fail "the mistyped rules path was created"

# A lone dash is not a project: cd would read it as $OLDPWD.
new_case lone-dash-project
OLDPWD=/etc run_capsule_fails --shell -
assert_not_contains "$PODMAN_LOG" 'CALL='

# Handoff files are only in memory under XDG_RUNTIME_DIR; the status must not claim it otherwise.
new_case handoff-on-disk
printf -- '-----BEGIN CERTIFICATE-----\nMIIBcapsuleRootOne\n-----END CERTIFICATE-----\n' > "$CASE_DIR/corp.pem"
mkdir -p "$CASE_DIR/tmp"
# No XDG_RUNTIME_DIR, as on macOS, so the handoff files go under TMPDIR.
capsule_env
on_disk_env=()
for entry in "${CAPSULE_ENV[@]}"; do
  [[ "$entry" == XDG_RUNTIME_DIR=* ]] || on_disk_env+=("$entry")
done
env "${on_disk_env[@]}" TMPDIR="$CASE_DIR/tmp" AGENT_CAPSULE_CA_CERTS="$CASE_DIR/corp.pem" \
  "$BASH_BIN" "$SCRIPT" --ca --shell --session on-disk "$ROOT_DIR" > "$OUTPUT" 2>&1
assert_not_contains "$OUTPUT" 'kept in memory'
assert_contains "$OUTPUT" "$CASE_DIR/tmp/agent-capsule-$UID"
rm -rf "$CASE_DIR/tmp"

# A project path too long to name a memory folder skips shared memory instead of failing.
new_case project-path-too-long
long_project="$CASE_DIR/$(printf 'p%.0s' {1..130})/$(printf 'q%.0s' {1..130})"
mkdir -p "$long_project"
run_capsule --shell --session long-path "$long_project"
assert_contains "$PODMAN_LOG" 'CALL=run'
assert_not_contains "$PODMAN_LOG" '/home/dev/.claude/projects/'
assert_contains "$OUTPUT" 'project memory'

# Only the tools the launcher needs, with shasum and no sha256sum, as on macOS.
new_case shasum-fallback
portable_bin="$CASE_DIR/portable-bin"
mkdir -p "$portable_bin"
command -v shasum >/dev/null || fail "this case needs shasum, the fallback it checks"
for tool in bash awk tr mkdir chmod touch cp cat date dirname basename shasum rm sleep find sort; do
  ln -s "$(command -v "$tool")" "$portable_bin/$tool"
done
capsule_env
env "${CAPSULE_ENV[@]}" PATH="$portable_bin:$FAKE_BIN" \
  "$BASH_BIN" "$SCRIPT" --shell --session shasum-fallback "$ROOT_DIR" > "$OUTPUT" 2>&1
assert_contains "$PODMAN_LOG" 'CALL=run'

new_case session-owned-by-other-agent
codex_home="$CAPSULE_HOME/homes/codex-owned"
mkdir -p "$codex_home/.codex"
printf '%s\n' codex > "$codex_home/.agent"
run_capsule_fails --shell --session codex-owned "$ROOT_DIR"
assert_contains "$OUTPUT" "was created by agent 'codex'"

new_case herdr-agent-divergence
HERDR_AGENT=codex run_capsule --shell --session herdr-divergence "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Agent   : claude (HERDR_AGENT=codex)'

new_case removed-shared-claude-md
run_capsule_fails --shared-claude-md "$CASE_DIR/x.md" --shell --session removed-flag "$ROOT_DIR"
assert_contains "$OUTPUT" 'Unknown option: --shared-claude-md'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case linked-worktree
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
sub_dir="$main_repo/pkg"
mkdir -p "$sub_dir"
run_capsule --shell --session subdir-launch "$sub_dir"
assert_contains "$PODMAN_LOG" 'CALL=run'
assert_not_contains "$PODMAN_LOG" "ARG=$main_repo/.git:"
assert_not_contains "$OUTPUT" 'linked-worktree metadata'
sub_slug="$(printf '%s' "$sub_dir" | tr -c 'a-zA-Z0-9' '-')"
assert_contains "$PODMAN_LOG" \
  "ARG=$CAPSULE_HOME/project-memory/$memory_hash:/home/dev/.claude/projects/$sub_slug/memory"

new_case concurrent-launches
(
  KEEP_PODMAN_LOG=1 RUN_OUTPUT="$CASE_DIR/first.output" PODMAN_BUILD_DELAY=0.2 \
    run_capsule --shell --session concurrent-first "$ROOT_DIR"
) &
first_pid=$!
(
  KEEP_PODMAN_LOG=1 RUN_OUTPUT="$CASE_DIR/second.output" PODMAN_BUILD_DELAY=0.2 \
    run_capsule --shell --session concurrent-second "$ROOT_DIR"
) &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
[[ "$(grep -c '^CALL=build$' "$PODMAN_LOG")" == "1" ]] ||
  fail "concurrent launches built the image more than once"
[[ ! -e "$XDG_DIR/agent-capsule-$UID/image.lock" ]] ||
  fail "image build lock was not removed"

# A process killed before its EXIT trap leaves a stale lock. The next launch
# must reclaim it instead of waiting forever.
new_case stale-lock-reclaimed
stale_lock_root="$XDG_DIR/agent-capsule-$UID"
mkdir -p "$stale_lock_root"
printf '%s\n' 999999999 > "$stale_lock_root/image.lock"
capsule_env
timeout 2 env "${CAPSULE_ENV[@]}" "$BASH_BIN" "$SCRIPT" --shell --session stale-lock "$ROOT_DIR" \
  > "$OUTPUT" 2>&1 || fail "stale image lock was not reclaimed"
assert_contains "$PODMAN_LOG" 'CALL=build'

# A directory at the lock path is reported and left alone, never waited on.
new_case lock-path-is-dir
legacy_lock_root="$XDG_DIR/agent-capsule-$UID"
mkdir -p "$legacy_lock_root/image.lock"
capsule_env
if timeout 2 env "${CAPSULE_ENV[@]}" "$BASH_BIN" "$SCRIPT" --shell --session legacy-lock "$ROOT_DIR" \
  > "$OUTPUT" 2>&1; then
  fail "a directory at the lock path did not stop the launch"
fi
[[ -d "$legacy_lock_root/image.lock" ]] || fail "legacy image lock was removed"
assert_contains "$OUTPUT" 'Not a lock file'

# Shell completion asks the launcher for these two lists, so the contract is
# one value per line, exit 0, and no podman anywhere near it.
new_case list-agents-and-extras
run_capsule --agent list
[[ "$(cat "$OUTPUT")" == "$(printf 'claude\ncodex\nopencode')" ]] ||
  fail "--agent list is not one agent per line"
assert_not_contains "$PODMAN_LOG" 'CALL='
run_capsule --with list
expected_extras="$(printf '%s\n' anydoc ca explain-diff github gitlab superpowers vault worklog)"
[[ "$(cat "$OUTPUT")" == "$expected_extras" ]] ||
  fail "--with list is not one integration per line"
assert_not_contains "$PODMAN_LOG" 'CALL='

# The completion script reads the extras from the launcher on PATH.
new_case completion-extras-per-agent
for agent in claude codex opencode; do
  extras="$(in_completion "_agent_capsule_extras $agent")"
  if [[ "$agent" == claude ]]; then
    grep -qx worklog <<<"$extras" || fail "claude completion does not offer worklog"
  elif grep -qx worklog <<<"$extras"; then
    fail "$agent completion offers worklog"
  fi
done

# Both must work with no podman on PATH at all: completion runs in shells that
# have never launched a capsule.
new_case lists-without-podman
nopodman_bin="$CASE_DIR/nopodman-bin"
mkdir -p "$nopodman_bin"
for tool in bash awk tr cat; do
  ln -s "$(command -v "$tool")" "$nopodman_bin/$tool"
done
capsule_env
for subcommand in '--agent list' '--with list'; do
  # shellcheck disable=SC2086
  env "${CAPSULE_ENV[@]}" PATH="$nopodman_bin" "$BASH_BIN" "$SCRIPT" $subcommand > "$OUTPUT" 2>&1 ||
    fail "$subcommand failed with no podman on PATH"
  [[ -s "$OUTPUT" ]] || fail "$subcommand printed nothing"
done

# Rebuilding strands the image it replaced, so a build prunes what it superseded.
new_case prune-images-after-build
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
new_case prune-images-no-build
PODMAN_DANGLING="$CASE_DIR/dangling"
: > "$PODMAN_DANGLING"
run_capsule --shell --session prune-no-build "$ROOT_DIR"
printf '%s\n' cccc3333 > "$PODMAN_DANGLING"
run_capsule --shell --session prune-no-build "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'
assert_not_contains "$PODMAN_LOG" 'CALL=rmi'

new_case prune-images-disabled
PODMAN_DANGLING="$CASE_DIR/dangling"
printf '%s\n' dddd4444 > "$PODMAN_DANGLING"
AGENT_CAPSULE_PRUNE=0 run_capsule --shell --session prune-disabled "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_not_contains "$PODMAN_LOG" 'CALL=rmi'
assert_not_contains "$OUTPUT" '>> Pruned'

# Removing caches rewrites directory times, which must not make an idle home look used.
new_case prune-dir-times-ignored
make_session_home idle-home 40
run_capsule --prune-caches --yes
run_capsule --prune-sessions
assert_contains "$OUTPUT" 'idle-home'

# Without --yes, prune only reports. Homes with nothing to free are not listed.
new_case prune-caches-dry-run-then-yes
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
new_case prune-sessions-skips
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
new_case prune-legacy-marker
make_session_home legacy-home 40
touch "$CAPSULE_HOME/homes/legacy-home/.claude.json"
run_capsule --prune-sessions
assert_not_contains "$OUTPUT" 'legacy-home'

# A write below the top level still counts as use.
new_case prune-deep-write
make_session_home deep-write 40
touch "$CAPSULE_HOME/homes/deep-write/.claude/projects/p/s.jsonl"
run_capsule --prune-sessions
assert_not_contains "$OUTPUT" 'deep-write'

# A symlinked go/ must not lead --prune-caches out of the home.
new_case prune-symlinked-go
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

new_case prune-days-threshold
make_session_home ten-days 10
run_capsule --prune-sessions
assert_not_contains "$OUTPUT" 'ten-days'
run_capsule --prune-sessions=7
assert_contains "$OUTPUT" 'ten-days'
[[ -d "$CAPSULE_HOME/homes/ten-days" ]] || fail "dry run removed a home"

# Without podman's answer nothing proves a home is not in use, so prune stops.
new_case prune-needs-podman-ps
make_session_home idle-home 40
PODMAN_PS_FAIL=1 run_capsule_fails --prune-sessions --yes
[[ -d "$CAPSULE_HOME/homes/idle-home" ]] || fail "prune removed a home without checking podman"

new_case prune-bad-args
for prune_args in '--prune-caches=soon' '--prune-sessions=-1' '--yes' \
  '--prune-caches --prune-sessions' '--prune-sessions=100000' \
  '--prune-sessions --session x' '--prune-sessions .' '--prune-sessions --'; do
  # shellcheck disable=SC2086
  run_capsule_fails $prune_args
  assert_not_contains "$OUTPUT" 'Unknown option'
  assert_not_contains "$PODMAN_LOG" 'CALL='
done

# Every launch records last use on the session marker.
new_case launch-refreshes-marker
make_session_home relaunched 40
run_capsule --shell --session relaunched "$ROOT_DIR"
(($(date +%s) - $(file_mtime "$CAPSULE_HOME/homes/relaunched/.agent") < 3600)) ||
  fail "launch did not refresh the session marker"

# The image lives in podman's store, not under AGENT_CAPSULE_HOME, so a second
# capsule home reuses it rather than building its own.
new_case second-capsule-home
other_capsule_home="$CASE_DIR/other-capsule"
mkdir -p "$other_capsule_home"
run_capsule --shell --session first-home "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
CAPSULE_HOME="$other_capsule_home" run_capsule --shell --session second-home "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'


# Floating distro tags keep both toolchains on their latest upstream release.
assert_contains "$SCRIPT" "NODE_TAG=\"\${AGENT_CAPSULE_NODE_TAG:-trixie-slim}\""
assert_contains "$SCRIPT" "GO_TAG=\"\${AGENT_CAPSULE_GO_TAG:-trixie}\""
assert_contains "$DOCKERFILE" 'ARG NODE_TAG=trixie-slim'
assert_contains "$DOCKERFILE" 'ARG GO_TAG=trixie'
assert_contains "$DOCKERFILE" 'SUPERPOWERS_VERSION:-latest'
assert_contains "$DOCKERFILE" "firecrawl/anydoc/v\$anydoc_installed"
for version_variable in \
  ANYDOC_VERSION \
  MCPVAULT_VERSION \
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
for tool_arg in TOOL_GH TOOL_GLAB TOOL_KUBERNETES TOOL_TALOS; do
  assert_contains "$DOCKERFILE" "ARG $tool_arg=0"
done

# = is in COMP_WORDBREAKS, so readline replaces only the text after it: a candidate
# that repeats --opt= ends up typed twice.
new_case completion-after-equals
mkdir -p "$CAPSULE_HOME/homes/work" "$CASE_DIR/notesdir"
: > "$CASE_DIR/mountfile"
[[ "$(complete_line 'agent-capsule --agent=co')" == codex ]] || fail "--agent= completion repeats the flag"
[[ "$(complete_line 'agent-capsule --session=wo')" == work ]] || fail "--session= completion repeats the flag"
[[ "$(complete_line 'agent-capsule --with=an')" == anydoc ]] || fail "--with= completion repeats the flag"
[[ "$(complete_line 'agent-capsule --with=anydoc,ex')" == anydoc,explain-diff ]] ||
  fail "--with= list completion repeats the flag"
[[ "$(complete_line "agent-capsule --vault=$CASE_DIR/notes")" == "$CASE_DIR/notesdir" ]] ||
  fail "--vault= completion repeats the flag"
[[ "$(complete_line "agent-capsule --mount=$CASE_DIR/mountf")" == "$CASE_DIR/mountfile" ]] ||
  fail "--mount= completion repeats the flag"

# Flags come from --help. After a prune flag a flag still completes, its DAYS do not.
new_case completion-flags
[[ "$(complete_line 'agent-capsule --ve')" == "$(printf '%s\n' --version --versions)" ]] ||
  fail "--ve does not complete to the version flags"
[[ "$(complete_line 'agent-capsule --prune-caches --y')" == --yes ]] || fail "no flag completes after --prune-caches"
[[ -z "$(complete_line 'agent-capsule --prune-caches=')" ]] || fail "--prune-caches= offers values"

# With no --agent on the line the launcher runs AGENT_CAPSULE_AGENT, so --with filters on it.
new_case completion-ambient-agent
[[ -z "$(AGENT_CAPSULE_AGENT=codex complete_line 'agent-capsule --with wo')" ]] ||
  fail "--with completion offers worklog under AGENT_CAPSULE_AGENT=codex"
[[ "$(AGENT_CAPSULE_AGENT=codex complete_line 'agent-capsule --agent claude --with wo')" == worklog ]] ||
  fail "--agent on the line does not override AGENT_CAPSULE_AGENT in --with completion"

# --auth-login keeps its home under auth-home/, so homes/_auth is an ordinary session.
new_case completion-auth-session
mkdir -p "$CAPSULE_HOME/homes/_auth"
[[ "$(complete_line 'agent-capsule --session _a')" == _auth ]] || fail "--session completion hides the _auth session"

echo "PASS: $case_count launcher scenarios"
