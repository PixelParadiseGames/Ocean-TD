--!strict
--[[
	Thinner white wireframes for other occupied / friend-preview plots.
	Friend previews also get a top-center name billboard.
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
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local player = Players.LocalPlayer

local FOLDER_NAME = "OtherPlayersPlotVisuals"
local NEIGHBOR_THICKNESS = 0.12
local WHITE = Color3.fromRGB(255, 255, 255)
local TRANS = 0.15
local NAME_LIFT = 4 -- studs above plot top center
local nameCache: { [number]: string } = {}
local rebuildGen = 0

export type RosterEntry = {
	plotId: string,
	cframe: CFrame,
	size: Vector3,
	ownerUserId: number,
	previewUserId: number,
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

local function resolveDisplayName(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	local plr = Players:GetPlayerByUserId(userId)
	if plr then
		nameCache[userId] = plr.DisplayName
		return plr.DisplayName
	end
	local okInfos, infos = pcall(function()
		return Players:GetUserInfosByUserIdsAsync({ userId })
	end)
	if okInfos and typeof(infos) == "table" then
		local info = infos[1]
		if typeof(info) == "table" then
			local display = info.DisplayName or info.Username
			if typeof(display) == "string" and display ~= "" then
				nameCache[userId] = display
				return display
			end
		end
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and typeof(name) == "string" and name ~= "" then
		nameCache[userId] = name
		return name
	end
	return "Friend"
end

local function attachFriendNameLabel(parent: Folder, entry: RosterEntry, gen: number)
	local userId = entry.previewUserId
	if userId <= 0 then
		return
	end

	local anchor = Instance.new("Part")
	anchor.Name = "FriendNameAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = entry.cframe * CFrame.new(0, entry.size.Y * 0.5 + NAME_LIFT, 0)
	anchor.Parent = parent

	local bb = Instance.new("BillboardGui")
	bb.Name = "FriendName"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(280, 40)
	bb.StudsOffset = Vector3.zero
	bb.MaxDistance = 400
	bb.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Name = "Name"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = UiTheme.Font
	label.TextSize = 22
	label.TextColor3 = Color3.fromRGB(240, 248, 255)
	label.TextStrokeTransparency = 0.35
	label.TextStrokeColor3 = Color3.fromRGB(0, 20, 32)
	label.TextScaled = false
	label.Text = nameCache[userId] or "…"
	label.Parent = bb

	if nameCache[userId] then
		return
	end
	task.spawn(function()
		local name = resolveDisplayName(userId)
		if gen ~= rebuildGen or not label.Parent then
			return
		end
		label.Text = name
	end)
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
				previewUserId = num(entry.previewUserId, 0),
			})
		end
	end
	roster = nextRoster
end

local function rebuild()
	rebuildGen += 1
	local gen = rebuildGen
	local root = ensureFolder()
	PlotOutlineWire.clear(root)
	local own = ownPlotId()
	for _, entry in ipairs(roster) do
		local show = entry.plotId ~= own and (entry.ownerUserId > 0 or entry.previewUserId > 0)
		if show then
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
			if entry.previewUserId > 0 then
				attachFriendNameLabel(sub, entry, gen)
			end
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
