--!strict
--[[
	Random coral seed pool + paint swatches for the prize-wheel grant UI.
	Colors = PlotOutlineColors coral 1–14.
]]

local ItemCatalog = require(script.Parent:WaitForChild("ItemCatalog"))
local PlotOutlineColors = require(script.Parent:WaitForChild("PlotOutlineColors"))

local SeedWheel = {}

local POOL: { string } = {
	"BrainCoral",
	"Sponge",
	"SeaGrass",
	"FireCoral",
	"Zoas",
	"TreeCoral",
	"LeatherCoral",
	"SeaFan",
}

function SeedWheel.pool(): { string }
	return POOL
end

function SeedWheel.isWheelItem(itemId: string): boolean
	for _, id in ipairs(POOL) do
		if id == itemId then
			return true
		end
	end
	return false
end

function SeedWheel.pickRandom(rng: Random?): string
	local r = rng or Random.new()
	return POOL[r:NextInteger(1, #POOL)]
end

function SeedWheel.pickRandomColorIndex(rng: Random?): number
	local r = rng or Random.new()
	return r:NextInteger(PlotOutlineColors.MIN_INDEX, PlotOutlineColors.CORAL_MAX_INDEX)
end

function SeedWheel.colorIndices(): { number }
	local out: { number } = {}
	for i = PlotOutlineColors.MIN_INDEX, PlotOutlineColors.CORAL_MAX_INDEX do
		table.insert(out, i)
	end
	return out
end

function SeedWheel.iconFor(itemId: string): string?
	local def = ItemCatalog.get(itemId)
	return if def then def.icon else nil
end

function SeedWheel.colorForIndex(index: number): Color3
	return PlotOutlineColors.coralColor(index)
end

return SeedWheel
