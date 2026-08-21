-- Niri-like workspaces: per-monitor and collapsing

--- Filters an array based on a provided predicate function.
---@generic T
---@param array T[] The table/array to filter.
---@param predicate fun(value: T): boolean The function used to test each element.
---@return T[] result A new array containing only the elements that passed the predicate.
local function filter(array, predicate)
    local result = {}
    for _, value in ipairs(array) do
        if predicate(value) then
            table.insert(result, value)
        end
    end
    return result
end

local M = {}

--- Where a workspace sits in the scheme: the numbered slot it holds, and the monitor that owns
--- that slot. A workspace's hyprland name and id are both written from its slot, and the name is
--- read back to recover it.
---@class Nirispaces.WorkspaceSlot
---@field workspace_number integer The number of the workspace on its monitor.
---@field monitor HL.Monitor The monitor holding the workspace.

--- Constructs the name hyprland will carry for a slot. This is the one thing the module reads
--- back off a workspace; `get_workspace_slot` is the inverse.
---@param slot Nirispaces.WorkspaceSlot The slot.
---@return string name The workspace name.
local function get_workspace_name(slot)
    return slot.workspace_number .. M.opts.name_separator .. slot.monitor.name
end

--- Constructs the id hyprland will carry for a slot. Every monitor owns the block of ids from
--- `monitor_id * monitor_workspaces_count + 1` to `+ monitor_workspaces_count`.
---
--- The id is written, never read: the name is what says which slot a workspace holds. It still has
--- to be written, though -- shells that order the workspaces they display by id (noctalia does)
--- draw a monitor's workspaces backwards unless the ids ascend along with the numbering, and
--- hyprland only ever hands *named* workspaces descending negative ids.
---@param slot Nirispaces.WorkspaceSlot The slot.
---@return integer id The workspace id.
local function get_workspace_id(slot)
    return slot.monitor.id * M.opts.monitor_workspaces_count + slot.workspace_number
end

--- Gets a connected monitor by its hyprland id or its connector name.
---
--- The scan is deliberate: `hl.get_monitor` range-checks a numeric selector against the number of
--- monitors rather than matching it against the ids in use, and ids are handed out per connector
--- and never renumbered. Unplug the laptop screen and the external monitor keeps id 1 while the
--- count drops to 1, so `hl.get_monitor(1)` returns nil for a monitor still in `hl.get_monitors()`.
---@param monitor_selector integer|string The id or the name of the monitor.
---@return HL.Monitor|nil monitor The monitor, if one is connected under that id or name.
local function find_monitor(monitor_selector)
    local field = type(monitor_selector) == "number" and "id" or "name"
    for _, monitor in ipairs(hl.get_monitors()) do
        if monitor[field] == monitor_selector then
            return monitor
        end
    end
    return nil
end

--- Gets a monitor by its hyprland id or its connector name, defaulting to the focused one when
--- no selector is given. A selector that matches no connected monitor gets nothing back rather
--- than the focused monitor: falling back there would act on whichever screen happens to be
--- focused, which is never what the caller asked for.
---@param monitor_selector integer|string|nil The id or the name of the monitor.
---@return HL.Monitor|nil monitor The monitor, if there is one to give.
local function get_selected_or_active_monitor(monitor_selector)
    if monitor_selector == nil then
        return hl.get_active_monitor()
    end
    return find_monitor(monitor_selector)
end

--- The `<number><separator><monitor>` pattern `get_workspace_slot` matches names against. Built
--- once in `setup`, so the separator is escaped there rather than on every parse.
---@type string
local workspace_name_pattern

--- Gets the slot a workspace holds: its workspace number, and the monitor owning it. The name is
--- what identifies a workspace here, so this reads the name and nothing else.
---
--- A workspace holds no slot -- and is owned by nobody, whatever its id says -- when its name does
--- not fit `<number><separator><monitor>`, when the number falls outside the monitor's count, or
--- when the monitor it names is not connected. `get_workspace_name` is the inverse.
---@param workspace HL.Workspace|nil The workspace.
---@return Nirispaces.WorkspaceSlot|nil slot The slot the name holds, if any.
local function get_workspace_slot(workspace)
    local workspace_name = workspace and workspace.name
    if not workspace_name then
        return nil
    end

    local digits, workspace_monitor_name = workspace_name:match(workspace_name_pattern)
    local workspace_number = digits and math.tointeger(tonumber(digits))
    if
        not workspace_number
        or workspace_number < 1
        or workspace_number > M.opts.monitor_workspaces_count
    then
        return nil
    end

    local monitor = find_monitor(workspace_monitor_name)
    if not monitor then
        return nil
    end

    return { workspace_number = workspace_number, monitor = monitor }
