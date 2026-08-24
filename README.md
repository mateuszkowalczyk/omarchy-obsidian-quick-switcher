# Obsidian Quick Switcher for Omarchy

A native Omarchy search overlay for opening any Obsidian vault file by name,
path, alias, or bookmark name. Recent Obsidian files appear while the vault
index loads asynchronously from the Obsidian CLI, then the list is
fuzzy-filtered with headless fzf on every keystroke.

## Requirements

- Omarchy 4 or newer with `omarchy-shell`
- Obsidian with its CLI enabled
- `fzf`

Verify the external tools before installing:

```bash
obsidian files | head
obsidian aliases verbose | head
obsidian bookmarks verbose | head
fzf --version
```

## Install

Once this repository is published, install and enable it with:

```bash
omarchy plugin add https://github.com/mateuszkowalczyk/omarchy-obsidian-quick-switcher --enable
```

For a local checkout, sync it to the user plugin directory, validate it, and
enable it:

```bash
mkdir -p ~/.config/omarchy/plugins/mk.obsidian-quick-switcher
rsync -a --exclude .git \
  ./ ~/.config/omarchy/plugins/mk.obsidian-quick-switcher/
omarchy plugin validate ~/.config/omarchy/plugins/mk.obsidian-quick-switcher
omarchy-shell shell rescanPlugins
omarchy plugin enable mk.obsidian-quick-switcher
```

Add this to `~/.config/hypr/bindings.lua`. It deliberately replaces Omarchy's
standard Obsidian launcher, so the same shortcut now opens the quick switcher:

```lua
-- SUPER + SHIFT + O was previously bound to: Obsidian
hl.unbind("SUPER + SHIFT + O")
o.bind(
  "SUPER + SHIFT + O",
  "Obsidian quick switcher",
  "omarchy-shell shell toggle mk.obsidian-quick-switcher '{}'"
)
```

Hyprland reloads the file automatically. Validate it with:

```bash
hyprctl reload
hyprctl configerrors
```

## Use

| Key | Action |
| --- | --- |
| Type | Fuzzy-search file names, paths, aliases, and bookmark names |
| `↑` / `↓` | Move through results |
| `Page Up` / `Page Down` | Move by a page |
| `Enter` | Open the selected file through `obsidian open path=...` |
| `Shift` + `Enter` | Create and open a new note using the query |
| `Esc` | Clear the query, then close the panel |

Each invocation starts `obsidian files`, `obsidian aliases verbose`,
`obsidian bookmarks verbose`, and `obsidian recents` in parallel. Bookmarked
files appear as separate bookmark results, including duplicate file entries.
Recent files are shown until the first query response is ready; if there are
no matches, the query becomes a create action. QML merges the CLI output and
keeps the resulting index in memory for that panel session. There is no
debounce: every query revision starts a short-lived headless fzf process
immediately, while the previous results remain visible until their replacement
is ready. The panel starts at roughly one quarter of the screen height and
never grows beyond half the screen height. If Obsidian is closed, the plugin
waits for its CLI command server to become ready before loading the index.
Closing the panel terminates active Obsidian/fzf processes and clears the
in-memory index.

To target a named vault, pass it in the summon payload:

```bash
omarchy-shell shell summon mk.obsidian-quick-switcher '{"vault":"My vault"}'
```

## Development

```bash
omarchy plugin validate .
qmllint -I /usr/share/omarchy/shell QuickSwitcher.qml
```

## License

MIT
