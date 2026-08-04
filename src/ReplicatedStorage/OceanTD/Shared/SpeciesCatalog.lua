-- Species definitions (visual / place rules). Linked from ItemCatalog via speciesId — do not assume ItemId == SpeciesId forever.

export type SpeciesDef = {
	speciesId: string,
	itemId: string,
	displayName: string,
	diameter: number,
	material: Enum.Material,
	colorMin: Color3,
	colorMax: Color3,
	castShadow: boolean,
	canCollide: boolean,
	-- Client wave combat (optional; defaults applied by WaveSim).
	reloadSec: number?,
	foodFill: number?,
}

local SpeciesCatalog = {}

local BY_ID: { [string]: SpeciesDef } = {
	BrainCoral = {
		speciesId = "BrainCoral",
		itemId = "BrainCoral",
		displayName = "Brain Coral",
		diameter = 4,
		material = Enum.Material.Pebble,
		colorMin = Color3.fromRGB(255, 255, 0), -- #ffff00
		colorMax = Color3.fromRGB(255, 188, 33), -- #ffbc21
		castShadow = false,
		canCollide = false,
		reloadSec = 3, -- 50% slower than original 2s
		foodFill = 1,
	},
}

function SpeciesCatalog.get(speciesId: string): SpeciesDef?
	return BY_ID[speciesId]
end

function SpeciesCatalog.getByItemId(itemId: string): SpeciesDef?
	for _, def in pairs(BY_ID) do
		if def.itemId == itemId then
			return def
		end
	end
	return nil
end

function SpeciesCatalog.randomColor(def: SpeciesDef): Color3
	local t = math.random()
	return def.colorMin:Lerp(def.colorMax, t)
end

return SpeciesCatalog
