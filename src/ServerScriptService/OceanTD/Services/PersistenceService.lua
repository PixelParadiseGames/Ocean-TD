--!strict
-- DataStore load/save. Join/leave/autosave only. Anti-wipe on empty layout overwrite.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("Constants"))
local PlotTypes = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("PlotTypes"))

type PlayerProfile = PlotTypes.PlayerProfile
type LayoutObject = PlotTypes.LayoutObject

local PersistenceService = {}

local store: DataStore? = nil
local profiles: { [Player]: PlayerProfile } = {}
local intentionalClear: { [number]: boolean } = {} -- userId -> allow empty overwrite once

local function log(...: any)
	print("[PERSIST]", ...)
end

local function warnPersist(...: any)
	warn("[PERSIST]", ...)
end

local function getStore(): DataStore
	if store then
		return store
	end
	store = DataStoreService:GetDataStore(Constants.DATASTORE_NAME)
	return store :: DataStore
end

local function keyFor(userId: number): string
	return "u:" .. tostring(userId)
end

local function sanitizeProfile(raw: any): PlayerProfile
	local profile = PlotTypes.defaultProfile()
	if typeof(raw) ~= "table" then
		return profile
	end
	if typeof(raw.version) == "number" then
		profile.version = raw.version
	end
	if typeof(raw.currencies) == "table" then
		profile.currencies.sandDollars = tonumber(raw.currencies.sandDollars) or 0
		profile.currencies.gold = tonumber(raw.currencies.gold) or 0
	end
	if typeof(raw.inventory) == "table" then
		profile.inventory = raw.inventory
	end
	if typeof(raw.skillTree) == "table" then
		profile.skillTree = raw.skillTree
	end
	if typeof(raw.layout) == "table" then
		local layout: { LayoutObject } = {}
		for _, obj in ipairs(raw.layout) do
			if typeof(obj) == "table" and typeof(obj.id) == "string" then
				table.insert(layout, {
					id = obj.id,
					lx = tonumber(obj.lx) or 0,
					ly = tonumber(obj.ly) or 0,
					lz = tonumber(obj.lz) or 0,
				})
			end
		end
		profile.layout = layout
	end
	return profile
end

local function layoutCount(layout: { LayoutObject }): number
	return #layout
end

function PersistenceService.init()
	if RunService:IsStudio() then
		log("Studio mode — DataStores work if API access enabled in Game Settings.")
	end
	getStore()
	log("Using DataStore", Constants.DATASTORE_NAME)
end

function PersistenceService.getProfile(player: Player): PlayerProfile?
	return profiles[player]
end

-- Credit seed count in profile.inventory[itemId] (number). Used by recycle.
function PersistenceService.creditItem(player: Player, itemId: string, amount: number?): number
	local profile = profiles[player]
	if not profile or typeof(itemId) ~= "string" or itemId == "" then
		return 0
	end
	local add = math.max(1, math.floor(tonumber(amount) or 1))
	local inv = profile.inventory
	if typeof(inv) ~= "table" then
		inv = {}
		profile.inventory = inv
	end
	local cur = tonumber(inv[itemId]) or 0
	local nextCount = cur + add
	inv[itemId] = nextCount
	log("Credit", itemId, "x", add, "→", nextCount, "for", player.Name)
	return nextCount
end

function PersistenceService.allowIntentionalClear(userId: number)
	intentionalClear[userId] = true
end

function PersistenceService.load(player: Player): PlayerProfile
	local userId = player.UserId
	local profile = PlotTypes.defaultProfile()

	local ok, result = pcall(function()
		return getStore():GetAsync(keyFor(userId))
	end)

	if not ok then
		warnPersist("GetAsync failed for", userId, result)
		profiles[player] = profile
		log("Load fallback empty profile userId=", userId, "layout=0")
		return profile
	end

	profile = sanitizeProfile(result)
	profiles[player] = profile
	log("Load userId=", userId, "layout=", layoutCount(profile.layout), "sandDollars=", profile.currencies.sandDollars, "gold=", profile.currencies.gold)
	return profile
end

-- UpdateAsync with anti-wipe: refuse empty layout overwrite of non-empty stored layout
-- unless intentional clear flag is set for this userId.
function PersistenceService.save(player: Player, layoutOverride: { LayoutObject }?): boolean
	local profile = profiles[player]
	if not profile then
		warnPersist("Save skipped — no in-memory profile for", player.Name)
		return false
	end

	if layoutOverride ~= nil then
		profile.layout = layoutOverride
	end

	local userId = player.UserId
	local toWrite = {
		version = profile.version,
		currencies = {
			sandDollars = profile.currencies.sandDollars,
			gold = profile.currencies.gold,
		},
		inventory = profile.inventory,
		skillTree = profile.skillTree,
		layout = profile.layout,
	}

	local saved = false
	local blocked = false

	local ok, err = pcall(function()
		getStore():UpdateAsync(keyFor(userId), function(old)
			local oldProfile = sanitizeProfile(old)
			local newCount = layoutCount(toWrite.layout)
			local oldCount = layoutCount(oldProfile.layout)

			if newCount == 0 and oldCount > 0 then
				if intentionalClear[userId] then
					intentionalClear[userId] = nil
					log("Intentional clear allowed userId=", userId, "oldLayout=", oldCount)
				else
					blocked = true
					warnPersist("Anti-wipe blocked empty overwrite userId=", userId, "oldLayout=", oldCount)
					-- Keep old layout; still update wallet/stubs.
					toWrite.layout = oldProfile.layout
				end
			end

			saved = true
			return toWrite
		end)
	end)

	if not ok then
		warnPersist("UpdateAsync failed for", userId, err)
		return false
	end

	log("Save userId=", userId, "layout=", layoutCount(toWrite.layout), "blockedEmptyWipe=", blocked)
	return saved
end

function PersistenceService.release(player: Player)
	profiles[player] = nil
end

return PersistenceService
