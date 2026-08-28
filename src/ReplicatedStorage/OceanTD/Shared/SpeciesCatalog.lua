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
	-- Mesh folder under ReplicatedStorage.Coral (e.g. "Sponge").
	meshFolder: string?,
	-- Default paint palette index (PlotOutlineColors coral 1–14).
	defaultColorIndex: number?,
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
		canCollide = true,
		reloadSec = 6, -- half as fast as previous 3s (original was 2s)
		foodFill = 1,
		defaultColorIndex = 9, -- yellow
	},
	Sponge = {
		speciesId = "Sponge",
		itemId = "Sponge",
		displayName = "Sponge",
		diameter = 4,
		material = Enum.Material.Pebble,
		colorMin = Color3.fromRGB(120, 60, 180),
		colorMax = Color3.fromRGB(170, 90, 230),
		castShadow = false,
		canCollide = true,
		reloadSec = 6,
		foodFill = 1,
		meshFolder = "Sponge",
		defaultColorIndex = 5, -- purple
	},
	SeaGrass = {
		speciesId = "SeaGrass",
		itemId = "SeaGrass",
		displayName = "Sea Grass",
		diameter = 4,
		material = Enum.Material.Pebble,
		-- Fallback tint if mesh has no Color; place uses imported mesh green by default.
		colorMin = Color3.fromRGB(40, 140, 55),
		colorMax = Color3.fromRGB(70, 180, 80),
		castShadow = false,
		-- Mesh itself is non-collidable; OceanTD_Climb TrussPart is the only collider.
		canCollide = false,
		reloadSec = 6, -- same as BrainCoral for now
		foodFill = 1,
		meshFolder = "Seagrass",
		defaultColorIndex = 11, -- green
	},
	FireCoral = {
		speciesId = "FireCoral",
		itemId = "FireCoral",
		displayName = "Fire Coral",
		diameter = 4,
		material = Enum.Material.Pebble, -- unused for mesh; Studio Material kept
		-- Fallback only; first place keeps imported mesh Color/Material.
		colorMin = Color3.fromRGB(200, 60, 30),
		colorMax = Color3.fromRGB(255, 110, 40),
		castShadow = false,
		canCollide = true, -- walkable; Elasticity forced to 0 in CoralVisual
		reloadSec = 6,
		foodFill = 1,
		meshFolder = "Fire Coral", -- Studio: ReplicatedStorage.Coral["Fire Coral"]
		defaultColorIndex = 1, -- warm; paint later — spawn uses template color
	},
	Zoas = {
		speciesId = "Zoas",
		itemId = "Zoas",
		displayName = "Zoas",
		diameter = 4,
		material = Enum.Material.Pebble,
		colorMin = Color3.fromRGB(180, 50, 80),
		colorMax = Color3.fromRGB(255, 120, 160),
		castShadow = false,
		canCollide = true,
		reloadSec = 6,
		foodFill = 1,
		meshFolder = "Zoas", -- ReplicatedStorage.Coral.Zoas
		defaultColorIndex = 1,
	},
	TreeCoral = {
		speciesId = "TreeCoral",
		itemId = "TreeCoral",
		displayName = "Tree Coral",
		diameter = 4,
		material = Enum.Material.Pebble,
		colorMin = Color3.fromRGB(60, 120, 70),
		colorMax = Color3.fromRGB(100, 180, 90),
		castShadow = false,
		canCollide = true,
		reloadSec = 6,
		foodFill = 1,
		meshFolder = "TreeCoral", -- ReplicatedStorage.Coral.TreeCoral
		defaultColorIndex = 11, -- green stem; accent from template / paint
	},
	LeatherCoral = {
		speciesId = "LeatherCoral",
		itemId = "LeatherCoral",
		displayName = "Leather Coral",
		diameter = 4,
		material = Enum.Material.Pebble,
		colorMin = Color3.fromRGB(130, 85, 55),
		colorMax = Color3.fromRGB(195, 140, 95),
		castShadow = false,
		canCollide = true,
		reloadSec = 6,
		foodFill = 1,
		meshFolder = "Leather", -- ReplicatedStorage.Coral.Leather
		defaultColorIndex = 1,
	},
	SeaFan = {
		speciesId = "SeaFan",
		itemId = "SeaFan",
		displayName = "Sea Fan",
		diameter = 4,
		material = Enum.Material.Pebble,
		-- Fallback only; first place keeps imported Stem/Web colors.
		colorMin = Color3.fromRGB(200, 90, 60),
		colorMax = Color3.fromRGB(255, 140, 90),
		castShadow = false,
		canCollide = true,
		reloadSec = 6,
		foodFill = 1,
		meshFolder = "Seafan",
		defaultColorIndex = 7, -- pumpkin
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
