--!strict
-- DataStore load/save. Join/leave/autosave only. Anti-wipe on empty layout overwrite.
-- Active plot-save slot receives layout snapshots; all four slots persist with the profile.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("Constants"))
local PlotTypes = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("PlotTypes"))

type PlayerProfile = PlotTypes.PlayerProfile
type LayoutObject = PlotTypes.LayoutObject
type PlotSaveSlot = PlotTypes.PlotSaveSlot
type PlotSaves = PlotTypes.PlotSaves

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

local function sanitizeLayout(raw: any): { LayoutObject }
	local layout: { LayoutObject } = {}
	if typeof(raw) ~= "table" then
		return layout
	end
	for _, obj in ipairs(raw) do
		if typeof(obj) == "table" and typeof(obj.id) == "string" then
			table.insert(layout, {
				id = obj.id,
				lx = tonumber(obj.lx) or 0,
				ly = tonumber(obj.ly) or 0,
				lz = tonumber(obj.lz) or 0,
			})
		end
	end
	return layout
end

local function cloneLayout(layout: { LayoutObject }): { LayoutObject }
	local out: { LayoutObject } = {}
	for _, obj in ipairs(layout) do
		table.insert(out, {
			id = obj.id,
			lx = obj.lx,
			ly = obj.ly,
			lz = obj.lz,
		})
	end
	return out
end

local function sanitizePlotSaves(raw: any, legacyLayout: { LayoutObject }): PlotSaves
	local defaults = PlotTypes.defaultPlotSaves()
	if typeof(raw) ~= "table" then
		-- Migrate pre-plotSaves profiles: live layout becomes slot 1.
		defaults.slots[1].layout = cloneLayout(legacyLayout)
		defaults.slots[1].saved = true
		defaults.activeIndex = 1
		return defaults
	end

	local activeIndex = math.clamp(math.floor(tonumber(raw.activeIndex) or 1), 1, Constants.PLOT_SAVE_SLOT_COUNT)
	local slots: { PlotSaveSlot } = {}
	local rawSlots = raw.slots
	for i = 1, Constants.PLOT_SAVE_SLOT_COUNT do
		local src = if typeof(rawSlots) == "table" then rawSlots[i] else nil
		local name = PlotTypes.defaultSlotName(i)
		local saved = i == 1
		local layout: { LayoutObject } = {}
		if typeof(src) == "table" then
			if typeof(src.name) == "string" and src.name ~= "" then
				name = string.sub(src.name, 1, 24)
			end
			if src.saved == true then
				saved = true
			elseif src.saved == false then
				saved = false
			end
			layout = sanitizeLayout(src.layout)
			if #layout > 0 then
				saved = true
			end
		elseif i == 1 and #legacyLayout > 0 then
			layout = cloneLayout(legacyLayout)
			saved = true
		end
		table.insert(slots, {
			name = name,
			saved = saved,
			layout = layout,
		})
	end

	-- Ensure active slot mirrors legacy layout when migrating partial data.
	if #slots[activeIndex].layout == 0 and #legacyLayout > 0 and activeIndex == 1 then
		slots[1].layout = cloneLayout(legacyLayout)
		slots[1].saved = true
	end

	return {
		activeIndex = activeIndex,
		slots = slots,
	}
end