end

--- Gets the workspace number of the slot a workspace holds.
---@param workspace HL.Workspace|nil The workspace.
---@return integer|nil workspace_number The workspace number.
local function get_workspace_number(workspace)
    local slot = get_workspace_slot(workspace)
    return slot and slot.workspace_number
end

--- Places a workspace on the `<number><separator><monitor>` slot, giving it the name, the id and
--- the monitor that slot owns. The rename goes first: hyprland refuses to move a workspace onto an
--- id that is already taken, and renaming first keeps that refusal from pointing the rename at
--- whatever holds the id instead.
---@param workspace HL.Workspace The workspace to place.
---@param slot Nirispaces.WorkspaceSlot The slot to place it on.
local function assign_workspace_slot(workspace, slot)
    local workspace_monitor = workspace.monitor

    local workspace_name = get_workspace_name(slot)
    if workspace.name ~= workspace_name then
        hl.dispatch(hl.dsp.workspace.rename({
            workspace = tostring(workspace.id),
            name = workspace_name,
        }))
    end

    local workspace_id = get_workspace_id(slot)
    if workspace.id ~= workspace_id then
        hl.dispatch(hl.dsp.workspace.change_id({
            workspace = tostring(workspace.id),
            id = workspace_id,
        }))
    end

    -- A focus/move dispatch opens a new workspace on the focused monitor and ignores the rule
    -- routing its id block, so a slot aimed at any other monitor lands on the wrong one.
    if workspace_monitor == nil or workspace_monitor.id ~= slot.monitor.id then
        hl.dispatch(hl.dsp.workspace.move({
            workspace = tostring(workspace_id),
            monitor = slot.monitor.name,
        }))
    end
end

--- Gets the live workspaces currently placed on a specific monitor (excludes special).
--- Placement, not ownership: an orphan is placed here while its slot says it belongs elsewhere.
---@param monitor HL.Monitor The monitor.
---@return HL.Workspace[] workspaces Array of workspaces on the monitor.
local function get_monitor_workspaces(monitor)
    return filter(hl.get_workspaces(), function(workspace)
        local workspace_monitor = workspace.monitor
        return not workspace.special
            and workspace_monitor ~= nil
            and workspace_monitor.id == monitor.id
    end)
end

--- Gets the non-empty workspaces a monitor owns: placed on it, and holding a slot in its block.
---@param monitor HL.Monitor The monitor.
---@return HL.Workspace[] workspaces Array of the monitor's own non-empty workspaces.
local function get_owned_non_empty_workspaces(monitor)
    return filter(get_monitor_workspaces(monitor), function(workspace)
        local slot = get_workspace_slot(workspace)
        return slot ~= nil and slot.monitor.id == monitor.id and #workspace:get_windows() > 0
    end)
end

