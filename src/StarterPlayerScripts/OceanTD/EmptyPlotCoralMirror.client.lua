--!strict
--[[
	Solo-room cosmetic: clone local player's OceanTD_Placed corals onto empty plots.
	- Client-local only (never GridService / persist / replicate)
	- Instance Clone + CFrame remap (not CoralVisual.create) for 2000+ density
	- Chunked Heartbeat spawn; torn down the instant anyone else joins
]]

local ENABLED = false -- feature paused

if not ENABLED then
	local leftover = game:GetService("Workspace"):FindFirstChild("OceanTD_EmptyPlotMirrors")
	if leftover then
		leftover:Destroy()
	end
	return
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local player = Players.LocalPlayer

local PLACED_ROOT = "OceanTD_Placed"
local MIRROR_ROOT = "OceanTD_EmptyPlotMirrors"
local MIRROR_ATTR = "OceanTD_EmptyPlotMirror"

-- Budget: keep frame spikes small even at 2k–10k clones.
local CLONES_PER_FRAME = 40
local REBUILD_DEBOUNCE_SEC = 2.75
local SOURCE_WAIT_SEC = 12

export type RosterEntry = {
	plotId: string,
	cframe: CFrame,
	size: Vector3,
	ownerUserId: number,
	-- Stable RingMath pose (matches décor/terrain). Prefer over active Plot Size bounds.
	ringCFrame: CFrame?,
}

local roster: { RosterEntry } = {}
local sessionReady = false
local buildGen = 0
local buildConn: RBXScriptConnection? = nil
local debounceToken = 0
local sourceFolderConns: { RBXScriptConnection } = {}
local watchingSourceId: string? = nil

local rosterRemote = Remotes.get("PlotRoster")
local requestRoster = Remotes.getFunction("RequestPlotRoster")
local sessionReadyRemote = Remotes.get("SessionReady")

local function log(...: any)
	print("[EMPTY_MIRROR]", ...)
end

local function aloneInRoom(): boolean
	return #Players:GetPlayers() <= 1
end

local function ownPlotId(): string?
	local plot = ClientPlot.get()
	if plot then
		return plot.plotId
	end
	local attr = player:GetAttribute(Constants.PLOT_ID_ATTR)
	return if typeof(attr) == "string" then attr else nil
end

-- Terrain/décor-aligned pose. Active Plot Size bounds centers sit higher and were
-- lifting mirrored corals when used as the remap frame.
local function poseCf(entry: RosterEntry): CFrame
	return entry.ringCFrame or entry.cframe
end

local function ownRemapCFrame(): CFrame?
	local plot = ClientPlot.get()
	if plot then
		return plot.ringCFrame or plot.cframe
	end
	local id = ownPlotId()
	if not id then
		return nil
	end
	for _, entry in ipairs(roster) do
		if entry.plotId == id then
			return poseCf(entry)
		end
	end
	return nil
end

local function placedFolder(plotId: string): Folder?
	local root = Workspace:FindFirstChild(PLACED_ROOT)
	if not root then
		return nil
	end
	local folder = root:FindFirstChild(plotId)
	return if folder and folder:IsA("Folder") then folder else nil
end

local function destroyMirrorRoot()
	local existing = Workspace:FindFirstChild(MIRROR_ROOT)
	if existing then
		existing:Destroy()
	end
end

local function ensureMirrorRoot(): Folder
	local existing = Workspace:FindFirstChild(MIRROR_ROOT)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = MIRROR_ROOT
	folder:SetAttribute(MIRROR_ATTR, true)
	folder.Parent = Workspace
	return folder
end

local function stopBuild()
	buildGen += 1
	if buildConn then
		buildConn:Disconnect()
		buildConn = nil
	end
end

local function clearMirrors()
	stopBuild()
	destroyMirrorRoot()
end

local function num(v: any, fallback: number): number
	local n = tonumber(v)
	return if n then n else fallback
end

