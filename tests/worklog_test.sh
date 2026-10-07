#!/usr/bin/env bash
# Tests for the worklog plugin hook. Run: bash tests/worklog_test.sh
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK:-$ROOT_DIR/plugins/worklog/hooks/worklog.mjs}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASSES=0
# A file, not a variable: hook() fails from inside command substitutions.
FAILS_FILE="$WORK/fails"
: > "$FAILS_FILE"
pass() { PASSES=$((PASSES + 1)); }
fail() {
  echo "FAIL: $1" >&2
  echo x >> "$FAILS_FILE"
}

gitc() { git -C "$REPO" -c user.name=t -c user.email=t@t "$@"; }

setup() {
  rm -rf "$WORK/case"
  T_HOME="$WORK/case/home"
  T_VAULT="$WORK/case/vault"
  REPO="$WORK/case/repo"
  proc="$WORK/case/procedure.md"
  SID="s1"
  mkdir -p "$T_HOME" "$T_VAULT" "$REPO"
  git -C "$REPO" init -q
  printf 'a\n' > "$REPO/main.go"
  gitc add main.go
  gitc commit -q -m base
}

# hook MODE PROMPT STOP_HOOK_ACTIVE [VAR=VALUE...]: runs the hook in a clean environment, prints its stdout.
hook() {
  local mode="$1" prompt="$2" active="$3"
  shift 3
  printf '{"session_id":"%s","cwd":"%s","prompt":"%s","stop_hook_active":%s}' "$SID" "$REPO" "$prompt" "$active" |
    env -i PATH="$PATH" HOME="$T_HOME" AGENT_CAPSULE_VAULT_DEST="$T_VAULT" "$@" node "$HOOK" "$mode"
  local status=$?
  [[ "$status" == 0 ]] || fail "$mode exited $status"
}

# Prints the block reason, or fails when the output is not a block decision.
reason_of() {
  node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      const j = JSON.parse(s);
      if (j.decision !== "block") process.exit(1);
      process.stdout.write(j.reason);
    });' <<<"$1" 2>/dev/null
}

assert_empty() {
  if [[ -z "$2" ]]; then pass; else fail "$1: expected no output, got: $2"; fi
}

assert_blocks() {
  local name="$1" out="$2" reason needle
  shift 2
  if ! reason="$(reason_of "$out")"; then
    fail "$name: expected a block decision, got: $out"
    return
  fi
  for needle in "$@"; do
    if [[ "$reason" == *"$needle"* ]]; then pass; else fail "$name: reason lacks '$needle'"; fi
  done
}

test_blocks_after_a_turn_that_edits() {
  setup
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  # hook() clears the environment, so both sides pin the time zone.
  assert_blocks "edit" "$(hook check "" false TZ=UTC)" "main.go" "$(TZ=UTC date +%A)" "$(TZ=UTC date +%G-W%V)" \
    "durable change to behavior"
}

test_snapshot_prints_nothing() {
  # UserPromptSubmit stdout is added to the prompt context.
  setup
  assert_empty "snapshot stdout" "$(hook snapshot "do it" false)"
}

test_silent_when_the_turn_changed_nothing() {
  setup
  hook snapshot "explain it" false > /dev/null
  assert_empty "no change" "$(hook check "" false)"
}

test_ignores_edits_made_between_turns() {
  setup
  printf 'b\n' >> "$REPO/main.go"
  hook snapshot "explain it" false > /dev/null
  assert_empty "edit before prompt" "$(hook check "" false)"
}

test_ignores_lockfiles_and_vendor() {
  setup
  hook snapshot "tidy" false > /dev/null
  printf 'x\n' > "$REPO/flake.lock"
  printf 'x\n' > "$REPO/go.sum"
  mkdir -p "$REPO/vendor/dep" "$REPO/sub"
  printf 'x\n' > "$REPO/vendor/dep/dep.go"
  printf 'x\n' > "$REPO/sub/package-lock.json"
  assert_empty "lockfiles" "$(hook check "" false)"
}

test_silent_when_stop_hook_is_active() {
  setup
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  assert_empty "stop_hook_active" "$(hook check "" true)"
}

