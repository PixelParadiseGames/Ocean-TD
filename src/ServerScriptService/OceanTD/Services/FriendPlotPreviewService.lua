--!strict
--[[
	Fill free world seats with friends' saved reefs (offline DataStore layouts).
	Seats stay unowned so real joins claim them normally; preview is evicted first.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local LayoutRestore = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LayoutRestore"))
local PlotTypes = require(oceanRoot:WaitForChild("Shared"):WaitForChild("PlotTypes"))

local PlotService = require(script.Parent:WaitForChild("PlotService"))
local GridService = require(script.Parent:WaitForChild("GridService"))
local PlacementService = require(script.Parent:WaitForChild("PlacementService"))
local PersistenceService = require(script.Parent:WaitForChild("PersistenceService"))
local WaveWatchService = require(script.Parent:WaitForChild("WaveWatchService"))

type LayoutObject = PlotTypes.LayoutObject

local FriendPlotPreviewService = {}

local previewByPlot: { [string]: number } = {} -- plotId → preview userId
local usedPreviewIds: { [number]: boolean } = {}
local friendIdCache: { [number]: { ids: { number }, at: number } } = {}
local layoutCache: {
	[number]: {
		layout: { LayoutObject },
		plotSizeStage: number,
		savedLayoutStage: number?,
		empty: boolean,
	},
} =
	{}
local FRIEND_CACHE_TTL = 300
local fillGen = 0
local fillQueued = false

local function log(...: any)
	print("[FRIEND_PREVIEW]", ...)
end

local function warnPreview(...: any)
	warn("[FRIEND_PREVIEW]", ...)
end

local function shuffleInPlace(list: { any })
	for i = #list, 2, -1 do
		local j = math.random(1, i)
		list[i], list[j] = list[j], list[i]
	end
end

local function cloneLayout(layout: { LayoutObject }): { LayoutObject }
	local out: { LayoutObject } = {}
	for i, obj in ipairs(layout) do
		out[i] = table.clone(obj)
	end
	return out
end

local function playersInServer(): { [number]: boolean }
	local map: { [number]: boolean } = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		map[plr.UserId] = true
	end
	return map
end

local function collectFriendIds(userId: number): { number }
	local cached = friendIdCache[userId]
	local now = os.clock()
	if cached and (now - cached.at) < FRIEND_CACHE_TTL then
		return cached.ids
	end
	local ids: { number } = {}
	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(userId)
	end)
	if not ok or pages == nil then
		warnPreview("GetFriendsAsync failed for", userId, pages)
		friendIdCache[userId] = { ids = ids, at = now }
		return ids
	end
	while true do
		local pageOk, page = pcall(function()
			return (pages :: any):GetCurrentPage()
		end)
		if pageOk and typeof(page) == "table" then
			for _, item in ipairs(page) do
				local id = if typeof(item) == "table" then (item.Id or item.id) else nil
				if typeof(id) == "number" and id > 0 then
					table.insert(ids, id)
				end
			end
		end
		local finished = true
		pcall(function()
			finished = (pages :: any).IsFinished == true
		end)
		if finished then
			break
		end
		local advOk = pcall(function()
			(pages :: any):AdvanceToNextPageAsync()
		end)
		if not advOk then
			break
		end
	end
	friendIdCache[userId] = { ids = ids, at = now }
	return ids
end

local function unionFriendCandidates(): { number }
	local inServer = playersInServer()
	local seen: { [number]: boolean } = {}
	local out: { number } = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		for _, fid in ipairs(collectFriendIds(plr.UserId)) do
			if not inServer[fid] and not seen[fid] then
				seen[fid] = true
				table.insert(out, fid)
			end
		end
	end
	shuffleInPlace(out)
	return out
end

local function readOfflineLayout(userId: number): ( { LayoutObject }, number, number?, boolean )
	local cached = layoutCache[userId]
	if cached then
		return cached.layout, cached.plotSizeStage, cached.savedLayoutStage, cached.empty
	end
	local profile = PersistenceService.loadOfflineProfile(userId)
	if not profile then
		layoutCache[userId] = { layout = {}, plotSizeStage = 1, savedLayoutStage = nil, empty = true }
		return {}, 1, nil, true
	end
	local unlocked = SkillStages.sanitizeMap(profile.skillStages)
	local active = SkillStages.sanitizeActiveMap(profile.skillActiveStages, unlocked)
	local stage = SkillStages.clampStageFor("PlotSize", active.PlotSize or unlocked.PlotSize or 1)
	local layout = profile.layout or {}
	local savedLayoutStage: number? = nil
	local activeSlot = profile.plotSaves and profile.plotSaves.slots[profile.plotSaves.activeIndex]
	if activeSlot and typeof(activeSlot.plotSizeStage) == "number" then
		savedLayoutStage = SkillStages.clampStageFor("PlotSize", activeSlot.plotSizeStage)
	end
	local empty = #layout == 0
	layoutCache[userId] = {
		layout = layout,
		plotSizeStage = stage,
		savedLayoutStage = savedLayoutStage,
		empty = empty,
	}
	-- Opportunistically seed/update the global reef-score board from offline layouts.
	if not empty then
		task.spawn(function()
			PersistenceService.publishReefScore(userId, layout, false)
		end)
	end
	return layout, stage, savedLayoutStage, empty
end

local function forgetPreview(plotId: string)
	local uid = previewByPlot[plotId]
	if uid then
		usedPreviewIds[uid] = nil
		previewByPlot[plotId] = nil
	end
	PlotService.setPreviewUserId(plotId, nil)
end

function FriendPlotPreviewService.evictPreview(plotId: string)
	local had = previewByPlot[plotId] ~= nil or PlotService.getPreviewUserId(plotId) ~= nil
	forgetPreview(plotId)
	GridService.clearPlot(plotId)
	PlacementService.clearPlotVisuals(plotId)
	if had then
		log("Evicted preview on", plotId)
	end
end

local function hydrateFriend(
	plotId: string,
	friendUserId: number,
	layout: { LayoutObject },
	plotSizeStage: number,
	savedLayoutStage: number?
): boolean
	local slot = PlotService.getSlot(plotId)
	if not slot or slot.owner ~= nil then
		return false
	end

	local layoutCopy = cloneLayout(layout)
	if typeof(savedLayoutStage) == "number" and savedLayoutStage ~= plotSizeStage then
		local oldCf = select(1, PlotService.getStageWorldPose(slot, savedLayoutStage))
		local newCf = select(1, PlotService.getStageWorldPose(slot, plotSizeStage))
		if oldCf and newCf and oldCf ~= newCf then
			layoutCopy = LayoutRestore.reframeLayout(layoutCopy, oldCf, newCf)
		end
	end

	local worldCf = select(1, PlotService.applySlotPlotSizeStage(plotId, plotSizeStage)) or slot.cframe
	GridService.hydrate(plotId, friendUserId, layoutCopy, worldCf)
	PlacementService.hydrateVisuals(plotId, worldCf)
	previewByPlot[plotId] = friendUserId
	usedPreviewIds[friendUserId] = true
	PlotService.setPreviewUserId(plotId, friendUserId)
	log("Filled", plotId, "with preview", friendUserId, "corals=", #layoutCopy, "plotSize=", plotSizeStage)
	return true
end

local function pickFromCandidates(candidates: { number }, allowReuse: boolean): (number?, { LayoutObject }, number, number?)
	local nonempty: { number } = {}
	for _, uid in ipairs(candidates) do
		if allowReuse or not usedPreviewIds[uid] then
			local _layout, _stage, _saved, empty = readOfflineLayout(uid)
			if not empty then
				table.insert(nonempty, uid)
			end
		end
	end
	shuffleInPlace(nonempty)
	if #nonempty == 0 then
		return nil, {}, 1, nil
	end
	local uid = nonempty[1]
	local layout, stage, saved = readOfflineLayout(uid)
	return uid, layout, stage, saved
end

local function topReefCandidates(allowReuse: boolean): { number }
	local top = PersistenceService.getTopReefUserIds(25)
	local inServer = playersInServer()
	local filtered: { number } = {}
	for _, topId in ipairs(top) do
		-- Never mirror a seated player's own live reef onto a neighbor seat.
		if not inServer[topId] and (allowReuse or not usedPreviewIds[topId]) then
			table.insert(filtered, topId)
		end
	end
	shuffleInPlace(filtered)
	return filtered
end

local function pickPreviewForFill(friendCandidates: { number }): (number?, { LayoutObject }, number, number?)
	-- 1) Unique friends with reefs
	local uid, layout, stage, saved = pickFromCandidates(friendCandidates, false)
	if uid then
		return uid, layout, stage, saved
	end
	-- 2) Unique top-25 reef scores
	uid, layout, stage, saved = pickFromCandidates(topReefCandidates(false), false)
	if uid then
		log("Top-reef unique pick", uid)
		return uid, layout, stage, saved
	end
	-- 3) Reuse top-25 (high-score reefs can fill multiple empty seats)
	uid, layout, stage, saved = pickFromCandidates(topReefCandidates(true), true)
	if uid then
		log("Top-reef reuse pick", uid)
		return uid, layout, stage, saved
	end
	-- 4) Last resort: reuse friend reefs
	uid, layout, stage, saved = pickFromCandidates(friendCandidates, true)
	if uid then
		log("Friend reuse pick", uid)
	else
		log("No preview candidate (friends=", #friendCandidates, "top=", #PersistenceService.getTopReefUserIds(25), ")")
	end
	return uid, layout, stage, saved
end

local function fillPlotId(plotId: string, friendCandidates: { number }): boolean
	local slot = PlotService.getSlot(plotId)
	if not slot or slot.owner ~= nil then
		return false
	end
	if previewByPlot[plotId] then
		forgetPreview(plotId)
		GridService.clearPlot(plotId)
		PlacementService.clearPlotVisuals(plotId)
	end
	local pickUid, layout, stage, saved = pickPreviewForFill(friendCandidates)
	if not pickUid then
		return false
	end
	return hydrateFriend(plotId, pickUid, layout, stage, saved)
end

function FriendPlotPreviewService.fillEmptyPlots()
	local seated = 0
	for _, _plr in ipairs(Players:GetPlayers()) do
		seated += 1
	end
	if seated == 0 then
		return
	end
	fillGen += 1
	local token = fillGen
	local friends = unionFriendCandidates()
	local free = PlotService.listFreePlotIds()
	shuffleInPlace(free)
	local filled = 0
	local skipped = 0
	for _, plotId in ipairs(free) do
		if token ~= fillGen then
			return
		end
		if PlotService.getPlotOwner(plotId) == nil and previewByPlot[plotId] == nil then
			if fillPlotId(plotId, friends) then
				filled += 1
			else
				skipped += 1
			end
			task.wait(0.05)
		end
	end
	log(
		"Fill empty done filled=",
		filled,
		"skipped=",
		skipped,
		"friendPool=",
		#friends,
		"topPool=",
		#PersistenceService.getTopReefUserIds(25)
	)
	WaveWatchService.broadcastRoster(nil)
end

function FriendPlotPreviewService.fillVacated(plotId: string)
	local slot = PlotService.getSlot(plotId)
	if not slot or slot.owner ~= nil then
		return
	end
	forgetPreview(plotId)
	GridService.clearPlot(plotId)
	PlacementService.clearPlotVisuals(plotId)
	local friends = unionFriendCandidates()
	fillPlotId(plotId, friends)
	WaveWatchService.broadcastRoster(nil)
end

function FriendPlotPreviewService.scheduleFillEmpty()
	if fillQueued then
		return
	end
	fillQueued = true
	task.defer(function()
		fillQueued = false
		task.wait(0.35)
		FriendPlotPreviewService.fillEmptyPlots()
	end)
end

function FriendPlotPreviewService.clearAllPreviews()
	fillGen += 1
	for i = 1, Constants.MAX_PLOTS do
		local plotId = "Plot" .. tostring(i)
		if PlotService.getSlot(plotId) and PlotService.getPlotOwner(plotId) == nil then
			forgetPreview(plotId)
			GridService.clearPlot(plotId)
			PlacementService.clearPlotVisuals(plotId)
		end
	end
	WaveWatchService.broadcastRoster(nil)
	log("Cleared all previews (empty server)")
end

function FriendPlotPreviewService.init()
	log("Ready")
end

return FriendPlotPreviewService
