#!/usr/bin/env bash
# Install, update or remove the instruction that makes agents write kata refs as
# clickable links, in the global instruction files of the agents on this machine.
#
#   agent-instructions.sh install   [file...]   add or refresh the block
#   agent-instructions.sh uninstall [file...]   remove the block
#   agent-instructions.sh status    [file...]   show where it is installed
#
# Without files, it targets the known global files that already exist; it never
# creates an agent's config. The block sits between markers, so install is
# idempotent and refreshes old wording, and uninstall removes exactly it.
set -uo pipefail

START="<!-- kata-popover:start -->"
END="<!-- kata-popover:end -->"

block() {
  cat <<EOF
$START
## kata issue links

When mentioning a kata issue, always write it as a markdown link to
\`https://kata.invalid/<project>/<short_id>\` with the qualified ref as text, e.g.
[pirula-box#p2rg](https://kata.invalid/pirula-box/p2rg) — never as bare text.
Herdr's Kata Popover plugin opens the issue on Ctrl-click. Use the project name
from \`.kata.toml\` or \`kata\` output; if unknown, link \`https://kata.invalid/<short_id>\`.
$END
EOF
}

default_targets() {
  local f
  for f in \
    "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/CLAUDE.md" \
    "${CODEX_HOME:-$HOME/.codex}/AGENTS.md" \
    "$HOME/.config/opencode/AGENTS.md" \
    "$HOME/.pi/agent/AGENTS.md" \
    "$HOME/.gemini/GEMINI.md"; do
    [[ -f "$f" ]] && printf '%s\n' "$f"
  done
}

# Print the file without the block (and without the blank line before it).
strip() {
  START="$START" END="$END" perl -0pe '
    s/\n*\Q$ENV{START}\E.*?\Q$ENV{END}\E\n?/\n/s; s/\n+\z/\n/' "$1"
}

install_one() {
  local f="$1" tmp
  [[ -f "$f" ]] || { echo "skip  $f (missing)"; return; }
  tmp=$(mktemp) || return 1
  { strip "$f"; printf '\n'; block; } >"$tmp"
  if cmp -s "$tmp" "$f"; then echo "ok    $f (up to date)"; rm -f "$tmp"; return; fi
  cat "$tmp" >"$f" && rm -f "$tmp"   # cat keeps the file's inode, mode and symlinks
  echo "added $f"
}

uninstall_one() {
  local f="$1" tmp
  [[ -f "$f" ]] && grep -qF "$START" "$f" || { echo "none  $f"; return; }
  tmp=$(mktemp) || return 1
  strip "$f" >"$tmp" && cat "$tmp" >"$f" && rm -f "$tmp"
  echo "removed $f"
}

status_one() {
  if [[ -f "$1" ]] && grep -qF "$START" "$1"; then echo "installed  $1"
  else echo "absent     $1"; fi
}

cmd="${1:-}"; shift || true
case "$cmd" in
  install|uninstall|status) ;;
  *) echo "usage: $0 install|uninstall|status [file...]" >&2; exit 2 ;;
esac

targets=("$@")
if (( ${#targets[@]} == 0 )); then
  while IFS= read -r f; do targets+=("$f"); done < <(default_targets)
fi
(( ${#targets[@]} )) || { echo "no agent instruction files found; pass paths explicitly" >&2; exit 1; }

for f in "${targets[@]}"; do "${cmd}_one" "$f"; done
