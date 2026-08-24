#!/usr/bin/env bash

set -euo pipefail

BASH_BIN="$(command -v bash)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/agent-capsule"
DOCKERFILE="$ROOT_DIR/Dockerfile"
# The script owns its version; asserting a literal here breaks on every bump.
LAUNCHER_VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT")"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

# The suite is commonly run from inside a capsule, where AGENT_CAPSULE_* and
# HERDR_* are exported. They would reach the script under test and change what
# it does, so drop the whole namespace before the first case.
for leaked_variable in $(env | sed -n 's/^\(AGENT_CAPSULE_[A-Za-z0-9_]*\)=.*/\1/p;s/^\(HERDR_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$leaked_variable"
done
unset leaked_variable

FAKE_BIN="$TEST_ROOT/bin"
mkdir -p "$FAKE_BIN"

printf '#!%s\n' "$BASH_BIN" > "$FAKE_BIN/podman"
cat >> "$FAKE_BIN/podman" <<'PODMAN'
set -eu

printf 'CALL=%s\n' "${1:-}" >> "$PODMAN_LOG"
previous=""
bundle_hash=""
image_ref=""
for arg in "$@"; do
  printf 'ARG=%s\n' "$arg" >> "$PODMAN_LOG"
  if [[ "$previous" == "--label" && "$arg" == io.agent-capsule.bundle=* ]]; then
    bundle_hash="${arg#*=}"
  fi
  if [[ "$previous" == "-t" ]]; then
    image_ref="$arg"
  fi
  previous="$arg"
done

if [[ "${1:-}" == "image" && "${2:-}" == "inspect" ]]; then
  for arg in "$@"; do image_ref="$arg"; done
  awk -F '\t' -v image="$image_ref" '$1 == image { value = $2 } END { if (value != "") print value }' \
    "$PODMAN_IMAGE_STATE"
  exit 0
fi

if [[ "${1:-}" == "build" && -n "$image_ref" && -n "$bundle_hash" ]]; then
  sleep "${PODMAN_BUILD_DELAY:-0}"
  printf '%s\t%s\n' "$image_ref" "$bundle_hash" >> "$PODMAN_IMAGE_STATE"
fi

exit 0
PODMAN
chmod +x "$FAKE_BIN/podman"

if command -v sha256sum >/dev/null 2>&1; then
  SHA256_COMMAND=(sha256sum)
else
  SHA256_COMMAND=(shasum -a 256)
fi

file_mode() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

pass_count=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

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
  mkdir -p "$CAPSULE_HOME" "$HOST_HOME"
  : > "$PODMAN_LOG"
  : > "$PODMAN_IMAGE_STATE"
  ((pass_count += 1))
}

