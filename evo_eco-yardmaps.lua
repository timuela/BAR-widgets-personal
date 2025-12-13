-- Evolve Eco
local UnitDefs = UnitDefs or {}
local baseFusions = {
	arm = "armafust3",
	cor = "corafust3",
	leg = "legafust3",
}
local baseConverters = {
	arm = "armmmkrt3",
	cor = "cormmkrt3",
	leg = "legadveconvt3",
}

local MaxFusionLevel = 9
local MaxConverterLevel = 9


local function r4(quadrant, quadRows, quadCols)
    local fullRows = quadRows * 2
    local fullCols = quadCols * 2
    local grid = {}
    local quad = {}
    local idx = 1
    for r = 1, quadRows do
        quad[r] = {}
        for c = 1, quadCols do
            quad[r][c] = quadrant:sub(idx, idx)
            idx = idx + 1
        end
    end
    for r = 1, fullRows do
        grid[r] = {}
    end
    for r = 0, quadRows - 1 do
        for c = 0, quadCols - 1 do
            local char = quad[r + 1][c + 1]
            grid[r + 1][c + 1] = char
            local r90 = c + 1
            local c90 = fullCols - r
            grid[r90][c90] = char
            local r180 = fullRows - r
            local c180 = fullCols - c
            grid[r180][c180] = char
            local r270 = fullRows - c
            local c270 = r + 1
            grid[r270][c270] = char
        end
    end
    local result = "h "
    for r = 1, fullRows do
        for c = 1, fullCols do
            result = result .. grid[r][c]
        end
    end
    return result
end

local function rep(c, n)
	return string.rep(c, n)
end

local s = string.rep

local fusionyardmaps = {
[1] = r4("occooococcbobbocbobbbbcobboccbbcbcbcoobbccbcocbcocboccbccobcobobbbbbobbobobbbbobccobobobccoocbcobcbocbcccbbcobbbobcobcccobccobocbcobcbcoobboccbo", 12, 12),
[2] = r4("socsssbsccbsbsscbsbbbocsbbscsbbcbcbcsssbccbcscbcscbsccbccsscsbsbobbosbbsbsbbbbssscsbsbssbcsscbcsbcbscoscbbbcsbbssbcsscccsbssssscocsbcbcssbbsccss", 12, 12),
[3] = r4("sscsssbscbbsbsscbsbbbscsbbscsbbcbcscssssccbcscbbscbsccbccsscsbsosbbssbbsbsbbbbssscsbsbssbcsscbssbcbscsscbbocsbbssbossccosbsssssoscsocbcssbssccss", 12, 12),
[4] = r4("sscsssbscbssbsscssbboscssbscssbcbbscssssccbcscobsobsccbccsscsosssbbssobsbsbbbsssscsosbssbcssbbssbbbscsscbbscsbbssbsssccssbssssssscsscbcssbssccss", 12, 12),
[5] = r4("sscsssbscbssbsscssbbssossbscssbcbbscsssscobcscssssosccbccsscsssssbbsssssbsbbosssscsssbssbcssbbsssbsscsscobsosbbssbsssbcssosssssssbsscbbssbsscbss", 12, 12),
[6] = r4("ssssssbscbssbsscssbosssssbsossocbbscssssssbcscssssssccbccsscssssssbsssssosbbsssssssssbssbcssbbsssbsscsscsbsssbbssosssbossssssssssbsscbbssbssosss", 12, 12),
[7] = r4("sssssssscbssossbsssssssssossssscbbscsssssssbscssssssccbcbsscssssssosssssssossssssssssbssbossbbsssbsscssosbsssbbssssssbsssssssssssbsscosssbssssss", 12, 12),
[8] = r4("sssssssscbsssssbssssssssssssssscbbsssssssssbsossssssccbcbsscsssssssssssssssssssssssssbssssssbbsssbsscssssosssbbssssssbsssssssssssbsscssssbssssss", 12, 12),
[9] = r4("sssssssscssssssbssssssssssssssscbbsssssssssbssssssssccbcbssbsssssssssssssssssssssssssbssssssbbsssbssossssssssbbssssssbsssssssssssossbssssbssssss", 12, 12),
}
local mmkrtyardmaps = {
[1] = r4("ccboboocbccooboccbobobccbbbcobocobbc", 6, 6),
[2] = r4("ccbsbsscbccssbsccbsbsbcsbbscsbscssbc", 6, 6),
[3] = r4("ccbsbsscsocssbsccbsbsbcsbbscsbscssbs", 6, 6),
[4] = r4("ccbsbssssssssbsccbsbsbcsboscsoscssbs", 6, 6),
[5] = r4("ccosbssssssssbscbosbsbcsbsscssscssbs", 6, 6),
[6] = r4("ccssbssssssssbscbssbsbsssssbssscssbs", 6, 6),
[7] = r4("ocssbssssssssbscbssbsbssssssssssssbs", 6, 6),
[8] = r4("scssossssssssbsosssbsossssssssssssbs", 6, 6),
[9] = r4("scsssssssssssbsssssbssssssssssssssbs", 6, 6),
}
local NewFusions = {}
local NewConverters = {}

