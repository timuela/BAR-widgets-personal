function widget:GetInfo()
    return {
        name      = "Grid Draw",
        desc      = "Draws a build-border grid from external JSON profiles, matched by map name and game mode",
        author    = "Lu5ck",
        date      = "31 May 2025",
        layer     = 1,
        enabled   = true
    }
end

--[[
Border values
NONE = 0
TOP = 1
RIGHT = 2
BOTTOM = 4
LEFT = 8
Diagonal \ = 16
Diagonal / = 32

For multiple borders in same cell, add the value together
TOP and RIGHT border = 1 + 2 = 3

Profiles live in:
	LuaUI/Widgets/map_grid_profiles/<anything>.json

A profile must set maps; gameModes is optional:
    "maps": ["Full Metal Plate 1.7"],
    "gameModes": ["IsCoop", "IsSinglePlayer", "IsSandbox", "IsPvE"]
]]--

local PROFILE_DIR = "LuaUI/Widgets/map_grid_profiles/"
local Json = Json or VFS.Include("common/luaUtilities/json.lua")

local drawLineQueue = {}
local timer = 0

local GAME_MODE_TESTS = {
	"IsSinglePlayer", -- only Player in the game
	"IsTeams",        -- one team has > 2 players
	"IsBigTeams",     -- IsTeams, one team has > 4 players
	"IsSmallTeams",   -- IsTeams, all team has =< 4 players
	"IsRaptors",      -- a Raptor AI is present
	"IsScavengers",   -- a Scavenger AI is present
	"IsPvE",          -- IsRaptors or IsScavengers
	"IsCoop",         -- all players (> 2) on one team
	"IsSandbox",      -- 1 Player against Inactive AI
}

local KNOWN_GAME_MODES = {}
for _, name in ipairs(GAME_MODE_TESTS) do
	KNOWN_GAME_MODES[name] = true
end

local function readFile(path)
	local data = VFS.LoadFile(path, VFS.RAW_FIRST)
	if data then
		return data
	end
	local file = io.open(path, "r")
	if file then
		local text = file:read("*all")
		file:close()
		return text
	end
	return nil
end

