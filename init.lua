-- Niri-like workspaces: per-monitor and collapsing

-- Utilities

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

--- Splits a workspace's real name into its workspace number and owning monitor name.
--- Returns nil if the name isn't in our `<number><separator><monitor>` format.
---@param workspace HL.Workspace|nil The workspace.
---@return integer|nil workspace_number The extracted workspace number.
---@return string|nil monitor_name The extracted owning monitor name.
local function split_workspace_full_name(workspace)
    if not workspace then
        return nil
    end
    local workspace_number, monitor_name =
        string.match(workspace.name, "^(%d+)" .. M.opts.name_separator .. "(.+)$")
    return tonumber(workspace_number), monitor_name
end

--- Gets the workspace number of the workspace.
---@param workspace HL.Workspace|nil The workspace.
---@return integer|nil workspace_number The workspace number.
local function get_workspace_number(workspace)
    local workspace_number, _ = split_workspace_full_name(workspace)
    return workspace_number
end

--- Constructs the real workspace name that will be used by hyprland.
---@param workspace_number integer The workspace number.
---@param monitor_name string The name of the owning monitor.
---@return string full_name The real name.
local function get_workspace_real_name(workspace_number, monitor_name)
    return workspace_number .. M.opts.name_separator .. monitor_name
end

--- Gets the live workspaces currently placed on a specific monitor (excludes special).
---@param monitor_name string|nil The name of the monitor.
---@return HL.Workspace[] workspaces Array of workspaces on the monitor.
local function get_monitor_workspaces(monitor_name)
    local fixed_monitor_name = monitor_name or hl.get_monitor_at_cursor().name
    return filter(hl.get_workspaces(), function(workspace)
        local workspace_monitor = workspace.monitor
        return not workspace.special
            and workspace_monitor ~= nil
            and workspace_monitor.name == fixed_monitor_name
    end)
end

