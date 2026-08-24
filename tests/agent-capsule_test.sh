#!/usr/bin/env bash

set -euo pipefail

BASH_BIN="$(command -v bash)"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/agent-capsule"
DOCKERFILE="$ROOT_DIR/Dockerfile"
DOCKERIGNORE="$ROOT_DIR/.dockerignore"
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
    AGENT_CAPSULE_DOCKERFILE="$DOCKERFILE" \
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
[[ "$(stat -c %a "$rules_file")" == "644" ]] || fail "shared rules mode changed"

new_case
legacy_dir="$CAPSULE_HOME/homes/opencode-state/.config/opencode"
mkdir -p "$legacy_dir"
printf '%s\n' '{"legacy":true}' > "$legacy_dir/opencode.json"
touch "$legacy_dir/.opencode.json.capsule"
set +e
run_capsule --agent opencode --shell --session opencode-state \
  "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" "legacy OpenCode marker $legacy_dir/.opencode.json.capsule"
assert_contains "$OUTPUT" 'No files were changed.'
[[ "$(<"$legacy_dir/opencode.json")" == '{"legacy":true}' ]] ||
  fail "legacy OpenCode config changed"
[[ -e "$legacy_dir/.opencode.json.capsule" ]] || fail "legacy OpenCode marker changed"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

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
set +e
AGENT_CAPSULE_CONFIG="$CASE_DIR/missing" "$BASH_BIN" "$SCRIPT" --help > "$OUTPUT" 2>&1
status=$?
set -e
[[ "$status" -eq 0 ]] || fail "--help was blocked by a missing config"
assert_contains "$OUTPUT" 'Usage:'
assert_contains "$OUTPUT" '--versions'
assert_contains "$OUTPUT" '--shared-rules PATH'
[[ "$(wc -l < "$OUTPUT")" -le 45 ]] || fail "--help is too verbose"
AGENT_CAPSULE_CONFIG="$CASE_DIR/missing" "$BASH_BIN" "$SCRIPT" --version > "$OUTPUT" 2>&1 ||
  fail "--version was blocked by a missing config"
assert_contains "$OUTPUT" "agent-capsule $LAUNCHER_VERSION"

new_case
printf '%s\n' 'AGENT_CAPSULE_AGENT="codex' > "$CASE_DIR/config"
set +e
HOME="$HOST_HOME" PATH="$FAKE_BIN:$PATH" PODMAN_LOG="$PODMAN_LOG" \
  AGENT_CAPSULE_CONFIG="$CASE_DIR/config" "$BASH_BIN" "$SCRIPT" --shell "$ROOT_DIR" > "$OUTPUT" 2>&1
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" 'unterminated quoted value for AGENT_CAPSULE_AGENT'

new_case
printf '%s\n' 'accidentally-pasted-secret' > "$CAPSULE_HOME/config"
run_capsule --shell --session malformed-config "$ROOT_DIR"
assert_contains "$OUTPUT" "$CAPSULE_HOME/config:1: ignoring line without '='"
assert_not_contains "$OUTPUT" 'accidentally-pasted-secret'

new_case
AGENT_CAPSULE_CLAUDE_CODE_VERSION=9.8.7 AGENT_CAPSULE_CODEX_VERSION=6.5.4 run_capsule --versions
assert_contains "$OUTPUT" 'claude-code 9.8.7'
assert_contains "$OUTPUT" 'codex 6.5.4'
assert_not_contains "$PODMAN_LOG" 'CALL='

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

# A session from the environment or config is an ambient default; only an
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

# Legacy credentials stop the launch without changing files.
for profile in \
  'claude|.claude/.credentials.json|.claude' \
  'codex|.codex/auth.json|.codex' \
  'opencode|.local/share/opencode/auth.json|.local/share/opencode/auth.json'; do
  IFS='|' read -r agent credential_path detected_path <<< "$profile"
  new_case
  legacy_credential="$CAPSULE_HOME/auth-home/$credential_path"
  mkdir -p "$(dirname "$legacy_credential")"
  printf '%s\n' token > "$legacy_credential"
  set +e
  run_capsule --agent "$agent" --shell --session "credentials-$agent" "$ROOT_DIR"
  status=$?
  set -e
  assert_status_fails "$status"
  assert_contains "$OUTPUT" \
    "legacy authentication state $CAPSULE_HOME/auth-home/$detected_path"
  [[ "$(<"$legacy_credential")" == token ]] || fail "legacy $agent credential changed"
  assert_not_contains "$PODMAN_LOG" 'CALL=run'
done

new_case
for agent in claude codex opencode; do
  mkdir -p "$CAPSULE_HOME/auth-home/$agent"
done
run_capsule --agent codex --auth-login -- --with-api-key
assert_contains "$PODMAN_LOG" "ARG=$CAPSULE_HOME/auth-home/codex:/home/dev"
assert_not_contains "$PODMAN_LOG" "$CAPSULE_HOME/auth-home/claude:/home/dev"
assert_not_contains "$PODMAN_LOG" "$CAPSULE_HOME/auth-home/opencode:/home/dev"

