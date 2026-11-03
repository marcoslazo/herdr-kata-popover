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
# Closing the pane hangs us up; without this the EXIT trap never runs.
trap 'exit 0' HUP TERM INT

# Seed from the environment on first launch so the pane has content before the
# state file is consulted.
if [[ ! -s "$CURRENT" && -n "${KATA_REF:-}" ]]; then
  printf '%s\n%s\n' "$KATA_REF" "${KATA_CWD:-$PWD}" >"$CURRENT"
fi

PICK="$STATE_DIR/pick"
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state() { cat "$CURRENT" "$PICK" 2>/dev/null; }

# Select a ref through the action script, so the back trail is kept exactly as
# a click would keep it.
choose() {
  local ref="$1" cwd="$2" ws
  ws=$(basename "$STATE_DIR")
  [[ "$ws" == default ]] && ws=""
  HERDR_PLUGIN_CLICKED_URL="https://kata.invalid/$(ref_path "$ref")" \
  HERDR_PLUGIN_CONTEXT_JSON="{\"workspace_id\":\"$ws\",\"focused_pane_cwd\":\"$cwd\"}" \
  KATA_POPOVER_CWD="$cwd" \
    bash "$SELF_DIR/show-kata.sh" >/dev/null 2>&1
}

# Numbered list of the refs the action found; a digit opens one, Enter the
# first (most recent), q or Esc cancels back to the issue on screen, if any.
picker() {
  local refs=() cwds=() ref cwd title i key snap
  while IFS=$'\t' read -r ref cwd; do
    [[ -n "$ref" ]] && { refs+=("$ref"); cwds+=("$cwd"); }
  done <"$PICK"
  snap=$(state)

  printf '\033[2J\033[H\033[1mKata refs on screen\033[0m  \033[2m(most recent first)\033[0m\n\n'
  for (( i = 0; i < ${#refs[@]}; i++ )); do
    title=$(cd "${cwds[$i]:-$PWD}" 2>/dev/null \
      && kata show "${refs[$i]}" --json 2>/dev/null | jq -r '.issue.title // empty' 2>/dev/null)
    printf '  \033[1;36m%d\033[0m  %s  %s\n' $(( i + 1 )) "${refs[$i]}" \
      "${title:-$'\033[2m(not found)\033[0m'}"
  done
  printf '\n\033[2m1-%d open · enter first · q cancel\033[0m\n' "${#refs[@]}"

  while :; do
    # Another selection arrived while waiting: let the main loop redraw.
    [[ "$(state)" == "$snap" ]] || return
    IFS= read -rsn1 -t 1 key || continue
    case "$key" in
      [1-9])
        (( key <= ${#refs[@]} )) || continue
        choose "${refs[$((key - 1))]}" "${cwds[$((key - 1))]}"; return ;;
      "")
        choose "${refs[0]}" "${cwds[0]}"; return ;;
      q|Q|$'\e')
        rm -f "$PICK"
        [[ -n "$(sed -n '1p;3p' "$CURRENT" 2>/dev/null | tr -d '[:space:]')" ]] || exit 0
        return ;;
    esac
  done
}

while :; do
  if [[ -s "$PICK" ]]; then picker; continue; fi
  snapshot=$(state)
  ref=$(sed -n '1p' "$CURRENT" 2>/dev/null)
  cwd=$(sed -n '2p' "$CURRENT" 2>/dev/null)
  err=$(sed -n '3,$p' "$CURRENT" 2>/dev/null)

  render "$ref" "$cwd" "$err" | wrapansi "$(term_cols)" >"$TMP"

  prompt="${ref:-kata} · ctrl-click or ${KATA_POPOVER_KEY:-prefix+i} to follow a ref · j/k scroll · / search · q close"

  # Watch for a new selection while the pager is up, and retire the pager when
  # one arrives so the same pane redraws with the new issue.
  ( while :; do
      sleep 0.2
      [[ "$(state)" != "$snapshot" ]] || continue
      pkill -P $$ -x less 2>/dev/null
      break
    done ) &
  watcher=$!

  LESSOPEN= less -R -L -Ps"$prompt" "$TMP"

  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null

  # less exited on its own (the user quit) rather than being replaced.
  [[ "$(state)" == "$snapshot" ]] && exit 0
done
