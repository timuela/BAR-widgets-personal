function widget:GetInfo()
    return {
        name      = "Grid Draw",
        desc      = "Draws lines from external JSON profiles, matched by map name and game mode",
        author    = "Lu5ck, timuela",
        date      = "31 May 2025",
        layer     = 1,
        enabled   = true
    }
end

local PROFILE_DIR = "LuaUI/Widgets/map_grid_profiles/"
local Json = Json or VFS.Include("common/luaUtilities/json.lua")

local BU_SIZE = 16        -- 1 BU = 16 elmos, as in layout_planner_plus
local CHUNK_SIZE = 192    -- long lines are split into pieces this size so the render stays gradual
local MARKER_HEIGHT = 0   -- elmos above ground to draw at

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

local function queueLine(x1, z1, x2, z2)
	local dx = x2 - x1
	local dz = z2 - z1
	local length = math.sqrt(dx * dx + dz * dz)
	if length == 0 then
		return
	end

	local chunks = math.ceil(length / CHUNK_SIZE)
	for i = 0, chunks - 1 do
		local t1 = i / chunks
		local t2 = (i + 1) / chunks

		table.insert(drawLineQueue, {
			startX = x1 + dx * t1,
			startZ = z1 + dz * t1,
			endX = x1 + dx * t2,
			endZ = z1 + dz * t2,
		})
	end
end

-- Validates the profile against the running map and fills the draw queue.
local function buildQueue(profile)
	local lines = profile.lines
	if type(lines) ~= "table" or #lines == 0 then
		return false, "no \"lines\" list"
	end

	drawLineQueue = {}
	for index, line in ipairs(lines) do
		if type(line) ~= "table" or #line ~= 4 then
			drawLineQueue = {}
			return false, "line " .. index .. " is not [x1, z1, x2, z2]"
		end
		for i = 1, 4 do
			if type(line[i]) ~= "number" then
				drawLineQueue = {}
				return false, "line " .. index .. " has a non-numeric coordinate"
			end
		end
		queueLine(line[1] * BU_SIZE, line[2] * BU_SIZE, line[3] * BU_SIZE, line[4] * BU_SIZE)
	end

	if #drawLineQueue == 0 then
		return false, "every line is zero length"
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
		Spring.Echo("[GridDraw] No profiles found in " .. PROFILE_DIR .. ", disabling.")
		widgetHandler:RemoveWidget()
		return
	end

	local chosen
	local modeNeed  -- gameModes of the first profile whose map matched but mode did not
	local broken    -- a profile matched the map, but its lines could not be used

	for _, profile in ipairs(profiles) do
		local status = evaluate(profile)
		if status == "map_match" then
			local ok, err = buildQueue(profile)
			if ok then
				chosen = profile
				break
			end
			broken = err
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
		elseif broken then
			Spring.Echo("[GridDraw] Map '" .. mapName .. "' has a profile, but its lines are unusable ("
				.. broken .. "), disabling.")
		else
			Spring.Echo("[GridDraw] No profile for map '" .. mapName .. "', disabling.")
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
			Spring.MarkerAddLine(data.startX, MARKER_HEIGHT, data.startZ, data.endX, MARKER_HEIGHT, data.endZ)
		end
		timer = 0
	end
end