test_no_doc_skips_only_that_turn() {
  setup
  hook snapshot "try this #no-doc" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  assert_empty "#no-doc" "$(hook check "" false)"
  hook snapshot "now for real" false > /dev/null
  printf 'c\n' >> "$REPO/main.go"
  assert_blocks "after #no-doc" "$(hook check "" false)" "main.go"
}

test_no_doc_does_not_reach_a_turn_without_a_prompt() {
  setup
  hook snapshot "try this #no-doc" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  hook check "" false > /dev/null
  printf 'c\n' >> "$REPO/main.go"
  assert_blocks "turn after #no-doc" "$(hook check "" false)" "main.go"
}

test_counts_work_committed_during_the_turn() {
  setup
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  gitc commit -q -am change
  assert_blocks "committed" "$(hook check "" false)" "main.go"
}

test_flags_changes_brought_in_by_git() {
  setup
  gitc checkout -q -b upstream
  printf 'upstream\n' > "$REPO/upstream.go"
  gitc add upstream.go
  gitc commit -q -m upstream
  gitc checkout -q -
  hook snapshot "pull it" false > /dev/null
  gitc merge -q upstream
  assert_blocks "head moved" "$(hook check "" false)" "upstream.go" "HEAD moved during this turn"
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  local reason
  reason="$(reason_of "$(hook check "" false)")"
  if [[ "$reason" != *"HEAD moved"* ]]; then pass; else fail "HEAD reported as moved"; fi
}

test_works_before_the_first_commit() {
  setup
  rm -rf "$REPO/.git"
  git -C "$REPO" init -q
  hook snapshot "do it" false > /dev/null
  printf 'new\n' > "$REPO/new.go"
  assert_blocks "no commit" "$(hook check "" false)" "new.go"
}

test_counts_new_untracked_files() {
  setup
  hook snapshot "do it" false > /dev/null
  printf 'new\n' > "$REPO/new.go"
  assert_blocks "untracked" "$(hook check "" false)" "new.go"
}

test_lists_a_change_of_thousands_of_files() {
  # Their listing outgrows the 1 MiB that node buffers by default.
  setup
  local long
  long="$(printf '%0230d' 0)"
  hook snapshot "do it" false > /dev/null
  (cd "$REPO" && seq 5000 | sed "s/^/$long-/" | xargs touch)
  assert_blocks "large change" "$(hook check "" false)" "- and 4980 more"
}

test_skips_paths_git_cannot_add() {
  setup
  mkdir "$REPO/nested"
  git -C "$REPO/nested" init -q
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  printf 'new\n' > "$REPO/new.go"
  assert_blocks "unaddable path" "$(hook check "" false)" "main.go" "new.go"
}

test_does_not_report_the_same_work_twice() {
  # A turn can start without a prompt (background task done), so check must rebaseline.
  setup
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  hook check "" false > /dev/null
  assert_empty "second check" "$(hook check "" false)"
}

test_first_check_only_sets_the_baseline() {
  setup
  printf 'b\n' >> "$REPO/main.go"
  assert_empty "check before snapshot" "$(hook check "" false)"
  printf 'c\n' >> "$REPO/main.go"
  assert_blocks "check after check" "$(hook check "" false)" "main.go"
}

test_ignores_a_baseline_from_another_repository() {
  setup
  hook snapshot "do it" false > /dev/null
  REPO="$WORK/case/other"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  printf 'other\n' > "$REPO/other.go"
  assert_empty "other repository" "$(hook check "" false)"
}

test_leaves_the_real_index_untouched() {
  setup
  printf 'staged\n' >> "$REPO/main.go"
  gitc add main.go
  printf 'unstaged\n' >> "$REPO/main.go"
  local before after
  before="$(git hash-object --stdin < "$REPO/.git/index")"
  hook snapshot "do it" false > /dev/null
  printf 'new\n' > "$REPO/new.go"
  hook check "" false > /dev/null
  after="$(git hash-object --stdin < "$REPO/.git/index")"
  if [[ "$before" == "$after" ]]; then pass; else fail "real index changed"; fi
}