---@param workspace_number integer The workspace number.
---@param monitor_name string|nil The name of the monitor.
---@return integer
local function get_collapsed_new_name(workspace_number, monitor_name)
    if not M.opts.collapse_workspaces then
        return workspace_number
    end

    local fixed_monitor_name = monitor_name or hl.get_monitor_at_cursor().name

    local owned_non_empty = filter(get_monitor_workspaces(fixed_monitor_name), function(workspace)
        local number, owner = split_workspace_full_name(workspace)
        return number ~= nil and owner == fixed_monitor_name and #workspace:get_windows() > 0
    end)

    return math.min(workspace_number, #owned_non_empty + 1)
end

--- Focuses on the specified workspace.
---@param workspace_number integer The workspace number.
---@param monitor_name string|nil The name of the monitor.
local function focus_workspace(workspace_number, monitor_name)
    local fixed_monitor_name = monitor_name or hl.get_monitor_at_cursor().name
    local collapsed_workspace_number = get_collapsed_new_name(workspace_number, fixed_monitor_name)
    hl.dispatch(hl.dsp.focus({
        workspace = string.format(
            "name:%s",
            get_workspace_real_name(collapsed_workspace_number, fixed_monitor_name)
        ),
    }))
end

--- Focuses on the next monitor.
local function focus_next_monitor()
    hl.dispatch(hl.dsp.focus({ monitor = "+1" }))
end

--- Moves the window to the specified workspace.
---@param workspace_number integer The workspace number.
---@param monitor_name string|nil The name of the monitor.
---@param follow boolean|nil If it should also focus the workspace.
local function move_to_workspace(workspace_number, monitor_name, follow)
    local fixed_monitor_name = monitor_name or hl.get_monitor_at_cursor().name
    local collapsed_workspace_number = get_collapsed_new_name(workspace_number, fixed_monitor_name)
    hl.dispatch(hl.dsp.window.move({
        workspace = string.format(
            "name:%s",
            get_workspace_real_name(collapsed_workspace_number, fixed_monitor_name)
        ),
    }))
    if follow then
        focus_workspace(collapsed_workspace_number, fixed_monitor_name)
    end
end

--- Moves the window to the workspace with the same name on the next monitor.
---@param follow boolean|nil If it should also focus the workspace.
local function move_to_next_monitor(follow)
    hl.dispatch(hl.dsp.window.move({ monitor = "+1", follow = follow }))
end

--- Gets the active workspace that is currently shown, even if it is a special workspace.
---@return HL.Workspace The actual active workspace that the user sees.
local function get_active_visible_workspace()
    return hl.get_active_special_workspace() or hl.get_active_workspace()
end

--- Focuses on the specified workspace, or if it is already the active workspace,
--- jumps focus to the next available monitor instead.
---@param workspace_number integer The workspace number.
---@param or_next_monitor boolean|nil If it should focus to the next monitor when the workspace is already focused.
function M.focus_workspace(workspace_number, or_next_monitor)
    if
        or_next_monitor
        and get_workspace_number(get_active_visible_workspace()) == workspace_number
    then
        focus_next_monitor()
    else
        focus_workspace(workspace_number)
    end
end

--- Moves the window to the specified workspace, or if already
--- on that workspace, moves it to the next available monitor.
---@param workspace_number integer The workspace number to target.
---@param follow boolean|nil If it should also focus the workspace.
---@param or_next_monitor boolean|nil If it should move to the next monitor when the workspace is already focused.
function M.move_to_workspace(workspace_number, follow, or_next_monitor)
    if
        or_next_monitor
        and get_workspace_number(get_active_visible_workspace()) == workspace_number
    then
        move_to_next_monitor(follow)
    else
        move_to_workspace(workspace_number, nil, follow)
    end
end

--- Registers the workspace rules that route and name a monitor's workspaces.
---@param monitor HL.Monitor The monitor.
local function apply_monitor_workspace_rules(monitor)
    local name = monitor.name
    -- Route every workspace whose name ends with this monitor's suffix to it.
    hl.workspace_rule({
        workspace = string.format("n[e:%s%s]", M.opts.name_separator, name),
        monitor = name,
    })
    -- Name the monitor's initial workspace according to the scheme.
    hl.workspace_rule({
        workspace = string.format("name:1%s%s", M.opts.name_separator, name),
        monitor = name,
        default = true,
    })
end

--- Picks the slot number a workspace should take when adopted onto a monitor.
---@param workspace HL.Workspace The workspace being adopted.
---@param used table<integer, boolean> Numbers already taken on the target monitor.
---@return integer number The chosen, now-reserved slot number.
local function adopt_number(workspace, used)
    if not M.opts.collapse_workspaces then
        local original = get_workspace_number(workspace)
        if original and not used[original] then
            used[original] = true
            return original
        end
    end

    local number = 1
    while used[number] do
        number = number + 1
    end
    used[number] = true
    return number
end

--- Enforces the naming invariant: every workspace on a connected monitor whose owner is
--- gone (or unset) is adopted into that monitor's numbering. Workspaces owned by another
--- connected monitor are left for hyprland to re-pin.
---@param removed_monitor HL.Monitor|nil A monitor name to treat as disconnected.
local function reconcile(removed_monitor)
    local connected = {}
    for _, monitor in ipairs(hl.get_monitors()) do
        if monitor ~= removed_monitor then
            connected[monitor.name] = true
        end
    end

    for monitor_name in pairs(connected) do
        local used = {}
        local orphans = {}

        for _, workspace in ipairs(get_monitor_workspaces(monitor_name)) do
            local workspace_number, workspace_monitor_name = split_workspace_full_name(workspace)
            if workspace_monitor_name == monitor_name then
                if workspace_number then
                    used[workspace_number] = true
                end
            elseif workspace_monitor_name == nil or not connected[workspace_monitor_name] then
                table.insert(orphans, workspace)
            end
        end

        for _, workspace in ipairs(orphans) do
            hl.dispatch(hl.dsp.workspace.rename({
                workspace = string.format("name:%s", workspace.name),
                name = get_workspace_real_name(adopt_number(workspace, used), monitor_name),
            }))
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
        local owned_non_empty = filter(get_monitor_workspaces(monitor.name), function(workspace)
            local number, owner = split_workspace_full_name(workspace)
            return owner == monitor.name and number ~= nil and #workspace:get_windows() > 0
        end)

        table.sort(owned_non_empty, function(a, b)
            return get_workspace_number(a) < get_workspace_number(b)
        end)

        for i, workspace in ipairs(owned_non_empty) do
            if get_workspace_number(workspace) ~= i then
                hl.dispatch(hl.dsp.workspace.rename({
                    workspace = string.format("name:%s", workspace.name),
                    name = get_workspace_real_name(i, monitor.name),
                }))
            end
        end
    end
end

---@class Nirispaces.Opts
---@field name_separator string Separator between the workspace number and the monitor name. Must not be `-` or any character that appears in monitor connector names. Default `"@"`.
---@field collapse_workspaces boolean Keep each monitor's workspace numbering gap-free (1..n). Default `true`.

---@type Nirispaces.Opts
local default_opts = {
    name_separator = "@",
    collapse_workspaces = true,
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

    -- Shallow copy defaults
    for key, value in pairs(default_opts) do
        if M.opts[key] == nil then
            M.opts[key] = value
        end
    end

    -- Apply the workspace rules of all of the monitors in case of a config reload
    for _, monitor in ipairs(hl.get_monitors()) do
        apply_monitor_workspace_rules(monitor)
    end

    reconcile()

    hl.on("monitor.added", on_monitor_added)
    hl.on("monitor.removed", on_monitor_removed)
    hl.on("monitor.layout_changed", on_monitor_layout_changed)

    -- Workspace collapsing event handling
    if M.opts.collapse_workspaces then
        hl.on("workspace.removed", on_workspace_removed)
    end
end

return M
