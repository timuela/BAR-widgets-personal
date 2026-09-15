-- Dynamic Queue
function widget:GetInfo()
	return {
		name = "Dynamic Queue",
		desc = "Dynamically chain-advance the build queue based on build ETA, with decay guard",
		author = "timuela",
		date = "2025-09-10",
		license = "GPLv2+",
		layer = 2,
		enabled = false,
		handler = true,
	}
end

local GetSelectedUnits = Spring.GetSelectedUnits
local GetUnitDefID = Spring.GetUnitDefID
local GetUnitIsBuilding = Spring.GetUnitIsBuilding
local GetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local GetUnitTeam = Spring.GetUnitTeam
local GetMyTeamID = Spring.GetMyTeamID
local GetUnitHealth = Spring.GetUnitHealth
local GetUnitCommands = Spring.GetUnitCommands
local GetUnitCurrentCommand = Spring.GetUnitCurrentCommand
local GetUnitPosition = Spring.GetUnitPosition
local GetUnitSeparation = Spring.GetUnitSeparation
local GetUnitsInCylinder = Spring.GetUnitsInCylinder
local GetGameSeconds = Spring.GetGameSeconds
local ValidUnitID = Spring.ValidUnitID
local GiveOrderToUnit = Spring.GiveOrderToUnit

local CMD_DYNAMIC_QUEUE = 28342
local CMD_DYNAMIC_QUEUE_DESCRIPTION = {
	id = CMD_DYNAMIC_QUEUE,
	type = CMDTYPE.ICON_MODE,
	name = "Dynamic Queue",
	action = "dynamic_queue",
	params = { 0, "dynamic_queue_off", "dynamic_queue_on", "dynamic_queue_yolo" },
}

-- The threshold advances the queue once the current nanoframe passes it.
local ETA_STEPS = {
	{ eta = 5,  threshold = 0 },  -- < 5s left: advance immediately
	{ eta = 15, threshold = 0.3 }, -- < 15s: advance at 30%
	{ eta = 25, threshold = 0.6 }, -- < 25s: advance at 60%
	{ eta = math.huge, threshold = 0.9 }, -- longer: advance at 90%
}

local function thresholdForETA(etaSeconds)
	for _, step in ipairs(ETA_STEPS) do
		if etaSeconds < step.eta then
			return step.threshold
		end
	end
	return 0.9
end

-- Advance threshold for the builder's current nanoframe, or nil while its ETA is unknown/negative.
local function advanceThreshold(entry)
	if entry and entry.timeLeft and entry.timeLeft > 0 then
		return thresholdForETA(entry.timeLeft)
	end
	return nil
end

BAR.I18N.set("en.ui.orderMenu.dynamic_queue_off", "DynamicQ Off")
BAR.I18N.set("en.ui.orderMenu.dynamic_queue_on", "DynamicQ On")
BAR.I18N.set("en.ui.orderMenu.dynamic_queue_yolo", "DynamicQ YOLO")
BAR.I18N.set("en.ui.orderMenu.dynamic_queue_tooltip", "Advance the build queue based on each build's ETA, guard decaying nanoframes")

local BUILDER_DEFS = {}
local NANO_DEFS = {}
local MAX_DISTANCE = 0
local DYNAMIC_QUEUES = {}

-- Index builders and nano_turrets
for id, unitDef in pairs(UnitDefs) do
	if unitDef.isBuilder and not unitDef.isFactory then
		if #unitDef.buildOptions > 0 then
			BUILDER_DEFS[id] = true
		end
		if not unitDef.canMove then
			NANO_DEFS[id] = unitDef.buildDistance
			MAX_DISTANCE = math.max(MAX_DISTANCE, unitDef.buildDistance)
		end
	end
end

-- Check if the unit has WAIT.
local function unitHasWait(unit_id)
	for _, cmd in ipairs(GetUnitCommands(unit_id, 20) or {}) do
		if cmd.id == CMD.WAIT then
			return true
		end
	end
	return false
end

-- Builder's own queue tracking
local function ownQueuedNanoframes(unit_id)
	local nanoframes = {}
	for _, cmd in ipairs(GetUnitCommands(unit_id, 40) or {}) do
		if cmd.id == CMD.BUILD and cmd.params and cmd.params[1] then
			nanoframes[cmd.params[1]] = true
		end
	end
	return nanoframes
end

-- Find a nearby free nano_turret.
local function findAssistNano(nanoframe_id)
	local fx, _, fz = GetUnitPosition(nanoframe_id)
	if not fx then
		return nil
	end
	for _, nano_id in ipairs(GetUnitsInCylinder(fx, fz, MAX_DISTANCE, -2)) do
		local buildDistance = NANO_DEFS[GetUnitDefID(nano_id)]
		if
			buildDistance
			and nano_id ~= nanoframe_id
			and buildDistance > GetUnitSeparation(nanoframe_id, nano_id, true)
			and not unitHasWait(nano_id)
		then
			local cmds = GetUnitCommands(nano_id, 2) or {}
			if (cmds[1] and cmds[1].id == CMD.FIGHT) or (cmds[2] and cmds[2].id == CMD.FIGHT) then
				return nano_id
			end
		end
	end
	return nil