test_keeps_snapshots_out_of_the_repository() {
  setup
  local before after
  before="$(find "$REPO/.git/objects" -type f | wc -l)"
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  printf 'new\n' > "$REPO/new.go"
  assert_blocks "private objects" "$(hook check "" false)" "main.go" "new.go"
  after="$(find "$REPO/.git/objects" -type f | wc -l)"
  if [[ "$before" == "$after" ]]; then pass; else fail "snapshots wrote $((after - before)) repository objects"; fi
}

test_drops_old_snapshot_objects_on_each_prompt() {
  setup
  local blob object
  blob="$(printf 'gone\n' | git hash-object --stdin)"
  object="*/${blob:0:2}/${blob:2}"
  hook snapshot "do it" false > /dev/null
  printf 'gone\n' > "$REPO/gone.go"
  hook check "" false > /dev/null
  [[ -n "$(find "$T_HOME/.cache/worklog" -path "$object")" ]] || fail "test expects the private object store"
  rm "$REPO/gone.go"
  hook snapshot "next" false > /dev/null
  if [[ -z "$(find "$T_HOME/.cache/worklog" -path "$object")" ]]; then pass; else fail "old snapshot kept"; fi
}

test_prunes_sessions_idle_for_a_week() {
  setup
  local sid cache="$T_HOME/.cache/worklog" state="$T_HOME/.claude/worklog"
  mkdir -p "$state"
  for sid in idle recent half; do
    mkdir -p "$cache/$sid"
    echo '{}' > "$state/$sid"
  done
  # A session is idle only when both its state and its store are.
  touch -t 202001010000 "$cache/idle" "$state/idle" "$state/half"
  hook snapshot "do it" false > /dev/null
  if [[ ! -e "$cache/idle" && ! -e "$state/idle" ]]; then pass; else fail "idle session kept"; fi
  for sid in recent half "$SID"; do
    if [[ -e "$cache/$sid" && -e "$state/$sid" ]]; then pass; else fail "session $sid pruned"; fi
  done
}

test_keeps_the_baseline_when_a_snapshot_fails() {
  setup
  # Uncommitted work puts the baseline's objects in the private store.
  printf 'pending\n' > "$REPO/pending.go"
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  cp "$REPO/.git/index" "$WORK/case/index"
  printf 'corrupt' > "$REPO/.git/index"
  printf '{"session_id":"%s","cwd":"%s","prompt":"next"}' "$SID" "$REPO" |
    env -i PATH="$PATH" HOME="$T_HOME" AGENT_CAPSULE_VAULT_DEST="$T_VAULT" node "$HOOK" snapshot > /dev/null 2>&1
  cp "$WORK/case/index" "$REPO/.git/index"
  assert_blocks "failed snapshot" "$(hook check "" false)" "main.go"
}

test_handles_unusual_repository_paths() {
  local dir
  for dir in "repo " "re:po"; do
    setup
    mv "$REPO" "$WORK/case/$dir"
    REPO="$WORK/case/$dir"
    # An old mtime stops git from rehashing main.go, so the snapshot must read the repository's objects.
    touch -t 202001010000 "$REPO/main.go"
    gitc update-index -q --refresh
    hook snapshot "do it" false > /dev/null
    printf 'b\n' >> "$REPO/main.go"
    assert_blocks "repository path '$dir'" "$(hook check "" false)" "main.go"
  done
}

test_silent_outside_a_git_repo() {
  setup
  REPO="$WORK/case/plain"
  mkdir -p "$REPO"
  hook snapshot "do it" false > /dev/null
  printf 'b\n' > "$REPO/file"
  assert_empty "not a repo" "$(hook check "" false)"
}

test_silent_for_a_repo_inside_the_vault() {
  # Logging edits the vault, which would then count as new work.
  setup
  hook snapshot "do it" false AGENT_CAPSULE_VAULT_DEST="$WORK/case" > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  assert_empty "repo in vault" "$(hook check "" false AGENT_CAPSULE_VAULT_DEST="$WORK/case")"
}

test_rejects_unsafe_session_ids() {
  setup
  SID="../escape"
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  assert_empty "unsafe id" "$(hook check "" false)"
  if [[ ! -e "$T_HOME/.claude/escape" ]]; then pass; else fail "state written outside its directory"; fi
}

