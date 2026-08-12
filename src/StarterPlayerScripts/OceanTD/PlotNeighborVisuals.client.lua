--!strict
--[[
	Thinner white wireframes for other occupied plots.
	Folder: Workspace.OtherPlayersPlotVisuals
	Skips the local player's plot id. Uses PlotRoster.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local Constants = require(oceanRoot:WaitForChild("Shared"):WaitForChild("Constants"))
local PlotOutlineWire = require(oceanRoot:WaitForChild("Shared"):WaitForChild("PlotOutlineWire"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local player = Players.LocalPlayer

local FOLDER_NAME = "OtherPlayersPlotVisuals"
local NEIGHBOR_THICKNESS = 0.12
local WHITE = Color3.fromRGB(255, 255, 255)
local TRANS = 0.15

export type RosterEntry = {
	plotId: string,
	cframe: CFrame,
	size: Vector3,
	ownerUserId: number,
}

local roster: { RosterEntry } = {}
local folder: Folder? = nil

local rosterRemote = Remotes.get("PlotRoster")
local requestRoster = Remotes.getFunction("RequestPlotRoster")

local function ensureFolder(): Folder
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		folder = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = FOLDER_NAME
	f.Parent = Workspace
	folder = f
	return f
end

local function ownPlotId(): string?
	local plot = ClientPlot.get()
	if plot then
		return plot.plotId
	end
	local attr = player:GetAttribute(Constants.PLOT_ID_ATTR)
	if typeof(attr) == "string" then
		return attr
	end
	return nil
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
			})
		end
	end
	roster = nextRoster
end

local function rebuild()
	local root = ensureFolder()
	PlotOutlineWire.clear(root)
	local own = ownPlotId()
	for _, entry in ipairs(roster) do
		if entry.ownerUserId > 0 and entry.plotId ~= own then
			local sub = Instance.new("Folder")
			sub.Name = entry.plotId
			sub.Parent = root
			PlotOutlineWire.rebuild(sub, entry.cframe, entry.size, {
				thickness = NEIGHBOR_THICKNESS,
				tagOwn = false,
				color = WHITE,
				transparency = TRANS,
				namePrefix = "NEdge",
			})
		end
	end
end

local function refreshRoster()
	local ok, payload = pcall(function()
		return requestRoster:InvokeServer()
	end)
	if ok then
		applyRoster(payload)
		rebuild()
	end
end

rosterRemote.OnClientEvent:Connect(function(payload)
	applyRoster(payload)
	rebuild()
end)

ClientPlot.onChanged(function()
	rebuild()
end)

player:GetAttributeChangedSignal(Constants.PLOT_ID_ATTR):Connect(function()
	rebuild()
end)

task.defer(function()
	refreshRoster()
end)

print("[PLOT_OUTLINE] Neighbor wireframes ready")
