# hypr-nirispaces

Niri-style **per-monitor workspaces** and workspace collapse for [Hyprland](https://hyprland.org), implemented with
Hyprland's native Lua config API

Each managed workspace is named `<number>@<monitor>` (e.g. `1@DP-1`, `2@eDP-1`), so the same
workspace number exists _independently_ on every monitor — switching to workspace `2` always
means "this monitor's workspace 2", never steals a workspace from another output. Optionally,
workspaces collapse to stay gap-free (`1..n`) as they empty.

## Requirements

- Hyprland 0.56+ — the Lua config API arrived in 0.55, but writing a workspace's id needs
  `hl.dsp.workspace.change_id`, added in 0.56.0.

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
    monitor_workspaces_count = 100,
    swipe_threshold = 150,
    swipe_invert = true,
})
```

## Options

| Option                | Type      | Default | Description                                                                                                                            |
| --------------------- | --------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `name_separator`      | `string`  | `"@"`   | Separator between the workspace number and the monitor name. Must not be a digit. |
| `collapse_workspaces` | `boolean` | `true`  | Keep each monitor's workspace numbering gap-free (`1..n`) as workspaces empty.                                                         |
| `monitor_workspaces_count` | `integer` | `100` | How many workspaces a monitor can hold. Sets the size of the id block each monitor owns, and so also caps how far `focus_relative_workspace` climbs. |
| `swipe_threshold`     | `number`  | `150`   | Pixels of travel needed for `workspace_swipe_action` to commit a step.                                                                 |
| `swipe_invert`        | `boolean` | `true`  | Swipe up moves to the next workspace.                                                                                                  |

## API

### `nirispaces.focus_workspace(number, monitor)`

Focus workspace `number` on `monitor` — a connector name (`"DP-1"`) or a Hyprland monitor id
(`0`), defaulting to the focused monitor when omitted. A `monitor` that matches nothing currently
connected is a no-op rather than a fall back to the focused monitor, which would act on the wrong
screen. When collapsing, `number` is clamped to the trailing empty slot. Focusing the workspace
that is already active is a no-op.

### `nirispaces.move_to_workspace(number, monitor, follow)`

Move the active window to workspace `number` on `monitor` — a connector name or a monitor id,
as above. If `follow` is `true`, also focus that workspace. With no active window the whole call
is a no-op: Hyprland creates nothing for the window to land in, so the target workspace is not
opened either.

### `nirispaces.focus_relative_workspace(offset)`

Focus the workspace `offset` slots away on the focused monitor. Clamped at `1` going down and,
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
target with `m±1`, which steps through the workspaces that already _exist_ on the monitor and
wraps around at either end — so it can never reach the next empty slot the way
`focus_relative_workspace` does, and it silently jumps from your last workspace back to your
first. Turning on `gestures:workspace_swipe_create_new` does not fix it: that creates a workspace
by raw numeric id, which arrives with a bare numeric name and stays that way until the next
reconcile renames it.

## Behavior

- **Names identify, ids are derived** — a workspace's `<number>@<monitor>` name is the only thing
  the module reads to work out which slot it holds and which monitor owns it. Its id is computed
  from that slot as `monitor_id * monitor_workspaces_count + workspace_number` and written back,
  never read. So when the two disagree — a workspace renamed out from under the module, an id
  Hyprland picked itself — the **name wins**, and the next reconcile rewrites the id to match. A
  name that does not parse, numbers a slot past `monitor_workspaces_count`, or points at a monitor
  that is not connected holds no slot at all, and the workspace is adopted into the numbering of
  the monitor it sits on.
- **Ids** — every monitor owns the id block
  `id*monitor_workspaces_count + 1 .. + monitor_workspaces_count`, so with the defaults monitor
  `0` owns `1..100` and monitor `1` owns `101..200`. Workspaces are created _by id_ and named
  afterwards, which is the opposite of what the naming scheme suggests, because
  Hyprland only ever hands **named** workspaces negative ids counting down from `-1337` — in
  creation order. Anything that orders the workspaces it draws by id (noctalia does) would then
  render a monitor's bar backwards. A workspace rule routes each block to its monitor. Monitors
  are compared by id internally; their connector name is used for the workspace rules Hyprland
  will only accept a name for, and for the text of a workspace name.
- **Startup / connect** — each monitor's first workspace is named `1@<monitor>` instead of the
  bare `1` Hyprland would create. A monitor Hyprland has just connected is handed the next free
  workspace id — one belonging to an already-connected monitor's block — rather than the id its
  own `default` rule asks for; the module adopts that workspace into the new monitor's numbering
  rather than leave it stranded under a name that points at the wrong screen.
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
