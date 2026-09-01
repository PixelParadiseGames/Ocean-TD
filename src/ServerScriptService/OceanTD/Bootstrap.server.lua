--!strict
-- OceanTD server bootstrap. Ownership: session lifecycle wiring only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Workspace = game:GetService("Workspace")

-- Roblox-native jump: JumpHeight (not JumpPower). Default 7.2 → +50% = 10.8.
StarterPlayer.CharacterUseJumpPower = false
StarterPlayer.CharacterJumpHeight = 10.8
-- Fall ~20% slower (default Gravity 196.2).
Workspace.Gravity = 196.2 * 0.8

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local Services = script.Parent:WaitForChild("Services")
local PlayerSession = require(Services:WaitForChild("PlayerSession"))
local PlotService = require(Services:WaitForChild("PlotService"))
local GridService = require(Services:WaitForChild("GridService"))
local PersistenceService = require(Services:WaitForChild("PersistenceService"))
local EconomyService = require(Services:WaitForChild("EconomyService"))
local DecorReplicator = require(Services:WaitForChild("DecorReplicator"))
local PlacementService = require(Services:WaitForChild("PlacementService"))
local UndoService = require(Services:WaitForChild("UndoService"))
local PlotSaveService = require(Services:WaitForChild("PlotSaveService"))
local WaveWatchService = require(Services:WaitForChild("WaveWatchService"))
local UrchinStingService = require(Services:WaitForChild("UrchinStingService"))

local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))

Remotes.initServer()
PersistenceService.init()
EconomyService.init()
PlotService.init()
PlacementService.init()
PlotSaveService.init()
WaveWatchService.init()
UrchinStingService.init()

do
	local poses = {}
	for i = 1, Constants.MAX_PLOTS do
		local slot = PlotService.getSlotByIndex(i)
		if slot then
			poses[i] = { plotIndex = slot.plotIndex, cframe = slot.cframe, size = slot.size }
		end
	end
	DecorReplicator.replicate(poses)
	local WaveHeartReplicator = require(Services:WaitForChild("WaveHeartReplicator"))
	WaveHeartReplicator.replicate(poses)
end

local plotAssignedRemote = Remotes.get("PlotAssigned")
local plotClearedRemote = Remotes.get("PlotCleared")
local sessionReadyRemote = Remotes.get("SessionReady")

local function onCharacterAdded(player: Player, _character: Model)
	-- Retarget spawn after respawn once session owns a plot.
	if PlayerSession.canSave(player) then
		task.defer(function()
			PlotService.teleportToPlot(player)
		end)
	end
end

local function savePlayer(player: Player, reason: string)
	if PlayerSession.isPlotLoading(player) then
		print("[PERSIST] Skip save (" .. reason .. ") — plot slot load in progress for", player.Name)
		return
	end
	if not PlayerSession.canSave(player) then
		print("[PERSIST] Skip save (" .. reason .. ") — session not ready for", player.Name)
		return
	end
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		print("[PERSIST] Skip save (" .. reason .. ") — no plot for", player.Name)
		return
	end

	PlayerSession.setSaving(player, true)
	local layout = PlacementService.snapshotLayout(plotId)
	local ok = PersistenceService.save(player, layout)
	PlayerSession.setSaving(player, false)
	print("[PERSIST] Save complete (" .. reason .. ") ok=", ok, "player=", player.Name)
end

