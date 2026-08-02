--!strict
-- OceanTD server bootstrap. Ownership: session lifecycle wiring only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local Services = script.Parent:WaitForChild("Services")
local PlayerSession = require(Services:WaitForChild("PlayerSession"))
local PlotService = require(Services:WaitForChild("PlotService"))
local GridService = require(Services:WaitForChild("GridService"))
local PersistenceService = require(Services:WaitForChild("PersistenceService"))
local DecorReplicator = require(Services:WaitForChild("DecorReplicator"))
local PlacementService = require(Services:WaitForChild("PlacementService"))

local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))

Remotes.initServer()
PersistenceService.init()
PlotService.init()
PlacementService.init()

do
	local poses = {}
	for i = 1, Constants.MAX_PLOTS do
		local slot = PlotService.getSlotByIndex(i)
		if slot then
			poses[i] = { plotIndex = slot.plotIndex, cframe = slot.cframe }
		end
	end
	DecorReplicator.replicate(poses)
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
	local layout = GridService.snapshot(plotId)
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

	GridService.hydrate(payload.plotId, player.UserId, profile.layout, payload.cframe)
	PlacementService.hydrateVisuals(payload.plotId, payload.cframe)
	PlayerSession.markReady(player, payload.plotId)

	plotAssignedRemote:FireClient(player, payload)
	sessionReadyRemote:FireClient(player)

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
	savePlayer(player, "leave")

	local plotId = PlotService.getOwnerPlotId(player)
	if plotId then
		GridService.clearPlot(plotId)
		PlacementService.clearPlotVisuals(plotId)
	end
	PlotService.free(player)
	plotClearedRemote:FireClient(player)

	PersistenceService.release(player)
	PlayerSession.remove(player)
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
requestPlace.OnServerInvoke = function(player: Player, itemId: any, worldPos: any)
	if typeof(itemId) ~= "string" or typeof(worldPos) ~= "Vector3" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PlacementService.place(player, itemId, worldPos)
end

local requestMove = Remotes.getFunction("RequestMove")
requestMove.OnServerInvoke = function(player: Player, placeId: any, fromWorldPos: any, toWorldPos: any)
	if typeof(placeId) ~= "string" or typeof(fromWorldPos) ~= "Vector3" or typeof(toWorldPos) ~= "Vector3" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PlacementService.move(player, placeId, fromWorldPos, toWorldPos)
end

local requestRecycle = Remotes.getFunction("RequestRecycle")
requestRecycle.OnServerInvoke = function(player: Player, placeId: any, worldPos: any)
	if typeof(placeId) ~= "string" or typeof(worldPos) ~= "Vector3" then
		return { ok = false, errorCode = "BadRequest" }
	end
	return PlacementService.recycle(player, placeId, worldPos)
end
