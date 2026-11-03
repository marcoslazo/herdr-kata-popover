# Kata Popover

Ctrl-click a [kata](https://github.com/wesm/kata) issue ref in any Herdr pane and
get its details in a split below it, without leaving what you were doing.

The detail pane is recursive: linked issues (related, blocks, parent…) are
themselves clickable, and a `← back to …` link walks you back.

Forked from [hexsprite/herdr-beads](https://github.com/hexsprite/herdr-beads),
which does the same for beads.

## Install

```sh
herdr plugin install marcoslazo/herdr-kata-popover
# or, from a local checkout:
herdr plugin link /path/to/herdr-kata-popover
```

Requires `kata` (configured against your kata server), `jq` and `perl` on `PATH`.

## How it works

Herdr detects hyperlinks in pane output and routes Ctrl-clicks matching a
plugin's `pattern` to that plugin instead of the browser. This plugin claims
URLs under `kata.invalid`:

```
https://kata.invalid/<project>/<short_id>    e.g. https://kata.invalid/pirula-box/p2rg
https://kata.invalid/<short_id>              resolved via the clicked pane's .kata.toml
```

`.invalid` is reserved by [RFC 2606](https://www.rfc-editor.org/rfc/rfc2606), so
if the plugin is disabled the click fails closed instead of opening a stranger's
site. Herdr only routes http(s) links to plugins, so a custom `kata://` scheme
would render as inert text (the manifest claims it anyway, for the future).

kata is a central tracker, so a qualified ref (`project#id`) resolves from any
directory: `kata show 'pirula-box#p2rg'`. A bare id needs a `.kata.toml` in the
clicked pane's directory; otherwise the pane shows kata's
`no project bound to this workspace` error with the cwd.

## Making refs clickable

The plugin handles clicks; something still has to emit the links.

**Agent output**: agents have to write refs as markdown links, e.g.
`[pirula-box#p2rg](https://kata.invalid/pirula-box/p2rg)`. The plugin ships a
script that adds that instruction to your global agent files:

```sh
scripts/agent-instructions.sh install     # or: uninstall, status
scripts/agent-instructions.sh install path/to/repo/AGENTS.md   # explicit files
```

Without arguments it targets the files that already exist among
`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.config/opencode/AGENTS.md`,
`~/.pi/agent/AGENTS.md` and `~/.gemini/GEMINI.md`, and never creates one. The
text sits between `<!-- kata-popover:start/end -->` markers, so re-running it
refreshes the wording and `uninstall` removes exactly that block. The same is
available from Herdr as the plugin actions *Kata: add/remove link instruction*.
Installing the plugin does not run it on its own.

**`kata` CLI output**: `examples/demo-list.sh <project> [args]` pipes
`kata list --agent` through the same linkifier the pane uses.

Bare 4-character ids (`p2rg`) are never linkified in free text: they collide
with shas, hex and plain words. Only `project#id` and kata's `issue=id` are.

## The detail pane

A split (not a popup: Herdr does not route Ctrl-clicks from inside a plugin
popup, so links there would be dead). It shows the title, status, labels,
author, body, links and comments, re-wrapped to the pane width. `j`/`k` or the
arrows scroll, `/` searches, `q` closes. Clicking another ref replaces the
contents in place; state is kept per workspace.

## Tests

```sh
bats tests/
```

## License

MIT, as upstream.
