function widget:GetInfo()
    return {
        name    = "Reclaim Selected",
        desc    = "Reclaim selected units with nearby nano turrets",
        author  = "manshanko",
        date    = "2025-04-01",
        home    = "https://github.com/manshanko/bar-widgets",
        layer   = 2,
        handler = true,
    }
end

local CONFIG = {
    -- change default action on button press to shuffle
    shuffle = true,
}

if Spring.GetSpectatingState() then return end

local echo = Spring.Echo
local i18n = BAR.I18N
local GetSelectedUnits = Spring.GetSelectedUnits
local GetUnitCommandCount = Spring.GetUnitCommandCount
local GetUnitDefID = Spring.GetUnitDefID
local GetUnitPosition = Spring.GetUnitPosition
local GetUnitSeparation = Spring.GetUnitSeparation
local GetUnitsInCylinder = Spring.GetUnitsInCylinder
local GiveOrderToUnitArray = Spring.GiveOrderToUnitArray
local GiveOrderArrayToUnit = Spring.GiveOrderArrayToUnit
local UnitDefs = UnitDefs
local CMD_RECLAIM = CMD.RECLAIM
local CMD_INSERT = CMD.INSERT
local CMD_OPT_ALT = CMD.OPT_ALT
local CMD_OPT_SHIFT = CMD.OPT_SHIFT

local CMD_RECLAIM_SELECTED = 28329
local CMD_RECLAIM_SELECTED_DESCRIPTION = {
    id = CMD_RECLAIM_SELECTED,
    type = CMDTYPE.ICON,
    name = "Reclaim Units",
    cursor = nil,
    action = "reclaim_selected",
}

i18n.set("en.ui.orderMenu." .. CMD_RECLAIM_SELECTED_DESCRIPTION.action, "Reclaim Selected")
i18n.set("en.ui.orderMenu." .. CMD_RECLAIM_SELECTED_DESCRIPTION.action .. "_tooltip", "Reclaim selected units")

local NANO_DEFS = {}
local MAX_DISTANCE = 0

for unit_def_id, unit_def in pairs(UnitDefs) do
    if unit_def.isBuilder and not unit_def.canMove and not unit_def.isFactory then
        NANO_DEFS[unit_def_id] = unit_def.buildDistance
        if unit_def.buildDistance > MAX_DISTANCE then
            MAX_DISTANCE = unit_def.buildDistance
        end
    end
end

local CMD_CACHE = { 0, CMD_RECLAIM, CMD_OPT_SHIFT, 0 }

local function ntNearUnit(target_unit_id)
    local x, y, z = GetUnitPosition(target_unit_id)
    local units_near = GetUnitsInCylinder(x, z, MAX_DISTANCE, -2)
    local unit_ids = {}
    for _, id in ipairs(units_near) do
        local dist = NANO_DEFS[GetUnitDefID(id)]
        if dist ~= nil and target_unit_id ~= id then
            if dist > GetUnitSeparation(target_unit_id, id, true) then
                unit_ids[#unit_ids + 1] = id
            end
        end
    end

    return unit_ids
end

local function signalReclaim(target_unit_id)
    local unit_ids = ntNearUnit(target_unit_id)

    CMD_CACHE[4] = target_unit_id
    GiveOrderToUnitArray(unit_ids, CMD_INSERT, CMD_CACHE, CMD_OPT_ALT)
end

local TASKS = nil
local function signalReclaimShuffle(target_unit_ids)
    TASKS = coroutine.wrap(function()
        local nt_seen = {}
        local nt_queue = {}
        for i=1, #target_unit_ids do
            local unit_id = target_unit_ids[i]
            local nt_ids = ntNearUnit(unit_id)
            for i=1, #nt_ids do
                local nt_id = nt_ids[i]
                if not (nt_seen[nt_id] and nt_seen[nt_id][unit_id]) then
                    nt_seen[nt_id] = nt_seen[nt_id] or {}
                    nt_seen[nt_id][unit_id] = true

                    nt_queue[nt_id] = nt_queue[nt_id] or {}
                    nt_queue[nt_id][#nt_queue[nt_id] + 1] = {
                        CMD_RECLAIM,
                        unit_id,
                        CMD_OPT_SHIFT,
                    }
                end
            end
        end

        local executed = 0
        for nt_id, cmds in pairs(nt_queue) do
            local num_cmds = GetUnitCommandCount(nt_id)
            if num_cmds then
                table.shuffle(cmds)

                -- Try to append reclaim orders if user does multiple reclaim selected.
                -- This check is arbitrary but works in the common case.
                if num_cmds <= 5 then
                    cmds[1][3] = nil
                end
                GiveOrderArrayToUnit(nt_id, cmds)
                nt_queue[nt_id] = nil

                executed = executed + 5 + #cmds
                if executed > 200 then
                    executed = 0
                    coroutine.yield()
                end
            end
        end

        TASKS = nil
    end)

    TASKS()
end

local function handleReclaimSelected()
    local unit_ids = GetSelectedUnits()

    for _, unit_id in ipairs(unit_ids) do
        signalReclaim(unit_id)
    end
end

local function handleReclaimSelectedShuffle()
    signalReclaimShuffle(GetSelectedUnits())
end

function widget:CommandsChanged()
    local unit_ids = GetSelectedUnits()
    if #unit_ids > 0 then
        local cmds = widgetHandler.customCommands
        cmds[#cmds + 1] = CMD_RECLAIM_SELECTED_DESCRIPTION
    end
end

function widget:CommandNotify(cmd_id, cmd_params, cmd_options)
    if cmd_id == CMD_RECLAIM_SELECTED then
        if CONFIG.shuffle then
            handleReclaimSelectedShuffle()
        else
            handleReclaimSelected()
        end
    end
end

function widget:GameFrame(n)
    if TASKS and n % 3 == 0 then
        TASKS()
    end
end

function widget:Initialize()
    widgetHandler.actionHandler:AddAction(self, "reclaim_selected", handleReclaimSelected, nil, "p")
    widgetHandler.actionHandler:AddAction(self, "reclaim_selected_shuffle", handleReclaimSelectedShuffle, nil, "p")
end

function widget:Shutdown()
    widgetHandler.actionHandler:RemoveAction(self, "reclaim_selected", "p")
    widgetHandler.actionHandler:RemoveAction(self, "reclaim_selected_shuffle", "p")
end