end

-- Check if a nano_turret is already assisting this nanoframe.
local function nanoframeIsAssisted(nanoframe_id)
	local fx, _, fz = GetUnitPosition(nanoframe_id)
	if not fx then
		return false
	end
	for _, nano_id in ipairs(GetUnitsInCylinder(fx, fz, MAX_DISTANCE * 2, -2)) do
		local buildDistance = NANO_DEFS[GetUnitDefID(nano_id)]
		if buildDistance and nano_id ~= nanoframe_id and buildDistance > GetUnitSeparation(nanoframe_id, nano_id, true) then
			if GetUnitIsBuilding(nano_id) == nanoframe_id then
				return true
			end
			for _, cmd in ipairs(GetUnitCommands(nano_id, 2) or {}) do
				if
					(cmd.id == CMD.REPAIR or cmd.id == CMD.GUARD or cmd.id == CMD.BUILD)
					and cmd.params
					and cmd.params[1] == nanoframe_id
				then
					return true
				end
			end
		end
	end
	return false
end

-- Start tracking a nanoframe for this builder; new entries get the next priority.
local function addNanoframe(rusher, nanoframe_id, progress)
	if not rusher.nanoframes[nanoframe_id] then
		rusher.nanoframes[nanoframe_id] = {
			priority = rusher.nextPriority,
			decayed = false,
			rate = nil,
			timeLeft = nil,
			lastProg = progress,
			lastTime = GetGameSeconds(),
		}
		rusher.nextPriority = rusher.nextPriority + 1
	end
end

-- Update the smoothed ETA estimate for a nanoframe entry.
local function updateNanoframeETA(entry, progress, gameSeconds)
	if not entry or not entry.lastProg then
		return
	end
	local dp = progress - entry.lastProg
	local dt = gameSeconds - entry.lastTime
	if dt > 2 then
		entry.rate = nil
		entry.timeLeft = nil
		entry.lastProg = progress
		entry.lastTime = gameSeconds
		return
	end
	if dt > 0 then
		local rate = dp / dt
		if rate ~= 0 then
			if entry.rate then
				entry.rate = (0.5 * entry.rate) + (0.5 * rate)
			else
				entry.rate = rate
			end
			if rate < 0 then
				-- decaying: timeLeft negative
				entry.timeLeft = -math.abs(progress / rate)
			else
				local newTime = (1 - progress) / entry.rate
				if entry.timeLeft and entry.timeLeft > 0 then
					entry.timeLeft = (0.9 * entry.timeLeft) + (0.1 * newTime)
				else
					entry.timeLeft = newTime
				end
			end
		end
		entry.lastProg = progress
		entry.lastTime = gameSeconds
	end
end

-- Mark a nanoframe decaying when its build rate is negative.
local function pollDecay(rusher, nanoframe_id, progress, gameSeconds)
	local entry = rusher.nanoframes[nanoframe_id]
	if not entry or progress >= 1 then
		return
	end
	updateNanoframeETA(entry, progress, gameSeconds)
	if entry.rate then
		if entry.rate < 0 then
			if not entry.decayed then
				entry.decayed = true
				entry.inserted = nil
				entry.priority = rusher.nextDecayPriority
				rusher.nextDecayPriority = rusher.nextDecayPriority - 1
			end
		elseif entry.decayed then
			entry.decayed = false
			entry.rate = nil
			entry.timeLeft = nil
			entry.lastProg = progress
			entry.lastTime = gameSeconds
		end
	end
end

local function removeNanoframe(rusher, nanoframe_id)
	rusher.nanoframes[nanoframe_id] = nil
end

local function checkUnits(update)
	local builderCount = 0
	for _, id in ipairs(GetSelectedUnits()) do
		if BUILDER_DEFS[GetUnitDefID(id)] then
			builderCount = builderCount + 1
		end
	end
	if builderCount > 0 then
		if update then
			local mode = CMD_DYNAMIC_QUEUE_DESCRIPTION.params[1]
			for _, id in ipairs(GetSelectedUnits()) do
				if mode == 0 then
					DYNAMIC_QUEUES[id] = nil
				else
					local rusher = DYNAMIC_QUEUES[id] or {
						nanoframes = {},
						nextPriority = 1,
						nextDecayPriority = 0,
					}
					rusher.yolo = mode == 2
					DYNAMIC_QUEUES[id] = rusher
				end
			end
		end
		return true
	end
end

local function forgetUnit(_, id)
	DYNAMIC_QUEUES[id] = nil
end
widget.UnitDestroyed = forgetUnit
widget.UnitTaken = forgetUnit

function widget:CommandsChanged()
	local modeIndex = 0
	for _, id in ipairs(GetSelectedUnits()) do
		local rusher = DYNAMIC_QUEUES[id]
		if rusher then
			modeIndex = math.max(modeIndex, rusher.yolo and 2 or 1)
		end
	end
	CMD_DYNAMIC_QUEUE_DESCRIPTION.params[1] = modeIndex
	if checkUnits(false) then
		table.insert(widgetHandler.customCommands, CMD_DYNAMIC_QUEUE_DESCRIPTION)
	end
