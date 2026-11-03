#!/usr/bin/env bash
# Print `kata list` with every issue id wrapped as an OSC 8 hyperlink, so the ids
# are Ctrl-clickable in Herdr.
#
# Usage: examples/demo-list.sh <project> [kata list args...]
#   e.g. examples/demo-list.sh sample-app --status open
set -uo pipefail

[[ $# -ge 1 ]] || { echo "usage: $0 <project> [kata list args...]" >&2; exit 2; }
project="$1"; shift

source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/render.sh"
kata list --project "$project" --agent "$@" 2>&1 | KATA_PROJECT="$project" linkify
