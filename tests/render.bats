#!/usr/bin/env bats
# Covers the two perl programs in scripts/lib/render.sh. Both manipulate escape
# sequences, and a regression is invisible in the pane — a ref just quietly
# stops responding to Ctrl-click, or a line wraps at the wrong column.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  unset KATA_PROJECT
  # Sourcing must be side-effect free, and detail.sh runs under these options.
  set -uo pipefail
  source "$ROOT/scripts/lib/render.sh"
  ESC=$'\033'
  OSC_END=$'\033\\'
}

# ESC is invisible and bats compares bytes, so failures are unreadable without
# this. Every assertion below is written against visualised output.
vis() { perl -pe 's/\e/<ESC>/g'; }

lk()  { printf '%s\n' "$1" | linkify | vis; }
wr()  { printf '%s\n' "$2" | wrapansi "$1"; }
wrv() { printf '%s\n' "$2" | wrapansi "$1" | vis; }

# What linkify should emit: link <url-path> <visible text>
link() {
  printf '<ESC>]8;;https://kata.invalid/%s<ESC>\\<ESC>[4m%s<ESC>[24m<ESC>]8;;<ESC>\\' \
    "$1" "$2"
}

# --- linkify ---------------------------------------------------------------

@test "linkify: wraps a qualified ref" {
  run lk "see pirula-box#p2rg today"
  [ "$status" -eq 0 ]
  [ "$output" = "see $(link pirula-box/p2rg pirula-box#p2rg) today" ]
}

@test "linkify: keeps capitals and dots in the project name" {
  run lk "Driving-lessons-simulator#ab12 and web.v2#zz99"
  [ "$status" -eq 0 ]
  [ "$output" = "$(link Driving-lessons-simulator/ab12 Driving-lessons-simulator#ab12) and $(link web.v2/zz99 web.v2#zz99)" ]
}

@test "linkify: matches a ref that starts immediately after an SGR" {
  run lk "${ESC}[36mpirula-box#p2rg${ESC}[0m"
  [ "$status" -eq 0 ]
  [ "$output" = "<ESC>[36m$(link pirula-box/p2rg pirula-box#p2rg)<ESC>[0m" ]
}

@test "linkify: keeps surrounding colour intact" {
  run lk "${ESC}[33mstatus pirula-box#p2rg open${ESC}[0m"
  [ "$status" -eq 0 ]
  [ "$output" = "<ESC>[33mstatus $(link pirula-box/p2rg pirula-box#p2rg) open<ESC>[0m" ]
}

@test "linkify: issue= is qualified with KATA_PROJECT" {
  export KATA_PROJECT=pirula-box
  run lk "- type=related issue=vjn8"
  [ "$status" -eq 0 ]
  [ "$output" = "- type=related issue=$(link pirula-box/vjn8 vjn8)" ]
}

@test "linkify: issue= without a project links the bare id" {
  run lk "issue=vjn8"
  [ "$status" -eq 0 ]
  [ "$output" = "issue=$(link vjn8 vjn8)" ]
}

@test "linkify: leaves bare ids, words and shas alone" {
  run lk "p2rg done in commit ca3c89d, see #main"
  [ "$status" -eq 0 ]
  [ "$output" = "p2rg done in commit ca3c89d, see #main" ]
}

@test "linkify: leaves a URL fragment alone" {
  run lk "https://example.com/page#section"
  [ "$status" -eq 0 ]
  [ "$output" = "https://example.com/page#section" ]
}

@test "linkify: leaves an existing OSC 8 target untouched" {
  run lk "${ESC}]8;;https://kata.invalid/pirula-box/p2rg${OSC_END}pirula-box#p2rg${ESC}]8;;${OSC_END}"
  [ "$status" -eq 0 ]
  [[ "$output" == "<ESC>]8;;https://kata.invalid/pirula-box/p2rg<ESC>\\"* ]]
  [[ "$output" == *"<ESC>]8;;<ESC>\\" ]]
}

@test "linkify: runs under bash 3.2 with set -u" {
  # macOS still ships 3.2 as /bin/bash; the pane must not die there.
  [ -x /bin/bash ] || skip "no /bin/bash"
  run /bin/bash -c \
    "set -uo pipefail; source '$ROOT/scripts/lib/render.sh'; printf 'x#abcd\n' | linkify"
  [ "$status" -eq 0 ]
  [[ "$output" == *"https://kata.invalid/x/abcd"* ]]
}

# --- wrapansi --------------------------------------------------------------

@test "wrapansi: breaks on a space at the width" {
  run wr 20 "aaaa bbbb cccc dddd eeee"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "aaaa bbbb cccc dddd" ]
  [ "${lines[1]}" = "eeee" ]
}

@test "wrapansi: a line exactly at the width does not wrap" {
  run wr 20 "aaaa bbbb cccc dddd"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "wrapansi: escape sequences do not count toward the width" {
  run wrv 20 "${ESC}[31maaaa${ESC}[0m ${ESC}[32mbbbb${ESC}[0m cccc dddd"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "<ESC>[31maaaa<ESC>[0m <ESC>[32mbbbb<ESC>[0m cccc dddd" ]
}

@test "wrapansi: never splits a ref" {
  run wr 20 "blocked by pirula-box#p2rg and more"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pirula-box#p2rg"* ]]
}

@test "wrapansi: an OSC 8 link survives unbroken" {
  local id="${ESC}]8;;https://kata.invalid/x/p2rg${OSC_END}x#p2rg${ESC}]8;;${OSC_END}"
  run wrv 20 "aaaa bbbb cccc $id dddd"
  [ "$status" -eq 0 ]
  [[ "$output" == *"<ESC>]8;;https://kata.invalid/x/p2rg<ESC>\\x#p2rg<ESC>]8;;<ESC>\\"* ]]
}

@test "wrapansi: continuation lines keep the original indent" {
  run wr 20 "    aaa bbb ccc ddd eee fff"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -gt 1 ]
  [ "${lines[1]:0:4}" = "    " ]
}

@test "wrapansi: floors the width at 20" {
  run wr 5 "aaaa bbbb cccc dddd"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "wrapansi: leaves multibyte text intact" {
  run wr 40 "← back to pirula-box#p2rg"
  [ "$status" -eq 0 ]
  [ "$output" = "← back to pirula-box#p2rg" ]
}