test_uses_the_procedure_file() {
  setup
  printf 'MY VAULT STEPS\n' > "$proc"
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  assert_blocks "procedure file" "$(hook check "" false AGENT_CAPSULE_WORKLOG_PROCEDURE="$proc")" "MY VAULT STEPS"
}

test_blank_or_missing_procedure_falls_back() {
  setup
  local file
  printf '  \n' > "$proc"
  for file in "$proc" "$WORK/case/missing.md"; do
    hook snapshot "do it" false > /dev/null
    printf 'b\n' >> "$REPO/main.go"
    assert_blocks "fallback ${file##*/}" "$(hook check "" false AGENT_CAPSULE_WORKLOG_PROCEDURE="$file")" \
      "README or index notes"
  done
}

test_strips_procedure_frontmatter() {
  setup
  printf -- '---\ntags: [log]\n---\nMY VAULT STEPS\n' > "$proc"
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  local out reason
  out="$(hook check "" false AGENT_CAPSULE_WORKLOG_PROCEDURE="$proc")"
  assert_blocks "frontmatter" "$out" "MY VAULT STEPS"
  reason="$(reason_of "$out")"
  if [[ "$reason" != *'tags: [log]'* ]]; then pass; else fail "frontmatter left in the reason"; fi
}

test_reason_carries_the_significance_test() {
  setup
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  assert_blocks "significance" "$(hook check "" false)" \
    "durable change to behavior, architecture, configuration" 'reply only "Nothing to log."'
}

test_procedure_mode_prints_the_procedure() {
  setup
  printf 'MY VAULT STEPS\n' > "$proc"
  local out
  out="$(env -i PATH="$PATH" HOME="$T_HOME" AGENT_CAPSULE_WORKLOG_PROCEDURE="$proc" node "$HOOK" procedure </dev/null)"
  if [[ "$out" == "MY VAULT STEPS" ]]; then pass; else fail "procedure mode printed: $out"; fi
}

test_missing_vault_path_does_not_crash() {
  setup
  hook snapshot "do it" false AGENT_CAPSULE_VAULT_DEST="$WORK/nowhere" > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  assert_blocks "missing vault" "$(hook check "" false AGENT_CAPSULE_VAULT_DEST="$WORK/nowhere")" "main.go"
}

test_lists_unusual_file_names() {
  setup
  hook snapshot "do it" false > /dev/null
  printf 'n\n' > "$REPO/with space.go"
  printf 'n\n' > "$REPO/café.go"
  assert_blocks "file names" "$(hook check "" false)" "with space.go" "café.go"
}

test_labels_binary_files() {
  setup
  hook snapshot "do it" false > /dev/null
  printf 'b\n' >> "$REPO/main.go"
  printf 'a\0b' > "$REPO/image.bin"
  assert_blocks "binary" "$(hook check "" false)" "- image.bin (binary)" "- main.go (+1 -0)"
}

test_lists_twenty_files_at_most() {
  setup
  local out rows
  hook snapshot "do it" false > /dev/null
  (cd "$REPO" && seq 20 | sed 's/$/.go/' | xargs touch)
  rows="$(reason_of "$(hook check "" false)" | grep -c '^- ')"
  if [[ "$rows" == 20 ]]; then pass; else fail "20 files: $rows rows"; fi
  hook snapshot "next" false > /dev/null
  (cd "$REPO" && seq 21 | sed 's/$/.txt/' | xargs touch)
  out="$(hook check "" false)"
  assert_blocks "21 files" "$out" "- and 1 more"
  rows="$(reason_of "$out" | grep -c '^- ')"
  if [[ "$rows" == 21 ]]; then pass; else fail "21 files: $rows rows"; fi
}

for t in $(declare -F | awk '$3 ~ /^test_/ {print $3}'); do
  "$t"
done

# Arithmetic drops the padding that BSD wc adds.
FAILS=$(($(wc -l < "$FAILS_FILE")))
if [[ "$FAILS" == 0 ]]; then
  echo "PASS: $PASSES worklog checks"
else
  echo "failed: $FAILS, passed: $PASSES" >&2
  exit 1
fi