local function sanitizeInventory(raw: any, isNewProfile: boolean): { [string]: any }
	if typeof(raw) ~= "table" then
		if isNewProfile then
			return {
				BrainCoral = Constants.STARTING_BRAIN_CORAL_SEEDS,
			}
		end
		return {}
	end
	local inv: { [string]: any } = {}
	for k, v in pairs(raw) do
		if typeof(k) == "string" then
			inv[k] = v
		end
	end
	return inv
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
	local hadInventoryKey = typeof(raw.inventory) == "table"
	-- Brand-new store miss uses defaultProfile seeds; existing empty inventory stays empty
	-- (placed corals already "spent" those seeds onto the plot).
	if hadInventoryKey then
		profile.inventory = sanitizeInventory(raw.inventory, false)
	elseif raw.layout ~= nil or raw.plotSaves ~= nil then
		profile.inventory = {}
	else
		profile.inventory = sanitizeInventory(nil, true)
	end
	if typeof(raw.skillTree) == "table" then
		profile.skillTree = raw.skillTree
	end
	profile.layout = sanitizeLayout(raw.layout)
	profile.plotSaves = sanitizePlotSaves(raw.plotSaves, profile.layout)
	-- Live layout is always the active slot's layout.
	local active = profile.plotSaves.slots[profile.plotSaves.activeIndex]
	if active then
		profile.layout = cloneLayout(active.layout)
	end
	profile.version = math.max(profile.version, Constants.PROFILE_VERSION)
	return profile
end

local function layoutCount(layout: { LayoutObject }): number
	return #layout
end

local function syncActiveLayout(profile: PlayerProfile)
	local idx = profile.plotSaves.activeIndex
	local slot = profile.plotSaves.slots[idx]
	if not slot then
		return
	end
	slot.layout = cloneLayout(profile.layout)
	slot.saved = true
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

function PersistenceService.getActiveSlotIndex(player: Player): number
	local profile = profiles[player]
	if not profile then
		return 1
	end
	return profile.plotSaves.activeIndex
end

function PersistenceService.getPlotSaves(player: Player): PlotSaves?
	local profile = profiles[player]
	if not profile then
		return nil
	end
	return profile.plotSaves
end

function PersistenceService.setActiveSlotIndex(player: Player, index: number): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	local idx = math.clamp(math.floor(index), 1, Constants.PLOT_SAVE_SLOT_COUNT)
	profile.plotSaves.activeIndex = idx
	local slot = profile.plotSaves.slots[idx]
	if slot then
		profile.layout = cloneLayout(slot.layout)
	end
	return true
end

function PersistenceService.writeSlotLayout(player: Player, index: number, layout: { LayoutObject }, markSaved: boolean?): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	local idx = math.clamp(math.floor(index), 1, Constants.PLOT_SAVE_SLOT_COUNT)
	local slot = profile.plotSaves.slots[idx]
	if not slot then
		return false
	end
	slot.layout = cloneLayout(layout)
	if markSaved ~= false then
		slot.saved = true
	end
	if idx == profile.plotSaves.activeIndex then
		profile.layout = cloneLayout(layout)
	end
	return true
end

function PersistenceService.renameSlot(player: Player, index: number, name: string): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	local idx = math.clamp(math.floor(index), 1, Constants.PLOT_SAVE_SLOT_COUNT)
	local slot = profile.plotSaves.slots[idx]
	if not slot then
		return false
	end
	local cleaned = string.gsub(name, "%s+", " ")
	cleaned = string.match(cleaned, "^%s*(.-)%s*$") or cleaned
	if cleaned == "" then
		cleaned = PlotTypes.defaultSlotName(idx)
	end
	slot.name = string.sub(cleaned, 1, 24)
	return true
end

-- Credit seed count in profile.inventory[itemId] (number). Used by recycle / clear / load swap.
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

-- Debit seed count (floor at 0). Used when undoing a recycle credit / consuming on place.
function PersistenceService.debitItem(player: Player, itemId: string, amount: number?): number
	local profile = profiles[player]
	if not profile or typeof(itemId) ~= "string" or itemId == "" then
		return 0
	end
	local sub = math.max(1, math.floor(tonumber(amount) or 1))
	local inv = profile.inventory
	if typeof(inv) ~= "table" then
		inv = {}
		profile.inventory = inv
	end
	local cur = tonumber(inv[itemId]) or 0
	local nextCount = math.max(0, cur - sub)
	inv[itemId] = nextCount
	log("Debit", itemId, "x", sub, "→", nextCount, "for", player.Name)
	return nextCount
end

