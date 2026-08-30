--!strict
--[[
	Per-coral paint color unlocks (PlotOutlineColors indices 1–14).
	Profile shape: coralColorUnlocks[itemId][tostring(index)] = true
]]

local ItemCatalog = require(script.Parent:WaitForChild("ItemCatalog"))
local PlotOutlineColors = require(script.Parent:WaitForChild("PlotOutlineColors"))
local SeedWheel = require(script.Parent:WaitForChild("SeedWheel"))

local ColorUnlocks = {}

ColorUnlocks.LOCK_ICON = "rbxassetid://136120555834466"
ColorUnlocks.UNLOCK_COST = 10

export type UnlockMap = { [string]: { [string]: boolean } }

local function indexKey(colorIndex: number): string
	return tostring(PlotOutlineColors.clampCoralIndex(colorIndex))
end

function ColorUnlocks.sanitize(raw: any): UnlockMap
	local out: UnlockMap = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for itemId, set in pairs(raw) do
		if typeof(itemId) == "string" and ItemCatalog.get(itemId) and typeof(set) == "table" then
			local bucket: { [string]: boolean } = {}
			for k, v in pairs(set) do
				if v == true then
					local idx = tonumber(k)
					if typeof(idx) == "number" then
						bucket[indexKey(idx)] = true
					end
				end
			end
			if next(bucket) then
				out[itemId] = bucket
			end
		end
	end
	return out
end

function ColorUnlocks.isUnlocked(map: UnlockMap, itemId: string, colorIndex: number): boolean
	if typeof(itemId) ~= "string" or itemId == "" then
		return false
	end
	local set = map[itemId]
	if typeof(set) ~= "table" then
		return false
	end
	return set[indexKey(colorIndex)] == true
end

function ColorUnlocks.markUnlocked(map: UnlockMap, itemId: string, colorIndex: number): UnlockMap
	local idx = PlotOutlineColors.clampCoralIndex(colorIndex)
	if not map[itemId] then
		map[itemId] = {}
	end
	map[itemId][indexKey(idx)] = true
	return map
end

function ColorUnlocks.displayName(colorIndex: number): string
	local sw = PlotOutlineColors.get(PlotOutlineColors.clampCoralIndex(colorIndex))
	local name = sw.name or "Color"
	return string.upper(string.sub(name, 1, 1)) .. string.sub(name, 2)
end

function ColorUnlocks.isWheelItem(itemId: string): boolean
	return SeedWheel.isWheelItem(itemId)
end

return ColorUnlocks
