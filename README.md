# hypr-nirispaces

Niri-style **per-monitor workspaces** and workspace collapse for [Hyprland](https://hyprland.org), implemented with
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
    swipe_threshold = 150,
    swipe_invert = true,
})
```

## Options

| Option                | Type      | Default | Description                                                                                                                            |
| --------------------- | --------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `name_separator`      | `string`  | `"@"`   | Separator between the workspace number and the monitor name. Must not be `-` or any character that appears in monitor connector names. |
| `collapse_workspaces` | `boolean` | `true`  | Keep each monitor's workspace numbering gap-free (`1..n`) as workspaces empty.                                                         |
| `swipe_threshold`     | `number`  | `150`   | Pixels of travel needed for `workspace_swipe_action` to commit a step.                                                                 |
| `swipe_invert`        | `boolean` | `true`  | Swipe up moves to the next workspace.                                                                                                  |

## API

### `nirispaces.focus_workspace(number, monitor)`

Focus workspace `number` on `monitor` (defaults to the monitor under the cursor). When
collapsing, `number` is clamped to the trailing empty slot. Focusing the workspace that is
already active is a no-op.

### `nirispaces.move_to_workspace(number, monitor, follow)`

Move the active window to workspace `number` on `monitor` (defaults to the monitor under the
cursor). If `follow` is `true`, also focus that workspace.

### `nirispaces.focus_relative_workspace(offset)`

Focus the workspace `offset` slots away on the current monitor. Clamped at `1` going down and,
when collapsing, at the trailing empty slot going up — it never wraps around.

### `nirispaces.workspace_swipe_action()`

Build an action table for `hl.gesture` that switches workspaces through
`focus_relative_workspace`, configured by the `swipe_threshold` and `swipe_invert` options.
Safe to call before `setup()` — the options are read when a swipe ends.

## Keybind example

Bind `MOD+1..9` to focus and `MOD+SHIFT+1..9` to move-and-follow:

```lua
local nirispaces = require("hyprland.modules.hypr-nirispaces")

for workspace_number = 1, 9 do
    local key = workspace_number % 10 -- If you want to bind '0' as well (may complicate workspace name presentation in your shell)
    hl.bind(mod .. key, function()
        nirispaces.focus_workspace(workspace_number)
    end)
    hl.bind(mod .. "SHIFT + " .. key, function()
        nirispaces.move_to_workspace(workspace_number, nil, true)
    end)
end
```

## Gesture example

Switch workspaces with a 3-finger vertical swipe on the trackpad:

```lua
local nirispaces = require("hyprland.modules.hypr-nirispaces")

hl.gesture({ fingers = 3, direction = "vertical", action = nirispaces.workspace_swipe_action() })
```

Do **not** use Hyprland's built-in `action = "workspace"` with this module. That swipe picks its
target with `m±1`, which orders a monitor's workspaces by workspace _id_. Named workspaces get
negative ids in creation order, so the swipe order has nothing to do with the numbering you see,
one direction silently does nothing, and `gestures:workspace_swipe_create_new` creates workspaces
by numeric id — outside the `<number>@<monitor>` scheme this module's rules depend on.

## Behavior

- **Startup / connect** — each monitor's first workspace is named `1@<monitor>` instead of the
  bare `1` Hyprland would create.
- **Collapse** — with `collapse_workspaces`, per-monitor numbering stays contiguous as
  workspaces are emptied, and focusing past the end lands on the next free slot.
- **Disconnect** — when a monitor is unplugged, its orphaned workspaces are _merged_ into a
  surviving monitor (renumbered into that monitor's scheme); the monitor starts fresh on
  reconnect.
- **Swipe** — one swipe moves one workspace, committed when your fingers lift. It is not the
  1:1 finger-tracked slide Hyprland's own swipe renders — Lua can't drive the workspace render
  offset — so the normal workspace-change animation plays instead and the
  `gestures:workspace_swipe_*` options do not apply. Tune `swipe_threshold` instead; `scale` on the
  gesture spec has no effect, since Hyprland passes Lua callbacks the unscaled delta.

> **Note:** anything that _displays_ workspace names (waybar, eww, scripts) will see the full
> name `1@DP-1`, not just `1`. Strip the `@<monitor>` suffix when rendering if you only want
> numbers.

## Also check

- <https://github.com/cfyeung-dojjy/hyprland_virtual_desktops_lua> - Inspiration for this
- <https://github.com/yayuuu/hyprland-scroll-overview> - To complete the hyprland-niri abomination experience
