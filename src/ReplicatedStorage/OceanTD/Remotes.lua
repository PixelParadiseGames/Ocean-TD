-- OceanTD remotes. Folder is named RemoteEvents (not Remotes) so it does not
-- collide with this ModuleScript under ReplicatedStorage.OceanTD.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

local FOLDER_NAME = "RemoteEvents"

local REMOTE_EVENTS = {
	"PlotAssigned", -- server -> owner: PlotBoundsPayload
	"PlotCleared", -- server -> owner
	"SessionReady", -- server -> owner
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
	-- Do not reuse a non-Folder named similarly; create the events folder.
	folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = root
	return folder
end

local function ensureRemote(folder: Folder, name: string): RemoteEvent
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

function Remotes.initServer()
	local folder = getFolder()
	for _, name in ipairs(REMOTE_EVENTS) do
		ensureRemote(folder, name)
	end
	return folder
end

function Remotes.get(name: string): RemoteEvent
	local folder = getFolder()
	if RunService:IsServer() then
		return ensureRemote(folder, name)
	end
	local remote = folder:WaitForChild(name, 30)
	assert(remote and remote:IsA("RemoteEvent"), "[OceanTD] Missing remote: " .. name)
	return remote
end

return Remotes
