#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null && pwd)"
CHECK_COMPLETION="$ROOT_DIR/scripts/check-shell-completion"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

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
  if grep -F -- "$2" "$1" >/dev/null; then fail "$1 unexpectedly contains: $2"; fi
}

# Installs both completion files under a prefix in a fresh case dir.
setup_case() { # name
  CASE_ROOT="$TEST_ROOT/$1"
  BASH_DIR="$CASE_ROOT/prefix/share/bash-completion/completions"
  ZSH_DIR="$CASE_ROOT/prefix/share/zsh/site-functions"
  mkdir -p "$CASE_ROOT/home" "$CASE_ROOT/empty" "$BASH_DIR" "$ZSH_DIR"
  cp "$ROOT_DIR/completions/agent-capsule.bash" "$BASH_DIR/agent-capsule"
  cp "$ROOT_DIR/completions/_agent-capsule" "$ZSH_DIR/_agent-capsule"
}

# Runs the installer's completion check with SHELL set to $1, and prints the path of its output.
run_check() { # shell
  # bash-completion's loader would find a completion installed on the host.
  HOME="$CASE_ROOT/home" SHELL="$1" XDG_DATA_HOME="$CASE_ROOT/empty" \
    XDG_DATA_DIRS="$CASE_ROOT/empty" BASH_COMPLETION_USER_DIR="$CASE_ROOT/empty" \
    "$CHECK_COMPLETION" "$BASH_DIR" "$ZSH_DIR" > "$CASE_ROOT/output" 2>&1
  printf '%s\n' "$CASE_ROOT/output"
}

# Without active Bash completion, installation gives a command that can be
# copied as-is and points to the relevant documentation section.
setup_case bash-inactive
output="$(run_check "$(command -v bash)")"
assert_contains "$output" 'Bash completion is installed but is not active.'
assert_contains "$output" "source \"$BASH_DIR/agent-capsule\""
assert_contains "$output" 'See docs/shell-completion.md.'

# A configured Bash session is recognized, so it does not receive repair steps.
setup_case bash-active
printf 'source "%s"\n' "$BASH_DIR/agent-capsule" > "$CASE_ROOT/home/.bashrc"
output="$(run_check "$(command -v bash)")"
assert_contains "$output" 'Bash completion is active.'
assert_not_contains "$output" 'See docs/shell-completion.md.'

# Zsh receives fpath and compinit commands instead of Bash source commands.
setup_case zsh-inactive
printf '#!/bin/sh\nexit 1\n' > "$CASE_ROOT/zsh"
chmod +x "$CASE_ROOT/zsh"
output="$(run_check "$CASE_ROOT/zsh")"
assert_contains "$output" 'Zsh completion is installed but is not active.'
assert_contains "$output" "fpath=(\"$ZSH_DIR\""
assert_contains "$output" 'autoload -Uz compinit && compinit'
assert_contains "$output" 'See docs/shell-completion.md.'

# The Zsh probe checks the autoload name registered from _agent-capsule.
setup_case zsh-active
printf '%s\n' \
  '#!/bin/sh' \
  'case "$*" in' \
  '  *"whence -w _agent-capsule"*) exit 0 ;;' \
  '  *) exit 1 ;;' \
  'esac' > "$CASE_ROOT/zsh"
chmod +x "$CASE_ROOT/zsh"
output="$(run_check "$CASE_ROOT/zsh")"
assert_contains "$output" 'Zsh completion is active.'

echo 'PASS: installer completion guidance'
