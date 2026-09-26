#!/usr/bin/env bats
# Covers the prefix index in scripts/lib/index.sh.
#
# Regression: the index used to read only the first line of .beads/issues.jsonl.
# A repo in Dolt server mode (~/co/focuster) has no issues.jsonl, so it was
# never indexed. Its prefix then resolved only to a stale checkout that had
# one, and every new bead showed "No repo contains <id>".

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIX="$BATS_TEST_TMPDIR/roots"
  mkdir -p "$FIX"
  export BEADS_POPOVER_ROOTS="$FIX"
  export BEADS_POPOVER_INDEX="$BATS_TEST_TMPDIR/index.tsv"
  set -uo pipefail
  source "$ROOT/scripts/lib/index.sh"
}

# repo <name> <config.yaml body> [first issues.jsonl line]
repo() {
  mkdir -p "$FIX/$1/.beads"
  printf '%s\n' "$2" >"$FIX/$1/.beads/config.yaml"
  [[ -n "${3:-}" ]] && printf '%s\n' "$3" >"$FIX/$1/.beads/issues.jsonl"
  return 0
}

@test "indexes a Dolt server repo that has no issues.jsonl" {
  repo focuster $'dolt.mode: server\nissue_prefix: fo-'
  build_index
  run cat "$BEADS_POPOVER_INDEX"
  [ "$output" = "$(printf 'fo\t%s' "$FIX/focuster")" ]
}

@test "strips quotes and a trailing separator from the configured prefix" {
  repo intervaltree 'issue-prefix: "in"'
  repo beads 'issue-prefix: bd-'
  run repo_prefix "$FIX/intervaltree"
  [ "$output" = "in" ]
  run repo_prefix "$FIX/beads"
  [ "$output" = "bd" ]
}

@test "ignores the commented example and falls back to issues.jsonl" {
  repo lc $'# issue-prefix: ""\n# Example: issue-prefix: "myproject"' \
    '{"_type":"issue","id":"lc-abc12","title":"x"}'
  run repo_prefix "$FIX/lc"
  [ "$output" = "lc" ]
}

@test "config.yaml wins over a stale issues.jsonl" {
  repo pnpm 'issue_prefix: fo-' '{"id":"focuster-old1"}'
  run repo_prefix "$FIX/pnpm"
  [ "$output" = "fo" ]
}

@test "skips a repo with an empty prefix and no issues.jsonl" {
  repo gastown 'issue-prefix: '
  build_index
  run cat "$BEADS_POPOVER_INDEX"
  [ -z "$output" ]
}

@test "indexes every repo that shares a prefix" {
  repo focuster 'issue_prefix: fo-'
  repo focuster-qa '' '{"id":"fo-jkd6.12"}'
  build_index
  run awk -F'\t' '$1=="fo" {print $2}' "$BEADS_POPOVER_INDEX"
  [ "${#lines[@]}" -eq 2 ]
}
