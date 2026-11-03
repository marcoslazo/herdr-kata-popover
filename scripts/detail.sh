#!/usr/bin/env bash
# Detail pane body: render one kata issue (title, status, body, comments, links),
# with every linked issue wrapped as an OSC 8 hyperlink so the pane is recursive —
# Ctrl-click a related or blocking issue to jump straight to it.
#
# The pane is long-lived. It watches a state file and re-renders in place when a
# new issue is selected, so clicking a link inside this pane replaces its own
# contents instead of spawning another pane.
set -uo pipefail

# Set by the link handler so each workspace's pane watches its own state.
STATE_DIR="${KATA_STATE_DIR:-${TMPDIR:-/tmp}/kata-popover/default}"
CURRENT="$STATE_DIR/current"
HISTORY="$STATE_DIR/history"
mkdir -p "$STATE_DIR" 2>/dev/null

# linkify/wrapansi live in a sourced file so the tests can call them without
# starting the pager loop below.
source "$(dirname "${BASH_SOURCE[0]}")/lib/render.sh"

# Ask the tty directly. tput honours an inherited LINES/COLUMNS, which in a
# plugin pane are the parent shell's dimensions, not this pane's.
term_cols() { local s; s=$(stty size 2>/dev/null) && printf '%s' "${s##* }" || printf 80; }
hr() { printf '\033[2m%*s\033[0m\n' "$(term_cols)" '' | tr ' ' '─'; }

