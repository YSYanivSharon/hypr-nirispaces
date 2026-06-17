# hypr-nirispaces

Niri-style **per-monitor workspaces** for [Hyprland](https://hyprland.org), implemented with
Hyprland's native Lua config API

Each managed workspace is named `<number>@<monitor>` (e.g. `1@DP-1`, `2@eDP-1`), so the same
workspace number exists _independently_ on every monitor — switching to workspace `2` always
means "this monitor's workspace 2", never steals a workspace from another output. Optionally,
workspaces collapse to stay gap-free (`1..n`) as they empty.

## Requirements

- Hyprland 0.55+ (for Lua config support).

## Install

Place the module under your config so it resolves as a Lua module, e.g.
`~/.config/hypr/hyprland/modules/hypr-nirispaces/`, then `require` it once and call `setup()`:

```lua
require("hyprland.modules.hypr-nirispaces").setup()
```

Or with options:

```lua
require("hyprland.modules.hypr-nirispaces").setup({
    name_separator = "@",
    collapse_workspaces = true,
})
```

## Options

| Option                | Type      | Default | Description                                                                                                                            |
| --------------------- | --------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `name_separator`      | `string`  | `"@"`   | Separator between the workspace number and the monitor name. Must not be `-` or any character that appears in monitor connector names. |
| `collapse_workspaces` | `boolean` | `true`  | Keep each monitor's workspace numbering gap-free (`1..n`) as workspaces empty.                                                         |

## API

### `nirispaces.focus_workspace(number, or_next_monitor)`

Focus workspace `number` on the current monitor. If `or_next_monitor` is `true` and that
workspace is already focused, focus the next monitor instead.

### `nirispaces.move_to_workspace(number, follow, or_next_monitor)`

Move the active window to workspace `number` on the current monitor. If `follow` is `true`,
also focus that workspace. If `or_next_monitor` is `true` and the window is already on that
workspace, move it to the next monitor instead.

## Keybind example

Bind `MOD+1..9` to focus and `MOD+SHIFT+1..9` to move-and-follow:

```lua
local nirispaces = require("hyprland.modules.hypr-nirispaces")

for workspace_number = 1, 9 do
    local key = workspace_number % 10 -- If you want to bind '0' as well (may complicate workspace name presentation in your shell)
    hl.bind(mod .. key, function()
        nirispaces.focus_workspace(workspace_number, true)
    end)
    hl.bind(mod .. "SHIFT + " .. key, function()
        nirispaces.move_to_workspace(workspace_number, true, true)
    end)
end
```

## Behavior

- **Startup / connect** — each monitor's first workspace is named `1@<monitor>` instead of the
  bare `1` Hyprland would create.
- **Collapse** — with `collapse_workspaces`, per-monitor numbering stays contiguous as
  workspaces are emptied, and focusing past the end lands on the next free slot.
- **Disconnect** — when a monitor is unplugged, its orphaned workspaces are _merged_ into a
  surviving monitor (renumbered into that monitor's scheme); the monitor starts fresh on
  reconnect.

> **Note:** anything that _displays_ workspace names (waybar, eww, scripts) will see the full
> name `1@DP-1`, not just `1`. Strip the `@<monitor>` suffix when rendering if you want bare
> numbers.