local function onPlayerAdded(player: Player)
	print("[PLOT] PlayerAdded", player.Name)
	PlayerSession.begin(player)

	local profile = PersistenceService.load(player)
	local payload = PlotService.assign(player)
	if not payload then
		warn("[PLOT] Could not assign plot to", player.Name, "— kicking soft (no slot).")
		player:Kick("All reef plots are full. Try another server.")
		PlayerSession.remove(player)
		PersistenceService.release(player)
		return
	end

	-- Apply Plot Size stage BEFORE hydrate so layout locals match the Studio box pose.
	do
		local plotSizeStage = PersistenceService.getSkillStage(player, "PlotSize")
		local sized = PlotService.applyOwnerPlotSizeStage(player, plotSizeStage)
		if sized then
			payload = sized
		end
	end

	local LayoutRestore = require(game:GetService("ReplicatedStorage"):WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("LayoutRestore"))
	local ringSlot = PlotService.getSlot(payload.plotId)
	local activeIdx = profile.plotSaves.activeIndex
	local activeSlot = profile.plotSaves.slots[activeIdx]
	if ringSlot and activeSlot and #activeSlot.layout > 0 then
		local currentStage = PersistenceService.getSkillStage(player, "PlotSize")
		local savedStage = activeSlot.plotSizeStage
		if typeof(savedStage) == "number" and savedStage ~= currentStage then
			local oldCf, _ = PlotService.getStageWorldPose(ringSlot, savedStage)
			local newCf, _ = PlotService.getStageWorldPose(ringSlot, currentStage)
			if oldCf and newCf and oldCf ~= newCf then
				local reframed = LayoutRestore.reframeLayout(activeSlot.layout, oldCf, newCf)
				profile.layout = reframed
				activeSlot.layout = reframed
				activeSlot.plotSizeStage = currentStage
			end
		end
	end

	GridService.hydrate(payload.plotId, player.UserId, profile.layout, payload.cframe)
	PlacementService.hydrateVisuals(payload.plotId, payload.cframe)
	PlayerSession.markReady(player, payload.plotId)
	PersistenceService.syncWaveRecordAttributes(player)
	PersistenceService.syncPlotOutlineColorAttribute(player)
	PersistenceService.syncSandDollarsAttribute(player)
	PersistenceService.syncInventoryToClient(player)

	plotAssignedRemote:FireClient(player, payload)
	sessionReadyRemote:FireClient(player)
	Remotes.get("SkillStagesSync"):FireClient(player, PersistenceService.getSkillStagesPayload(player))
	PersistenceService.syncCoralColorUnlocksToClient(player)
	-- Seed wheel auto-roll off until the player presses START (StopAutoRoll button).
	PersistenceService.syncSeedWheelAutoRollToClient(player)
	-- Joiner first (race-safe), then everyone.
	WaveWatchService.broadcastRoster(player)
	WaveWatchService.broadcastRoster(nil)

	local function hookCharacter(character: Model)
		onCharacterAdded(player, character)
	end
	if player.Character then
		hookCharacter(player.Character)
	end
	player.CharacterAdded:Connect(hookCharacter)

	-- Initial teleport once character exists.
	task.spawn(function()
		if not player.Character then
			player.CharacterAdded:Wait()
		end
		PlotService.teleportToPlot(player)
	end)

	print("[PLOT] Session ready", player.Name, "plot=", payload.plotId, "layout=", #profile.layout)
end

local function onPlayerRemoving(player: Player)
	print("[PLOT] PlayerRemoving", player.Name)
	PlacementService.clearPendingColorSave(player)
	savePlayer(player, "leave")

	local plotId = PlotService.getOwnerPlotId(player)
	if plotId then
		GridService.clearPlot(plotId)
		PlacementService.clearPlotVisuals(plotId)
	end
	PlotService.free(player)
	plotClearedRemote:FireClient(player)
	WaveWatchService.broadcastRoster(nil)

	PersistenceService.release(player)
	PlayerSession.remove(player)
	UndoService.clear(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- Autosave: only ready sessions; staggered lightly by UserId.
task.spawn(function()
	while true do
		task.wait(Constants.AUTOSAVE_INTERVAL_SEC)
		for _, player in ipairs(Players:GetPlayers()) do
			if PlayerSession.canSave(player) then
				-- Stagger: wait a fraction based on userId to avoid thundering herd.
				task.wait((player.UserId % 7) * 0.05)
				if player.Parent then
					savePlayer(player, "autosave")
				end
			end
		end
	end
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		savePlayer(player, "bindtoclose")
	end
	if game:GetService("RunService"):IsStudio() then
		task.wait(1)
	else
		task.wait(3)
	end
end)

print("[PLOT] OceanTD server bootstrap complete")

local requestPlace = Remotes.getFunction("RequestPlace")
requestPlace.OnServerInvoke = function(player: Player, itemId: any, worldPos: any, diameter: any)
	if typeof(itemId) ~= "string" or typeof(worldPos) ~= "Vector3" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PlacementService.place(player, itemId, worldPos, true, diameter)
end

local requestMove = Remotes.getFunction("RequestMove")
requestMove.OnServerInvoke = function(player: Player, placeId: any, fromWorldPos: any, toWorldPos: any, facingYaw: any, parentPlaceId: any)
	if typeof(placeId) ~= "string" or typeof(fromWorldPos) ~= "Vector3" or typeof(toWorldPos) ~= "Vector3" then
		return { ok = false, errorCode = "BadRequest" }
	end
	local parentId = if typeof(parentPlaceId) == "string" and parentPlaceId ~= "" then parentPlaceId else nil
	return PlacementService.move(player, placeId, fromWorldPos, toWorldPos, tonumber(facingYaw), parentId)
end

local requestRecycle = Remotes.getFunction("RequestRecycle")
requestRecycle.OnServerInvoke = function(player: Player, placeId: any, worldPos: any)
	if typeof(placeId) ~= "string" or typeof(worldPos) ~= "Vector3" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PlacementService.recycle(player, placeId, worldPos)
end

local requestUndo = Remotes.getFunction("RequestUndo")
requestUndo.OnServerInvoke = function(player: Player)
	return PlacementService.undoLast(player)
end

local requestClearPlot = Remotes.getFunction("RequestClearPlot")
requestClearPlot.OnServerInvoke = function(player: Player)
	return PlacementService.clearPlot(player)
end

local requestGetPlotSaves = Remotes.getFunction("RequestGetPlotSaves")
requestGetPlotSaves.OnServerInvoke = function(player: Player)
	return PlotSaveService.getClientState(player)
end

local requestSavePlotSlot = Remotes.getFunction("RequestSavePlotSlot")
requestSavePlotSlot.OnServerInvoke = function(player: Player, slotIndex: any)
	if typeof(slotIndex) ~= "number" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PlotSaveService.saveSlot(player, slotIndex)
end

local requestLoadPlotSlot = Remotes.getFunction("RequestLoadPlotSlot")
requestLoadPlotSlot.OnServerInvoke = function(player: Player, slotIndex: any)
	if typeof(slotIndex) ~= "number" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PlotSaveService.loadSlot(player, slotIndex)
end

local requestRenamePlotSave = Remotes.getFunction("RequestRenamePlotSave")
requestRenamePlotSave.OnServerInvoke = function(player: Player, slotIndex: any, name: any)
	if typeof(slotIndex) ~= "number" or typeof(name) ~= "string" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PlotSaveService.renameSlot(player, slotIndex, name)
end

local reportFishFed = Remotes.get("ReportFishFed")
reportFishFed.OnServerEvent:Connect(function(player: Player, fishCount: any)
	local session = PlayerSession.get(player)
	if not session or session.layoutLoaded ~= true then
		return
	end
	PersistenceService.creditSandDollarsFromFeed(player, fishCount)
end)

local reportHighestWave = Remotes.get("ReportHighestWave")
reportHighestWave.OnServerEvent:Connect(function(player: Player, wave: any)
	if typeof(wave) ~= "number" then
		return
	end
	-- Cap absurd client values.
	local w = math.clamp(math.floor(wave), 0, 100000)
	PersistenceService.reportHighestWave(player, w)
end)

local reportWaveRecords = Remotes.get("ReportWaveRecords")
reportWaveRecords.OnServerEvent:Connect(function(player: Player, wave: any, fishFed: any, elapsedSec: any)
	if typeof(wave) ~= "number" or typeof(fishFed) ~= "number" or typeof(elapsedSec) ~= "number" then
		return
	end
	PersistenceService.reportWaveRecords(player, wave, fishFed, elapsedSec)
end)

local requestSetPlotOutlineColor = Remotes.getFunction("RequestSetPlotOutlineColor")
requestSetPlotOutlineColor.OnServerInvoke = function(player: Player, index: any)
	if typeof(index) ~= "number" then
		return PersistenceService.getPlotOutlineColorIndex(player)
	end
	return PersistenceService.setPlotOutlineColorIndex(player, index)
end

local requestGetSkillStages = Remotes.getFunction("RequestGetSkillStages")
requestGetSkillStages.OnServerInvoke = function(player: Player)
	return PersistenceService.getSkillStagesPayload(player)
end

local requestSetSkillActiveStage = Remotes.getFunction("RequestSetSkillActiveStage")
requestSetSkillActiveStage.OnServerInvoke = function(player: Player, skillId: any, stage: any)
	if typeof(skillId) ~= "string" or typeof(stage) ~= "number" then
		return { ok = false, errorCode = "BadArgs" }
	end
	local prevPlotSize: number? = nil
	if skillId == "PlotSize" then
		prevPlotSize = PersistenceService.getSkillStage(player, "PlotSize")
	end
	local result = PersistenceService.setSkillActiveStage(player, skillId, stage)
	if result.ok then
		Remotes.get("SkillStagesSync"):FireClient(player, PersistenceService.getSkillStagesPayload(player))
		if skillId == "PlotSize" then
			local newActive = result.active :: number
			if typeof(prevPlotSize) == "number" and newActive ~= prevPlotSize then
				-- Defer bounds until client grow tween (dial up/down between unlocked stages).
				local plotId = PlotService.getOwnerPlotId(player)
				local slot = if plotId then PlotService.getSlot(plotId) else nil
				local prevCf: CFrame? = nil
				local prevSize: Vector3? = nil
				local newCf: CFrame? = nil
				local newSize: Vector3? = nil
				local ringCf: CFrame? = nil
				local spawnCf: CFrame? = nil
				local plot1Cf: CFrame? = nil
				if slot then
					prevCf, prevSize = PlotService.getStageWorldPose(slot, prevPlotSize :: number)
					newCf, newSize = PlotService.getStageWorldPose(slot, newActive)
					ringCf = slot.ringCFrame
					spawnCf = slot.spawnCFrame
					local bounds = PlotService.getBoundsPayload(player)
					plot1Cf = if bounds then bounds.plot1CFrame else nil
				end
				Remotes.get("PlotSizeChanged"):FireClient(player, {
					prevStage = prevPlotSize,
					stage = newActive,
					dial = true,
					prevCFrame = prevCf,
					prevSize = prevSize,
					cframe = newCf,
					size = newSize,
					plotId = plotId,
					plot1CFrame = plot1Cf,
					ringCFrame = ringCf,
					spawnCFrame = spawnCf,
				})
			end
		end
	end
	return result
end

local requestUnlockSkillStage = Remotes.getFunction("RequestUnlockSkillStage")
requestUnlockSkillStage.OnServerInvoke = function(player: Player, skillId: any)
	if typeof(skillId) ~= "string" then
		return { ok = false, stage = 1, errorCode = "BadSkill" }
	end
	local result = PersistenceService.tryUnlockSkillStage(player, skillId)
	if result.ok then
		Remotes.get("SkillStagesSync"):FireClient(player, PersistenceService.getSkillStagesPayload(player))
		if skillId == "PlotSize" then
			-- Defer bounds apply until the client grow tween finishes (ReportPlotSizeCinematicDone).
			-- Otherwise PlotAssigned snaps the outline to the new size before the cinematic.
			local plotId = PlotService.getOwnerPlotId(player)
			local slot = if plotId then PlotService.getSlot(plotId) else nil
			local prevStage = result.prevStage or (result.stage - 1)
			local prevCf: CFrame? = nil
			local prevSize: Vector3? = nil
			local newCf: CFrame? = nil
			local newSize: Vector3? = nil
			local ringCf: CFrame? = nil
			local spawnCf: CFrame? = nil
			local plot1Cf: CFrame? = nil
			if slot then
				prevCf, prevSize = PlotService.getStageWorldPose(slot, prevStage)
				newCf, newSize = PlotService.getStageWorldPose(slot, result.stage)
				ringCf = slot.ringCFrame
				spawnCf = slot.spawnCFrame
				local bounds = PlotService.getBoundsPayload(player)
				plot1Cf = if bounds then bounds.plot1CFrame else nil
			end
			Remotes.get("PlotSizeChanged"):FireClient(player, {
				prevStage = prevStage,
				stage = result.stage,
				prevCFrame = prevCf,
				prevSize = prevSize,
				cframe = newCf,
				size = newSize,
				plotId = plotId,
				plot1CFrame = plot1Cf,
				ringCFrame = ringCf,
				spawnCFrame = spawnCf,
			})
		end
	end
	return result
end

local reportPlotSizeCinematicDone = Remotes.get("ReportPlotSizeCinematicDone")
reportPlotSizeCinematicDone.OnServerEvent:Connect(function(player: Player, stage: any)
	if typeof(stage) ~= "number" then
		return
	end
	local want = PersistenceService.getSkillStage(player, "PlotSize")
	local s = math.floor(stage)
	if s ~= want then
		-- Still apply saved stage (reconnect / desync).
		s = want
	end
	local payload = PlotService.applyOwnerPlotSizeStage(player, s)
	if payload then
		Remotes.get("PlotAssigned"):FireClient(player, payload)
		WaveWatchService.broadcastRoster(nil)
	end
end)

local requestResetSkillStages = Remotes.getFunction("RequestResetSkillStages")
requestResetSkillStages.OnServerInvoke = function(player: Player)
	local stages = PersistenceService.resetSkillStages(player)
	Remotes.get("SkillStagesSync"):FireClient(player, stages)
	local payload = PlotService.applyOwnerPlotSizeStage(player, 1)
	if payload then
		Remotes.get("PlotAssigned"):FireClient(player, payload)
		Remotes.get("PlotSizeChanged"):FireClient(player, {
			prevStage = 1,
			stage = 1,
			size = payload.size,
			cframe = payload.cframe,
			plotId = payload.plotId,
			plot1CFrame = payload.plot1CFrame,
			reset = true,
		})
		WaveWatchService.broadcastRoster(nil)
	end
	return { ok = true, skillStages = stages }
end

local requestCoralSize = Remotes.getFunction("RequestCoralSize")
requestCoralSize.OnServerInvoke = function(player: Player, placeId: any, targetClass: any, unlockNext: any)
	if typeof(placeId) ~= "string" then
		return { ok = false, errorCode = "BadRequest" }
	end
	local want = tonumber(targetClass)
	if typeof(want) ~= "number" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PlacementService.setCoralSize(player, placeId, want, unlockNext == true)
end

local requestCoralColor = Remotes.getFunction("RequestCoralColor")
requestCoralColor.OnServerInvoke = function(
	player: Player,
	placeId: any,
	colorIndex: any,
	colorR: any,
	colorG: any,
	colorB: any,
	webColorIndex: any,
	webColorR: any,
	webColorG: any,
	webColorB: any
)
	if typeof(placeId) ~= "string" then
		return { ok = false, errorCode = "BadRequest" }
	end
	local idx = tonumber(colorIndex)
	if typeof(idx) ~= "number" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PlacementService.setCoralColor(
		player,
		placeId,
		idx,
		tonumber(colorR),
		tonumber(colorG),
		tonumber(colorB),
		tonumber(webColorIndex),
		tonumber(webColorR),
		tonumber(webColorG),
		tonumber(webColorB)
	)
end

local requestUnlockCoralColor = Remotes.getFunction("RequestUnlockCoralColor")
requestUnlockCoralColor.OnServerInvoke = function(player: Player, itemId: any, colorIndex: any)
	if typeof(itemId) ~= "string" then
		return { ok = false, errorCode = "BadItem" }
	end
	local idx = tonumber(colorIndex)
	if typeof(idx) ~= "number" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PersistenceService.tryUnlockCoralColor(player, itemId, idx)
end
