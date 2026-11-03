#!/usr/bin/env bats
# The link-handler action, run against a stub herdr that records what it was
# asked to open. Covers URL parsing and the state file the detail pane reads.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export TMPDIR="$BATS_TEST_TMPDIR"
  export HERDR_PLUGIN_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$HERDR_PLUGIN_ROOT"
  CALLS="$BATS_TEST_TMPDIR/calls"
  export CALLS
  stub="$BATS_TEST_TMPDIR/herdr"
  cat >"$stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$1 $2" in
  "pane list") printf '{"result":{"panes":[]}}\n' ;;
  "plugin pane") printf '{"result":{"plugin_pane":{"pane":{"pane_id":"p9"}}}}\n' ;;
esac
EOF
  chmod +x "$stub"
  export HERDR_BIN_PATH="$stub"
  export HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1","focused_pane_id":"p1","focused_pane_cwd":"/tmp"}'
  CURRENT="$BATS_TEST_TMPDIR/kata-popover/w1/current"
}

click() { HERDR_PLUGIN_CLICKED_URL="$1" bash "$ROOT/scripts/show-kata.sh"; }

@test "qualified URL selects project#id and opens a split" {
  run click "https://kata.invalid/pirula-box/p2rg"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CURRENT")" = "pirula-box#p2rg" ]
  grep -q -- "--entrypoint detail --placement split" "$CALLS"
  grep -q -- "--target-pane p1" "$CALLS"
  grep -q -- "KATA_REF=pirula-box#p2rg" "$CALLS"
}

@test "bare URL selects the id with the pane's cwd" {
  run click "https://kata.invalid/vjn8/"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CURRENT")" = "vjn8" ]
  [ "$(sed -n 2p "$CURRENT")" = "/tmp" ]
}

@test "kata:// scheme is accepted" {
  run click "kata://Driving-lessons-simulator/ab12"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CURRENT")" = "Driving-lessons-simulator#ab12" ]
}

@test "a malformed id opens the pane with an error" {
  run click "https://kata.invalid/pirula-box/NOPE!"
  [ "$status" -eq 0 ]
  [ -z "$(sed -n 1p "$CURRENT")" ]
  grep -q "Not a kata issue id" "$CURRENT"
}
