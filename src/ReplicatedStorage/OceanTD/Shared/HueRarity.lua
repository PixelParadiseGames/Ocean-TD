--!strict
--[[
	Per-species hue odds for seed-wheel rolls and common-area coral.
	Tier percentage is split evenly across that tier's colors.
	Tiers with no colors are omitted and the rest are used as relative weights.
]]

local PlotOutlineColors = require(script.Parent:WaitForChild("PlotOutlineColors"))

local HueRarity = {}

local NAME_TO_INDEX: { [string]: number } = {
	pink = 1,
	teal = 2,
	blue = 3,
	navy = 4,
	purple = 5,
	red = 6,
	pumpkin = 7,
	orange = 8,
	yellow = 9,
	["toxic green"] = 10,
	green = 11,
	grey = 12,
	gray = 12,
	black = 13,
	white = 14,
}

type TierDef = { percent: number, colors: { string } }
type Entry = { index: number, weight: number, rarity: string }
type Table = { entries: { Entry }, total: number }

local RARITY_NAMES = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Extinct" }

local function build(tiers: { TierDef }): Table
	local entries: { Entry } = {}
	local total = 0
	for tierIndex, tier in ipairs(tiers) do
		local names = tier.colors
		local n = #names
		if n <= 0 or tier.percent <= 0 then
			continue
		end
		local rarity = RARITY_NAMES[tierIndex] or "Common"
		-- Tenths of a percent so 67.6 stays exact.
		local bucket = math.floor(tier.percent * 10 + 0.5)
		local base = math.floor(bucket / n)
		local rem = bucket - base * n
		for i, name in ipairs(names) do
			local index = NAME_TO_INDEX[string.lower(name)]
			if index then
				local weight = base + (if i <= rem then 1 else 0)
				if weight > 0 then
					table.insert(entries, { index = index, weight = weight, rarity = rarity })
					total += weight
				end
			end
		end
	end
	return { entries = entries, total = total }
end

local BY_SPECIES: { [string]: Table } = {
	FireCoral = build({
		{ percent = 67.6, colors = { "Red", "Pumpkin", "Orange", "Yellow" } },
		{ percent = 16.7, colors = { "Pink", "Teal", "Toxic green" } },
		{ percent = 6.8, colors = { "Purple", "Green" } },
		{ percent = 5.8, colors = { "Blue", "Navy" } },
		{ percent = 1.0, colors = { "White" } },
		{ percent = 1.0, colors = { "Black" } },
		{ percent = 1.0, colors = { "Grey" } },
	}),
	LeatherCoral = build({
		{ percent = 43.1, colors = { "Teal", "Purple", "Toxic green" } },
		{ percent = 26.4, colors = { "Pink", "Yellow", "Green" } },
		{ percent = 9.3, colors = { "Navy", "Orange" } },
		{ percent = 8.0, colors = { "Blue", "Black" } },
		{ percent = 7.3, colors = { "Pumpkin", "White" } },
		{ percent = 4.4, colors = { "Red" } },
		{ percent = 1.5, colors = { "Grey" } },
	}),
	SeaFan = build({
		{ percent = 45.4, colors = { "Purple" } },
		{ percent = 14.1, colors = { "Pink" } },
		{ percent = 13.5, colors = { "White" } },
		{ percent = 10.0, colors = { "Black" } },
		{ percent = 9.1, colors = {} },
		{ percent = 6.5, colors = {} },
		{ percent = 1.5, colors = { "Grey" } },
	}),
	SeaGrass = build({
		{ percent = 51.9, colors = { "Toxic green", "Green" } },
		{ percent = 15.1, colors = { "Orange", "Yellow" } },
		{ percent = 7.6, colors = { "Red", "Pumpkin" } },
		{ percent = 10.1, colors = { "Blue", "Navy", "Purple" } },
		{ percent = 9.7, colors = { "Pink", "Teal", "Black" } },
		{ percent = 3.9, colors = { "White" } },
		{ percent = 1.6, colors = { "Grey" } },
	}),
	TreeCoral = build({
		{ percent = 50.1, colors = { "Pink", "Teal", "White" } },
		{ percent = 15.9, colors = { "Blue", "Purple", "Green" } },
		{ percent = 10.8, colors = { "Navy", "Red", "Toxic green" } },
		{ percent = 8.7, colors = { "Pumpkin", "Yellow" } },
		{ percent = 6.2, colors = { "Orange" } },
		{ percent = 6.5, colors = { "Black" } },
		{ percent = 1.7, colors = { "Grey" } },
	}),
	Sponge = build({
		{ percent = 42.7, colors = { "Navy", "Purple" } },
		{ percent = 18.1, colors = { "Pink", "Blue", "Pumpkin" } },
		{ percent = 13.5, colors = { "Teal", "Yellow", "Green" } },
		{ percent = 10.9, colors = { "Orange", "Toxic green" } },
		{ percent = 7.9, colors = { "Red", "White" } },
		{ percent = 5.9, colors = { "Black" } },
		{ percent = 1.1, colors = { "Grey" } },
	}),
	Zoas = build({
		{ percent = 42.7, colors = { "Teal", "Navy", "Yellow" } },
		{ percent = 23.1, colors = { "Pink", "Pumpkin", "White" } },
		{ percent = 11.3, colors = { "Orange", "Toxic green", "Black" } },
		{ percent = 8.4, colors = { "Red", "Green" } },
		{ percent = 6.6, colors = { "Blue" } },
		{ percent = 6.5, colors = { "Purple" } },
		{ percent = 1.5, colors = { "Grey" } },
	}),
	BrainCoral = build({
		{ percent = 46.2, colors = { "Orange", "Yellow" } },
		{ percent = 18.2, colors = { "Red", "Pumpkin", "Toxic green" } },
		{ percent = 17.2, colors = { "Pink", "Teal", "Blue", "Purple" } },
		{ percent = 9.8, colors = { "Navy", "Green" } },
		{ percent = 3.8, colors = { "White" } },
		{ percent = 3.0, colors = { "Black" } },
		{ percent = 1.8, colors = { "Grey" } },
	}),
}

