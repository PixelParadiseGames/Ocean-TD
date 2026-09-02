--!strict
-- DataStore load/save. Join/leave/autosave only. Anti-wipe on empty layout overwrite.
-- Active plot-save slot receives layout snapshots; all four slots persist with the profile.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Constants = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("Constants"))
local PlotTypes = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("PlotTypes"))
local PlotOutlineColors = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("PlotOutlineColors"))
local ColorUnlocks = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("ColorUnlocks"))
local HueSeeds = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("HueSeeds"))
local HideUiUnlock = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("HideUiUnlock"))
local SkillStages = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("SkillStages"))
local SeedWheel = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("SeedWheel"))
local Remotes = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Remotes"))

type PlayerProfile = PlotTypes.PlayerProfile
type LayoutObject = PlotTypes.LayoutObject
type PlotSaveSlot = PlotTypes.PlotSaveSlot
type PlotSaves = PlotTypes.PlotSaves
type ProcessedReceipt = PlotTypes.ProcessedReceipt

local PersistenceService = {}

local store: DataStore? = nil
local profiles: { [Player]: PlayerProfile } = {}
local intentionalClear: { [number]: boolean } = {} -- userId -> allow empty overwrite once
-- GetAsync failed: session may play, but we must not persist (would write $D = 0).
local loadFailed: { [Player]: boolean } = {}
-- Anti-spam for client-reported fish fills (count this second).
local feedRate: { [Player]: { t0: number, count: number } } = {}
local FEED_MAX_PER_SEC = 40

local function log(...: any)
	print("[PERSIST]", ...)
end

local function warnPersist(...: any)
	warn("[PERSIST]", ...)
end

local function isTransientDataStoreError(err: any): boolean
	local msg = string.lower(tostring(err))
	return string.find(msg, "502", 1, true) ~= nil
		or string.find(msg, "internal server", 1, true) ~= nil
		or string.find(msg, "internalserver", 1, true) ~= nil
		or string.find(msg, "timeout", 1, true) ~= nil
		or string.find(msg, "throttl", 1, true) ~= nil
		or string.find(msg, "429", 1, true) ~= nil
		or string.find(msg, "busy", 1, true) ~= nil
end

local function getStore(): DataStore
	if store then
		return store
	end
	store = DataStoreService:GetDataStore(Constants.DATASTORE_NAME)
	return store :: DataStore
end