run_capsule() {
  HOME="$HOST_HOME" \
    PATH="$FAKE_BIN:$PATH" \
    PODMAN_LOG="$PODMAN_LOG" \
    PODMAN_IMAGE_STATE="$PODMAN_IMAGE_STATE" \
    AGENT_CAPSULE_HOME="$CAPSULE_HOME" \
    AGENT_CAPSULE_DOCKERFILE="${AGENT_CAPSULE_DOCKERFILE:-$DOCKERFILE}" \
    XDG_RUNTIME_DIR="$TEST_ROOT/xdg" \
    "$BASH_BIN" "$SCRIPT" "$@" > "$OUTPUT" 2>&1
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
assert_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT={"plugin":["/opt/superpowers/source"],"mcp":{"obsidian":{"type":"local","command":["mcpvault","/vault"]}}}'

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
assert_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT={"mcp":{"obsidian":{"type":"local","command":["mcpvault","/vault"]}}}'

: > "$PODMAN_LOG"
run_capsule --agent opencode --shell --session opencode-state --with none "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT='
[[ "$(<"$user_config")" == '{"theme":"user-owned"}' ]] || fail "user OpenCode config changed"

# Vault flags are last-one-wins, in both directions.
: > "$PODMAN_LOG"
run_capsule --agent opencode --shell --session opencode-state \
  --with mcpvault --no-vault --vault="$vault_dir" "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT={"mcp":{"obsidian":{"type":"local","command":["mcpvault","/vault"]}}}'

: > "$PODMAN_LOG"
run_capsule --agent opencode --shell --session opencode-state \
  --with mcpvault --vault="$vault_dir" --no-vault "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'obsidian'

new_case
run_capsule --help
assert_contains "$OUTPUT" 'Usage:'
assert_contains "$OUTPUT" '--versions'
assert_contains "$OUTPUT" '--shared-rules PATH'
assert_contains "$OUTPUT" 'explain-diff'
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
assert_not_contains "$PODMAN_LOG" 'CALL='

# An unset pin reaches the build as an empty arg, which the Dockerfile reads as
# "latest"; an override carries its value through.
new_case
run_capsule --shell --session unpinned-build "$ROOT_DIR"
assert_arg_after "$PODMAN_LOG" --build-arg 'CLAUDE_CODE_VERSION='
assert_arg_after "$PODMAN_LOG" --build-arg 'SUPERPOWERS_VERSION='
: > "$PODMAN_LOG"
AGENT_CAPSULE_CLAUDE_CODE_VERSION=9.8.7 \
  run_capsule --shell --session pinned-build "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'CLAUDE_CODE_VERSION=9.8.7'

new_case
AGENT_CAPSULE_CLAUDE_CODE_VERSION=1.2.3-beta.1+build.7 run_capsule --versions
assert_contains "$OUTPUT" 'claude-code 1.2.3-beta.1+build.7'

new_case
AGENT_CAPSULE_SUPERPOWERS_VERSION=v1.2.3-beta.1+build.7 run_capsule --versions
assert_contains "$OUTPUT" 'superpowers v1.2.3-beta.1+build.7'

new_case
set +e
AGENT_CAPSULE_CLAUDE_CODE_VERSION=invalid run_capsule --shell "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" 'Invalid pinned package version: invalid'
assert_not_contains "$PODMAN_LOG" 'CALL='

# A session from the environment is an ambient default; only an
# explicit --session conflicts with the dedicated auth home.
new_case
AGENT_CAPSULE_SESSION=configured-session run_capsule --auth-login
assert_contains "$OUTPUT" '>> Session : _auth'

new_case
set +e
run_capsule --auth-login --session explicit-session
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" '--auth-login uses its own session'

for agent in claude codex opencode; do
  new_case
  set +e
  run_capsule --agent "$agent" --auth-login --offline
  status=$?
  set -e
  assert_status_fails "$status"
  assert_contains "$OUTPUT" '--auth-login cannot be combined with --offline'
done

# These values must stay aligned when another agent profile is added.
for profile in \
  'claude|agent-capsule-dev:latest|claude|.claude/CLAUDE.md' \
  'codex|agent-capsule-dev:latest|codex|.codex/AGENTS.md' \
  'opencode|agent-capsule-dev:latest|opencode|.config/opencode/AGENTS.md'; do
  IFS='|' read -r agent image command rules_path <<< "$profile"
  new_case
  run_capsule --agent "$agent" --session "profile-$agent" "$ROOT_DIR" -- --version
  assert_contains "$PODMAN_LOG" "ARG=ai.agent=$agent"
  assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/CLAUDE.md:/home/dev/$rules_path:ro"
  assert_arg_after "$PODMAN_LOG" "$image" "$command"
  assert_arg_after "$PODMAN_LOG" "$command" '--version'
done

# The shared 0.1 authentication home stops the launch without changing files.
new_case
legacy_credential="$CAPSULE_HOME/auth-home/.claude/.credentials.json"
mkdir -p "$(dirname "$legacy_credential")"
printf '%s\n' token > "$legacy_credential"
set +e
run_capsule --shell --session legacy-auth-home "$ROOT_DIR"
status=$?
set -e
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
run_capsule --agent claude --shell --session selection-claude "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'CALL=build'
assert_arg_after "$PODMAN_LOG" --build-arg 'AGENT=claude'
assert_arg_after "$PODMAN_LOG" --build-arg 'WITH_SUPERPOWERS=0'

: > "$PODMAN_LOG"
run_capsule --agent claude --shell --session selection-claude "$ROOT_DIR"
assert_not_contains "$PODMAN_LOG" 'CALL=build'

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

# So does changing the integrations, with the agent held fixed.
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
set +e
run_capsule --with hunkdiff --session removed-hunkdiff "$ROOT_DIR"
status=$?
set -e
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
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_WITH='
assert_not_contains "$PODMAN_LOG" 'OPENCODE_CONFIG_CONTENT='
assert_not_contains "$PODMAN_LOG" '/opt/superpowers/source'
assert_contains "$OUTPUT" '>> Extras  : none'

new_case
ANTHROPIC_API_KEY=anthropic-secret OPENAI_API_KEY=openai-secret \
  run_capsule --agent opencode --session opencode-env "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=ANTHROPIC_API_KEY'
assert_contains "$PODMAN_LOG" 'ARG=OPENAI_API_KEY'
assert_not_contains "$PODMAN_LOG" 'anthropic-secret'
assert_not_contains "$PODMAN_LOG" 'openai-secret'

new_case
set +e
run_capsule --agent codex --with anydoc --session unsupported-extra "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" "Extra 'anydoc' is not available with --agent codex"

new_case
set +e
run_capsule --with= --shell --session empty-extra "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" '--with requires a tool list'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
mount_file="$CASE_DIR/tool.conf"
printf '%s\n' setting > "$mount_file"
run_capsule --shell --session file-mount --mount "$mount_file:/etc/tool.conf:ro" "$ROOT_DIR"
assert_contains "$PODMAN_LOG" "ARG=$mount_file:/etc/tool.conf:ro"

new_case
set +e
run_capsule --shell --session missing-vault --vault "$ROOT_DIR"
status=$?
set -e
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
set +e
AGENT_CAPSULE_VAULT_DEST=relative \
  run_capsule --shell --session invalid-vault-destination --vault="$vault_dir" "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" 'Invalid vault destination: relative'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
long_session="$(printf 'a%.0s' {1..121})"
set +e
run_capsule --shell --session "$long_session" "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" 'not starting with a dot'

new_case
set +e
run_capsule --shell --session 'fix/auth' "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" "Invalid session name: 'fix/auth'."
[[ ! -e "$CAPSULE_HOME/homes/fixauth" ]] || fail "invalid session name was normalized"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
set +e
run_capsule --shell --session= "$ROOT_DIR"
status=$?
set -e
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
  set +e
  run_capsule --shell --session "$invalid_session" "$ROOT_DIR"
  status=$?
  set -e
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

new_case
portable_bin="$CASE_DIR/portable-bin"
mkdir -p "$portable_bin"
for tool in bash awk tr mkdir chmod touch cp cat dirname basename shasum rm sleep; do
  ln -s "$(command -v "$tool")" "$portable_bin/$tool"
done
HOME="$HOST_HOME" \
  PATH="$portable_bin:$FAKE_BIN" \
  PODMAN_LOG="$PODMAN_LOG" \
  PODMAN_IMAGE_STATE="$PODMAN_IMAGE_STATE" \
  AGENT_CAPSULE_HOME="$CAPSULE_HOME" \
  AGENT_CAPSULE_DOCKERFILE="$DOCKERFILE" \
  "$BASH_BIN" "$SCRIPT" --shell --session shasum-fallback "$ROOT_DIR" > "$OUTPUT" 2>&1
assert_contains "$PODMAN_LOG" 'CALL=run'
[[ "$(file_mode "$CAPSULE_HOME/CLAUDE.md")" == "600" ]] || fail "default rules mode is not private"

new_case
codex_home="$CAPSULE_HOME/homes/codex-owned"
mkdir -p "$codex_home/.codex"
printf '%s\n' codex > "$codex_home/.agent"
set +e
run_capsule --shell --session codex-owned "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" "was created by agent 'codex'"

new_case
HERDR_AGENT=codex run_capsule --shell --session herdr-divergence "$ROOT_DIR"
assert_contains "$OUTPUT" '>> Agent   : claude (HERDR_AGENT=codex)'

new_case
set +e
run_capsule --shared-claude-md "$CASE_DIR/x.md" --shell --session removed-flag "$ROOT_DIR"
status=$?
set -e
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
  OUTPUT="$CASE_DIR/first.output"
  PODMAN_BUILD_DELAY=0.2 run_capsule --shell --session concurrent-first "$ROOT_DIR"
) &
first_pid=$!
(
  OUTPUT="$CASE_DIR/second.output"
  PODMAN_BUILD_DELAY=0.2 run_capsule --shell --session concurrent-second "$ROOT_DIR"
) &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
[[ "$(grep -c '^CALL=build$' "$PODMAN_LOG")" == "1" ]] ||
  fail "concurrent launches built the image more than once"
[[ ! -e "$TEST_ROOT/xdg/agent-capsule-$UID/image.lock" ]] ||
  fail "image build lock was not removed"

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

echo "PASS: $pass_count launcher scenarios"