local function applyRoster(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local nextRoster: { RosterEntry } = {}
	for _, entry in ipairs(payload) do
		if typeof(entry) == "table"
			and typeof(entry.plotId) == "string"
			and typeof(entry.cframe) == "CFrame"
			and typeof(entry.size) == "Vector3"
		then
			table.insert(nextRoster, {
				plotId = entry.plotId,
				cframe = entry.cframe,
				size = entry.size,
				ownerUserId = num(entry.ownerUserId, 0),
				ringCFrame = if typeof(entry.ringCFrame) == "CFrame" then entry.ringCFrame else nil,
			})
		end
	end
	roster = nextRoster
end

local function emptyTargets(ownId: string): { RosterEntry }
	local out: { RosterEntry } = {}
	for _, entry in ipairs(roster) do
		if entry.ownerUserId <= 0 and entry.plotId ~= ownId then
			table.insert(out, entry)
		end
	end
	return out
end

-- Strip interaction / HUD cost from cosmetic clones.
local function sanitizeMirrorInstance(root: Instance)
	if root:IsA("BasePart") then
		root.Anchored = true
		root.CanCollide = false
		root.CanQuery = false
		root.CanTouch = false
		root.CastShadow = false
		root:SetAttribute(MIRROR_ATTR, true)
		root:SetAttribute("OceanTD_PlaceId", nil)
		root:SetAttribute("OceanTD_ParentPlaceId", nil)
	elseif root:IsA("Model") then
		root:SetAttribute(MIRROR_ATTR, true)
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d:SetAttribute(MIRROR_ATTR, true)
			d:SetAttribute("OceanTD_PlaceId", nil)
			d:SetAttribute("OceanTD_ParentPlaceId", nil)
		elseif d:IsA("BillboardGui") or d:IsA("SurfaceGui") or d:IsA("ProximityPrompt") then
			d:Destroy()
		elseif d:IsA("BaseScript") then
			d:Destroy()
		end
	end
end

local function remapCloneToPlot(clone: Instance, fromCf: CFrame, toCf: CFrame)
	local parts: { BasePart } = {}
	if clone:IsA("BasePart") then
		table.insert(parts, clone)
	end
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	-- Snapshot locals first so parent moves don't skew child object-space.
	local locals: { [BasePart]: CFrame } = {}
	for _, p in ipairs(parts) do
		locals[p] = fromCf:ToObjectSpace(p.CFrame)
	end
	for _, p in ipairs(parts) do
		p.CFrame = toCf * locals[p]
	end
	sanitizeMirrorInstance(clone)
end

local function listSourceChildren(source: Folder): { Instance }
	local kids = source:GetChildren()
	-- Stable order helps resumable chunking look consistent across plots.
	table.sort(kids, function(a, b)
		return a.Name < b.Name
	end)
	return kids
end

local function beginChunkedBuild(ownId: string, fromCf: CFrame, sourceKids: { Instance }, targets: { RosterEntry })
	stopBuild()
	destroyMirrorRoot()
	if #sourceKids == 0 or #targets == 0 then
		return
	end

	buildGen += 1
	local myGen = buildGen
	local mirrorRoot = ensureMirrorRoot()

	-- Pre-create target folders.
	local targetFolders: { Folder } = {}
	for _, t in ipairs(targets) do
		local sub = Instance.new("Folder")
		sub.Name = t.plotId
		sub:SetAttribute(MIRROR_ATTR, true)
		sub.Parent = mirrorRoot
		table.insert(targetFolders, sub)
	end

	local targetIndex = 1
	local childIndex = 1
	local spawned = 0
	local total = #sourceKids * #targets
	local t0 = os.clock()

	buildConn = RunService.Heartbeat:Connect(function()
		if myGen ~= buildGen or not aloneInRoom() then
			stopBuild()
			return
		end
		local budget = CLONES_PER_FRAME
		while budget > 0 and targetIndex <= #targets do
			local target = targets[targetIndex]
			local dest = targetFolders[targetIndex]
			if not dest or not dest.Parent then
				stopBuild()
				return
			end
			if childIndex > #sourceKids then
				targetIndex += 1
				childIndex = 1
				continue
			end
			local src = sourceKids[childIndex]
			childIndex += 1
			if not src.Parent then
				budget -= 1
				continue
			end
			local ok, cloneOrErr = pcall(function()
				return src:Clone()
			end)
			if not ok or typeof(cloneOrErr) ~= "Instance" then
				budget -= 1
				continue
			end
			local clone = cloneOrErr :: Instance
			remapCloneToPlot(clone, fromCf, poseCf(target))
			clone.Parent = dest
			spawned += 1
			budget -= 1
		end
		if targetIndex > #targets then
			stopBuild()
			log(
				"Mirrored",
				spawned,
				"/",
				total,
				"onto",
				#targets,
				"empty plots in",
				string.format("%.2fs", os.clock() - t0)
			)
		end
	end)
end

local function disconnectSourceWatch()
	for _, c in ipairs(sourceFolderConns) do
		c:Disconnect()
	end
	table.clear(sourceFolderConns)
	watchingSourceId = nil
end

local scheduleEvaluate: () -> ()

local function watchSourceFolder(plotId: string, folder: Folder)
	if watchingSourceId == plotId then
		return
	end
	disconnectSourceWatch()
	watchingSourceId = plotId
	table.insert(
		sourceFolderConns,
		folder.ChildAdded:Connect(function()
			if aloneInRoom() then
				scheduleEvaluate()
			end
		end)
	)
	table.insert(
		sourceFolderConns,
		folder.ChildRemoved:Connect(function()
			if aloneInRoom() then
				scheduleEvaluate()
			end
		end)
	)
end

local function evaluateNow()
	if not sessionReady or not aloneInRoom() then
		clearMirrors()
		disconnectSourceWatch()
		return
	end
	local ownId = ownPlotId()
	local fromCf = ownRemapCFrame()
	if not ownId or not fromCf then
		clearMirrors()
		return
	end
	local source = placedFolder(ownId)
	if not source then
		clearMirrors()
		return
	end
	watchSourceFolder(ownId, source)
	local targets = emptyTargets(ownId)
	if #targets == 0 then
		clearMirrors()
		return
	end
	local kids = listSourceChildren(source)
	if #kids == 0 then
		clearMirrors()
		return
	end
	beginChunkedBuild(ownId, fromCf, kids, targets)
end

scheduleEvaluate = function()
	debounceToken += 1
	local my = debounceToken
	task.delay(REBUILD_DEBOUNCE_SEC, function()
		if my ~= debounceToken then
			return
		end
		evaluateNow()
	end)
end

local function onBecameAlone()
	-- Wait briefly for hydrate visuals to land, then build.
	task.spawn(function()
		local deadline = os.clock() + SOURCE_WAIT_SEC
		while os.clock() < deadline do
			if not aloneInRoom() then
				return
			end
			local ownId = ownPlotId()
			local folder = if ownId then placedFolder(ownId) else nil
			if folder and (#folder:GetChildren() > 0 or sessionReady) then
				break
			end
			task.wait(0.2)
		end
		if aloneInRoom() and sessionReady then
			evaluateNow()
		end
	end)
end

local function refreshRoster()
	local ok, payload = pcall(function()
		return requestRoster:InvokeServer()
	end)
	if ok then
		applyRoster(payload)
	end
end

rosterRemote.OnClientEvent:Connect(function(payload)
	applyRoster(payload)
	if aloneInRoom() then
		scheduleEvaluate()
	else
		clearMirrors()
	end
end)

Players.PlayerAdded:Connect(function()
	-- Anyone else joining: drop mirrors immediately (don't wait for roster).
	clearMirrors()
	disconnectSourceWatch()
end)

Players.PlayerRemoving:Connect(function(leaving)
	task.defer(function()
		-- After leave, we may be alone again.
		if leaving ~= player and aloneInRoom() and sessionReady then
			refreshRoster()
			onBecameAlone()
		end
	end)
end)

ClientPlot.onChanged(function()
	if aloneInRoom() and sessionReady then
		scheduleEvaluate()
	end
end)

player:GetAttributeChangedSignal(Constants.PLOT_ID_ATTR):Connect(function()
	if aloneInRoom() and sessionReady then
		scheduleEvaluate()
	end
end)

sessionReadyRemote.OnClientEvent:Connect(function()
	sessionReady = true
	refreshRoster()
	if aloneInRoom() then
		onBecameAlone()
	else
		clearMirrors()
	end
end)

-- Hot-reload / late join: SessionReady may have already fired.
task.defer(function()
	if ClientPlot.isReady() then
		sessionReady = true
	end
	refreshRoster()
	if sessionReady and aloneInRoom() then
		onBecameAlone()
	end
end)

log("Ready — solo empty-plot coral mirror")