end

function widget:CommandNotify(id)
	if id == CMD_DYNAMIC_QUEUE then
		CMD_DYNAMIC_QUEUE_DESCRIPTION.params[1] = (CMD_DYNAMIC_QUEUE_DESCRIPTION.params[1] + 1) % 3
		checkUnits(true)
		return true
	end
end

local function advanceQueue(unit_id)
	local _, _, tag = GetUnitCurrentCommand(unit_id)
	if tag then
		GiveOrderToUnit(unit_id, CMD.REMOVE, tag, 0)
	end
end

-- Guard a decaying nanoframe: insert a REPAIR at the front of the builder's queue.
local function guardNanoframe(unit_id, nanoframe_id)
	GiveOrderToUnit(unit_id, CMD.INSERT, { 0, CMD.REPAIR, 0, nanoframe_id }, { "alt" })
end

function widget:UnitFinished(unitID)
	for _, rusher in pairs(DYNAMIC_QUEUES) do
		removeNanoframe(rusher, unitID)
	end
end

function widget:GameFrame()
	local gameSeconds = GetGameSeconds()
	for unit_id, rusher in pairs(DYNAMIC_QUEUES) do
		local target_id = GetUnitIsBuilding(unit_id)

		if rusher.yolo then
			-- YOLO: advance the moment a nanoframe is under way; no ETA, assist, hand-off or decay guard.
			if target_id and not unitHasWait(unit_id) then
				advanceQueue(unit_id)
			end
		else
			-- Track the nanoframe the builder is currently working on.
			if target_id then
				local progress = select(5, GetUnitHealth(target_id)) or 0
				addNanoframe(rusher, target_id, progress)
			end

			-- Track nearby nanoframes
			local ownNanoframes = ownQueuedNanoframes(unit_id)
			local builderPosX, _, builderPosZ = GetUnitPosition(unit_id)
			if builderPosX then
				for _, nearby in ipairs(GetUnitsInCylinder(builderPosX, builderPosZ, MAX_DISTANCE * 2, -2)) do
					local _, beingBuilt = GetUnitIsBeingBuilt(nearby)
					-- Another builder's nearby nanoframe must not divert this builder off its own queue.
					if beingBuilt and GetUnitTeam(nearby) == GetMyTeamID() and ownNanoframes[nearby] then
						local progress = select(5, GetUnitHealth(nearby)) or 0
						addNanoframe(rusher, nearby, progress)
						pollDecay(rusher, nearby, progress, gameSeconds)
					end
				end
			end

			-- Update decay state for all tracked nanoframes.
			for nanoframe_id, entry in pairs(rusher.nanoframes) do
				if not ValidUnitID(nanoframe_id) then
					rusher.nanoframes[nanoframe_id] = nil -- destroyed or fully reclaimed
				else
					local progress = select(5, GetUnitHealth(nanoframe_id)) or 0
					if progress >= 1 then
						rusher.nanoframes[nanoframe_id] = nil -- finished
					else
						pollDecay(rusher, nanoframe_id, progress, gameSeconds)
					end
				end
			end

			-- Update the current nanoframe's ETA and try to hand it off to a free nano.
			if target_id then
				local progress = select(5, GetUnitHealth(target_id)) or 0
				updateNanoframeETA(rusher.nanoframes[target_id], progress, gameSeconds)
				local entry = rusher.nanoframes[target_id]
				local assisted = nanoframeIsAssisted(target_id)

				if entry and not entry.assist and not assisted and not unitHasWait(unit_id) then
					local nano_id = findAssistNano(target_id)
					if nano_id then
						entry.assist = true
						GiveOrderToUnit(nano_id, CMD.REPAIR, target_id, 0)
					end
				end

				-- Advance once the nanoframe is actually assisted.
				local threshold = advanceThreshold(entry)
				if threshold and progress >= threshold and assisted and not unitHasWait(unit_id) then
					advanceQueue(unit_id)
				end
			elseif not unitHasWait(unit_id) then
				-- Builder idle: guard the highest-priority decaying nanoframe.
				local nanoframeToGuard = nil
				local bestPriority = math.huge
				for nanoframe_id, entry in pairs(rusher.nanoframes) do
					local progress = select(5, GetUnitHealth(nanoframe_id)) or 0
					if entry.decayed and not entry.inserted then
						if entry.priority < bestPriority and progress > 0 and progress < 1 then
							nanoframeToGuard = nanoframe_id
							bestPriority = entry.priority
						elseif progress >= 1 then
							rusher.nanoframes[nanoframe_id] = nil
						end
					end
				end
				if nanoframeToGuard then
					rusher.nanoframes[nanoframeToGuard].inserted = true
					guardNanoframe(unit_id, nanoframeToGuard)
				end
			end
		end
	end
end

function widget:Initialize()
	widgetHandler.actionHandler:AddAction(self, "dynamic_queue", function()
		checkUnits(true)
	end, nil, "p")
end
function widget:Shutdown()
	widgetHandler.actionHandler:RemoveAction(self, "dynamic_queue", "p")
end
