--!strict
--[[
	720p+ class: scale MobileLeftUI.dPad and pin $D + $DCount to the bottom-left corner.
	Mobile class: restore Studio-authored dPad layout.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))

local CORNER_MARGIN = 16
local ROW_PADDING = 10

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

type SavedWidget = {
	parent: Instance,
	position: UDim2,
	anchorPoint: Vector2,
	size: UDim2,
	zIndex: number,
	layoutOrder: number,
}

local savedCount: SavedWidget? = nil
local savedLabel: SavedWidget? = nil
local lastIs720: boolean? = nil
local sizeConn: RBXScriptConnection? = nil

local function saveWidget(widget: GuiObject): SavedWidget
	return {
		parent = widget.Parent :: Instance,
		position = widget.Position,
		anchorPoint = widget.AnchorPoint,
		size = widget.Size,
		zIndex = widget.ZIndex,
		layoutOrder = widget.LayoutOrder,
	}
end

local function saveWidgetDefaults(widget: GuiObject, saved: SavedWidget?): SavedWidget
	if saved then
		return saved
	end
	return saveWidget(widget)
end

local function ensureViewportScale(obj: GuiObject, scale: number): UIScale
	local existing = obj:FindFirstChild(LeftHudLayout.VIEWPORT_SCALE_NAME)
	local s: UIScale
	if existing and existing:IsA("UIScale") then
		s = existing
	else
		s = Instance.new("UIScale")
		s.Name = LeftHudLayout.VIEWPORT_SCALE_NAME
		s.Parent = obj
	end
	s.Scale = scale
	obj:SetAttribute(LeftHudLayout.BASE_SCALE_ATTR, scale)
	return s
end

local function clearViewportScale(obj: GuiObject)
	local sc = obj:FindFirstChild(LeftHudLayout.VIEWPORT_SCALE_NAME)
	if sc and sc:IsA("UIScale") then
		sc.Scale = 1
	end
	obj:SetAttribute(LeftHudLayout.BASE_SCALE_ATTR, 1)
end

local function restoreWidget(widget: GuiObject, saved: SavedWidget?)
	if saved then
		widget.Parent = saved.parent
		widget.Position = saved.position
		widget.AnchorPoint = saved.anchorPoint
		widget.Size = saved.size
		widget.ZIndex = saved.zIndex
		widget.LayoutOrder = saved.layoutOrder
	end
	clearViewportScale(widget)
end

local function ensureSandDollarRow(left: ScreenGui): Frame
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row and row:IsA("Frame") then
		local lay = row:FindFirstChildOfClass("UIListLayout")
		if lay then
			lay.Padding = UDim.new(0, ROW_PADDING)
		end
		return row
	end
	if row then
		row:Destroy()
	end
	row = Instance.new("Frame")
	row.Name = LeftHudLayout.ROW_NAME
	row.BackgroundTransparency = 1
	row.BorderSizePixel = 0
	row.AutomaticSize = Enum.AutomaticSize.XY
	row.Size = UDim2.fromOffset(0, 0)
	row.Parent = left
	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Horizontal
	lay.HorizontalAlignment = Enum.HorizontalAlignment.Left
	lay.VerticalAlignment = Enum.VerticalAlignment.Center
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Padding = UDim.new(0, ROW_PADDING)
	lay.Parent = row
	return row
end

local function prepRowChild(widget: GuiObject, order: number)
	widget.LayoutOrder = order
	widget.AnchorPoint = Vector2.new(0, 0.5)
	widget.Position = UDim2.fromOffset(0, 0)
	widget.ClipsDescendants = false
end

local function layoutSandDollar720p(left: ScreenGui, dLabel: GuiObject?, dCount: GuiObject, scale: number)
	savedCount = saveWidgetDefaults(dCount, savedCount)
	if dLabel then
		savedLabel = saveWidgetDefaults(dLabel, savedLabel)
	end

	local row = ensureSandDollarRow(left)
	row.AnchorPoint = Vector2.new(0, 1)
	local margin = math.floor(CORNER_MARGIN * scale + 0.5)
	row.Position = UDim2.new(0, margin, 1, -margin)
	row.ZIndex = math.max(dCount.ZIndex, if dLabel then dLabel.ZIndex else 0, 40)

	if dLabel then
		prepRowChild(dLabel, 1)
		dLabel.Parent = row
	end
	prepRowChild(dCount, 2)
	dCount.Parent = row

	ensureViewportScale(row, scale)
	dCount:SetAttribute(LeftHudLayout.BASE_SCALE_ATTR, scale)
end

local function restoreSandDollar(left: ScreenGui, dLabel: GuiObject?, dCount: GuiObject?)
	if dCount then
		restoreWidget(dCount, savedCount)
	end
	if dLabel then
		restoreWidget(dLabel, savedLabel)
	end
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row and row:IsA("Frame") then
		row:Destroy()
	end
end

local function applyLeftHud()
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if not left or not left:IsA("ScreenGui") then
		return
	end

	left.IgnoreGuiInset = true
	left.ClipToDeviceSafeArea = false

	local dPad = left:FindFirstChild("dPad")
	if not dPad or not dPad:IsA("GuiObject") then
		return
	end

	local is720 = UiViewportTags.is720p()
	UiPopupScale.attachHud(dPad)

	local dCount = LeftHudLayout.findDCount(left)
	local dLabel = LeftHudLayout.findDLabel(left)
	if dCount then
		if is720 then
			layoutSandDollar720p(left, dLabel, dCount, UiPopupScale.getHud())
		elseif lastIs720 ~= false then
			restoreSandDollar(left, dLabel, dCount)
		end
	end
	lastIs720 = is720
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
		applyLeftHud()
	end)
	applyLeftHud()
end

task.spawn(function()
	playerGui:WaitForChild("MobileLeftUI", 60)
	bindCamera(Workspace.CurrentCamera)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		bindCamera(Workspace.CurrentCamera)
	end)
	task.delay(0.5, applyLeftHud)
	task.delay(1.5, applyLeftHud)
end)