function HueRarity.indices(speciesId: string): { number }
	local tableForSpecies = BY_SPECIES[speciesId]
	local seen: { [number]: boolean } = {}
	local out: { number } = {}
	if not tableForSpecies then
		return out
	end
	for _, entry in ipairs(tableForSpecies.entries) do
		if entry.weight > 0 and not seen[entry.index] then
			seen[entry.index] = true
			table.insert(out, entry.index)
		end
	end
	table.sort(out)
	return out
end

-- Whole-number "1 in N" for this species and color. Nil when that color cannot roll.
function HueRarity.oneIn(speciesId: string, colorIndex: number): number?
	local tableForSpecies = BY_SPECIES[speciesId]
	if not tableForSpecies or tableForSpecies.total <= 0 then
		return nil
	end
	local weight = 0
	for _, entry in ipairs(tableForSpecies.entries) do
		if entry.index == colorIndex then
			weight += entry.weight
		end
	end
	if weight <= 0 then
		return nil
	end
	return math.max(1, math.floor(tableForSpecies.total / weight + 0.5))
end

function HueRarity.className(speciesId: string, colorIndex: number): string?
	local tableForSpecies = BY_SPECIES[speciesId]
	if not tableForSpecies then
		return nil
	end
	for _, entry in ipairs(tableForSpecies.entries) do
		if entry.index == colorIndex then
			return entry.rarity
		end
	end
	return nil
end

function HueRarity.roll(speciesId: string, rng: Random?): number
	local r = rng or Random.new()
	local tableForSpecies = BY_SPECIES[speciesId]
	if not tableForSpecies or tableForSpecies.total <= 0 then
		return r:NextInteger(PlotOutlineColors.MIN_INDEX, PlotOutlineColors.CORAL_MAX_INDEX)
	end
	local pick = r:NextInteger(1, tableForSpecies.total)
	local acc = 0
	for _, entry in ipairs(tableForSpecies.entries) do
		acc += entry.weight
		if pick <= acc then
			return entry.index
		end
	end
	return tableForSpecies.entries[#tableForSpecies.entries].index
end

return HueRarity
