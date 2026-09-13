-- T3 flak
-- Adds a T3 flak cannon variant (armflakt3 / corflakt3 / legflakt3)
-- derived from the T2 flak cannon of each faction, then gives T3
-- constructors the ability to build it.
do
	local UnitDefs = UnitDefs or {}
	local floor = math.floor
	local max = math.max
	local tableInsert = table.insert
	local tonumber = tonumber
	local type = type
	local pairs = pairs
	local ipairs = ipairs
	local stringFormat = string.format

	-- Deep-copies a unit definition table.
	local function deepCopy(value)
		local copy = {}
		for key, entry in pairs(value) do
			copy[key] = type(entry) == 'table' and deepCopy(entry) or entry
		end
		return copy
	end

	-- Scales a "x y z" vector string (e.g. collisionvolumescales) by a
	-- multiplier. Returns the string unchanged if it doesn't match.
	local function scaleVectorString(vectorString, multiplier)
		if not vectorString then
			return vectorString
		end

		local x, y, z = vectorString:match("([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
		if not x then
			return vectorString
		end

		return stringFormat("%.4g %.4g %.4g",
			tonumber(x) * multiplier,
			tonumber(y) * multiplier,
			tonumber(z) * multiplier)
	end

	-- Adds a unit name to a constructor's buildoptions, skipping duplicates.
	local function addBuildOption(constructorName, unitName)
		local constructor = UnitDefs[constructorName]
		if not constructor then
			return
		end

		constructor.buildoptions = constructor.buildoptions or {}
		for i = 1, #constructor.buildoptions do
			if constructor.buildoptions[i] == unitName then
				return
			end
		end

		tableInsert(constructor.buildoptions, unitName)
	end

	-- Faction definitions: T2 flak source, T3 variant name, and name prefix.
	local factions = {
		arm = { source = 'armflak', variant = 'armflakt3', prefix = 'Armada ' },
		cor = { source = 'corflak', variant = 'corflakt3', prefix = 'Cortex ' },
		leg = { source = 'legflak', variant = 'legflakt3', prefix = 'Legion ' },
	}

	-- Create the T3 flak variant from the T2 flak of each faction.
	for _, faction in pairs(factions) do
		local source = UnitDefs[faction.source]
		if source and not UnitDefs[faction.variant] then
			local variant = deepCopy(source)

			variant.name = faction.prefix .. 'T3 Flak Cannon'
			variant.footprintx = 4
			variant.footprintz = 4
			variant.yardmap = "oooooooooooooooo"

			-- Scale collision volume and stats to match the larger footprint.
			variant.collisionvolumescales = scaleVectorString(variant.collisionvolumescales, 4 / 3)
			variant.collisionvolumeoffsets = scaleVectorString(variant.collisionvolumeoffsets, 4 / 3)
			variant.health = floor((source.health or 1) * 2.5)
			variant.metalcost = floor((source.metalcost or 1) * 4)
			variant.energycost = floor((source.energycost or 1) * 4)
			variant.buildtime = floor((source.buildtime or 1) * 4)
			variant.sightdistance = 720
			variant.airsightdistance = 1200

			if variant.featuredefs then
				for _, feature in pairs(variant.featuredefs) do
					feature.footprintx = 4
					feature.footprintz = 4
				end
			end

			variant.customparams = variant.customparams or {}
			variant.customparams.i18n_en_humanname = faction.prefix .. 'T3 Flak Cannon'
			variant.customparams.i18n_en_tooltip = 'T3 flak with increased AoE.'

			if variant.weapondefs then
				for _, weapon in pairs(variant.weapondefs) do
					weapon.range = floor((weapon.range or 0) * 2)
					weapon.areaofeffect = floor((weapon.areaofeffect or 0) * 4)
					weapon.reloadtime = max(0.1, (weapon.reloadtime or 1) * 0.5)
					weapon.weaponvelocity = floor((weapon.weaponvelocity or 0) * 2)

					if weapon.damage then
						for damageType, amount in pairs(weapon.damage) do
							weapon.damage[damageType] = floor(amount * 3)
						end
					end
				end
			end

			UnitDefs[faction.variant] = variant
		end
	end

	-- Constructors that should be able to build each faction's T3 flak.
	local constructorsByFaction = {
		arm = { 'armack', 'armaca', 'armacv', 'armt3aide', 'armt3airaide' },
		cor = { 'corack', 'coraca', 'coracv', 'cort3aide', 'cort3airaide' },
		leg = { 'legack', 'legaca', 'legacv', 'legt3aide', 'legt3airaide' },
	}

	for factionName, constructors in pairs(constructorsByFaction) do
		local variantName = factions[factionName].variant
		if UnitDefs[variantName] then
			for _, constructorName in ipairs(constructors) do
				addBuildOption(constructorName, variantName)
			end
		end
	end
end
