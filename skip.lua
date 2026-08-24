local widget = widget ---@type Widget

function widget:GetInfo()
    return {
        name = "Skip To Timestamp",
        desc = "Adds skipT command which skips to specific timestamp, for example /skipT 5:10",
        author = "SuperKitowiec",
        date = "Jan 2026",
        license = "GNU GPL, v2 or later",
        layer = 0,
        enabled = true,
    }
end

function SkipToTime(_, params)
    if not params or params == "" then
        Spring.Echo("Error: No timestamp provided.")
        return
    end

    if params:match("[^%d:]") then
        Spring.Echo("Invalid format: Only numbers and colons allowed (e.g., 10:30).")
        return
    end

    local parts = string.split(params, ':')
    local total = 0

    local function safeNum(str)
        return tonumber(str) or 0
    end

    if #parts == 1 then
        total = safeNum(parts[1]) -- seconds only
    elseif #parts == 2 then
        total = safeNum(parts[1]) * 60 + safeNum(parts[2]) -- also minutes
    elseif #parts == 3 then
        total = safeNum(parts[1]) * 3600 + safeNum(parts[2]) * 60 + safeNum(parts[3]) -- also hours
    else
        Spring.Echo("Invalid timestamp: " .. params)
        return
    end

    if total > 0 then
        local _, _, isClientPaused = Spring.GetGameState()
        if not isClientPaused then
            Spring.SendCommands("pause")
        end
        Spring.SendCommands("skip " .. total)
    end
end

function widget:Initialize()
    widgetHandler:AddAction("skipT", SkipToTime, nil, "tp")
end