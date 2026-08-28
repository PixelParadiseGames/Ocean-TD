-- Item catalog — backpack icons / ids. `speciesId` links to SpeciesCatalog for place visuals.

export type ItemDef = {
	id: string,
	displayName: string,
	icon: string,
	category: string, -- "Coral" | "Sponge" | "Seagrass" | "Critter" | ...
	sortOrder: number,
	speciesId: string?,
}

local ItemCatalog = {}

local BRAIN_ICON = "rbxassetid://137897292847744"
local SPONGE_ICON = "rbxassetid://130951757133075"

local BY_ID: { [string]: ItemDef } = {
	BrainCoral = {
		id = "BrainCoral",
		displayName = "Brain Coral",
		icon = BRAIN_ICON,
		category = "Coral",
		sortOrder = 10,
		speciesId = "BrainCoral",
	},
	Sponge = {
		id = "Sponge",
		displayName = "Sponge",
		icon = SPONGE_ICON,
		category = "Sponge",
		sortOrder = 20,
		speciesId = "Sponge",
	},
	SeaGrass = {
		id = "SeaGrass",
		displayName = "Sea Grass",
		icon = "rbxassetid://112749189598621",
		category = "Seagrass",
		sortOrder = 30,
		speciesId = "SeaGrass",
	},
	FireCoral = {
		id = "FireCoral",
		displayName = "Fire Coral",
		icon = "rbxassetid://119869570909704",
		category = "Coral",
		sortOrder = 35, -- before Sea Fan
		speciesId = "FireCoral",
	},
	Zoas = {
		id = "Zoas",
		displayName = "Zoas",
		icon = "rbxassetid://109884804548206",
		category = "Coral",
		sortOrder = 36,
		speciesId = "Zoas",
	},
	SeaFan = {
		id = "SeaFan",
		displayName = "Sea Fan",
		icon = "rbxassetid://105276585485138",
		category = "Coral",
		sortOrder = 40,
		speciesId = "SeaFan",
	},
}

function ItemCatalog.get(id: string): ItemDef?
	return BY_ID[id]
end

function ItemCatalog.all(): { ItemDef }
	local list: { ItemDef } = {}
	for _, def in pairs(BY_ID) do
		table.insert(list, def)
	end
	table.sort(list, function(a, b)
		if a.sortOrder == b.sortOrder then
			return a.displayName < b.displayName
		end
		return a.sortOrder < b.sortOrder
	end)
	return list
end

function ItemCatalog.register(def: ItemDef)
	assert(typeof(def.id) == "string" and def.id ~= "", "ItemCatalog.register requires id")
	BY_ID[def.id] = def
end

return ItemCatalog
