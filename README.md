# VisiGrid Scratch

A persistent scratch spreadsheet that drops down over your Omarchy desktop.
It replaces the pop-up calculator: type numbers and formulas, close it, and
everything is still there next time. The math is done by the real
[VisiGrid](https://visigrid.app) engine running headless, so the whole
function library works (`=SUM`, `=PMT`, `=VLOOKUP`, dates, text, …).

![Type a few numbers, close it, open it again: still there](demo.gif)

## Requirements

- Omarchy with the Quattro shell.
- The `vgrid` CLI, which ships with VisiGrid:

  ```bash
  omarchy pkg aur add visigrid-bin
  ```

  Any install that puts `vgrid` on your `PATH` works (see
  [visigrid.app/download](https://visigrid.app/download)). The plugin shows an
  install hint in its status line when `vgrid` is missing.

## Install

```bash
omarchy plugin add https://github.com/VisiGrid/omarchy-scratch.git --enable
```

Then bind a key. Add this to `~/.config/hypr/bindings.lua` to take over the
calculator shortcut:

```lua
hl.unbind("SUPER + CTRL + Q")
o.bind("SUPER + CTRL + Q", "Scratch grid", "omarchy-shell shell toggle visigrid.scratch")
```

Or keep the calculator and pick another key. The plugin can also be opened
from any script with `omarchy-shell shell toggle visigrid.scratch`.

For the drop-down slide, add a layer rule to `~/.config/hypr/hyprland.lua`
(or any file it requires):

```lua
hl.layer_rule({ match = { namespace = "visigrid-scratch" }, animation = "slide top" })
```

## Usage

| Key | Action |
|-----|--------|
| type | start editing the active cell (replaces its contents) |
| `F2` | edit the active cell in place |
| `Enter` / `Shift+Enter` | commit and move down / up |
| `Tab` / `Shift+Tab` | commit and move right / left |
| arrows, `PgUp`, `PgDn`, `Home`, `Ctrl+Home` | move; the grid scrolls when you hit an edge |
| `Shift+arrows`, `Shift+click` | extend the selection |
| `Ctrl+arrows` / `Ctrl+Shift+arrows` | jump to the edge of the data / extend the selection there |
| `Ctrl+A` | select the region around the cursor, again for the whole visible grid |
| `Ctrl+V` | paste tab-separated text from the clipboard, starting at the active cell |
| `Delete` / `Backspace` | clear the active cell or the selection |
| `Alt+=` | AutoSum: `=SUM()` over the numbers above, else to the left |
| `Ctrl+C` / `Ctrl+Shift+C` | copy the cell or selection as values / as formulas (tab-separated) |
| `Ctrl+O` | save and open the sheet in the VisiGrid app |
| `F11` | toggle between full width and a fitted sheet |
| `F12` | toggle vim mode |
| `Esc` | cancel the edit, or close the overlay |

Formulas start with `=`. Mouse: click selects, double-click edits, wheel scrolls.

While typing a formula, arrow keys pick cell references instead of moving the
caret: after `=`, an operator, `(` or `,`, press an arrow to start pointing,
keep pressing to move, hold `Shift` to extend to a range, then type the next
operator or `Enter`. Clicking a cell does the same.

### Vim mode

Set `"vim": true` in the settings file (below). The bindings mirror VisiGrid's
own vim mode:

| Key | Action |
|-----|--------|
| `h` `j` `k` `l` | move |
| `H` `J` `K` `L` | extend the selection |
| `0` / `$` | first column / last filled column in the row |
| `w` / `b` | next / previous filled cell in the row |
| `gg` / `G` | top-left / last filled row |
| `i` / `a` | edit with the cursor at the start / end |
| `x` | clear the cell |

Digits, `=`, `+`, `-` and `.` still start an edit directly, so `2+2` never
needs an `i` first. Other letters are ignored in normal mode.

The sheet lives at `~/.local/state/visigrid/scratch.sheet`. It is a normal
VisiGrid file: open it in the app, share it, or `vgrid peek` it from a terminal.

## Configure

Optional settings file at `~/.config/visigrid/scratch.json` (hot-reloads):

```json
{
  "theme": "phosphor",
  "rows": 15,
  "cols": 0,
  "width": "full",
  "font": "",
  "vim": false
}
```

- `theme`: `phosphor` (VisiCalc green, the default) or `system` (follows your
  Omarchy theme).
- `rows`: visible rows (5–60).
- `width`: `full` spans the monitor; `fit` is a centered sheet just wide
  enough for `cols` columns (10 when `cols` is 0); `"60%"` or a pixel count
  like `1200` gives a fixed width. Always centered and flush with the top.
  `F11` flips between `full` and `fit` until the shell restarts.
- `cols`: fixed column count (3–26), or `0` to fit as many 128px columns as
  the width holds.
- `font`: font family override; empty uses the shell's menu font.
- `vim`: `true` enables the vim bindings above. `F12` flips it until the
  shell restarts or the file changes.

## How it works

`engine.sh` starts one detached `vgrid serve` process that owns the sheet and
autosaves it. It outlives shell restarts: the plugin adopts the running engine
through `scratch.pid` and `scratch.token` (mode 0600) kept next to the sheet in
`~/.local/state/visigrid/`. Every edit is one JSONL operation piped to
`vgrid apply`; every refresh is one `vgrid inspect --json` of the visible range.
The engine listens on loopback only. Nothing leaves your machine.

While the overlay is open it polls the workbook revision and re-reads the
visible range when it changes, so cells written by anything else, such as an
agent over the VisiGrid MCP connector or `vgrid apply` from a script, appear
as they land. The scratchpad is an ordinary VisiGrid session: `vgrid sessions`
lists it and paired clients can write to it.

`Ctrl+O` saves, stops the engine, and opens the sheet in the VisiGrid app; the
next summon starts a fresh engine on whatever the app saved. Log output goes to
`scratch-engine.log` in the same directory.

## Remove

```bash
omarchy plugin remove visigrid.scratch
```

Your sheet stays in `~/.local/state/visigrid/` until you delete it. To stop a
running engine after removal: `kill $(cat ~/.local/state/visigrid/scratch.pid)`.

## License

MIT. VisiGrid itself is AGPL-3.0; this plugin only talks to its CLI.
