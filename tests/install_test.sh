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

run_install() {
  local shell_path="$1"
  local case_name="$2"
  local case_root="$TEST_ROOT/$case_name"

  mkdir -p "$case_root/home"
  mkdir -p "$case_root/prefix/share/bash-completion/completions"
  mkdir -p "$case_root/prefix/share/zsh/site-functions"
  cp "$ROOT_DIR/completions/agent-capsule.bash" \
    "$case_root/prefix/share/bash-completion/completions/agent-capsule"
  cp "$ROOT_DIR/completions/_agent-capsule" \
    "$case_root/prefix/share/zsh/site-functions/_agent-capsule"
  # bash-completion's loader would find a completion installed on the host.
  mkdir -p "$case_root/empty"
  HOME="$case_root/home" SHELL="$shell_path" XDG_DATA_HOME="$case_root/empty" \
    XDG_DATA_DIRS="$case_root/empty" BASH_COMPLETION_USER_DIR="$case_root/empty" \
    "$CHECK_COMPLETION" \
    "$case_root/prefix/share/bash-completion/completions" \
    "$case_root/prefix/share/zsh/site-functions" > "$case_root/output" 2>&1
  printf '%s\n' "$case_root/output"
}

# Without active Bash completion, installation gives a command that can be
# copied as-is and points to the relevant documentation section.
output="$(run_install "$(command -v bash)" bash-inactive)"
assert_contains "$output" 'Bash completion is installed but is not active.'
assert_contains "$output" 'source "'
assert_contains "$output" '/share/bash-completion/completions/agent-capsule"'
assert_contains "$output" 'README.md, section "Shell completion"'

# A configured Bash session is recognized, so it does not receive repair steps.
bash_active_root="$TEST_ROOT/bash-active"
mkdir -p "$bash_active_root/home"
mkdir -p "$bash_active_root/prefix/share/bash-completion/completions"
mkdir -p "$bash_active_root/prefix/share/zsh/site-functions"
cp "$ROOT_DIR/completions/agent-capsule.bash" \
  "$bash_active_root/prefix/share/bash-completion/completions/agent-capsule"
cp "$ROOT_DIR/completions/_agent-capsule" \
  "$bash_active_root/prefix/share/zsh/site-functions/_agent-capsule"
printf 'source "%s"\n' \
  "$bash_active_root/prefix/share/bash-completion/completions/agent-capsule" \
  > "$bash_active_root/home/.bashrc"
HOME="$bash_active_root/home" SHELL="$(command -v bash)" \
  "$CHECK_COMPLETION" \
  "$bash_active_root/prefix/share/bash-completion/completions" \
  "$bash_active_root/prefix/share/zsh/site-functions" \
  > "$bash_active_root/output" 2>&1
assert_contains "$bash_active_root/output" 'Bash completion is active.'

# Zsh receives fpath and compinit commands instead of Bash source commands.
fake_zsh="$TEST_ROOT/zsh"
printf '#!/bin/sh\nexit 1\n' > "$fake_zsh"
chmod +x "$fake_zsh"
output="$(run_install "$fake_zsh" zsh-inactive)"
assert_contains "$output" 'Zsh completion is installed but is not active.'
assert_contains "$output" 'fpath=('
assert_contains "$output" 'autoload -Uz compinit && compinit'
assert_contains "$output" 'README.md, section "Shell completion"'

# The Zsh probe checks the autoload name registered from _agent-capsule.
mkdir -p "$TEST_ROOT/active-zsh"
active_zsh="$TEST_ROOT/active-zsh/zsh"
printf '%s\n' \
  '#!/bin/sh' \
  'case "$*" in' \
  '  *"whence -w _agent-capsule"*) exit 0 ;;' \
  '  *) exit 1 ;;' \
  'esac' > "$active_zsh"
chmod +x "$active_zsh"
output="$(run_install "$active_zsh" zsh-active)"
assert_contains "$output" 'Zsh completion is active.'

echo 'PASS: installer completion guidance'
