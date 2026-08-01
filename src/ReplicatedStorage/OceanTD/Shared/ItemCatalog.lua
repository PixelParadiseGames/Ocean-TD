-- Item catalog — backpack icons / ids. `speciesId` links to SpeciesCatalog for place visuals.

export type ItemDef = {
	id: string,
	displayName: string,
	icon: string,
	category: string, -- "Coral" | "Sponge" | "Critter" | ...
	sortOrder: number,
	speciesId: string?,
}

local ItemCatalog = {}

local BY_ID: { [string]: ItemDef } = {
	BrainCoral = {
		id = "BrainCoral",
		displayName = "Brain Coral",
		icon = "rbxassetid://137897292847744",
		category = "Coral",
		sortOrder = 10,
		speciesId = "BrainCoral", -- links to SpeciesCatalog; may diverge later
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