-- Returns false if the player does not have enough seeds.
function PersistenceService.tryDebitItem(player: Player, itemId: string, amount: number?): (boolean, number)
	local profile = profiles[player]
	if not profile or typeof(itemId) ~= "string" or itemId == "" then
		return false, 0
	end
	local sub = math.max(1, math.floor(tonumber(amount) or 1))
	local inv = profile.inventory
	if typeof(inv) ~= "table" then
		inv = {}
		profile.inventory = inv
	end
	local cur = tonumber(inv[itemId]) or 0
	if cur < sub then
		return false, cur
	end
	local nextCount = cur - sub
	inv[itemId] = nextCount
	log("TryDebit", itemId, "x", sub, "→", nextCount, "for", player.Name)
	return true, nextCount
end

function PersistenceService.getItemCount(player: Player, itemId: string): number
	local profile = profiles[player]
	if not profile or typeof(itemId) ~= "string" then
		return 0
	end
	local inv = profile.inventory
	if typeof(inv) ~= "table" then
		return 0
	end
	return tonumber(inv[itemId]) or 0
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

	if result == nil then
		profiles[player] = profile
		log("Load new profile userId=", userId, "layout=0", "seeds=", Constants.STARTING_BRAIN_CORAL_SEEDS)
		return profile
	end

	profile = sanitizeProfile(result)
	-- Soft grant: empty plot + no BrainCoral seeds → starter pack (Studio infinite-place leftovers).
	if #profile.layout == 0 then
		local inv = profile.inventory
		if typeof(inv) ~= "table" then
			inv = {}
			profile.inventory = inv
		end
		if (tonumber(inv.BrainCoral) or 0) <= 0 then
			inv.BrainCoral = Constants.STARTING_BRAIN_CORAL_SEEDS
			log("Starter BrainCoral grant userId=", userId, "x", Constants.STARTING_BRAIN_CORAL_SEEDS)
		end
	end
	profiles[player] = profile
	log(
		"Load userId=",
		userId,
		"layout=",
		layoutCount(profile.layout),
		"activeSlot=",
		profile.plotSaves.activeIndex,
		"sandDollars=",
		profile.currencies.sandDollars,
		"gold=",
		profile.currencies.gold
	)
	return profile
end

-- UpdateAsync with anti-wipe: refuse empty layout overwrite of non-empty stored layout
-- unless intentional clear flag is set for this userId.
-- layoutOverride snapshots the live grid into the active plot-save slot.
function PersistenceService.save(player: Player, layoutOverride: { LayoutObject }?): boolean
	local profile = profiles[player]
	if not profile then
		warnPersist("Save skipped — no in-memory profile for", player.Name)
		return false
	end

	if layoutOverride ~= nil then
		profile.layout = layoutOverride
		syncActiveLayout(profile)
	else
		syncActiveLayout(profile)
	end

	local userId = player.UserId
	local slotsOut = {}
	for i, slot in ipairs(profile.plotSaves.slots) do
		slotsOut[i] = {
			name = slot.name,
			saved = slot.saved == true,
			layout = cloneLayout(slot.layout),
		}
	end
	local toWrite = {
		version = profile.version,
		currencies = {
			sandDollars = profile.currencies.sandDollars,
			gold = profile.currencies.gold,
		},
		inventory = profile.inventory,
		skillTree = profile.skillTree,
		layout = profile.layout,
		plotSaves = {
			activeIndex = profile.plotSaves.activeIndex,
			slots = slotsOut,
		},
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
					-- Keep old live layout + active slot; still update wallet / other slots.
					toWrite.layout = oldProfile.layout
					toWrite.plotSaves.slots[toWrite.plotSaves.activeIndex].layout = cloneLayout(oldProfile.layout)
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

	log(
		"Save userId=",
		userId,
		"layout=",
		layoutCount(toWrite.layout),
		"activeSlot=",
		toWrite.plotSaves.activeIndex,
		"blockedEmptyWipe=",
		blocked
	)
	return saved
end

function PersistenceService.release(player: Player)
	profiles[player] = nil
end

return PersistenceService
