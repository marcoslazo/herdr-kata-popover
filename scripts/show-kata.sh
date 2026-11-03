#!/usr/bin/env bash
# Plugin action: work out which kata issue to show, and show it.
#
# Two ways in:
#   - a Ctrl-click on a kata link (Herdr sets HERDR_PLUGIN_CLICKED_URL);
#   - a keybinding (no clicked URL): scan the selected text, or else the focused
#     pane's recent output, for kata refs. One ref opens directly; several open
#     a numbered picker in the detail pane. This is the path for terminals that
#     never deliver a Ctrl-click to Herdr (macOS Terminal.app turns it into a
#     right-click).
#
# Failures here are invisible by default — a click that does nothing looks
# identical to a click that missed. So every error path opens the pane anyway
# with the message inside it.
set -uo pipefail

PLUGIN_ID="kata.popover"
PANE_LABEL="Kata"
ROOT="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_ROOT="${TMPDIR:-/tmp}/kata-popover"
HERDR="${HERDR_BIN_PATH:-herdr}"
SCAN_LINES="${KATA_POPOVER_SCAN_LINES:-300}"
MAX_PICK=9

ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"

# Herdr does not document the context payload and it has changed shape between
# versions, so always keep the last one on disk. Gitignored, one file, no growth.
[[ -n "$ctx" ]] && printf '%s\n' "$ctx" >"$ROOT/last-context.json" 2>/dev/null

have_jq() { command -v jq >/dev/null 2>&1; }
ctx_get() { [[ -n "$ctx" ]] && have_jq && jq -r "$1 // empty" <<<"$ctx" 2>/dev/null; }

# State is per workspace, so each workspace can keep its own visible detail pane
# with its own back trail.
workspace=$(ctx_get '.workspace_id')
STATE_DIR="$STATE_ROOT/${workspace:-default}"
PANE_FILE="$STATE_DIR/pane"
CURRENT="$STATE_DIR/current"
HISTORY="$STATE_DIR/history"
PICK="$STATE_DIR/pick"
mkdir -p "$STATE_DIR" 2>/dev/null