new_case
run_capsule --agent claude --shell --session universal-claude "$ROOT_DIR"
: > "$PODMAN_LOG"
run_capsule --agent codex --shell --with superpowers \
  --session universal-codex "$ROOT_DIR"
assert_contains "$PODMAN_LOG" 'ARG=agent-capsule-dev:latest'
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_AGENT=codex'
assert_contains "$PODMAN_LOG" 'ARG=AGENT_CAPSULE_WITH=superpowers'
assert_not_contains "$PODMAN_LOG" 'CALL=build'

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
assert_contains "$OUTPUT" 'legacy integration hunkdiff'
assert_contains "$DOCKERFILE" "\"@anthropic-ai/claude-code@\$CLAUDE_CODE_VERSION\""
assert_not_contains "$DOCKERFILE" 'hunkdiff'
assert_contains "$DOCKERFILE" "if [[ -e \"\$marker\" ]]; then"
assert_not_contains "$DOCKERFILE" 'codex plugin marketplace list'
assert_not_contains "$DOCKERFILE" 'superpowers activation failed; retrying next run'
assert_not_contains "$DOCKERFILE" 'marketplace add /opt/superpowers/source >/dev/null 2>&1 || true'
assert_contains "$DOCKERIGNORE" '*'
assert_contains "$DOCKERIGNORE" '!Dockerfile'

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
assert_contains "$OUTPUT" '--with= requires a tool list'
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
assert_contains "$OUTPUT" 'Session name is too long'

new_case
set +e
run_capsule --shell --session 'fix/auth' "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" 'Invalid session name. Use only letters, digits, dots, underscores, and hyphens.'
[[ ! -e "$CAPSULE_HOME/homes/fixauth" ]] || fail "invalid session name was normalized"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
set +e
run_capsule --shell --session= "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" '--session= requires a name.'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

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
[[ "$(stat -c %a "$CAPSULE_HOME/CLAUDE.md")" == "600" ]] || fail "default rules mode is not private"

# Unmarked homes with agent state are rejected without assigning ownership.
new_case
mixed_home="$CAPSULE_HOME/homes/mixed-home"
mkdir -p "$mixed_home/.claude" "$mixed_home/.codex"
set +e
run_capsule --shell --session mixed-home "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" "unmarked session state $mixed_home/.claude"
[[ ! -e "$mixed_home/.agent" ]] || fail "legacy session was assigned an owner"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
project_hash="$(printf '%s' "$ROOT_DIR" | sha256sum | cut -c1-12)"
legacy_default_home="$CAPSULE_HOME/homes/$(basename "$ROOT_DIR")-$project_hash"
mkdir -p "$legacy_default_home/.claude"
set +e
run_capsule --agent codex --shell "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" "unmarked session state $legacy_default_home/.claude"
[[ ! -e "$legacy_default_home/.agent" ]] || fail "legacy default session was changed"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

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
agents_md="$CASE_DIR/agents.md"
touch "$agents_md"
printf 'AGENT_CAPSULE_SHARED_AGENTS_MD=%s\n' "$agents_md" > "$CAPSULE_HOME/config"
set +e
run_capsule --shell --session agents-md-fallback "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" 'legacy variable AGENT_CAPSULE_SHARED_AGENTS_MD'
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
legacy_rules="$CAPSULE_HOME/AGENTS.md"
touch "$legacy_rules"
set +e
run_capsule --shell --session legacy-rules-file "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" "legacy shared rules file $legacy_rules"
[[ ! -e "$CAPSULE_HOME/CLAUDE.md" ]] || fail "new rules file was created during preflight"
assert_not_contains "$PODMAN_LOG" 'CALL=run'

new_case
set +e
run_capsule --shared-claude-md "$agents_md" --shell --session legacy-rules "$ROOT_DIR"
status=$?
set -e
assert_status_fails "$status"
assert_contains "$OUTPUT" 'legacy option --shared-claude-md'
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
memory_hash="$(printf '%s' "$main_repo" | sha256sum | cut -c1-12)"
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

new_case
other_capsule_home="$CASE_DIR/other-capsule"
mkdir -p "$other_capsule_home"
(
  OUTPUT="$CASE_DIR/first-home.output"
  PODMAN_BUILD_DELAY=0.2 run_capsule --shell --session first-home "$ROOT_DIR"
) &
first_pid=$!
(
  CAPSULE_HOME="$other_capsule_home"
  OUTPUT="$CASE_DIR/second-home.output"
  PODMAN_BUILD_DELAY=0.2 run_capsule --shell --session second-home "$ROOT_DIR"
) &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
[[ "$(grep -c '^CALL=build$' "$PODMAN_LOG")" == "1" ]] ||
  fail "separate capsule homes built the same image more than once"

echo "PASS: $pass_count launcher scenarios"
