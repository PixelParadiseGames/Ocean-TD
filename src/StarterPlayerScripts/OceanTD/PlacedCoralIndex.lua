--!strict
--[[
	Client spatial index of Workspace.OceanTD_Placed coral.
	- Per-plot part list (ChildAdded/Removed) — no GetDescendants scans
	- Grid key map for the local plot (Spot Taken / gather) via ClientPlot CFrame
	Call reindex(part) after relocate moves a coral in-place.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanShared = ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared")
local GridMath = require(oceanShared:WaitForChild("GridMath"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local ROOT_NAME = "OceanTD_Placed"

type PlotBucket = {
	parts: { BasePart },
	partSet: { [BasePart]: boolean },
	byKey: { [string]: BasePart },
	partKey: { [BasePart]: string },
}

local PlacedCoralIndex = {}

local buckets: { [string]: PlotBucket } = {}
local folderConns: { [Instance]: { RBXScriptConnection } } = {}
local rootConns: { RBXScriptConnection } = {}
local started = false
local changedEvent: BindableEvent = Instance.new("BindableEvent")

local function fireChanged()
	changedEvent:Fire()
end

local function getBucket(plotId: string): PlotBucket
	local b = buckets[plotId]
	if b then
		return b
	end
	b = {
		parts = {},
		partSet = {},
		byKey = {},
		partKey = {},
	}
	buckets[plotId] = b
	return b
end

local function clearGridForPart(bucket: PlotBucket, part: BasePart)
	local oldKey = bucket.partKey[part]
	if not oldKey then
		return
	end
	if bucket.byKey[oldKey] == part then
		bucket.byKey[oldKey] = nil
	end
	bucket.partKey[part] = nil
end

local function assignGrid(plotId: string, bucket: PlotBucket, part: BasePart)
	clearGridForPart(bucket, part)
	local plot = ClientPlot.get()
	if not plot or plot.plotId ~= plotId then
		return
	end
	-- SeaGrass/SeaFan sit above the plant cell — prefer authored grid anchor.
	local ax = part:GetAttribute("OceanTD_GridAnchorX")
	local ay = part:GetAttribute("OceanTD_GridAnchorY")
	local az = part:GetAttribute("OceanTD_GridAnchorZ")
	local sample = if typeof(ax) == "number" and typeof(ay) == "number" and typeof(az) == "number"
		then Vector3.new(ax, ay, az)
		else part.Position
	local lp = GridMath.worldToPlotLocal(sample, plot.cframe)
	local gx, gy, gz = GridMath.worldToGrid(lp, Vector3.zero)
	local key = GridMath.key(gx, gy, gz)
	bucket.byKey[key] = part
	bucket.partKey[part] = key
end

local function addPart(plotId: string, part: BasePart)
	local bucket = getBucket(plotId)
	if bucket.partSet[part] then
		assignGrid(plotId, bucket, part)
		return
	end
	bucket.partSet[part] = true
	table.insert(bucket.parts, part)
	assignGrid(plotId, bucket, part)
	fireChanged()
end

local function removePart(plotId: string, part: BasePart)
	local bucket = buckets[plotId]
	if not bucket or not bucket.partSet[part] then
		return
	end
	clearGridForPart(bucket, part)
	bucket.partSet[part] = nil
	for i = #bucket.parts, 1, -1 do
		if bucket.parts[i] == part then
			table.remove(bucket.parts, i)
			break
		end
	end
	fireChanged()
end

local function unhookFolder(folder: Instance)
	local list = folderConns[folder]
	if not list then
		return
	end
	for _, c in ipairs(list) do
		c:Disconnect()
	end
	folderConns[folder] = nil
end

local function hookFolder(folder: Instance)
	if folderConns[folder] then
		return
	end
	local plotId = folder.Name
	local conns: { RBXScriptConnection } = {}
	for _, ch in ipairs(folder:GetChildren()) do
		if ch:IsA("BasePart") then
			addPart(plotId, ch)
		end
	end
	table.insert(
		conns,
		folder.ChildAdded:Connect(function(ch)
			if ch:IsA("BasePart") then
				addPart(plotId, ch)
			end
		end)
	)
	table.insert(
		conns,
		folder.ChildRemoved:Connect(function(ch)
			if ch:IsA("BasePart") then
				removePart(plotId, ch)
			end
		end)
	)
	folderConns[folder] = conns
end

local function rebuildLocalGrid()
	local plot = ClientPlot.get()
	if not plot then
		return
	end
	local bucket = buckets[plot.plotId]
	if not bucket then
		return
	end
	table.clear(bucket.byKey)
	table.clear(bucket.partKey)
	for _, part in ipairs(bucket.parts) do
		if part.Parent then
			assignGrid(plot.plotId, bucket, part)
		end
	end
end

local function hookRoot(root: Instance)
	for _, c in ipairs(rootConns) do
		c:Disconnect()
	end
	table.clear(rootConns)
	for folder, _ in pairs(folderConns) do
		unhookFolder(folder)
	end
	table.clear(buckets)

	for _, ch in ipairs(root:GetChildren()) do
		if ch:IsA("Folder") or ch:IsA("Model") then
			hookFolder(ch)
		end
	end
	table.insert(
		rootConns,
		root.ChildAdded:Connect(function(ch)
			if ch:IsA("Folder") or ch:IsA("Model") then
				hookFolder(ch)
			end
		end)
	)
	table.insert(
		rootConns,
		root.ChildRemoved:Connect(function(ch)
			unhookFolder(ch)
			buckets[ch.Name] = nil
		end)
	)
	rebuildLocalGrid()
end

function PlacedCoralIndex.ensure(): ()
	if started then
		return
	end
	started = true

	local existing = Workspace:FindFirstChild(ROOT_NAME)
	if existing then
		hookRoot(existing)
	end
	Workspace.ChildAdded:Connect(function(ch)
		if ch.Name == ROOT_NAME then
			hookRoot(ch)
		end
	end)
	Workspace.ChildRemoved:Connect(function(ch)
		if ch.Name == ROOT_NAME then
			for folder, _ in pairs(folderConns) do
				unhookFolder(folder)
			end
			table.clear(buckets)
			for _, c in ipairs(rootConns) do
				c:Disconnect()
			end
			table.clear(rootConns)
		end
	end)

	ClientPlot.onChanged(function()
		rebuildLocalGrid()
	end)
end

-- After in-place move (relocate) so grid keys stay correct.
function PlacedCoralIndex.reindex(part: BasePart)
	PlacedCoralIndex.ensure()
	local parent = part.Parent
	if not parent then
		return
	end
	local plotId = parent.Name
	local bucket = buckets[plotId]
	if not bucket or not bucket.partSet[part] then
		addPart(plotId, part)
		return
	end
	assignGrid(plotId, bucket, part)
end

function PlacedCoralIndex.getParts(plotId: string): { BasePart }
	PlacedCoralIndex.ensure()
	local bucket = buckets[plotId]
	if not bucket then
		return {}
	end
	return bucket.parts
end

function PlacedCoralIndex.countLocal(): number
	PlacedCoralIndex.ensure()
	local plot = ClientPlot.get()
	if not plot then
		return 0
	end
	local bucket = buckets[plot.plotId]
	if not bucket then
		return 0
	end
	local n = 0
	for _, part in ipairs(bucket.parts) do
		if part.Parent then
			n += 1
		end
	end
	return n
end

function PlacedCoralIndex.onChanged(cb: () -> ()): RBXScriptConnection
	return changedEvent.Event:Connect(cb)
end

function PlacedCoralIndex.getAtGrid(plotId: string, gx: number, gy: number, gz: number, ignore: BasePart?): BasePart?
	PlacedCoralIndex.ensure()
	local bucket = buckets[plotId]
	if not bucket then
		return nil
	end
	local key = GridMath.key(math.round(gx), math.round(gy), math.round(gz))
	local part = bucket.byKey[key]
	if part and part ~= ignore and part.Parent then
		return part
	end
	return nil
end

function PlacedCoralIndex.getAtWorld(plotId: string, worldPos: Vector3, plotCf: CFrame, ignore: BasePart?): BasePart?
	local localPos = GridMath.worldToPlotLocal(worldPos, plotCf)
	local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
	return PlacedCoralIndex.getAtGrid(plotId, gx, gy, gz, ignore)
end

return PlacedCoralIndex
