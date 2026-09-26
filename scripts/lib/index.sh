#!/usr/bin/env bash
# Prefix index for show-bead.sh: maps a bead prefix to the repos that hold it,
# one "<prefix>\t<repo>" line each. Split out so tests/index.bats can build an
# index over fixture repos. Sourcing this file must not do anything observable.

ROOTS="${BEADS_POPOVER_ROOTS:-$HOME/co:$HOME/src:$HOME/code:$HOME/projects}"
INDEX="${BEADS_POPOVER_INDEX:-${TMPDIR:-/tmp}/beads-popover-index.tsv}"

# Print a repo's bead prefix, or nothing.
#
# .beads/config.yaml comes first because it is authoritative and every repo has
# one. issues.jsonl is only a fallback: a repo in Dolt server mode has no
# issues.jsonl at all, so reading it alone left those repos unindexed and their
# beads unresolvable. Never shell out to bd here. It costs ~0.5s per repo, and
# in a repo without a running Dolt server it can start one.
repo_prefix() {
  local beads="$1/.beads" p="" id
  if [[ -r "$beads/config.yaml" ]]; then
    p=$(sed -n -E 's/^issue[-_]prefix:[[:space:]]*"?([^"#[:space:]]*)"?.*$/\1/p' \
      "$beads/config.yaml" 2>/dev/null | grep -v '^$' | head -1)
  fi
  if [[ -z "$p" && -r "$beads/issues.jsonl" ]]; then
    id=$(head -1 "$beads/issues.jsonl" 2>/dev/null |
      sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    p="${id%%-*}"
  fi
  # config.yaml may spell the prefix with its separator: "fo-".
  printf '%s' "${p%-}"
}

build_index() {
  local root beads repo prefix roots
  : >"$INDEX"
  IFS=':' read -ra roots <<<"$ROOTS"
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    for beads in "$root"/*/.beads; do
      [[ -d "$beads" ]] || continue
      repo=$(dirname "$beads")
      prefix=$(repo_prefix "$repo")
      [[ -n "$prefix" ]] && printf '%s\t%s\n' "$prefix" "$repo" >>"$INDEX"
    done
  done
  return 0
}