local function loadProfiles()
	local profiles = {}
	local files = VFS.DirList(PROFILE_DIR, "*.json", VFS.RAW_FIRST)
	if not files then
		return profiles
	end
	table.sort(files)

	for _, path in ipairs(files) do
		local text = readFile(path)
		if not text then
			Spring.Echo("[GridDraw] Could not read profile: " .. path)
		else
			local ok, profile = pcall(Json.decode, text)
			if not ok then
				Spring.Echo("[GridDraw] Invalid JSON in " .. path .. ": " .. tostring(profile))
			elseif type(profile) ~= "table" then
				Spring.Echo("[GridDraw] Profile " .. path .. " is not an object")
			else
				profile.filename = path
				profiles[#profiles + 1] = profile
			end
		end
	end

	return profiles
end

local function matchesMap(profile)
	local maps = profile.match.maps
	for _, mapName in ipairs(maps) do
		if mapName == Game.mapName then
			return true
		end
	end
	return false
end

-- True if ANY listed game mode matches.
local function matchesGameMode(profile)
	local modes = profile.match.gameModes
	if not modes or #modes == 0 then
		return true
	end
	local gametype = BAR and BAR.Utilities and BAR.Utilities.Gametype
	local matched, unknown = false, nil
	for _, modeName in ipairs(modes) do
		modeName = tostring(modeName)
		if KNOWN_GAME_MODES[modeName] then
			local test = gametype and gametype[modeName]
			if type(test) == "function" and test() then
				matched = true
			end
		else
			unknown = unknown or modeName
		end
	end
	if unknown then
		Spring.Echo("[GridDraw] " .. profile.filename .. " lists unknown game mode '" .. unknown .. "', ignoring it")
	end
	return matched
end

local function activeGameModes()
	local modes = {}
	local gametype = BAR and BAR.Utilities and BAR.Utilities.Gametype
	if gametype then
		for _, name in ipairs(GAME_MODE_TESTS) do
			local test = gametype[name]
			if type(test) == "function" and test() then
				modes[#modes + 1] = name
			end
		end
	end
	return modes
end

local function evaluate(profile)
	local conds = profile.match
	if type(conds) ~= "table" or type(conds.maps) ~= "table" or #conds.maps == 0 then
		return "invalid"
	end
	if not matchesMap(profile) then
		return "map_mismatch"
	end
	if not matchesGameMode(profile) then
		return "mode_mismatch"
	end
	return "map_match"
end

local function hasBit(val, bit)
	return math.floor(val / bit) % 2 == 1
end

local function drawLine(y, startX, startZ, endX, endZ, maxLength)
	local dx = endX - startX
	local dz = endZ - startZ
	local length = math.sqrt(dx * dx + dz * dz)

	local lengthCount = math.ceil(length / maxLength)

	for i = 0, lengthCount - 1 do
		local t1 = i / lengthCount
		local t2 = (i + 1) / lengthCount

		local sx = startX + dx * t1
		local sz = startZ + dz * t1
		local ex = startX + dx * t2
		local ez = startZ + dz * t2

		table.insert(drawLineQueue, {startX = sx, startZ = sz, endX = ex, endZ = ez, y = y})
	end
end

-- Validates the profile against the running map and fills the draw queue.
local function buildQueue(profile)
	local grid = profile.grid
	local mapping = profile.mapping
	if type(grid) ~= "table" or type(mapping) ~= "table" then
		return false, "missing grid/mapping"
	end
	local gridsize = grid.size
	local gridsquare = grid.square
	if type(gridsize) ~= "number" or type(gridsquare) ~= "number" then
		return false, "grid.size and grid.square must be numbers"
	end

	local cellsize = gridsize * gridsquare
	local expectedRows = Game.mapSizeZ / cellsize
	local expectedCols = Game.mapSizeX / cellsize

	if #mapping ~= expectedRows then
		return false, "mapping has " .. #mapping .. " rows, expected " .. expectedRows
	end
	for row = 1, #mapping do
		if #mapping[row] ~= expectedCols then
			return false, "row " .. row .. " has " .. #mapping[row] .. " columns, expected " .. expectedCols
		end
	end

	drawLineQueue = {}
	for row = 1, #mapping do
		for col = 1, #mapping[row] do
			local val = mapping[row][col]
			local x = (col - 1) * cellsize
			local z = (row - 1) * cellsize

			if hasBit(val, 1) then
				drawLine(0, x, z, x + cellsize, z, 24 * gridsquare) -- Top
			end
			if hasBit(val, 2) then
				drawLine(0, x + cellsize, z, x + cellsize, z + cellsize, 24 * gridsquare) -- Right
			end
			if hasBit(val, 4) then
				drawLine(0, x, z + cellsize, x + cellsize, z + cellsize, 24 * gridsquare) -- Bottom
			end
			if hasBit(val, 8) then
				drawLine(0, x, z, x, z + cellsize, 24 * gridsquare) -- Left
			end
			if hasBit(val, 16) then
				drawLine(0, x, z, x + cellsize, z + cellsize, 24 * gridsquare) -- Diagonal \
			end
			if hasBit(val, 32) then
				drawLine(0, x + cellsize, z, x, z + cellsize, 24 * gridsquare) -- Diagonal /
			end
		end
	end

	return true
end

function widget:Initialize()
	if Spring.GetSpectatingState() then
		widgetHandler:RemoveWidget() -- Don't draw when spectating
		return
	end

	local profiles = loadProfiles()
	if #profiles == 0 then
		Spring.Echo("[GridDraw] No grid profiles found in " .. PROFILE_DIR .. ", disabling.")
		widgetHandler:RemoveWidget()
		return
	end

	local chosen
	local modeNeed  -- gameModes of the first profile whose map matched but mode did not
	local sizeMiss  -- a profile matched, but its mapping did not fit this map size

	for _, profile in ipairs(profiles) do
		local status = evaluate(profile)
		if status == "map_match" then
			local ok, err = buildQueue(profile)
			if ok then
				chosen = profile
				break
			end
			sizeMiss = true
			Spring.Echo("[GridDraw] Skipping " .. profile.filename .. ": " .. err)
		elseif status == "mode_mismatch" then
			modeNeed = modeNeed or profile.match.gameModes
		elseif status == "invalid" then
			Spring.Echo("[GridDraw] Ignoring " .. profile.filename .. ": no map list")
		end
	end

	if not chosen then
		local mapName = tostring(Game.mapName)
		if modeNeed then
			local active = activeGameModes()
			Spring.Echo("[GridDraw] Map '" .. mapName .. "' is supported, but no profile matched the game mode"
				.. " (profile accepts: " .. table.concat(modeNeed, ", ")
				.. "; current: " .. (#active > 0 and table.concat(active, ", ") or "unknown") .. "), disabling.")
		elseif sizeMiss then
			Spring.Echo("[GridDraw] Map '" .. mapName .. "' has a profile, but its grid does not fit this map size, disabling.")
		else
			Spring.Echo("[GridDraw] No grid profile for map '" .. mapName .. "', disabling.")
		end
		widgetHandler:RemoveWidget()
		return
	end

	Spring.Echo("[GridDraw] Using profile " .. tostring(chosen.name or chosen.filename))
end

function widget:Update(dt)
	if #drawLineQueue == 0 then
		widgetHandler:RemoveWidget() -- All is done, stop the widget
		return
	end
	timer = timer + dt
	if timer > 0.1 then
		for i = 1, 10 do -- Draw 10 lines at a time, I think max is 12?
			if #drawLineQueue == 0 then
				break
			end
			local data = table.remove(drawLineQueue, 1) -- Get and remove
			Spring.MarkerAddLine(data.startX, data.y, data.startZ, data.endX, data.y, data.endZ)
		end
		timer = 0
	end
end
