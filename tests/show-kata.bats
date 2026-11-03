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
  "pane read") cat "$PANE_TEXT" ;;
esac
EOF
  chmod +x "$stub"
  export HERDR_BIN_PATH="$stub"
  export HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1","focused_pane_id":"p1","focused_pane_cwd":"/tmp"}'
  CURRENT="$BATS_TEST_TMPDIR/kata-popover/w1/current"
  PICKF="$BATS_TEST_TMPDIR/kata-popover/w1/pick"
  export PANE_TEXT="$BATS_TEST_TMPDIR/pane.txt"
  : >"$PANE_TEXT"
}

key() { bash "$ROOT/scripts/show-kata.sh"; }

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
  run click "kata://Sample-Project/ab12"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CURRENT")" = "Sample-Project#ab12" ]
}

@test "a malformed id opens the pane with an error" {
  run click "https://kata.invalid/pirula-box/NOPE!"
  [ "$status" -eq 0 ]
  [ -z "$(sed -n 1p "$CURRENT")" ]
  grep -q "Not a kata issue id" "$CURRENT"
}

@test "a URL followed by prose punctuation still resolves" {
  run click "https://kata.invalid/demo-app/abcd),"
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CURRENT")" = "demo-app#abcd" ]
}

@test "keyboard: several refs on screen open a picker, most recent first" {
  cat >"$PANE_TEXT" <<'TXT'
- demo-app#abcd (https://kata.invalid/demo-app/abcd) en feature/abcd-login
- demo-app#efgh (https://kata.invalid/demo-app/efgh) en feature/efgh-queue
demo-app#ijkl (https://kata.invalid/demo-app/ijkl) queda en espera
hasta que termine efgh, siguiendo mnop, commit ca3c89d
TXT
  run key
  [ "$status" -eq 0 ]
  [ "$(cut -f1 "$PICKF" | paste -sd, -)" = "demo-app#ijkl,demo-app#efgh,demo-app#abcd" ]
  grep -q -- "--entrypoint detail" "$CALLS"
  grep -q -- "pane read p1 --source recent-unwrapped" "$CALLS"
}

@test "keyboard: a single ref opens directly" {
  printf 'see [x](https://kata.invalid/pirula-box/p2rg) and pirula-box#p2rg\n' >"$PANE_TEXT"
  run key
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CURRENT")" = "pirula-box#p2rg" ]
  [ ! -e "$PICKF" ]
}

@test "keyboard: selected text wins over the pane" {
  printf 'a#aaaa b#bbbb\n' >"$PANE_TEXT"
  HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1","focused_pane_id":"p1","selected_text":"pirula-box#vjn8"}' run key
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CURRENT")" = "pirula-box#vjn8" ]
}

@test "keyboard: no refs shows an explanation" {
  printf 'only a bare p2rg and a sha ca3c89d\n' >"$PANE_TEXT"
  run key
  [ "$status" -eq 0 ]
  grep -q "No kata refs found" "$CURRENT"
}
