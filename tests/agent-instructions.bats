#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  S="$ROOT/scripts/agent-instructions.sh"
  F="$BATS_TEST_TMPDIR/CLAUDE.md"
  printf '# Mine\n\nkeep this\n' >"$F"
}

@test "install appends the block once, idempotently" {
  run bash "$S" install "$F"
  [ "$status" -eq 0 ]
  [[ "$output" == added* ]]
  run bash "$S" install "$F"
  [[ "$output" == *"up to date"* ]]
  [ "$(grep -c 'kata-popover:start' "$F")" -eq 1 ]
  grep -q 'https://kata.invalid/pirula-box/p2rg' "$F"
  head -3 "$F" | grep -q 'keep this'
}

@test "install refreshes an outdated block in place" {
  printf '\n<!-- kata-popover:start -->\nold wording\n<!-- kata-popover:end -->\n\n## After\n' >>"$F"
  run bash "$S" install "$F"
  [ "$status" -eq 0 ]
  ! grep -q 'old wording' "$F"
  grep -q '## After' "$F"
  [ "$(grep -c 'kata-popover:start' "$F")" -eq 1 ]
}

@test "uninstall restores the original file" {
  cp "$F" "$F.orig"
  bash "$S" install "$F"
  run bash "$S" uninstall "$F"
  [ "$status" -eq 0 ]
  cmp "$F" "$F.orig"
}

@test "a missing file is skipped, never created" {
  run bash "$S" install "$BATS_TEST_TMPDIR/nope.md"
  [ "$status" -eq 0 ]
  [[ "$output" == skip* ]]
  [ ! -e "$BATS_TEST_TMPDIR/nope.md" ]
}

@test "without paths it only targets existing known files" {
  mkdir -p "$BATS_TEST_TMPDIR/home/.claude"
  printf 'x\n' >"$BATS_TEST_TMPDIR/home/.claude/CLAUDE.md"
  HOME="$BATS_TEST_TMPDIR/home" CLAUDE_CONFIG_DIR= CODEX_HOME= run bash "$S" status
  [ "$status" -eq 0 ]
  [ "$output" = "absent     $BATS_TEST_TMPDIR/home/.claude/CLAUDE.md" ]
}
