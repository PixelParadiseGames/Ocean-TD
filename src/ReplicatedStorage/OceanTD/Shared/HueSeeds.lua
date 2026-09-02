--!strict
--[[
	Hue-specific coral seeds: inventory[itemId][tostring(colorIndex)] = count.
	Each seed lets you place one coral (default look) and assign that hue up to owned cap.
]]

local ItemCatalog = require(script.Parent:WaitForChild("ItemCatalog"))
local PlotOutlineColors = require(script.Parent:WaitForChild("PlotOutlineColors"))
local ColorUnlocks = require(script.Parent:WaitForChild("ColorUnlocks"))

local HueSeeds = {}

export type HueInventory = { [string]: { [string]: number } }

HueSeeds.SEED_COST = ColorUnlocks.UNLOCK_COST

local function indexKey(colorIndex: number): string
	return tostring(PlotOutlineColors.clampCoralIndex(colorIndex))
end

local function isLegacyFlatEntry(v: any): boolean
	return typeof(v) == "number"
end

function HueSeeds.isHueItem(itemId: string): boolean
	return ColorUnlocks.isWheelItem(itemId)
end

function HueSeeds.sanitize(raw: any, wipeLegacy: boolean?): HueInventory
	local wipe = wipeLegacy == true
	local out: HueInventory = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for itemId, bucket in pairs(raw) do
		if typeof(itemId) ~= "string" or not ItemCatalog.get(itemId) then
			continue
		end
		if isLegacyFlatEntry(bucket) then
			if wipe then
				continue
			end
			-- Preserve unknown legacy rows as empty (migration wipe handled upstream).
			continue
		end
		if typeof(bucket) ~= "table" then
			continue
		end
		local hues: { [string]: number } = {}
		for k, v in pairs(bucket) do
			local idx = tonumber(k)
			local n = tonumber(v)
			if typeof(idx) == "number" and typeof(n) == "number" and n == n then
				local count = math.max(0, math.floor(n))
				if count > 0 then
					hues[indexKey(idx)] = count
				end
			end
		end
		if next(hues) then
			out[itemId] = hues
		end
	end
	return out
end

function HueSeeds.hasLegacyFlatInventory(raw: any): boolean
	if typeof(raw) ~= "table" then
		return false
	end
	for _, v in pairs(raw) do
		if isLegacyFlatEntry(v) then
			return true
		end
	end
	return false
end

function HueSeeds.ensureBucket(inv: HueInventory, itemId: string): { [string]: number }
	local bucket = inv[itemId]
	if typeof(bucket) ~= "table" then
		bucket = {}
		inv[itemId] = bucket
	end
	return bucket
end

function HueSeeds.getCount(inv: HueInventory, itemId: string, colorIndex: number): number
	if typeof(itemId) ~= "string" or itemId == "" then
		return 0
	end
	local bucket = inv[itemId]
	if typeof(bucket) ~= "table" then
		return 0
	end
	return math.max(0, math.floor(tonumber(bucket[indexKey(colorIndex)]) or 0))
end

function HueSeeds.getSpeciesTotal(inv: HueInventory, itemId: string): number
	if typeof(itemId) ~= "string" or itemId == "" then
		return 0
	end
	local bucket = inv[itemId]
	if typeof(bucket) ~= "table" then
		return 0
	end
	local sum = 0
	for _, v in pairs(bucket) do
		local n = tonumber(v)
		if typeof(n) == "number" and n == n then
			sum += math.max(0, math.floor(n))
		end
	end
	return sum
end

function HueSeeds.credit(inv: HueInventory, itemId: string, colorIndex: number, amount: number?): number
	local add = math.max(1, math.floor(tonumber(amount) or 1))
	local bucket = HueSeeds.ensureBucket(inv, itemId)
	local key = indexKey(colorIndex)
	local cur = math.max(0, math.floor(tonumber(bucket[key]) or 0))
	local nextCount = cur + add
	bucket[key] = nextCount
	return nextCount
end

function HueSeeds.tryDebit(inv: HueInventory, itemId: string, colorIndex: number, amount: number?): (boolean, number)
	local sub = math.max(1, math.floor(tonumber(amount) or 1))
	local bucket = HueSeeds.ensureBucket(inv, itemId)
	local key = indexKey(colorIndex)
	local cur = math.max(0, math.floor(tonumber(bucket[key]) or 0))
	if cur < sub then
		return false, cur
	end
	local nextCount = cur - sub
	bucket[key] = nextCount
	if nextCount <= 0 then
		bucket[key] = nil
		if not next(bucket) then
			inv[itemId] = nil
		end
	end
	return true, nextCount
end

function HueSeeds.toClientPayload(inv: HueInventory): { [string]: { [string]: number } }
	local out: { [string]: { [string]: number } } = {}
	for itemId, bucket in pairs(inv) do
		if typeof(itemId) == "string" and typeof(bucket) == "table" then
			local copy: { [string]: number } = {}
			for k, v in pairs(bucket) do
				local n = tonumber(v)
				if typeof(n) == "number" and n == n then
					copy[k] = math.max(0, math.floor(n))
				end
			end
			if next(copy) then
				out[itemId] = copy
			end
		end
	end
	return out
end

function HueSeeds.ownedHueIndices(inv: HueInventory, itemId: string): { number }
	local list: { number } = {}
	local bucket = inv[itemId]
	if typeof(bucket) ~= "table" then
		return list
	end
	for k, v in pairs(bucket) do
		local idx = tonumber(k)
		local n = tonumber(v)
		if typeof(idx) == "number" and typeof(n) == "number" and n > 0 then
			table.insert(list, PlotOutlineColors.clampCoralIndex(idx))
		end
	end
	table.sort(list)
	return list
end

function HueSeeds.pickFirstOwnedHue(inv: HueInventory, itemId: string): number?
	local owned = HueSeeds.ownedHueIndices(inv, itemId)
	if #owned == 0 then
		return nil
	end
	return owned[1]
end

return HueSeeds
