-- Item catalog — backpack icons / ids. `speciesId` links to SpeciesCatalog for place visuals.

export type ItemDef = {
	id: string,
	displayName: string,
	icon: string,
	category: string, -- "Coral" | "Sponge" | "Seagrass" | "Critter" | ...
	sortOrder: number,
	speciesId: string?,
	-- Backpack class group title (Long Range / Fast Reload / Balanced).
	coralClass: string?,
}

export type CoralSection = {
	title: string,
	ids: { string },
}

local ItemCatalog = {}

local BRAIN_ICON = "rbxassetid://137897292847744"
local SPONGE_ICON = "rbxassetid://130951757133075"

-- Backpack section order + membership (stats per class come later).
ItemCatalog.CORAL_SECTIONS = {
	{ title = "Long Range", ids = { "TreeCoral", "SeaGrass" } },
	{ title = "Fast Reload", ids = { "Zoas", "FireCoral" } },
	{ title = "Balanced", ids = { "SeaFan", "LeatherCoral", "BrainCoral", "Sponge" } },
} :: { CoralSection }

local BY_ID: { [string]: ItemDef } = {
	TreeCoral = {
		id = "TreeCoral",
		displayName = "Tree Coral",
		icon = "rbxassetid://114115102333521",
		category = "Coral",
		sortOrder = 10,
		speciesId = "TreeCoral",
		coralClass = "Long Range",
	},
	SeaGrass = {
		id = "SeaGrass",
		displayName = "Sea Grass",
		icon = "rbxassetid://112749189598621",
		category = "Seagrass",
		sortOrder = 20,
		speciesId = "SeaGrass",
		coralClass = "Long Range",
	},
	Zoas = {
		id = "Zoas",
		displayName = "Zoas",
		icon = "rbxassetid://109884804548206",
		category = "Coral",
		sortOrder = 30,
		speciesId = "Zoas",
		coralClass = "Fast Reload",
	},
	FireCoral = {
		id = "FireCoral",
		displayName = "Fire Coral",
		icon = "rbxassetid://131053731672950",
		category = "Coral",
		sortOrder = 40,
		speciesId = "FireCoral",
		coralClass = "Fast Reload",
	},
	SeaFan = {
		id = "SeaFan",
		displayName = "Sea Fan",
		icon = "rbxassetid://105276585485138",
		category = "Coral",
		sortOrder = 50,
		speciesId = "SeaFan",
		coralClass = "Balanced",
	},
	LeatherCoral = {
		id = "LeatherCoral",
		displayName = "Leather Coral",
		icon = "rbxassetid://136151370827546",
		category = "Coral",
		sortOrder = 60,
		speciesId = "LeatherCoral",
		coralClass = "Balanced",
	},
	BrainCoral = {
		id = "BrainCoral",
		displayName = "Brain Coral",
		icon = BRAIN_ICON,
		category = "Coral",
		sortOrder = 70,
		speciesId = "BrainCoral",
		coralClass = "Balanced",
	},
	Sponge = {
		id = "Sponge",
		displayName = "Sponge",
		icon = SPONGE_ICON,
		category = "Sponge",
		sortOrder = 80,
		speciesId = "Sponge",
		coralClass = "Balanced",
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