-- Studio / cloud blips (502) are common; retry a few times before failing the save/load.
local function withDataStoreRetry(label: string, userId: number, fn: () -> any): (boolean, any)
	local attempts = 4
	local delaySec = 0.4
	local lastErr: any = nil
	for attempt = 1, attempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		if attempt < attempts and isTransientDataStoreError(result) then
			warnPersist(label, "transient fail for", userId, "attempt", attempt, "/", attempts, result)
			task.wait(delaySec)
			delaySec = math.min(delaySec * 2, 3)
		else
			break
		end
	end
	return false, tostring(lastErr)
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
			local entry: LayoutObject = {
				id = obj.id,
				lx = tonumber(obj.lx) or 0,
				ly = tonumber(obj.ly) or 0,
				lz = tonumber(obj.lz) or 0,
			}
			local gx = tonumber(obj.gx)
			local gy = tonumber(obj.gy)
			local gz = tonumber(obj.gz)
			if gx and gy and gz then
				entry.gx = math.round(gx)
				entry.gy = math.round(gy)
				entry.gz = math.round(gz)
			end
			local diameter = tonumber(obj.diameter)
			if diameter and diameter > 0 then
				entry.diameter = diameter
			end
			local sizeTier = tonumber(obj.sizeTier)
			if sizeTier then
				entry.sizeTier = math.clamp(math.floor(sizeTier), 1, 3)
			end
			local sizeClass = tonumber(obj.sizeClass)
			if sizeClass then
				entry.sizeClass = math.clamp(math.floor(sizeClass), 1, 3)
			end
			local colorIndex = tonumber(obj.colorIndex)
			if colorIndex then
				entry.colorIndex = math.clamp(math.floor(colorIndex), 1, 14)
			end
			local colorR = tonumber(obj.colorR)
			local colorG = tonumber(obj.colorG)
			local colorB = tonumber(obj.colorB)
			if colorR and colorG and colorB then
				entry.colorR = math.clamp(colorR, 0, 1)
				entry.colorG = math.clamp(colorG, 0, 1)
				entry.colorB = math.clamp(colorB, 0, 1)
			end
			local variantIndex = tonumber(obj.variantIndex)
			if variantIndex then
				entry.variantIndex = math.clamp(math.floor(variantIndex), 1, 5)
			end
			local scaleMult = tonumber(obj.scaleMult)
			if scaleMult and scaleMult > 0 then
				entry.scaleMult = math.clamp(scaleMult, 0.7, 1.35)
			end
			local scaleWidth = tonumber(obj.scaleWidth)
			if scaleWidth and scaleWidth > 0 then
				entry.scaleWidth = math.clamp(scaleWidth, 0.7, 1.35)
			end
			local scaleHeight = tonumber(obj.scaleHeight)
			if scaleHeight and scaleHeight > 0 then
				entry.scaleHeight = math.clamp(scaleHeight, 0.7, 1.35)
			end
			local facingYaw = tonumber(obj.facingYaw)
			if typeof(facingYaw) == "number" and facingYaw == facingYaw then
				entry.facingYaw = facingYaw
			end
			local webColorR = tonumber(obj.webColorR)
			local webColorG = tonumber(obj.webColorG)
			local webColorB = tonumber(obj.webColorB)
			if webColorR and webColorG and webColorB then
				entry.webColorR = math.clamp(webColorR, 0, 1)
				entry.webColorG = math.clamp(webColorG, 0, 1)
				entry.webColorB = math.clamp(webColorB, 0, 1)
			end
			if typeof(obj.placeId) == "string" and obj.placeId ~= "" then
				entry.placeId = obj.placeId
			end
			if typeof(obj.parentPlaceId) == "string" and obj.parentPlaceId ~= "" then
				entry.parentPlaceId = obj.parentPlaceId
			end
			table.insert(layout, entry)
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
			gx = obj.gx,
			gy = obj.gy,
			gz = obj.gz,
			diameter = obj.diameter,
			sizeTier = obj.sizeTier,
			sizeClass = obj.sizeClass,
			colorIndex = obj.colorIndex,
			colorR = obj.colorR,
			colorG = obj.colorG,
			colorB = obj.colorB,
			variantIndex = obj.variantIndex,
			scaleMult = obj.scaleMult,
			scaleWidth = obj.scaleWidth,
			scaleHeight = obj.scaleHeight,
			facingYaw = obj.facingYaw,
			webColorR = obj.webColorR,
			webColorG = obj.webColorG,
			webColorB = obj.webColorB,
			placeId = obj.placeId,
			parentPlaceId = obj.parentPlaceId,
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
		local plotSizeStage = tonumber(src.plotSizeStage)
		table.insert(slots, {
			name = name,
			saved = saved,
			layout = layout,
			plotSizeStage = if plotSizeStage then math.floor(plotSizeStage) else nil,
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

local function clampSandDollars(n: any): number
	local v = tonumber(n)
	if typeof(v) ~= "number" or v ~= v or v < 0 then
		return 0
	end
	local maxN = Constants.SAND_DOLLARS_MAX
	if v >= maxN then
		return maxN
	end
	return math.floor(v)
end

local function sanitizeReceipts(raw: any): { [string]: ProcessedReceipt }
	local out: { [string]: ProcessedReceipt } = {}
	if typeof(raw) ~= "table" then
		return out
	end
	for k, v in pairs(raw) do
		if typeof(k) == "string" and k ~= "" and typeof(v) == "table" then
			local amount = clampSandDollars(v.amount)
			local productId = math.floor(tonumber(v.productId) or 0)
			if amount > 0 then
				out[k] = { amount = amount, productId = productId }
			end
		end
	end
	return out
end

local function cloneReceipts(src: { [string]: ProcessedReceipt }): { [string]: ProcessedReceipt }
	local out: { [string]: ProcessedReceipt } = {}
	for k, v in pairs(src) do
		out[k] = { amount = v.amount, productId = v.productId }
	end
	return out
end

local function unionReceipts(
	a: { [string]: ProcessedReceipt },
	b: { [string]: ProcessedReceipt }
): { [string]: ProcessedReceipt }
	local out = cloneReceipts(a)
	for k, v in pairs(b) do
		if out[k] == nil then
			out[k] = { amount = v.amount, productId = v.productId }
		end
	end
	return out
end

local function playerByUserId(userId: number): Player?
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.UserId == userId then
			return plr
		end
	end
	return nil
end

local function sanitizeInventory(raw: any, _isNewProfile: boolean): HueSeeds.HueInventory
	-- v8: hue-specific seeds only. Legacy flat inventory is wiped on load.
	if HueSeeds.hasLegacyFlatInventory(raw) then
		return {}
	end
	return HueSeeds.sanitize(raw, false)
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
		profile.currencies.sandDollars = clampSandDollars(raw.currencies.sandDollars)
		profile.currencies.gold = math.max(0, math.floor(tonumber(raw.currencies.gold) or 0))
	end
	profile.processedReceipts = sanitizeReceipts(raw.processedReceipts)
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
	local hw = tonumber(raw.highestWave)
	profile.highestWave = if hw and hw > 0 then math.floor(hw) else 0
	local hf = tonumber(raw.highestFishFed)
	profile.highestFishFed = if hf and hf > 0 then math.floor(hf) else 0
	local ls = tonumber(raw.longestWaveSec)
	profile.longestWaveSec = if ls and ls > 0 then math.floor(ls) else 0
	profile.plotOutlineColorIndex = PlotOutlineColors.clampIndex(raw.plotOutlineColorIndex)
	profile.skillStages = SkillStages.sanitizeMap(raw.skillStages)
	profile.skillActiveStages = SkillStages.sanitizeActiveMap(raw.skillActiveStages, profile.skillStages)
	profile.coralColorUnlocks = {}
	profile.hideUiUnlocked = raw.hideUiUnlocked == true
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
	PersistenceService.initSeedWheel()
end

function PersistenceService.getProfile(player: Player): PlayerProfile?
	return profiles[player]
end

function PersistenceService.getHighestWave(player: Player): number
	local profile = profiles[player]
	if not profile then
		return 0
	end
	return profile.highestWave or 0
end

function PersistenceService.getHighestFishFed(player: Player): number
	local profile = profiles[player]
	if not profile then
		return 0
	end
	return profile.highestFishFed or 0
end

function PersistenceService.getLongestWaveSec(player: Player): number
	local profile = profiles[player]
	if not profile then
		return 0
	end
	return profile.longestWaveSec or 0
end

-- Returns true if the stored high score increased.
function PersistenceService.reportHighestWave(player: Player, wave: number): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	local w = math.max(0, math.floor(tonumber(wave) or 0))
	if w <= (profile.highestWave or 0) then
		return false
	end
	profile.highestWave = w
	player:SetAttribute(Constants.HIGHEST_WAVE_ATTR, w)
	return true
end

-- Best-of updates for wave / fish fed / duration from one run summary.
function PersistenceService.reportWaveRecords(
	player: Player,
	wave: number,
	fishFed: number,
	elapsedSec: number
): { wave: boolean, fishFed: boolean, duration: boolean }
	local changed = { wave = false, fishFed = false, duration = false }
	local profile = profiles[player]
	if not profile then
		return changed
	end
	local w = math.clamp(math.floor(tonumber(wave) or 0), 0, 100000)
	local fed = math.clamp(math.floor(tonumber(fishFed) or 0), 0, 10000000)
	local sec = math.clamp(math.floor(tonumber(elapsedSec) or 0), 0, 8640000) -- 100 days
	if w > (profile.highestWave or 0) then
		profile.highestWave = w
		player:SetAttribute(Constants.HIGHEST_WAVE_ATTR, w)
		changed.wave = true
	end
	if fed > (profile.highestFishFed or 0) then
		profile.highestFishFed = fed
		player:SetAttribute(Constants.HIGHEST_FISH_FED_ATTR, fed)
		changed.fishFed = true
	end
	if sec > (profile.longestWaveSec or 0) then
		profile.longestWaveSec = sec
		player:SetAttribute(Constants.LONGEST_WAVE_SEC_ATTR, sec)
		changed.duration = true
	end
	return changed
end

function PersistenceService.syncHighestWaveAttribute(player: Player)
	local profile = profiles[player]
	local w = if profile then (profile.highestWave or 0) else 0
	player:SetAttribute(Constants.HIGHEST_WAVE_ATTR, w)
end

function PersistenceService.syncWaveRecordAttributes(player: Player)
	local profile = profiles[player]
	local w = if profile then (profile.highestWave or 0) else 0
	local fed = if profile then (profile.highestFishFed or 0) else 0
	local sec = if profile then (profile.longestWaveSec or 0) else 0
	player:SetAttribute(Constants.HIGHEST_WAVE_ATTR, w)
	player:SetAttribute(Constants.HIGHEST_FISH_FED_ATTR, fed)
	player:SetAttribute(Constants.LONGEST_WAVE_SEC_ATTR, sec)
end

function PersistenceService.getPlotOutlineColorIndex(player: Player): number
	local profile = profiles[player]
	if not profile then
		return PlotOutlineColors.DEFAULT_INDEX
	end
	return PlotOutlineColors.clampIndex(profile.plotOutlineColorIndex)
end

function PersistenceService.setPlotOutlineColorIndex(player: Player, index: number): number
	local profile = profiles[player]
	local clamped = PlotOutlineColors.clampIndex(index)
	if not profile then
		player:SetAttribute(Constants.PLOT_OUTLINE_COLOR_ATTR, clamped)
		return clamped
	end
	profile.plotOutlineColorIndex = clamped
	player:SetAttribute(Constants.PLOT_OUTLINE_COLOR_ATTR, clamped)
	return clamped
end

function PersistenceService.syncPlotOutlineColorAttribute(player: Player)
	local profile = profiles[player]
	local idx = if profile
		then PlotOutlineColors.clampIndex(profile.plotOutlineColorIndex)
		else PlotOutlineColors.DEFAULT_INDEX
	player:SetAttribute(Constants.PLOT_OUTLINE_COLOR_ATTR, idx)
end

function PersistenceService.getSandDollars(player: Player): number
	local profile = profiles[player]
	if not profile then
		return 0
	end
	return clampSandDollars(profile.currencies.sandDollars)
end

function PersistenceService.syncSandDollarsAttribute(player: Player)
	player:SetAttribute(Constants.SAND_DOLLARS_ATTR, PersistenceService.getSandDollars(player))
end

-- Spend $D if the player can afford it. Returns ok, newBalance, errorCode?.
function PersistenceService.trySpendSandDollars(
	player: Player,
	amount: number
): (boolean, number, string?)
	local profile = profiles[player]
	if not profile then
		return false, 0, "NoProfile"
	end
	local cost = math.max(0, math.floor(tonumber(amount) or 0))
	local cash = clampSandDollars(profile.currencies.sandDollars)
	if cost <= 0 then
		return true, cash, nil
	end
	if cash < cost then
		return false, cash, "CantAfford"
	end
	profile.currencies.sandDollars = cash - cost
	PersistenceService.syncSandDollarsAttribute(player)
	return true, profile.currencies.sandDollars, nil
end

-- Steal up to `maxAmount` $D (clamped to balance). Always succeeds; stolen may be 0.
function PersistenceService.stealSandDollars(player: Player, maxAmount: number): (number, number)
	local profile = profiles[player]
	if not profile then
		return 0, 0
	end
	local cap = math.max(0, math.floor(tonumber(maxAmount) or 0))
	local cash = clampSandDollars(profile.currencies.sandDollars)
	local stolen = math.min(cap, cash)
	if stolen > 0 then
		profile.currencies.sandDollars = cash - stolen
		PersistenceService.syncSandDollarsAttribute(player)
	end
	return stolen, profile.currencies.sandDollars
end

-- Credit $D (orb pickups, etc.). Returns ok, granted, newBalance.
function PersistenceService.creditSandDollars(player: Player, amount: number): (boolean, number, number)
	local profile = profiles[player]
	if not profile or loadFailed[player] == true then
		return false, 0, 0
	end
	local grant = math.max(0, math.floor(tonumber(amount) or 0))
	if grant <= 0 then
		return true, 0, clampSandDollars(profile.currencies.sandDollars)
	end
	profile.currencies.sandDollars = clampSandDollars(profile.currencies.sandDollars + grant)
	PersistenceService.syncSandDollarsAttribute(player)
	return true, grant, profile.currencies.sandDollars
end

function PersistenceService.didLoadFail(player: Player): boolean
	return loadFailed[player] == true
end

function PersistenceService.getSkillStages(player: Player): { [string]: number }
	local profile = profiles[player]
	if not profile then
		return SkillStages.defaultMap()
	end
	return SkillStages.sanitizeMap(profile.skillStages)
end

function PersistenceService.getSkillActiveStages(player: Player): { [string]: number }
	local profile = profiles[player]
	if not profile then
		return SkillStages.defaultMap()
	end
	profile.skillActiveStages = SkillStages.sanitizeActiveMap(profile.skillActiveStages, profile.skillStages)
	return SkillStages.sanitizeActiveMap(profile.skillActiveStages, profile.skillStages)
end

-- Payload for client sync: unlocked (purchase progress) + active (currently enabled).
function PersistenceService.getSkillStagesPayload(player: Player): { unlocked: { [string]: number }, active: { [string]: number } }
	return {
		unlocked = PersistenceService.getSkillStages(player),
		active = PersistenceService.getSkillActiveStages(player),
	}
end

-- Gameplay reads the *active* stage (player may dial below unlocked max).
function PersistenceService.getSkillStage(player: Player, skillId: string): number
	local active = PersistenceService.getSkillActiveStages(player)
	return SkillStages.clampStageFor(skillId, active[skillId])
end

function PersistenceService.getSkillUnlockedStage(player: Player, skillId: string): number
	local unlocked = PersistenceService.getSkillStages(player)
	return SkillStages.clampStageFor(skillId, unlocked[skillId])
end

function PersistenceService.setSkillActiveStage(player: Player, skillId: string, stage: number): {
	ok: boolean,
	active: number?,
	unlocked: number?,
	errorCode: string?,
}
	local profile = profiles[player]
	if not profile then
		return { ok = false, errorCode = "NoProfile" }
	end
	if not SkillStages.get(skillId) then
		return { ok = false, errorCode = "BadSkill" }
	end
	profile.skillStages = SkillStages.sanitizeMap(profile.skillStages)
	local unlocked = SkillStages.clampStageFor(skillId, profile.skillStages[skillId])
	local want = math.floor(tonumber(stage) or unlocked)
	local active = math.clamp(want, SkillStages.MIN_STAGE, unlocked)
	profile.skillActiveStages = SkillStages.sanitizeActiveMap(profile.skillActiveStages, profile.skillStages)
	profile.skillActiveStages[skillId] = active
	return { ok = true, active = active, unlocked = unlocked }
end

-- Unlock next stage for skillId. Returns { ok, stage, prevStage?, errorCode?, sandDollars? }.
function PersistenceService.tryUnlockSkillStage(player: Player, skillId: string): {
	ok: boolean,
	stage: number,
	prevStage: number?,
	errorCode: string?,
	sandDollars: number?,
}
	local profile = profiles[player]
	if not profile then
		return { ok = false, stage = 1, errorCode = "NoProfile", sandDollars = 0 }
	end
	local def = SkillStages.get(skillId)
	if not def then
		return { ok = false, stage = 1, errorCode = "BadSkill", sandDollars = profile.currencies.sandDollars }
	end
	profile.skillStages = SkillStages.sanitizeMap(profile.skillStages)
	local current = SkillStages.clampStageFor(skillId, profile.skillStages[skillId])
	local nextStage = SkillStages.nextStageFor(skillId, current)
	if not nextStage then
		return { ok = false, stage = current, prevStage = current, errorCode = "Maxed", sandDollars = profile.currencies.sandDollars }
	end
	local cost = math.max(0, math.floor(SkillStages.stageCost(skillId, nextStage)))
	local cash = clampSandDollars(profile.currencies.sandDollars)
	if cash < cost then
		return { ok = false, stage = current, prevStage = current, errorCode = "CantAfford", sandDollars = cash }
	end
	-- Earn More / Place More require Plot Size stage 2+.
	-- Reef Health requires Place More stage 2+.
	if SkillStages.isSkillLocked(skillId, profile.skillStages) then
		local errorCode = if SkillStages.isLockedUntilPlaceMore(
				skillId,
				SkillStages.clampStage(profile.skillStages.PlaceMore)
			)
			then "PlaceMoreGate"
			else "PlotSizeGate"
		return {
			ok = false,
			stage = current,
			prevStage = current,
			errorCode = errorCode,
			sandDollars = cash,
		}
	end
	profile.currencies.sandDollars = cash - cost
	profile.skillStages[skillId] = nextStage
	-- Newly unlocked stage becomes the enabled stage.
	profile.skillActiveStages = SkillStages.sanitizeActiveMap(profile.skillActiveStages, profile.skillStages)
	profile.skillActiveStages[skillId] = nextStage
	PersistenceService.syncSandDollarsAttribute(player)
	return {
		ok = true,
		stage = nextStage,
		prevStage = current,
		sandDollars = profile.currencies.sandDollars,
	}
end

function PersistenceService.getCoralColorUnlocksPayload(_player: Player): ColorUnlocks.UnlockMap
	return {}
end

function PersistenceService.syncCoralColorUnlocksToClient(_player: Player)
	-- Hue seeds replace per-color unlock map; inventory sync carries counts.
end

function PersistenceService.isCoralColorUnlocked(player: Player, itemId: string, colorIndex: number): boolean
	return PersistenceService.getHueSeedCount(player, itemId, colorIndex) > 0
end

function PersistenceService.tryUnlockCoralColor(player: Player, itemId: string, colorIndex: number): {
	ok: boolean,
	errorCode: string?,
	sandDollars: number?,
	colorIndex: number?,
	itemId: string?,
	alreadyUnlocked: boolean?,
}
	local profile = profiles[player]
	if not profile then
		return { ok = false, errorCode = "NoProfile", sandDollars = 0 }
	end
	if typeof(itemId) ~= "string" or itemId == "" then
		return { ok = false, errorCode = "BadItem", sandDollars = profile.currencies.sandDollars }
	end
	if not ColorUnlocks.isWheelItem(itemId) then
		return { ok = false, errorCode = "BadItem", sandDollars = profile.currencies.sandDollars }
	end
	local idx = PlotOutlineColors.clampCoralIndex(colorIndex)
	local inv = profile.inventory
	if typeof(inv) ~= "table" then
		inv = {}
		profile.inventory = inv
	end
	if HueSeeds.getCount(inv, itemId, idx) > 0 then
		return {
			ok = true,
			alreadyUnlocked = true,
			colorIndex = idx,
			itemId = itemId,
			sandDollars = clampSandDollars(profile.currencies.sandDollars),
		}
	end
	local cost = HueSeeds.SEED_COST
	local cash = clampSandDollars(profile.currencies.sandDollars)
	if cash < cost then
		return { ok = false, errorCode = "CantAfford", sandDollars = cash, colorIndex = idx, itemId = itemId }
	end
	profile.currencies.sandDollars = cash - cost
	HueSeeds.credit(inv, itemId, idx, 1)
	PersistenceService.syncSandDollarsAttribute(player)
	PersistenceService.syncInventoryToClient(player)
	task.spawn(function()
		PersistenceService.save(player)
	end)
	return {
		ok = true,
		colorIndex = idx,
		itemId = itemId,
		sandDollars = profile.currencies.sandDollars,
	}
end

function PersistenceService.isHideUiUnlocked(player: Player): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	return profile.hideUiUnlocked == true
end

function PersistenceService.syncHideUiToClient(player: Player)
	local unlocked = PersistenceService.isHideUiUnlocked(player)
	player:SetAttribute(Constants.HIDE_UI_UNLOCKED_ATTR, unlocked)
	Remotes.get("HideUiSync"):FireClient(player, unlocked)
end

function PersistenceService.tryUnlockHideUi(player: Player): {
	ok: boolean,
	errorCode: string?,
	sandDollars: number?,
	alreadyUnlocked: boolean?,
}
	local profile = profiles[player]
	if not profile then
		return { ok = false, errorCode = "NoProfile", sandDollars = 0 }
	end
	if profile.hideUiUnlocked then
		return {
			ok = true,
			alreadyUnlocked = true,
			sandDollars = clampSandDollars(profile.currencies.sandDollars),
		}
	end
	local cost = HideUiUnlock.UNLOCK_COST
	local cash = clampSandDollars(profile.currencies.sandDollars)
	if cash < cost then
		return { ok = false, errorCode = "CantAfford", sandDollars = cash }
	end
	profile.currencies.sandDollars = cash - cost
	profile.hideUiUnlocked = true
	PersistenceService.syncSandDollarsAttribute(player)
	PersistenceService.syncHideUiToClient(player)
	task.spawn(function()
		PersistenceService.save(player)
	end)
	return {
		ok = true,
		sandDollars = profile.currencies.sandDollars,
	}
end

-- Free hue seed (rewards, admin grants).
function PersistenceService.grantHueSeed(player: Player, itemId: string, colorIndex: number, amount: number?): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	if typeof(itemId) ~= "string" or itemId == "" or not HueSeeds.isHueItem(itemId) then
		return false
	end
	local idx = PlotOutlineColors.clampCoralIndex(colorIndex)
	local inv = profile.inventory
	if typeof(inv) ~= "table" then
		inv = {}
		profile.inventory = inv
	end
	HueSeeds.credit(inv, itemId, idx, amount)
	PersistenceService.syncInventoryToClient(player)
	task.spawn(function()
		PersistenceService.save(player)
	end)
	log("HueSeed grant", itemId, "idx", idx, "for", player.Name)
	return true
end

-- TEMP / debug: reset every skill to stage 1.
function PersistenceService.resetSkillStages(player: Player): { unlocked: { [string]: number }, active: { [string]: number } }
	local profile = profiles[player]
	if not profile then
		local d = SkillStages.defaultMap()
		return { unlocked = d, active = SkillStages.defaultMap() }
	end
	profile.skillStages = SkillStages.defaultMap()
	profile.skillActiveStages = SkillStages.defaultMap()
	return PersistenceService.getSkillStagesPayload(player)
end

-- Atomic Robux $D grant. Idempotent on PurchaseId. Safe if the player is offline
-- or on another server (session save merges unknown receipts instead of clobbering).
function PersistenceService.grantSandDollarsFromReceipt(
	userId: number,
	purchaseId: string,
	productId: number,
	amount: number
): (string, number)
	if typeof(userId) ~= "number" or userId <= 0 then
		return "failed", 0
	end
	if typeof(purchaseId) ~= "string" or purchaseId == "" then
		return "failed", 0
	end
	local grant = clampSandDollars(amount)
	if grant <= 0 then
		return "failed", 0
	end
	local pid = math.floor(tonumber(productId) or 0)

	local applied = false
	local already = false
	local resultCash = 0

	local ok, err = withDataStoreRetry("ReceiptUpdate", userId, function()
		getStore():UpdateAsync(keyFor(userId), function(old)
			if typeof(old) == "table" then
				local receipts = sanitizeReceipts(old.processedReceipts)
				if receipts[purchaseId] ~= nil then
					already = true
					resultCash = clampSandDollars(if typeof(old.currencies) == "table" then old.currencies.sandDollars else 0)
					return old
				end
			end
			local p = sanitizeProfile(old)
			if p.processedReceipts[purchaseId] ~= nil then
				already = true
				resultCash = p.currencies.sandDollars
				return old
			end
			p.processedReceipts[purchaseId] = { amount = grant, productId = pid }
			p.currencies.sandDollars = clampSandDollars(p.currencies.sandDollars + grant)
			applied = true
			resultCash = p.currencies.sandDollars
			return p
		end)
	end)

	if not ok then
		warnPersist("Receipt grant failed userId=", userId, "purchaseId=", purchaseId, err)
		return "failed", 0
	end

	local plr = playerByUserId(userId)
	if plr and profiles[plr] and loadFailed[plr] ~= true then
		local mem = profiles[plr]
		if mem.processedReceipts[purchaseId] == nil then
			mem.processedReceipts[purchaseId] = { amount = grant, productId = pid }
			mem.currencies.sandDollars = clampSandDollars(mem.currencies.sandDollars + grant)
		end
		PersistenceService.syncSandDollarsAttribute(plr)
		resultCash = mem.currencies.sandDollars
	elseif plr then
		plr:SetAttribute(Constants.SAND_DOLLARS_ATTR, resultCash)
	end

	if already then
		log("Receipt already granted userId=", userId, "purchaseId=", purchaseId, "sandDollars=", resultCash)
		return "already", resultCash
	end
	if applied then
		log("Receipt granted userId=", userId, "purchaseId=", purchaseId, "+", grant, "sandDollars=", resultCash)
		return "granted", resultCash
	end
	return "failed", 0
end

-- Credit $D for fish whose hunger bars filled (client reports count only).
-- Amount comes from persisted EarnMore stage. In-memory; autosave/leave persist.
function PersistenceService.creditSandDollarsFromFeed(player: Player, fishCount: any): (boolean, number, number)
	local profile = profiles[player]
	if not profile or loadFailed[player] == true then
		return false, 0, 0
	end
	local n = math.floor(tonumber(fishCount) or 0)
	if n < 1 then
		return false, 0, clampSandDollars(profile.currencies.sandDollars)
	end
	n = math.min(n, FEED_MAX_PER_SEC)

	local now = os.clock()
	local window = feedRate[player]
	if window == nil or now - window.t0 >= 1 then
		window = { t0 = now, count = 0 }
		feedRate[player] = window
	end
	local room = FEED_MAX_PER_SEC - window.count
	if room <= 0 then
		return false, 0, clampSandDollars(profile.currencies.sandDollars)
	end
	n = math.min(n, room)
	window.count += n

	local stage = PersistenceService.getSkillStage(player, "EarnMore")
	local per = SkillStages.earnMorePerFish(stage)
	local grant = clampSandDollars(n * per)
	if grant <= 0 then
		return false, 0, clampSandDollars(profile.currencies.sandDollars)
	end
	profile.currencies.sandDollars = clampSandDollars(profile.currencies.sandDollars + grant)
	PersistenceService.syncSandDollarsAttribute(player)
	return true, grant, profile.currencies.sandDollars
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
		slot.plotSizeStage = PersistenceService.getSkillStage(player, "PlotSize")
	end
	if idx == profile.plotSaves.activeIndex then
		profile.layout = cloneLayout(layout)
	end
	return true
end

-- Rewrite every saved slot layout when Plot Size stage changes CFrame (world positions preserved).
function PersistenceService.reframeAllPlotSaveLayouts(player: Player, oldCf: CFrame, newCf: CFrame)
	local profile = profiles[player]
	if not profile or oldCf == newCf then
		return
	end
	local LayoutRestore = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("LayoutRestore"))
	local stage = PersistenceService.getSkillStage(player, "PlotSize")
	for _, slot in ipairs(profile.plotSaves.slots) do
		if #slot.layout > 0 then
			slot.layout = LayoutRestore.reframeLayout(slot.layout, oldCf, newCf)
			slot.plotSizeStage = stage
		end
	end
	profile.layout = cloneLayout(profile.plotSaves.slots[profile.plotSaves.activeIndex].layout)
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

local function ensureInventory(profile: PlayerProfile): HueSeeds.HueInventory
	local inv = profile.inventory
	if typeof(inv) ~= "table" then
		inv = {}
		profile.inventory = inv
	end
	return inv
end

function PersistenceService.getHueSeedCount(player: Player, itemId: string, colorIndex: number): number
	local profile = profiles[player]
	if not profile then
		return 0
	end
	return HueSeeds.getCount(ensureInventory(profile), itemId, colorIndex)
end

-- Credit one hue seed (recycle / clear / wheel / $D purchase).
function PersistenceService.creditHueSeed(
	player: Player,
	itemId: string,
	colorIndex: number,
	amount: number?
): number
	local profile = profiles[player]
	if not profile or typeof(itemId) ~= "string" or itemId == "" then
		return 0
	end
	local inv = ensureInventory(profile)
	local nextCount = HueSeeds.credit(inv, itemId, colorIndex, amount)
	log("Credit hue", itemId, "idx", colorIndex, "→", nextCount, "for", player.Name)
	PersistenceService.syncInventoryToClient(player)
	return nextCount
end

-- Back-compat wrapper: credits default teal when hue omitted (avoid in new code).
function PersistenceService.creditItem(
	player: Player,
	itemId: string,
	amount: number?,
	colorIndex: number?
): number
	local hue = if typeof(colorIndex) == "number"
		then PlotOutlineColors.clampCoralIndex(colorIndex)
		else PlotOutlineColors.DEFAULT_INDEX
	return PersistenceService.creditHueSeed(player, itemId, hue, amount)
end

-- Pending prize-wheel grants: credit only after client finishes the reveal fly.
type SeedWheelPending = { itemId: string, token: number, amount: number, colorIndex: number, at: number }
local seedWheelPending: { [number]: SeedWheelPending } = {}
local seedWheelAutoRollEnabled: { [number]: boolean } = {}
local seedWheelTokenSeq = 0
local SEED_WHEEL_CLAIM_TIMEOUT_SEC = 25

local function clearSeedWheelPending(userId: number)
	seedWheelPending[userId] = nil
end

local function isSeedWheelAutoRollEnabled(userId: number): boolean
	return seedWheelAutoRollEnabled[userId] == true
end

function PersistenceService.syncSeedWheelAutoRollToClient(player: Player)
	if not player or not player.Parent then
		return
	end
	Remotes.get("SeedWheelAutoRollSync"):FireClient(player, isSeedWheelAutoRollEnabled(player.UserId))
end

function PersistenceService.setSeedWheelAutoRollEnabled(player: Player, enabled: boolean)
	if not player or not player.Parent then
		return
	end
	local userId = player.UserId
	local next = enabled == true
	seedWheelAutoRollEnabled[userId] = next
	Remotes.get("SeedWheelAutoRollSync"):FireClient(player, next)
	if next then
		task.defer(function()
			if player.Parent and isSeedWheelAutoRollEnabled(userId) and not seedWheelPending[userId] then
				PersistenceService.beginSeedWheelGrant(player, 1)
			end
		end)
	end
end

local function fulfillSeedWheel(player: Player, pending: SeedWheelPending)
	clearSeedWheelPending(player.UserId)
	PersistenceService.creditHueSeed(player, pending.itemId, pending.colorIndex, pending.amount)
	log("SeedWheel grant", pending.itemId, "hue", pending.colorIndex, "x", pending.amount, "for", player.Name)
	if isSeedWheelAutoRollEnabled(player.UserId) then
		task.defer(function()
			if player.Parent and isSeedWheelAutoRollEnabled(player.UserId) then
				PersistenceService.beginSeedWheelGrant(player, 1)
			end
		end)
	end
end

-- Start a random coral seed wheel for the player. Seed is credited after claim (or timeout).
function PersistenceService.beginSeedWheelGrant(player: Player, amount: number?): (boolean, string?)
	if not player or not player.Parent then
		return false, "NoPlayer"
	end
	if not profiles[player] then
		return false, "NoProfile"
	end
	local userId = player.UserId
	if seedWheelPending[userId] then
		return false, "Busy"
	end
	if not isSeedWheelAutoRollEnabled(userId) then
		return false, "AutoRollOff"
	end
	local add = math.max(1, math.floor(tonumber(amount) or 1))
	local itemId = SeedWheel.pickRandom()
	local colorIndex = SeedWheel.pickRandomColorIndex()
	seedWheelTokenSeq += 1
	local token = seedWheelTokenSeq
	seedWheelPending[userId] = {
		itemId = itemId,
		token = token,
		amount = add,
		colorIndex = colorIndex,
		at = os.clock(),
	}
	Remotes.get("SeedWheelReveal"):FireClient(player, itemId, token, add, colorIndex)
	task.delay(SEED_WHEEL_CLAIM_TIMEOUT_SEC, function()
		local pending = seedWheelPending[userId]
		if not pending or pending.token ~= token then
			return
		end
		if player.Parent then
			fulfillSeedWheel(player, pending)
		else
			clearSeedWheelPending(userId)
		end
	end)
	return true, itemId
end

function PersistenceService.claimSeedWheel(player: Player, itemId: any, token: any): boolean
	if not player or not player.Parent then
		return false
	end
	-- Studio smoke-test: F7 client → grant a wheel spin.
	if RunService:IsStudio() and itemId == "__RequestStudioGrant__" then
		PersistenceService.beginSeedWheelGrant(player, 1)
		return true
	end
	local pending = seedWheelPending[player.UserId]
	if not pending then
		return false
	end
	if typeof(itemId) ~= "string" or itemId ~= pending.itemId then
		return false
	end
	if typeof(token) ~= "number" or token ~= pending.token then
		return false
	end
	fulfillSeedWheel(player, pending)
	return true
end

function PersistenceService.initSeedWheel()
	Remotes.get("SeedWheelClaim").OnServerEvent:Connect(function(player: Player, itemId: any, token: any)
		PersistenceService.claimSeedWheel(player, itemId, token)
	end)
	Remotes.get("SeedWheelAutoRoll").OnServerEvent:Connect(function(player: Player, enabled: any)
		if typeof(enabled) ~= "boolean" then
			return
		end
		PersistenceService.setSeedWheelAutoRollEnabled(player, enabled)
	end)
	Players.PlayerRemoving:Connect(function(player)
		clearSeedWheelPending(player.UserId)
		seedWheelAutoRollEnabled[player.UserId] = nil
	end)
end

function PersistenceService.tryDebitHueSeed(
	player: Player,
	itemId: string,
	colorIndex: number,
	amount: number?
): (boolean, number)
	local profile = profiles[player]
	if not profile or typeof(itemId) ~= "string" or itemId == "" then
		return false, 0
	end
	local inv = ensureInventory(profile)
	local ok, nextCount = HueSeeds.tryDebit(inv, itemId, colorIndex, amount)
	if not ok then
		return false, nextCount
	end
	log("TryDebit hue", itemId, "idx", colorIndex, "→", nextCount, "for", player.Name)
	PersistenceService.syncInventoryToClient(player)
	return true, nextCount
end

function PersistenceService.tryDebitItem(
	player: Player,
	itemId: string,
	amount: number?,
	colorIndex: number?
): (boolean, number)
	local hue = if typeof(colorIndex) == "number"
		then PlotOutlineColors.clampCoralIndex(colorIndex)
		else PlotOutlineColors.DEFAULT_INDEX
	return PersistenceService.tryDebitHueSeed(player, itemId, hue, amount)
end

function PersistenceService.debitHueSeed(player: Player, itemId: string, colorIndex: number, amount: number?): number
	local ok, nextCount = PersistenceService.tryDebitHueSeed(player, itemId, colorIndex, amount)
	if not ok then
		return 0
	end
	return nextCount
end

function PersistenceService.debitItem(
	player: Player,
	itemId: string,
	amount: number?,
	colorIndex: number?
): number
	local ok, nextCount = PersistenceService.tryDebitItem(player, itemId, amount, colorIndex)
	if not ok then
		return 0
	end
	return nextCount
end

function PersistenceService.getItemCount(player: Player, itemId: string): number
	local profile = profiles[player]
	if not profile or typeof(itemId) ~= "string" then
		return 0
	end
	return HueSeeds.getSpeciesTotal(ensureInventory(profile), itemId)
end

function PersistenceService.getInventoryPayload(player: Player): { [string]: { [string]: number } }
	local profile = profiles[player]
	if not profile then
		return {}
	end
	return HueSeeds.toClientPayload(ensureInventory(profile))
end

local inventorySyncQueued: { [Player]: boolean } = {}

function PersistenceService.syncInventoryToClient(player: Player)
	if not player or not player.Parent then
		return
	end
	if inventorySyncQueued[player] then
		return
	end
	inventorySyncQueued[player] = true
	task.defer(function()
		inventorySyncQueued[player] = nil
		if not player.Parent then
			return
		end
		Remotes.get("InventorySync"):FireClient(player, PersistenceService.getInventoryPayload(player))
	end)
end

function PersistenceService.allowIntentionalClear(userId: number)
	intentionalClear[userId] = true
end

function PersistenceService.load(player: Player): PlayerProfile
	local userId = player.UserId
	local profile = PlotTypes.defaultProfile()

	local ok, result = withDataStoreRetry("GetAsync", userId, function()
		return getStore():GetAsync(keyFor(userId))
	end)

	if not ok then
		warnPersist("GetAsync failed for", userId, result)
		loadFailed[player] = true
		profiles[player] = profile
		log("Load fallback empty profile userId=", userId, "layout=0 — SAVES BLOCKED (protect $D)")
		return profile
	end

	loadFailed[player] = nil
	if result == nil then
		profiles[player] = profile
		log("Load new profile userId=", userId, "layout=0", "seeds=0")
		return profile
	end

	profile = sanitizeProfile(result)
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
	if loadFailed[player] == true then
		warnPersist("Save skipped — load failed; refusing to persist (protect $D) for", player.Name)
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
			sandDollars = clampSandDollars(profile.currencies.sandDollars),
			gold = math.max(0, math.floor(tonumber(profile.currencies.gold) or 0)),
		},
		processedReceipts = cloneReceipts(profile.processedReceipts),
		inventory = profile.inventory,
		skillTree = profile.skillTree,
		layout = cloneLayout(profile.layout),
		plotSaves = {
			activeIndex = profile.plotSaves.activeIndex,
			slots = slotsOut,
		},
		highestWave = profile.highestWave or 0,
		highestFishFed = profile.highestFishFed or 0,
		longestWaveSec = profile.longestWaveSec or 0,
		plotOutlineColorIndex = PlotOutlineColors.clampIndex(profile.plotOutlineColorIndex),
		skillStages = SkillStages.sanitizeMap(profile.skillStages),
		skillActiveStages = SkillStages.sanitizeActiveMap(profile.skillActiveStages, profile.skillStages),
		coralColorUnlocks = {},
		hideUiUnlocked = profile.hideUiUnlocked == true,
	}

	local saved = false
	local blocked = false

	local ok, err = withDataStoreRetry("UpdateAsync", userId, function()
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

			-- Wallet merge: never drop Robux grants that landed via ProcessReceipt
			-- on this or another server while this session held a stale snapshot.
			-- Use the pre-UpdateAsync snapshot (toWrite) so retries cannot double-add.
			local memReceipts = toWrite.processedReceipts
			local oldReceipts = oldProfile.processedReceipts
			local extraFromStore = 0
			for purchaseId, rec in pairs(oldReceipts) do
				if memReceipts[purchaseId] == nil then
					extraFromStore += rec.amount
				end
			end
			toWrite.processedReceipts = unionReceipts(oldReceipts, memReceipts)
			toWrite.currencies.sandDollars =
				clampSandDollars(clampSandDollars(toWrite.currencies.sandDollars) + extraFromStore)

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
		"sandDollars=",
		toWrite.currencies.sandDollars,
		"blockedEmptyWipe=",
		blocked
	)
	profile.processedReceipts = cloneReceipts(toWrite.processedReceipts)
	profile.currencies.sandDollars = clampSandDollars(toWrite.currencies.sandDollars)
	PersistenceService.syncSandDollarsAttribute(player)
	return saved
end

function PersistenceService.release(player: Player)
	profiles[player] = nil
	loadFailed[player] = nil
	feedRate[player] = nil
	inventorySyncQueued[player] = nil
end

return PersistenceService
