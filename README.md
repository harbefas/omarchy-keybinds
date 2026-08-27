# Omarchy Keybinds

Native Omarchy overlay for looking up keybindings across the tools you
actually use. One tab per app, opening on the tab matching whatever window
was focused when you summoned it, with free-text search across all of them.

A hardcoded list of keybindings is a second copy of a fact the config already
knows, and second copies drift. The tabs that can be read live are read live,
straight from the compositor or a headless dump, never a table someone has to
remember to update.

## Sources

| Tab | Source |
|---|---|
| Hyprland | live — `hyprctl binds -j`, grouped by submap |
| Neovim | live — headless dump of `vim.api.nvim_get_keymap()`, loaded in the background |
| Herdr | bundled defaults + live overrides from `~/.config/herdr/config.toml` |
| Tridactyl | bundled (config lives in browser sync storage, no local file to read) |
| Spotify (spotify_player) | bundled |
| Lazygit | bundled |
| Yazi | bundled (defaults are compiled into the binary) |
| Glow | bundled |
| Tuicr | bundled |

Bundled tables are hand-copied from each tool's documented defaults and live
in `data/*.json`. They are the same files that
[keybinds-tui](https://github.com/harbefas/keybinds-tui) compiles into its
binary, so the terminal version and this overlay never disagree.

Reading Hyprland through `hyprctl` rather than parsing `~/.config/hypr/*.conf`
means binds pulled in through any include show up too, along with the submap
each belongs to.

## Keys

| Key | Action |
|---|---|
| type | filter the active tab |
| `@name` | jump to a tab by name or alias (`@vim scroll`) |
| `Tab` / `Shift+Tab`, `←` / `→` | previous / next tab |
| `↑` / `↓`, `Ctrl+P` / `Ctrl+N` | move selection |
| `Esc` | clear the filter, then close |

Search matches multiple words in any order, as substrings or fuzzily, so
"tab next", "next tab", and "nxt tb" all find "Next tab".

## Install

```bash
omarchy plugin add https://github.com/harbefas/omarchy-keybinds --enable
```

Bind it to a key in `~/.config/hypr/bindings.conf`:

```
bindd = SUPER, slash, Keybindings, exec, omarchy-shell shell summon harbefas.keybinds
```

Then reload:

```bash
omarchy restart shell
```

## Requirements

Hyprland and Quickshell, both of which Omarchy already provides. `nvim` is
optional: without it the Neovim tab says so and every other tab still works.

The Neovim keymaps are dumped in the background on first open. If
`keybinds-tui` has run recently its cache in `/tmp/kb-nvim-cache.json` is
reused, skipping the dump; the plugin only ever reads that file and writes
its own.

## Terminal version

[keybinds-tui](https://github.com/harbefas/keybinds-tui) is the same idea as a
ratatui TUI, for people not running Omarchy. Neither depends on the other.

## Remove

```bash
omarchy plugin remove harbefas.keybinds
```

The plugin writes no files outside its own directory, apart from the shared
Neovim cache in `/tmp`.

## License

MIT