for faction, baseFusion in pairs(baseFusions) do
	for i = 1, MaxFusionLevel do
		local unitName = faction .. "evfus" .. i
		NewFusions[unitName] = {
			name = faction:upper() .. " Evolve Fusion Reactor " .. i,
			description = "Upgradeable Fusion Reactor " .. i,
			yardmap = fusionyardmaps[i],
			customparams = {
				i18n_en_humanname = "Evolve Fusion Reactor " .. i,
				i18n_en_tooltip = "Fusion Level " .. i .. " Produce " .. (i * 30000) .. " Energy",
				geothermal = 1,
			},
		}
	end
end

for faction, baseConverter in pairs(baseConverters) do
	for i = 1, MaxConverterLevel do
		local unitName = faction .. "mmkrt3" .. i
		NewConverters[unitName] = {
			name = faction:upper() .. " Evolve Energy Converter " .. i,
			description = "Upgradeable Energy Converter " .. i,
			yardmap = mmkrtyardmaps[i],
			customparams = {
				i18n_en_humanname = "Evolve Energy Converter " .. i,
				i18n_en_tooltip = "Converts " .. (i * 6000) .. " energy into " .. (i * 120) .. " metal per sec (Hazardous)",
                geothermal = 1,
			},
		}
	end
end

for faction, baseFusion in pairs(baseFusions) do
	if UnitDefs[baseFusion] then
		local basefus = UnitDefs[baseFusion]
		for i = 1, MaxFusionLevel do
			local f = NewFusions[faction .. "evfus" .. i]
			if f then
                f.metalcost = basefus.metalcost * i
				f.energycost = basefus.energycost * i
				f.energymake = basefus.energymake * i
				f.energystorage = basefus.energystorage * i
				if not UnitDefs[faction .. "evfus" .. i] then
					UnitDefs[faction .. "evfus" .. i] = table.merge(basefus, f)
					UnitDefs[faction .. "evfus" .. i].customparams = UnitDefs[faction .. "evfus" .. i].customparams
						or {}
				end
			end
		end
	end
end

for faction, baseConverter in pairs(baseConverters) do
	if UnitDefs[baseConverter] then
		local basemmkrt3 = UnitDefs[baseConverter]
		for i = 1, MaxConverterLevel do
			local c = NewConverters[faction .. "mmkrt3" .. i]
			if c then
				c.metalcost = basemmkrt3.metalcost * i
				c.energycost = basemmkrt3.energycost * i
				c.customparams.energyconv_capacity = basemmkrt3.customparams.energyconv_capacity * i
				if not UnitDefs[faction .. "mmkrt3" .. i] then
					UnitDefs[faction .. "mmkrt3" .. i] = table.merge(basemmkrt3, c)
					UnitDefs[faction .. "mmkrt3" .. i].customparams = UnitDefs[faction .. "mmkrt3" .. i].customparams
						or {}
				end
			end
		end
	end
end

local builders = {
	arm = { "armaca", "armack", "armacsub", "armacv" },
	cor = { "coraca", "corack", "coracsub", "coracv" },
	leg = { "legaca", "legack", "legacv", "legcomt2com" },
}

local function addBuildOption(unitDef, option)
	for _, existing in ipairs(unitDef.buildoptions) do
		if existing == option then
			return
		end
	end
	table.insert(unitDef.buildoptions, option)
end

for faction, blds in pairs(builders) do
	for _, builder in ipairs(blds) do
		local unitDef = UnitDefs[builder]
		if unitDef and unitDef.buildoptions then
			for i = 1, MaxFusionLevel do
				addBuildOption(unitDef, faction .. "evfus" .. i)
				addBuildOption(unitDef, faction .. "mmkrt3" .. i)
			end
		end
	end
end
