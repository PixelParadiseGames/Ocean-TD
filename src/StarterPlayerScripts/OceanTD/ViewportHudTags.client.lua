--!strict
--[[
	Shows/hides ScreenGuis tagged "Mobile" or "720p", and always toggles the
	known right HUDs by name (MobileRightHUD / 720pRightHUD).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local TAG_MOBILE = UiViewportTags.MOBILE
local TAG_720P = UiViewportTags.P720

local sizeConn: RBXScriptConnection? = nil
local lastIs720p: boolean? = nil
local dualTagWarned: { [Instance]: boolean } = {}

local function joinIntroBusy(): boolean
	return playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true
end

local function applyGui(gui: Instance, is720p: boolean)
	if not gui:IsA("ScreenGui") or not gui:IsDescendantOf(playerGui) then
		return
	end
	-- Join intro owns HUD visibility — don't fight its suppress (wave/start flash).
	if joinIntroBusy() then
		return
	end
	local hasMobile = CollectionService:HasTag(gui, TAG_MOBILE)
	local has720 = CollectionService:HasTag(gui, TAG_720P)
	if not hasMobile and not has720 then
		return
	end
	if hasMobile and has720 then
		if not dualTagWarned[gui] then
			dualTagWarned[gui] = true
			warn("[UI] ScreenGui has both Mobile and 720p tags (use one):", gui:GetFullName())
		end
		gui.Enabled = is720p
		return
	end
	if hasMobile then
		gui.Enabled = not is720p
	else
		gui.Enabled = is720p
	end
end

local function applyKnownRightHuds(is720p: boolean)
	-- Join intro owns HUD visibility — don't re-enable wave/start chrome mid-intro.
	if joinIntroBusy() then
		return
	end
	-- Name-based so a missing CollectionService tag can't leave 720pRightHUD stuck disabled.
	local order = UiViewportTags.RIGHT_HUD_DISPLAY_ORDER
	local mobile = playerGui:FindFirstChild(UiViewportTags.MOBILE_RIGHT_HUD)
	if mobile and mobile:IsA("ScreenGui") then
		mobile.Enabled = not is720p
		mobile.DisplayOrder = math.max(mobile.DisplayOrder, order)
	end
	local p720 = playerGui:FindFirstChild(UiViewportTags.P720_RIGHT_HUD)
	if p720 and p720:IsA("ScreenGui") then
		p720.Enabled = is720p
		p720.DisplayOrder = math.max(p720.DisplayOrder, order)
	end
end

local function refreshAll(force: boolean?)
	if joinIntroBusy() then
		-- Still track class so the first post-intro refresh applies the right HUD.
		lastIs720p = UiViewportTags.is720p(UiViewportTags.readViewport())
		return
	end
	local vp = UiViewportTags.readViewport()
	local is720p = UiViewportTags.is720p(vp)
	if not force and lastIs720p == is720p then
		return
	end
	lastIs720p = is720p
	applyKnownRightHuds(is720p)
	for _, gui in ipairs(CollectionService:GetTagged(TAG_MOBILE)) do
		applyGui(gui, is720p)
	end
	for _, gui in ipairs(CollectionService:GetTagged(TAG_720P)) do
		applyGui(gui, is720p)
	end
end

local function bindCamera(cam: Camera?)
	if sizeConn then
		sizeConn:Disconnect()
		sizeConn = nil
	end
	if not cam then
		return
	end
	sizeConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		refreshAll(false)
	end)
	refreshAll(true)
end

bindCamera(Workspace.CurrentCamera)
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	bindCamera(Workspace.CurrentCamera)
end)
playerGui:GetAttributeChangedSignal("OceanTD_JoinIntroBusy"):Connect(function()
	if not joinIntroBusy() then
		refreshAll(true)
	end
end)

local function onTagged(inst: Instance)
	if lastIs720p == nil then
		refreshAll(true)
		return
	end
	applyGui(inst, lastIs720p)
end

CollectionService:GetInstanceAddedSignal(TAG_MOBILE):Connect(onTagged)
CollectionService:GetInstanceAddedSignal(TAG_720P):Connect(onTagged)

playerGui.ChildAdded:Connect(function(child)
	if child:IsA("ScreenGui") then
		task.defer(function()
			if lastIs720p ~= nil then
				applyKnownRightHuds(lastIs720p)
				applyGui(child, lastIs720p)
			else
				refreshAll(true)
			end
		end)
	end
end)

refreshAll(true)
-- Orientation / DPI can settle a beat after join on real devices.
task.delay(0.5, function()
	refreshAll(true)
end)
task.delay(1.5, function()
	refreshAll(true)
end)

local vp0 = UiViewportTags.readViewport()
print(
	"[UI] ViewportHudTags ready",
	string.format("vp=%.0fx%.0f", vp0.X, vp0.Y),
	if UiViewportTags.is720p(vp0) then "→720pRightHUD" else "→MobileRightHUD"
)
