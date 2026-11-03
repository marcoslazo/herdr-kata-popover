#!/usr/bin/env bash
# Link-handler action: work out which kata issue was clicked and show it.
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

ctx="${HERDR_PLUGIN_CONTEXT_JSON:-}"

# Herdr does not document the context payload and it has changed shape between
# versions, so always keep the last one on disk. Gitignored, one file, no growth.
[[ -n "$ctx" ]] && printf '%s\n' "$ctx" >"$ROOT/last-context.json" 2>/dev/null

have_jq() { command -v jq >/dev/null 2>&1; }

# State is per workspace, so each workspace can keep its own visible detail pane
# with its own back trail.
workspace=""
if [[ -n "$ctx" ]] && have_jq; then
  workspace=$(jq -r '.workspace_id // empty' <<<"$ctx" 2>/dev/null)
fi
STATE_DIR="$STATE_ROOT/${workspace:-default}"
PANE_FILE="$STATE_DIR/pane"
CURRENT="$STATE_DIR/current"
HISTORY="$STATE_DIR/history"
mkdir -p "$STATE_DIR" 2>/dev/null

# Is the detail pane from a previous click still on screen? The recorded pane id
# can go missing while the pane is alive (a cleared TMPDIR is enough), so fall
# back to adopting one by label rather than opening a second pane.
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

# Selecting an issue means writing it to the state file. A live detail pane polls
# that file and redraws itself, so clicking a link inside the pane replaces its
# contents instead of opening another pane.
#
# State file: line 1 the ref (project#id or a bare id), line 2 the directory
# kata runs in (only matters for a bare id), anything after an error message.
select_issue() {
  local ref="$1" cwd="$2" err="${3:-}"

  # State outlives any single pane. Without this, the first click after the pane
  # is gone offers "back" to whatever issue was last viewed hours ago.
  local fresh=0
  live_pane || fresh=1
  if (( fresh )); then
    : >"$HISTORY" 2>/dev/null
    : >"$CURRENT" 2>/dev/null
  fi

  # Keep a trail so the detail pane can offer a way back. Clicking the back link
  # selects the issue already on top of the trail, so that case pops.
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

  (( ! fresh )) && exit 0

  local args=(plugin pane open --plugin "$PLUGIN_ID" --entrypoint detail
              --placement split --direction down --focus)
  [[ -n "$cwd" && -d "$cwd" ]] && args+=(--cwd "$cwd")
  [[ -n "$ref" ]] && args+=(--env "KATA_REF=$ref" --env "KATA_CWD=$cwd")
  args+=(--env "KATA_STATE_DIR=$STATE_DIR")

  # Open against the clicking pane, or the split lands in whichever workspace
  # happens to hold UI focus.
  local target=""
  if [[ -n "$ctx" ]] && have_jq; then
    target=$(jq -r '.focused_pane_id // empty' <<<"$ctx" 2>/dev/null)
    [[ -n "$target" ]] && args+=(--target-pane "$target")
  fi

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
  exit 0
}

die() { select_issue "" "" "$1"; }

# Herdr sets this directly for link handlers; the context JSON is a fallback.
url="${HERDR_PLUGIN_CLICKED_URL:-}"
if [[ -z "$url" && -n "$ctx" ]] && have_jq; then
  url=$(jq -r '.clicked_url // .clickedUrl // .link.url // empty' <<<"$ctx")
fi
[[ -n "$url" ]] || die "No clicked URL. Invoke this by Ctrl-clicking a kata link."

# https://kata.invalid/pirula-box/p2rg  ->  project=pirula-box id=p2rg
# https://kata.invalid/p2rg             ->  project=""         id=p2rg
path="${url#*://}"
path="${path#kata.invalid/}"
path="${path%/}"
short_id="${path##*/}"
project=""
[[ "$path" == */* ]] && project="${path%/*}"

[[ "$short_id" =~ ^[a-z0-9]{4,12}$ ]] || die "Not a kata issue id: $short_id"
[[ -z "$project" || "$project" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || die "Not a kata project name: $project"

# The pane the click came from: a bare id resolves through its .kata.toml.
pane_cwd() {
  local c=""
  if [[ -n "$ctx" ]] && have_jq; then
    c=$(jq -r '.focused_pane_cwd // .workspace_cwd
               // .pane.cwd // .focused_pane.cwd // empty' <<<"$ctx" 2>/dev/null)
    [[ -n "$c" && "$c" != "null" ]] && { printf '%s' "$c"; return; }
  fi
  if have_jq; then
    c=$("$HERDR" pane list 2>/dev/null \
        | jq -r '[.result.panes[]? | select(.focused)][0]
                 | (.foreground_cwd // .cwd // empty)' 2>/dev/null)
    [[ -n "$c" && "$c" != "null" ]] && { printf '%s' "$c"; return; }
  fi
  printf ''
}

if [[ -n "$project" ]]; then
  # A qualified ref resolves from anywhere: kata is a single central tracker.
  select_issue "$project#$short_id" "$(pane_cwd)"
else
  select_issue "$short_id" "${KATA_POPOVER_CWD:-$(pane_cwd)}"
fi
