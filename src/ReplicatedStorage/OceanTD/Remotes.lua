-- OceanTD remotes. Folder is named RemoteEvents (not Remotes) so it does not
-- collide with this ModuleScript under ReplicatedStorage.OceanTD.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

local FOLDER_NAME = "RemoteEvents"

local REMOTE_EVENTS = {
	"PlotAssigned",
	"PlotCleared",
	"SessionReady",
	"PlaceResult",
	"ReportHighestWave",
}

local REMOTE_FUNCTIONS = {
	"RequestPlace",
	"RequestMove",
	"RequestRecycle",
	"RequestUndo",
	"RequestClearPlot",
	"RequestGetPlotSaves",
	"RequestSavePlotSlot",
	"RequestLoadPlotSlot",
	"RequestRenamePlotSave",
}

local function getRoot(): Instance
	return ReplicatedStorage:WaitForChild("OceanTD")
end

local function getFolder(): Folder
	local root = getRoot()
	local folder = root:FindFirstChild(FOLDER_NAME)
	if folder and folder:IsA("Folder") then
		return folder
	end
	folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = root
	return folder
end

local function ensureRemoteEvent(folder: Folder, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local re = Instance.new("RemoteEvent")
	re.Name = name
	re.Parent = folder
	return re
end

local function ensureRemoteFunction(folder: Folder, name: string): RemoteFunction
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteFunction") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local rf = Instance.new("RemoteFunction")
	rf.Name = name
	rf.Parent = folder
	return rf
end

function Remotes.initServer()
	local folder = getFolder()
	for _, name in ipairs(REMOTE_EVENTS) do
		ensureRemoteEvent(folder, name)
	end
	for _, name in ipairs(REMOTE_FUNCTIONS) do
		ensureRemoteFunction(folder, name)
	end
	return folder
end

function Remotes.get(name: string): RemoteEvent
	local folder = getFolder()
	if RunService:IsServer() then
		return ensureRemoteEvent(folder, name)
	end
	local remote = folder:WaitForChild(name, 30)
	assert(remote and remote:IsA("RemoteEvent"), "[OceanTD] Missing remote: " .. name)
	return remote
end

function Remotes.getFunction(name: string): RemoteFunction
	local folder = getFolder()
	if RunService:IsServer() then
		return ensureRemoteFunction(folder, name)
	end
	local remote = folder:WaitForChild(name, 30)
	assert(remote and remote:IsA("RemoteFunction"), "[OceanTD] Missing remote function: " .. name)
	return remote
end

return Remotes