# project#id -> project/id ; bare id -> id
ref_path() { local r="$1"; [[ "$r" == *#* ]] && printf '%s/%s' "${r%%#*}" "${r##*#}" || printf '%s' "$r"; }

# The previous issue, rendered as one link at the top of the content. Clicking it
# is just another issue click, so back navigation needs no keybindings.
back_line() {
  local prev ref
  prev=$(sed -n '1p' "$HISTORY" 2>/dev/null)
  [[ -n "$prev" ]] || return
  ref="${prev%%$'\t'*}"
  printf '\033]8;;https://kata.invalid/%s\033\\\033[4;38;5;75m← back to %s\033[24;39m\033]8;;\033\\\n\n' \
    "$(ref_path "$ref")" "$ref"
}

# kata show --json -> ANSI text. Links render as qualified refs (project#id) so
# linkify can turn them into click targets regardless of the current project.
format_issue() {
  jq -r '
    def dim: "\u001b[2m" + . + "\u001b[0m";
    def bold: "\u001b[1m" + . + "\u001b[0m";
    def status_c: if . == "open" then "\u001b[32m" + . + "\u001b[0m"
                  elif . == "closed" then "\u001b[2m" + . + "\u001b[0m"
                  else "\u001b[33m" + . + "\u001b[0m" end;
    .issue as $i
    | ([.labels[]?.label] | join(", ")) as $labels
    | (([.links[]? | (.from, .to) | select(.short_id == $i.short_id) | .qualified_id] | first)
        // $i.short_id) as $ref
    | (($ref | bold) + "  " + ($i.title | bold)),
      ([ ($i.status | status_c),
         (if $labels != "" then "labels: " + $labels else empty end),
         (if ($i.owner // "") != "" then "owner: " + $i.owner else empty end),
         ("by " + ($i.author // "?") + " · " + (($i.created_at // "")[0:10]))
       ] | join("  ·  ")),
      "",
      (($i.body // "") | if . == "" then ("(no description)" | dim) else . end),
      (if ((.links // []) | length) > 0 then
         "", ("Links" | bold),
         (.links[] |
           if .from.short_id == $i.short_id
           then "  " + .type + " → " + .to.qualified_id + "  " + (.to.status | dim)
           else "  " + .type + " ← " + .from.qualified_id + "  " + (.from.status | dim) end)
       else empty end),
      (if ((.comments // []) | length) > 0 then
         "", ("Comments" | bold),
         (.comments[] |
           "", (("— " + (.author // "?") + " · " + ((.created_at // "")[0:16] | sub("T"; " "))) | dim),
           .body)
       else empty end)
  '
}

# The project of the issue on screen, so linkify can qualify bare issue= refs.
project_of() {
  local ref="$1" json="$2"
  [[ "$ref" == *#* ]] && { printf '%s' "${ref%%#*}"; return; }
  jq -r --arg id "$ref" \
    '[.links[]? | (.from, .to) | select(.short_id == $id) | .project] | first // empty' \
    <<<"$json" 2>/dev/null
}

render() {
  local ref="$1" cwd="$2" err="$3" json

  if [[ -n "$err" ]]; then
    printf '\033[1;31mKata popover\033[0m\n\n%s\n' "$err"
    return
  fi
  if [[ -z "$ref" ]]; then
    printf '\033[1;31mNo issue selected\033[0m\n'; return
  fi
  if ! command -v kata >/dev/null 2>&1; then
    printf '\033[1;31mkata not found on PATH\033[0m\n'; return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    printf '\033[1;31mjq not found on PATH\033[0m\n'; return
  fi

  # A bare id needs the cwd's .kata.toml; kata says "no project bound to this
  # workspace" otherwise — the most likely failure, so show the cwd with it.
  if ! json=$(cd "${cwd:-$PWD}" 2>/dev/null && kata show "$ref" --json 2>&1) \
     || ! jq -e '.issue' >/dev/null 2>&1 <<<"$json"; then
    local msg
    msg=$(jq -r '.error.message // empty' <<<"$json" 2>/dev/null)
    printf '\033[1;31mCould not read %s\033[0m\n\n%s\n' "$ref" "${msg:-$json}"
    printf '\n\033[2mcwd: %s\033[0m\n' "${cwd:-$PWD}"
    return
  fi

  back_line
  format_issue <<<"$json" | KATA_PROJECT="$(project_of "$ref" "$json")" linkify
}

# Page with less: it handles scrolling, search and resize, and on the alternate
# screen Herdr translates the mouse wheel into scrolling for it.
#
# -L is load-bearing. A LESSOPEN preprocessor (commonly "| bat ... %s") rewrites
# every OSC 8 hyperlink into a form Herdr will not bind back to a URL — so every
# ref in the pane silently stops responding to Ctrl-click.
TMP="$STATE_DIR/render.$$"
trap 'rm -f "$TMP"' EXIT

# Seed from the environment on first launch so the pane has content before the
# state file is consulted.
if [[ ! -s "$CURRENT" && -n "${KATA_REF:-}" ]]; then
  printf '%s\n%s\n' "$KATA_REF" "${KATA_CWD:-$PWD}" >"$CURRENT"
fi

while :; do
  snapshot=$(cat "$CURRENT" 2>/dev/null)
  ref=$(sed -n '1p' "$CURRENT" 2>/dev/null)
  cwd=$(sed -n '2p' "$CURRENT" 2>/dev/null)
  err=$(sed -n '3,$p' "$CURRENT" 2>/dev/null)

  render "$ref" "$cwd" "$err" | wrapansi "$(term_cols)" >"$TMP"

  prompt="${ref:-kata} · ctrl-click a ref to follow · j/k scroll · / search · q close"

  # Watch for a new selection while the pager is up, and retire the pager when
  # one arrives so the same pane redraws with the new issue.
  ( while :; do
      sleep 0.2
      [[ "$(cat "$CURRENT" 2>/dev/null)" != "$snapshot" ]] || continue
      pkill -P $$ -x less 2>/dev/null
      break
    done ) &
  watcher=$!

  LESSOPEN= less -R -L -Ps"$prompt" "$TMP"

  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null

  # less exited on its own (the user quit) rather than being replaced.
  [[ "$(cat "$CURRENT" 2>/dev/null)" == "$snapshot" ]] && exit 0
done