# Is the detail pane from a previous invocation still on screen? The recorded
# pane id can go missing while the pane is alive (a cleared TMPDIR is enough),
# so fall back to adopting one by label rather than opening a second pane.
live_pane() {
  have_jq || return 1

  local prev=""
  [[ -r "$PANE_FILE" ]] && prev=$(<"$PANE_FILE")
  if [[ -n "$prev" ]] && "$HERDR" pane list 2>/dev/null \
      | jq -e --arg p "$prev" '[.result.panes[]? | select(.pane_id==$p)] | length > 0' \
        >/dev/null 2>&1; then
    return 0
  fi

  local found
  found=$("$HERDR" pane list 2>/dev/null \
    | jq -r --arg w "$workspace" --arg l "$PANE_LABEL" \
        '[.result.panes[]? | select(.label==$l) | select($w=="" or .workspace_id==$w)][0]
         | (.pane_id // empty)' 2>/dev/null)
  [[ -n "$found" ]] || return 1
  printf '%s' "$found" >"$PANE_FILE" 2>/dev/null
  return 0
}

# Open the detail pane as a split below the invoking pane.
open_pane() {
  local ref="$1" cwd="$2"
  local args=(plugin pane open --plugin "$PLUGIN_ID" --entrypoint detail
              --placement split --direction down --focus)
  [[ -n "$cwd" && -d "$cwd" ]] && args+=(--cwd "$cwd")
  [[ -n "$ref" ]] && args+=(--env "KATA_REF=$ref" --env "KATA_CWD=$cwd")
  args+=(--env "KATA_STATE_DIR=$STATE_DIR")

  # Open against the invoking pane, or the split lands in whichever workspace
  # happens to hold UI focus.
  local target
  target=$(ctx_get '.focused_pane_id')
  [[ -n "$target" ]] && args+=(--target-pane "$target")

  local out pane
  out=$("$HERDR" "${args[@]}" 2>&1)

  # A stale target pane fails the whole open; better to land in the focused
  # workspace than to do nothing at all.
  if [[ -n "$target" ]] && grep -q 'pane_not_found' <<<"$out"; then
    local retry=()
    for a in "${args[@]}"; do
      [[ "$a" == "--target-pane" || "$a" == "$target" ]] && continue
      retry+=("$a")
    done
    out=$("$HERDR" "${retry[@]}" 2>&1)
  fi

  if have_jq; then
    pane=$(printf '%s' "$out" \
      | jq -r '.result.plugin_pane.pane.pane_id // empty' 2>/dev/null)
    [[ -n "$pane" ]] && printf '%s' "$pane" >"$PANE_FILE" 2>/dev/null
  fi
}

# Selecting an issue means writing it to the state file. A live detail pane polls
# that file and redraws itself, so selecting from inside the pane replaces its
# contents instead of opening another pane.
#
# State file: line 1 the ref (project#id or a bare id), line 2 the directory
# kata runs in (only matters for a bare id), anything after an error message.
select_issue() {
  local ref="$1" cwd="$2" err="${3:-}"

  # State outlives any single pane. Without this, the first selection after the
  # pane is gone offers "back" to whatever issue was last viewed hours ago.
  local fresh=0
  live_pane || fresh=1
  if (( fresh )); then
    : >"$HISTORY" 2>/dev/null
    : >"$CURRENT" 2>/dev/null
  fi
  rm -f "$PICK" 2>/dev/null

  # Keep a trail so the detail pane can offer a way back. Selecting the issue
  # already on top of the trail (the back link) pops instead of pushing.
  if [[ -n "$ref" ]] && (( ! fresh )); then
    local top prev_ref prev_cwd
    top=$(sed -n '1p' "$HISTORY" 2>/dev/null)
    if [[ "${top%%$'\t'*}" == "$ref" ]]; then
      sed -i.bak '1d' "$HISTORY" 2>/dev/null && rm -f "$HISTORY.bak"
    else
      prev_ref=$(sed -n '1p' "$CURRENT" 2>/dev/null)
      prev_cwd=$(sed -n '2p' "$CURRENT" 2>/dev/null)
      if [[ -n "$prev_ref" && "$prev_ref" != "$ref" ]]; then
        printf '%s\t%s\n%s' "$prev_ref" "$prev_cwd" "$(cat "$HISTORY" 2>/dev/null)" \
          >"$HISTORY.new" 2>/dev/null
        mv "$HISTORY.new" "$HISTORY" 2>/dev/null
      fi
    fi
  fi

  { printf '%s\n%s\n' "$ref" "$cwd"; [[ -n "$err" ]] && printf '%s\n' "$err"; } \
    >"$CURRENT" 2>/dev/null

  (( fresh )) && open_pane "$ref" "$cwd"
  exit 0
}

die() { select_issue "" "" "$1"; }

# The pane the action came from: a bare id resolves through its .kata.toml.
pane_cwd() {
  local c
  c=$(ctx_get '.focused_pane_cwd // .workspace_cwd // .pane.cwd // .focused_pane.cwd')
  [[ -n "$c" && "$c" != "null" ]] && { printf '%s' "$c"; return; }
  if have_jq; then
    c=$("$HERDR" pane list 2>/dev/null \
        | jq -r '[.result.panes[]? | select(.focused)][0]
                 | (.foreground_cwd // .cwd // empty)' 2>/dev/null)
    [[ -n "$c" && "$c" != "null" ]] && { printf '%s' "$c"; return; }
  fi
  printf ''
}

# Kata refs in text, most recent (last on screen) first, deduplicated:
# kata.invalid URLs (with or without project) and qualified project#id refs.
# Bare 4-char ids are never picked up in free text: shas and words collide.
extract_refs() {
  perl -CSD -ne '
    while (m{https?://kata\.invalid/(?:([A-Za-z0-9][A-Za-z0-9._-]*)/)?([a-z0-9]{4,12})(?![A-Za-z0-9])
           |(?<![\w/.#-])([A-Za-z0-9][A-Za-z0-9._-]*)\#([a-z0-9]{4,12})(?![\w-])}xg) {
      push @r, defined $2 ? (defined $1 ? "$1#$2" : $2) : "$3#$4";
    }
    END { my %s; print "$_\n" for grep { !$s{$_}++ } reverse @r }
  '
}

choose_from() {
  local text="$1" source="$2" cwd current="" refs=() r
  cwd="${KATA_POPOVER_CWD:-$(pane_cwd)}"

  # Invoked from inside the detail pane: offer its links, not the issue itself.
  if [[ -n "$(ctx_get '.focused_pane_id')" && -r "$PANE_FILE" \
        && "$(ctx_get '.focused_pane_id')" == "$(<"$PANE_FILE")" ]]; then
    current=$(sed -n '1p' "$CURRENT" 2>/dev/null)
  fi

  while IFS= read -r r; do
    [[ -n "$r" && "$r" != "$current" ]] && refs+=("$r")
  done < <(printf '%s\n' "$text" | extract_refs)

  case ${#refs[@]} in
    0) die "No kata refs found in the $source.

Refs are recognised as https://kata.invalid/<project>/<id> links or as
<project>#<id>; bare ids are ignored on purpose." ;;
    1) select_issue "${refs[0]}" "$cwd" ;;
  esac

  # Several: hand the detail pane a numbered list. A live pane notices the file
  # and switches to the picker; otherwise open one that starts in it.
  local i=0
  : >"$PICK.new"
  for r in "${refs[@]}"; do
    (( i++ < MAX_PICK )) || break
    printf '%s\t%s\n' "$r" "$cwd" >>"$PICK.new"
  done
  mv "$PICK.new" "$PICK"
  if ! live_pane; then
    : >"$HISTORY"; : >"$CURRENT"
    open_pane "" "$cwd"
  fi
  exit 0
}

# Herdr sets this directly for link handlers; the context JSON is a fallback.
url="${HERDR_PLUGIN_CLICKED_URL:-}"
[[ -n "$url" ]] || url=$(ctx_get '.clicked_url // .clickedUrl // .link.url')

if [[ -z "$url" ]]; then
  sel=$(ctx_get '.selected_text')
  [[ -n "$sel" ]] && choose_from "$sel" "selected text"
  pane=$(ctx_get '.focused_pane_id')
  [[ -n "$pane" ]] || die "No clicked URL and no focused pane to scan."
  text=$("$HERDR" pane read "$pane" --source recent-unwrapped --lines "$SCAN_LINES" 2>/dev/null)
  choose_from "$text" "last $SCAN_LINES lines of the focused pane"
fi

# Terminal URL detection may keep punctuation that follows a URL in prose,
# e.g. "(https://kata.invalid/p/abcd)," — the manifest pattern tolerates it.
url=$(printf '%s' "$url" | sed -E "s/[]).,;:!?'\">]+\$//")

# https://kata.invalid/sample-app/q7xm  ->  project=sample-app id=q7xm
# https://kata.invalid/q7xm             ->  project=""         id=q7xm
path="${url#*://}"
path="${path#kata.invalid/}"
path="${path%/}"
short_id="${path##*/}"
project=""
[[ "$path" == */* ]] && project="${path%/*}"

[[ "$short_id" =~ ^[a-z0-9]{4,12}$ ]] || die "Not a kata issue id: $short_id"
[[ -z "$project" || "$project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "Not a kata project name: $project"

if [[ -n "$project" ]]; then
  # A qualified ref resolves from anywhere: kata is a single central tracker.
  select_issue "$project#$short_id" "$(pane_cwd)"
else
  select_issue "$short_id" "${KATA_POPOVER_CWD:-$(pane_cwd)}"
fi