--- Clamps a slot to what its monitor can actually hold.
---@param slot Nirispaces.WorkspaceSlot The slot asked for.
---@return Nirispaces.WorkspaceSlot collapsed The slot to use instead.
local function get_collapsed_workspace_slot(slot)
    local workspace_number = math.min(slot.workspace_number, M.opts.monitor_workspaces_count)

    if M.opts.collapse_workspaces then
        workspace_number =
            math.min(workspace_number, #get_owned_non_empty_workspaces(slot.monitor) + 1)
    end

    return { workspace_number = workspace_number, monitor = slot.monitor }
end

--- Focuses the workspace holding a monitor's slot, creating and naming it if it did not exist.
---@param slot Nirispaces.WorkspaceSlot The slot to focus.
local function focus_monitor_workspace(slot)
    local collapsed = get_collapsed_workspace_slot(slot)
    local workspace_id = get_workspace_id(collapsed)
    hl.dispatch(hl.dsp.focus({ workspace = tostring(workspace_id) }))
    -- Naming has to wait until after the dispatch: from `workspace.created` the workspace is not
    -- queryable yet (bugs.txt 3).
    local created = hl.get_workspace(workspace_id)
    if created then
        assign_workspace_slot(created, collapsed)
    end
end

--- Focuses on the specified workspace.
---@param workspace_number integer The workspace number.
---@param monitor_selector integer|string|nil The id or the name of the monitor.
function M.focus_workspace(workspace_number, monitor_selector)
    local monitor = get_selected_or_active_monitor(monitor_selector)
    if monitor then
        focus_monitor_workspace({ workspace_number = workspace_number, monitor = monitor })
    end
end

--- Moves the window to the specified workspace.
---@param workspace_number integer The workspace number.
---@param monitor_selector integer|string|nil The id or the name of the monitor.
---@param follow boolean|nil If it should also focus the workspace.
function M.move_to_workspace(workspace_number, monitor_selector, follow)
    local monitor = get_selected_or_active_monitor(monitor_selector)
    if not monitor then
        return
    end
    local slot =
        get_collapsed_workspace_slot({ workspace_number = workspace_number, monitor = monitor })
    local workspace_id = get_workspace_id(slot)
    hl.dispatch(hl.dsp.window.move({ workspace = tostring(workspace_id) }))
    -- Nothing is created when there was no window to move (bugs.txt 3).
    local created = hl.get_workspace(workspace_id)
    if created then
        assign_workspace_slot(created, slot)
    end
    if follow then
        focus_monitor_workspace(slot)
    end
end

--- Focuses the workspace `offset` slots away on the focused monitor.
--- Clamped at 1 on the low end and, when collapsing, at the trailing empty slot on the
--- high end; it never wraps around.
---@param offset integer Signed number of slots to move by.
function M.focus_relative_workspace(offset)
    local monitor = hl.get_active_monitor()
    if not monitor then
        return
    end
    local current = get_workspace_number(hl.get_active_workspace(monitor)) or 1
    focus_monitor_workspace({ workspace_number = math.max(current + offset, 1), monitor = monitor })
end

--- Builds an `hl.gesture` action that switches workspaces the nirispaces way, configured by
--- `swipe_threshold` and `swipe_invert`. The step commits when the fingers lift, so
--- `gestures:workspace_swipe_*` does not apply.
---@return table action A `start`/`update`/`finish` table for `hl.gesture`.
function M.workspace_swipe_action()
    -- M.opts is read in the callbacks, not here: this runs at config load, before setup().
    local travel = 0

    local function accumulate(event)
        travel = travel + event.delta.y
    end

    return {
        start = function(event)
            travel = 0
            accumulate(event)
        end,
        update = accumulate,
        finish = function(event)
            if event.cancelled or math.abs(travel) < M.opts.swipe_threshold then
                return
            end
            local step = travel < 0 and 1 or -1
            if not M.opts.swipe_invert then
                step = -step
            end
            M.focus_relative_workspace(step)
        end,
    }
end

--- Registers the workspace rules that route and name a monitor's workspaces.
---@param monitor HL.Monitor The monitor.
local function apply_monitor_workspace_rules(monitor)
    -- Hyprland's workspace rules only take a connector name, never a monitor id.
    local name = monitor.name
    local first = get_workspace_id({ workspace_number = 1, monitor = monitor })
    hl.workspace_rule({
        workspace = string.format(
            "r[%d-%d]",
            first,
            get_workspace_id({
                workspace_number = M.opts.monitor_workspaces_count,
                monitor = monitor,
            })
        ),
        monitor = name,
    })
    hl.workspace_rule({
        workspace = tostring(first),
        monitor = name,
        default = true,
    })
end

--- Picks the workspace number a workspace should take when adopted onto a monitor.
---@param workspace HL.Workspace The workspace being adopted.
---@param used table<integer, boolean> Workspace numbers already taken on the target monitor.
---@return integer workspace_number The chosen, now-reserved workspace number.
local function adopt_workspace_number(workspace, used)
    if not M.opts.collapse_workspaces then
        local original = get_workspace_number(workspace)
        if original and not used[original] then
            used[original] = true
            return original
        end
    end

    local workspace_number = 1
    while used[workspace_number] do
        workspace_number = workspace_number + 1
    end
    used[workspace_number] = true
    return workspace_number
end

--- Enforces the slot invariant. A workspace whose name gives it a free slot on the monitor it
--- sits on keeps that slot and has its id written from it; every other workspace is adopted into
--- the numbering of the monitor it is on. Adoption rather than relocation, even when the name
--- points at another connected monitor: hyprland hands a monitor it has just connected the next
--- free id instead of the one its `default` rule asks for, and moving that workspace away only
--- makes hyprland conjure another one just like it.
---@param removed_monitor HL.Monitor|nil A monitor to treat as disconnected.
local function reconcile(removed_monitor)
    local removed_monitor_id = removed_monitor and removed_monitor.id

    local connected = {}
    for _, monitor in ipairs(hl.get_monitors()) do
        if monitor.id ~= removed_monitor_id then
            connected[monitor.id] = monitor
        end
    end

    for monitor_id, monitor in pairs(connected) do
        local used = {}
        local orphans = {}

        for _, workspace in ipairs(get_monitor_workspaces(monitor)) do
            local slot = get_workspace_slot(workspace)
            -- Nothing stops two workspaces carrying the same name, so a second claim on a taken
            -- slot is adopted into a free one instead of fighting for the id.
            if slot and slot.monitor.id == monitor_id and not used[slot.workspace_number] then
                used[slot.workspace_number] = true
                assign_workspace_slot(workspace, slot)
            else
                table.insert(orphans, workspace)
            end
        end

        for _, workspace in ipairs(orphans) do
            assign_workspace_slot(workspace, {
                workspace_number = adopt_workspace_number(workspace, used),
                monitor = monitor,
            })
        end
    end
end

--- Handles the event where a monitor is added.
---@param monitor HL.Monitor The added monitor.
local function on_monitor_added(monitor)
    apply_monitor_workspace_rules(monitor)
    reconcile()
end

--- Handles the event where a monitor is removed: its orphaned workspaces are merged into
--- whichever monitor they were moved to.
---@param monitor HL.Monitor The removed monitor.
local function on_monitor_removed(monitor)
    reconcile(monitor)
end

--- Mirroring a monitor (or reverting) fires no monitor.added/removed event, only this one;
--- by the time it fires the mirror has left hl.get_monitors(), so reconcile adopts its orphans.
local function on_monitor_layout_changed()
    reconcile()
end

--- Handles the event where a workspace is removed by collapsing each monitor's owned,
--- non-empty workspaces back to a contiguous 1..n numbering.
---@param _ HL.Workspace The removed workspace.
local function on_workspace_removed(_)
    for _, monitor in ipairs(hl.get_monitors()) do
        local owned_non_empty = get_owned_non_empty_workspaces(monitor)

        table.sort(owned_non_empty, function(a, b)
            return get_workspace_number(a) < get_workspace_number(b)
        end)

        -- Ascending, so every slot a workspace moves down into has already been vacated by the
        -- workspace that held it -- hyprland refuses a change_id onto an id already in use.
        for i, workspace in ipairs(owned_non_empty) do
            assign_workspace_slot(workspace, { workspace_number = i, monitor = monitor })
        end
    end
end

---@class Nirispaces.Opts
---@field name_separator string Separator between the workspace number and the monitor name. Must not be a digit. Default `"@"`.
---@field collapse_workspaces boolean Keep each monitor's workspace numbering gap-free (1..n). Default `true`.
---@field monitor_workspaces_count integer How many workspaces a monitor can hold. Sets the size of the id block each monitor owns, so it also caps how far `focus_relative_workspace` can climb. Default `100`.
---@field swipe_threshold number Pixels of travel needed for `workspace_swipe_action` to commit a step. Default `150`.
---@field swipe_invert boolean Swipe up moves to the next workspace. Default `true`.

---@type Nirispaces.Opts
local default_opts = {
    name_separator = "@",
    collapse_workspaces = true,
    monitor_workspaces_count = 100,
    swipe_threshold = 150,
    swipe_invert = true,
}

local has_setup = false

--- Module setup/reload.
---@param opts Nirispaces.Opts|nil Configuration options.
function M.setup(opts)
    if has_setup then
        return
    end
    has_setup = true
    ---@type Nirispaces.Opts
    M.opts = opts or {}

    for key, value in pairs(default_opts) do
        if M.opts[key] == nil then
            M.opts[key] = value
        end
    end

    -- Escaped so the separator stays free to be a pattern metacharacter.
    workspace_name_pattern = "^(%d+)" .. (M.opts.name_separator:gsub("([^%w])", "%%%1")) .. "(.+)$"

    -- On a reload no monitor.added fires for the monitors that are already there.
    for _, monitor in ipairs(hl.get_monitors()) do
        apply_monitor_workspace_rules(monitor)
    end

    reconcile()

    hl.on("monitor.added", on_monitor_added)
    hl.on("monitor.removed", on_monitor_removed)
    hl.on("monitor.layout_changed", on_monitor_layout_changed)

    if M.opts.collapse_workspaces then
        hl.on("workspace.removed", on_workspace_removed)
    end
end

return M
