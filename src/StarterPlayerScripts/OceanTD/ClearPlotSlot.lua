--!strict
--[[
	Slot2 Clear Plot UI — extracted from InventoryUI to stay under Luau's 200-local limit.
]]

local ContentProvider = game:GetService("ContentProvider")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiIdleCycle = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiIdleCycle"))
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local ClearPlotVfx = require(script.Parent:WaitForChild("ClearPlotVfx"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local ClearPlotSlot = {}

local SLIDE_PX = 88
local SLIDE_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SLIDE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FLASH_HOLD = 1
local FLASH_FADE = 0.35
local CLEAR_GLOW = Color3.fromRGB(40, 220, 90)
local CLEAR_TEXT_RED = Color3.fromRGB(255, 40, 50)
local CLEAR_CONFIRM_SOUND_ID = "rbxassetid://80024435867181"
local CLEAR_PANEL_W = 420
local CLEAR_PANEL_H = 360
local CLEAR_SCALE_INFO = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CLEAR_SCALE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

export type Deps = {
	mainHUD: ScreenGui,
	playerGui: PlayerGui,
	ensureButton: (GuiObject) -> GuiButton,
	passthroughDecor: (GuiObject, GuiButton) -> (),
	ensureCircle: (GuiObject) -> GuiObject,
	ensureStroke: (GuiObject, string, Color3, number) -> UIStroke,
	getShortcutMode: () -> string,
	getIdlePeriod: () -> number,
	red: Color3,
	green: Color3,
	log: (...any) -> (),
}

local deps: Deps
local slot2: GuiObject? = nil
local slot2Button: GuiButton? = nil
local slot2Circle: GuiObject? = nil
local slot2Stroke: UIStroke? = nil
local slot2ClearLabel: TextLabel? = nil
local slot2IdleStop: UiIdleCycle.StopFn? = nil
local slot2OriginalImage = ""
local slot2OriginalBg = Color3.fromRGB(20, 30, 45)
local slot2OriginalBgTrans = 0.15
local slot2HomePos: UDim2? = nil
local helpSlot2: GuiObject? = nil
local helpSlot2Letter: TextLabel? = nil
local helpSlot2HomePos: UDim2? = nil
local helpSlot2Hit: GuiButton? = nil
local slot2SlideToken = 0
local slot2PressToken = 0
local slot2SuccessToken = 0
local clearConfirmActive = false
local clearConfirmCheck: TextButton? = nil
local clearConfirmCancel: TextButton? = nil
local clearConfirmGui: ScreenGui? = nil
local clearConfirmPanel: Frame? = nil
local clearConfirmList: ScrollingFrame? = nil
local clearConfirmDim: Frame? = nil
local clearConfirmTitle: TextLabel? = nil
local prevGuiSelected: GuiObject? = nil
local clearConfirmOpenedAt = 0
local titleFlashConn: RBXScriptConnection? = nil
local clearScaleToken = 0

local clearConfirmSound = Instance.new("Sound")
clearConfirmSound.Name = "OceanTD_ClearConfirmSound"
clearConfirmSound.SoundId = CLEAR_CONFIRM_SOUND_ID
clearConfirmSound.Volume = 0.95
clearConfirmSound.Parent = SoundService
task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ clearConfirmSound })
	end)
end)

local function stopSlot2IdleCycle()
	if slot2IdleStop then
		slot2IdleStop()
		slot2IdleStop = nil
	end
	if slot2ClearLabel then
		slot2ClearLabel.Visible = false
	end
end

local function applySlot2IdleFrame(showClearText: boolean)
	if not slot2Circle then
		return
	end
	if showClearText then
		if slot2Circle:IsA("ImageLabel") or slot2Circle:IsA("ImageButton") then
			(slot2Circle :: any).Image = ""
		end
		slot2Circle.BackgroundColor3 = Color3.new(0, 0, 0)
		slot2Circle.BackgroundTransparency = 0
		if slot2ClearLabel then
			slot2ClearLabel.Text = "CLEAR\nPLOT"
			slot2ClearLabel.TextColor3 = Color3.new(1, 1, 1)
			slot2ClearLabel.Visible = true
		end
	else
		if slot2Circle:IsA("ImageLabel") or slot2Circle:IsA("ImageButton") then
			(slot2Circle :: any).Image = slot2OriginalImage
		end
		slot2Circle.BackgroundColor3 = slot2OriginalBg
		slot2Circle.BackgroundTransparency = slot2OriginalBgTrans
		if slot2ClearLabel then
			slot2ClearLabel.Visible = false
		end
	end
end

local function startSlot2IdleCycle()
	if not slot2 or not slot2Circle then
		return
	end
	stopSlot2IdleCycle()
	if slot2Stroke then
		slot2Stroke.Enabled = true
		slot2Stroke.Color = Color3.new(1, 1, 1)
		slot2Stroke.Thickness = 2
	end
	UiCircles.ensure(slot2Circle)
	-- Opposite phase of Slot1/3/4 so CLEAR text doesn't land with SAVE/UNDO/BUILD.
	slot2IdleStop = UiIdleCycle.subscribeSharedToggle(deps.getIdlePeriod(), applySlot2IdleFrame, function()
		return InventoryState.isOpen()
			and slot2 ~= nil
			and slot2.Visible
			and not clearConfirmActive
			and not InventoryState.isClearPlotBusy()
	end, true)
end

local function styleSlot2HelpBadge(): boolean
	if not helpSlot2 or not helpSlot2Letter then
		return false
	end
	local mode = deps.getShortcutMode()
	if mode == "touch" then
		return false
	end
	if helpSlot2:IsA("ImageLabel") or helpSlot2:IsA("ImageButton") then
		(helpSlot2 :: any).Image = ""
	end
	helpSlot2.BackgroundColor3 = deps.green
	helpSlot2.BackgroundTransparency = 0
	helpSlot2.Active = true
	UiCircles.ensure(helpSlot2)
	helpSlot2Letter.Text = if mode == "gamepad" then "R3" else "C"
	helpSlot2Letter.TextColor3 = Color3.new(1, 1, 1)
	helpSlot2Letter.Visible = true
	if helpSlot2Hit then
		helpSlot2Hit.Active = true
		helpSlot2Hit.Visible = true
	end
	return true
end

local function slot2HiddenPos(home: UDim2): UDim2
	return home + UDim2.fromOffset(SLIDE_PX, 0)
end

local function isUsingGamepad(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function gatherOwnedPlotParts(): { BasePart }
	local parts: { BasePart } = {}
	local seen: { [BasePart]: boolean } = {}
	local function consider(inst: Instance)
		if not inst:IsA("BasePart") or seen[inst] then
			return
		end
		-- Skip placement ghosts (client-only).
		if typeof(inst:GetAttribute("OceanTD_GhostBaseR")) == "number" then
			return
		end
		local hasId = typeof(inst:GetAttribute("OceanTD_ItemId")) == "string"
			or typeof(inst:GetAttribute("OceanTD_SpeciesId")) == "string"
			or typeof(inst:GetAttribute("OceanTD_PlaceId")) == "string"
		if not hasId then
			return
		end
		seen[inst] = true
		table.insert(parts, inst)
	end

	local root = Workspace:FindFirstChild("OceanTD_Placed")
	if not root then
		return parts
	end
	local mirrored = ClientPlot.get()
	local folder = if mirrored then root:FindFirstChild(mirrored.plotId) else nil
	if folder then
		for _, inst in ipairs(folder:GetChildren()) do
			consider(inst)
		end
	end
	-- Fallback: streaming / folder mismatch — scan all placed visuals.
	if #parts == 0 then
		for _, inst in ipairs(root:GetDescendants()) do
			consider(inst)
		end
	end
	return parts
end

local function resolveItemId(part: BasePart): string
	local idAttr = part:GetAttribute("OceanTD_ItemId")
	if typeof(idAttr) == "string" and idAttr ~= "" then
		return idAttr
	end
	local speciesAttr = part:GetAttribute("OceanTD_SpeciesId")
	if typeof(speciesAttr) == "string" and speciesAttr ~= "" then
		local bySpecies = ItemCatalog.get(speciesAttr)
		if bySpecies then
			return bySpecies.id
		end
		return speciesAttr
	end
	-- Part name is often the speciesId from CoralVisual.
	if part.Name ~= "" and ItemCatalog.get(part.Name) then
		return part.Name
	end
	return "BrainCoral"
end

local function countSeedsByItemId(): { { itemId: string, count: number, displayName: string, icon: string } }
	local tallies: { [string]: number } = {}
	local gathered = gatherOwnedPlotParts()
	for _, p in ipairs(gathered) do
		local id = resolveItemId(p)
		tallies[id] = (tallies[id] or 0) + 1
	end
	local rows = {}
	for itemId, count in pairs(tallies) do
		local def = ItemCatalog.get(itemId)
		table.insert(rows, {
			itemId = itemId,
			count = count,
			displayName = if def then def.displayName else itemId,
			icon = if def then def.icon else "",
		})
	end
	table.sort(rows, function(a, b)
		if a.count == b.count then
			return a.displayName < b.displayName
		end
		return a.count > b.count
	end)
	deps.log("Clear preview seeds", #gathered, "parts →", #rows, "rows")
	return rows
end

local function clearSeedListRows()
	if not clearConfirmList then
		return
	end
	for _, child in ipairs(clearConfirmList:GetChildren()) do
		if child:IsA("GuiObject") and child.Name ~= "UIListLayout" and child.Name ~= "UIPadding" then
			child:Destroy()
		end
	end
end

local function populateSeedList()
	if not clearConfirmList then
		return
	end
	clearSeedListRows()
	local rows = countSeedsByItemId()
	if #rows == 0 then
		local empty = Instance.new("TextLabel")
		empty.Name = "EmptyRow"
		empty.BackgroundTransparency = 1
		empty.Size = UDim2.new(1, -8, 0, 40)
		empty.Font = UiTheme.Font
		empty.Text = "No corals on your plot"
		empty.TextColor3 = Color3.fromRGB(180, 190, 200)
		empty.TextSize = 18
		empty.TextWrapped = true
		empty.ZIndex = 5
		empty.Parent = clearConfirmList
		return
	end
	for i, row in ipairs(rows) do
		local line = Instance.new("Frame")
		line.Name = "Seed_" .. row.itemId
		line.BackgroundColor3 = Color3.fromRGB(24, 36, 52)
		line.BackgroundTransparency = 0.25
		line.BorderSizePixel = 0
		line.Size = UDim2.new(1, -8, 0, 48)
		line.LayoutOrder = i
		line.ZIndex = 5
		line.Parent = clearConfirmList
		local lineCorner = Instance.new("UICorner")
		lineCorner.CornerRadius = UDim.new(0, 8)
		lineCorner.Parent = line

		local icon = Instance.new("ImageLabel")
		icon.Name = "Icon"
		icon.BackgroundTransparency = 1
		icon.Size = UDim2.fromOffset(40, 40)
		icon.Position = UDim2.fromOffset(6, 4)
		icon.Image = row.icon
		icon.ScaleType = Enum.ScaleType.Fit
		icon.ZIndex = 6
		icon.Parent = line

		local name = Instance.new("TextLabel")
		name.Name = "Name"
		name.BackgroundTransparency = 1
		name.Position = UDim2.fromOffset(54, 0)
		name.Size = UDim2.new(1, -140, 1, 0)
		name.Font = UiTheme.Font
		name.Text = row.displayName
		name.TextColor3 = Color3.new(1, 1, 1)
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.TextSize = 20
		name.TextTruncate = Enum.TextTruncate.AtEnd
		name.ZIndex = 6
		name.Parent = line

		local qty = Instance.new("TextLabel")
		qty.Name = "Qty"
		qty.BackgroundTransparency = 1
		qty.AnchorPoint = Vector2.new(1, 0.5)
		qty.Position = UDim2.new(1, -10, 0.5, 0)
		qty.Size = UDim2.fromOffset(72, 40)
		qty.Font = UiTheme.Font
		qty.Text = "+" .. tostring(row.count)
		qty.TextColor3 = deps.green
		qty.TextSize = 22
		qty.ZIndex = 6
		qty.Parent = line
	end
end

function ClearPlotSlot.hideConfirm()
	clearConfirmActive = false
	InventoryState.setClearPlotConfirming(false)
	if titleFlashConn then
		titleFlashConn:Disconnect()
		titleFlashConn = nil
	end
	if clearConfirmTitle then
		clearConfirmTitle.TextColor3 = Color3.new(1, 1, 1)
	end
	if clearConfirmDim then
		clearConfirmDim.Visible = false
	end
	local sel = GuiService.SelectedObject
	if sel == clearConfirmCheck or sel == clearConfirmCancel then
		GuiService.SelectedObject = prevGuiSelected
	end
	prevGuiSelected = nil

	clearScaleToken += 1
	local token = clearScaleToken
	if clearConfirmPanel and clearConfirmPanel.Visible and slot2 then
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
		local btnPos = slot2.AbsolutePosition
		local btnSize = slot2.AbsoluteSize
		local endX = (btnPos.X + btnSize.X * 0.5) / vp.X
		local endY = (btnPos.Y + btnSize.Y * 0.5) / vp.Y
		local tw = TweenService:Create(clearConfirmPanel, CLEAR_SCALE_OUT, {
			Position = UDim2.fromScale(endX, endY),
			Size = UDim2.fromOffset(40, 40),
		})
		tw:Play()
		tw.Completed:Connect(function()
			if token ~= clearScaleToken then
				return
			end
			if clearConfirmPanel then
				clearConfirmPanel.Visible = false
			end
			if clearConfirmGui then
				clearConfirmGui.Enabled = false
			end
		end)
	else
		if clearConfirmPanel then
			clearConfirmPanel.Visible = false
		end
		if clearConfirmGui then
			clearConfirmGui.Enabled = false
		end
	end
end

function ClearPlotSlot.isConfirmActive(): boolean
	return clearConfirmActive
end

-- Gamepad A / Enter: activate whichever button is selected (default CONFIRM).
function ClearPlotSlot.handlePrimaryConfirm()
	if not clearConfirmActive then
		return
	end
	local sel = GuiService.SelectedObject
	if sel == clearConfirmCancel then
		ClearPlotSlot.cancelConfirm()
		return
	end
	ClearPlotSlot.commit()
end

function ClearPlotSlot.refreshHelpBadge()
	if not helpSlot2 or not helpSlot2.Visible then
		return
	end
	if not styleSlot2HelpBadge() then
		helpSlot2.Visible = false
	end
end

function ClearPlotSlot.layoutConfirmIfActive()
	-- Center popup; nothing to re-dock under Slot2.
end

function ClearPlotSlot.cancelConfirm()
	if not clearConfirmActive then
		return
	end
	ClearPlotSlot.hideConfirm()
	if InventoryState.isOpen() and slot2 and slot2.Visible then
		startSlot2IdleCycle()
	end
	deps.log("Clear plot confirm cancelled")
end

local function ensureClearConfirmUi()
	if clearConfirmGui and clearConfirmPanel and clearConfirmCheck and clearConfirmCancel and clearConfirmList then
		return
	end
	local g = Instance.new("ScreenGui")
	g.Name = "OceanTD_ClearPlotConfirm"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 12050
	g.Enabled = false
	g.Parent = deps.playerGui
	clearConfirmGui = g

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.Visible = false
	dim.Active = true
	dim.ZIndex = 1
	dim.Parent = g
	clearConfirmDim = dim
	dim.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			-- Ignore the same click/touch that opened the popup.
			if os.clock() - clearConfirmOpenedAt < 0.35 then
				return
			end
			ClearPlotSlot.cancelConfirm()
		end
	end)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(CLEAR_PANEL_W, CLEAR_PANEL_H)
	panel.BackgroundColor3 = Color3.fromRGB(18, 28, 40)
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.ZIndex = 2
	panel.Active = true
	panel.Parent = g
	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(300, 280)
	sizeConstraint.MaxSize = Vector2.new(520, 480)
	sizeConstraint.Parent = panel
	clearConfirmPanel = panel
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 140, 180)
	stroke.Thickness = 2
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(16, 12)
	title.Size = UDim2.new(1, -32, 0, 36)
	title.Font = UiTheme.Font
	title.Text = "Clear Plot?"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.ZIndex = 3
	title.Parent = panel
	clearConfirmTitle = title

	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromOffset(16, 48)
	subtitle.Size = UDim2.new(1, -32, 0, 22)
	subtitle.Font = UiTheme.Font
	subtitle.Text = "You will receive these seeds back:"
	subtitle.TextColor3 = Color3.fromRGB(170, 190, 210)
	subtitle.TextScaled = true
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.ZIndex = 3
	subtitle.Parent = panel

	local list = Instance.new("ScrollingFrame")
	list.Name = "SeedList"
	list.BackgroundColor3 = Color3.fromRGB(10, 16, 24)
	list.BackgroundTransparency = 0.2
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(16, 78)
	list.Size = UDim2.new(1, -32, 1, -160)
	list.ScrollBarThickness = 6
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ZIndex = 3
	list.Parent = panel
	clearConfirmList = list
	local listCorner = Instance.new("UICorner")
	listCorner.CornerRadius = UDim.new(0, 8)
	listCorner.Parent = list
	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 4)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list
	local listPad = Instance.new("UIPadding")
	listPad.PaddingTop = UDim.new(0, 6)
	listPad.PaddingBottom = UDim.new(0, 6)
	listPad.PaddingLeft = UDim.new(0, 6)
	listPad.PaddingRight = UDim.new(0, 6)
	listPad.Parent = list

	local function makeWideBtn(text: string, color: Color3, strokeColor: Color3): TextButton
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.42, 0, 0, 42)
		b.BackgroundColor3 = color
		b.Font = UiTheme.Font
		b.Text = text
		b.TextColor3 = Color3.new(1, 1, 1)
		b.TextScaled = true
		b.AutoButtonColor = true
		b.Selectable = true
		b.ZIndex = 4
		b.Parent = panel
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 10)
		c.Parent = b
		local edge = Instance.new("UIStroke")
		edge.Color = strokeColor
		edge.Thickness = 2.5
		edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		edge.Parent = b
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.12, 0)
		pad.PaddingBottom = UDim.new(0.12, 0)
		pad.PaddingLeft = UDim.new(0.08, 0)
		pad.PaddingRight = UDim.new(0.08, 0)
		pad.Parent = b
		return b
	end

	clearConfirmCheck = makeWideBtn("CONFIRM", deps.green, Color3.fromRGB(12, 70, 28))
	clearConfirmCancel = makeWideBtn("CANCEL", deps.red, Color3.fromRGB(90, 12, 18))
	clearConfirmCheck.AnchorPoint = Vector2.new(0, 1)
	clearConfirmCheck.Position = UDim2.new(0, 20, 1, -18)
	clearConfirmCancel.AnchorPoint = Vector2.new(1, 1)
	clearConfirmCancel.Position = UDim2.new(1, -20, 1, -18)
	clearConfirmCheck.NextSelectionRight = clearConfirmCancel
	clearConfirmCancel.NextSelectionLeft = clearConfirmCheck
	clearConfirmCheck.Activated:Connect(function()
		ClearPlotSlot.commit()
	end)
	clearConfirmCancel.Activated:Connect(function()
		ClearPlotSlot.cancelConfirm()
	end)
end

local function playSlot2ArmFlash()
	if not slot2Circle then
		return
	end
	slot2PressToken += 1
	local token = slot2PressToken
	stopSlot2IdleCycle()
	if slot2Circle:IsA("ImageLabel") or slot2Circle:IsA("ImageButton") then
		(slot2Circle :: any).Image = ""
	end
	slot2Circle.BackgroundColor3 = CLEAR_GLOW
	slot2Circle.BackgroundTransparency = 0
	if slot2ClearLabel then
		slot2ClearLabel.Text = "CLEAR\nPLOT"
		slot2ClearLabel.TextColor3 = Color3.new(1, 1, 1)
		slot2ClearLabel.Visible = true
	end
	task.delay(FLASH_HOLD, function()
		if token ~= slot2PressToken or not slot2Circle then
			return
		end
		if clearConfirmActive then
			slot2Circle.BackgroundColor3 = Color3.new(0, 0, 0)
			return
		end
		local fade = TweenService:Create(slot2Circle, TweenInfo.new(FLASH_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = Color3.new(0, 0, 0),
		})
		fade:Play()
		fade.Completed:Wait()
		if token ~= slot2PressToken then
			return
		end
		if InventoryState.isOpen() and slot2 and slot2.Visible and not clearConfirmActive and not InventoryState.isClearPlotBusy() then
			startSlot2IdleCycle()
		end
	end)
end

local function playSlot2SuccessFlash()
	if not slot2Circle then
		return
	end
	slot2SuccessToken += 1
	local token = slot2SuccessToken
	slot2PressToken += 1
	stopSlot2IdleCycle()
	if slot2Circle:IsA("ImageLabel") or slot2Circle:IsA("ImageButton") then
		(slot2Circle :: any).Image = ""
	end
	slot2Circle.BackgroundColor3 = CLEAR_GLOW
	slot2Circle.BackgroundTransparency = 0
	if slot2ClearLabel then
		slot2ClearLabel.Text = "CLEAR\nPLOT"
		slot2ClearLabel.TextColor3 = CLEAR_TEXT_RED
		slot2ClearLabel.Visible = true
	end
	task.delay(3, function()
		if token ~= slot2SuccessToken or not slot2Circle then
			return
		end
		if InventoryState.isOpen() and slot2 and slot2.Visible and not clearConfirmActive then
			startSlot2IdleCycle()
		end
	end)
end

function ClearPlotSlot.commit()
	if not clearConfirmActive or InventoryState.isClearPlotBusy() then
		return
	end
	if PlacementController.isActive() then
		PlacementController.cancel()
	end
	if RelocateController.isActive() then
		RelocateController.cancel(true)
	end

	ClearPlotSlot.hideConfirm()
	UiHaptics.pulseShort()
	local liveParts = gatherOwnedPlotParts()
	local parts: { BasePart } = {}
	local cam = Workspace.CurrentCamera
	local fxParent: Instance = cam or Workspace
	local folder = fxParent:FindFirstChild("OceanTD_LocalFX")
	if not (folder and folder:IsA("Folder")) then
		local f = Instance.new("Folder")
		f.Name = "OceanTD_LocalFX"
		f.Parent = fxParent
		folder = f
	end
	for _, src in ipairs(liveParts) do
		local clone = src:Clone()
		clone.Anchored = true
		clone.CanCollide = false
		clone.CanQuery = false
		clone.CanTouch = false
		clone.CastShadow = false
		clone.Parent = folder
		table.insert(parts, clone)
	end

	InventoryState.setClearPlotBusy(true)
	local ok, result = pcall(function()
		return Remotes.getFunction("RequestClearPlot"):InvokeServer()
	end)
	if not (ok and typeof(result) == "table" and result.ok) then
		InventoryState.setClearPlotBusy(false)
		local code = if ok and typeof(result) == "table" then result.errorCode else "Fail"
		deps.log("Clear plot rejected", code)
		for _, p in ipairs(parts) do
			if p.Parent then
				p:Destroy()
			end
		end
		if InventoryState.isOpen() and slot2 and slot2.Visible then
			startSlot2IdleCycle()
		end
		return
	end

	local count = tonumber(result.count) or #parts
	local snd = clearConfirmSound:Clone()
	snd.Parent = SoundService
	snd:Play()
	snd.Ended:Once(function()
		snd:Destroy()
	end)
	playSlot2SuccessFlash()

	ClearPlotVfx.play({
		parts = parts,
		count = count,
		getScrollCenter = function()
			return InventoryState.getScrollCenter()
		end,
		onDone = function()
			InventoryState.setClearPlotBusy(false)
			deps.log("Clear plot VFX done", count)
		end,
	})
	deps.log("Clear plot", count)
end

function ClearPlotSlot.beginConfirm()
	if not InventoryState.isOpen() or not slot2 or not slot2.Visible then
		return
	end
	if InventoryState.isSavePlotsBlocking() then
		return
	end
	if InventoryState.isClearPlotBusy() or ClearPlotVfx.isBusy() then
		return
	end
	if clearConfirmActive then
		return
	end
	if PlacementController.isActive() then
		PlacementController.cancel()
	end
	if RelocateController.isActive() then
		RelocateController.cancel(true)
	end
	ensureClearConfirmUi()
	playSlot2ArmFlash()
	clearConfirmOpenedAt = os.clock()
	clearConfirmActive = true
	InventoryState.setClearPlotConfirming(true)
	clearScaleToken += 1
	if clearConfirmGui then
		clearConfirmGui.Enabled = true
	end
	if clearConfirmDim then
		clearConfirmDim.Visible = true
	end
	if clearConfirmPanel then
		clearConfirmPanel.Visible = true
		-- Scale up from Slot2 into center.
		if slot2 then
			local cam = Workspace.CurrentCamera
			local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
			local btnPos = slot2.AbsolutePosition
			local btnSize = slot2.AbsoluteSize
			local startX = (btnPos.X + btnSize.X * 0.5) / vp.X
			local startY = (btnPos.Y + btnSize.Y * 0.5) / vp.Y
			clearConfirmPanel.Position = UDim2.fromScale(startX, startY)
			clearConfirmPanel.Size = UDim2.fromOffset(40, 40)
			TweenService:Create(clearConfirmPanel, CLEAR_SCALE_INFO, {
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(CLEAR_PANEL_W, CLEAR_PANEL_H),
			}):Play()
		else
			clearConfirmPanel.Position = UDim2.fromScale(0.5, 0.5)
			clearConfirmPanel.Size = UDim2.fromOffset(CLEAR_PANEL_W, CLEAR_PANEL_H)
		end
	end
	-- Populate after layout so the list has a real AbsoluteSize.
	task.defer(function()
		if not clearConfirmActive then
			return
		end
		populateSeedList()
	end)
	if titleFlashConn then
		titleFlashConn:Disconnect()
		titleFlashConn = nil
	end
	if clearConfirmTitle then
		local t0 = os.clock()
		titleFlashConn = RunService.RenderStepped:Connect(function()
			if not clearConfirmActive or not clearConfirmTitle then
				return
			end
			local wave = (math.sin((os.clock() - t0) * 7) + 1) * 0.5
			clearConfirmTitle.TextColor3 = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(255, 45, 55), wave)
		end)
	end
	if isUsingGamepad() and clearConfirmCheck then
		prevGuiSelected = GuiService.SelectedObject
		GuiService.SelectedObject = clearConfirmCheck
	end
	deps.log("Clear plot confirm")
end

function ClearPlotSlot.playReveal()
	if not slot2 or not slot2HomePos then
		return
	end
	slot2SlideToken += 1
	local token = slot2SlideToken
	local home = slot2HomePos
	local hidden = slot2HiddenPos(home)

	slot2.Position = hidden
	slot2.Visible = true
	if slot2Stroke then
		slot2Stroke.Enabled = true
		slot2Stroke.Color = Color3.new(1, 1, 1)
		slot2Stroke.Thickness = 2
	end
	startSlot2IdleCycle()

	local showHelp = styleSlot2HelpBadge()
	if showHelp and helpSlot2 and helpSlot2HomePos then
		helpSlot2.Position = slot2HiddenPos(helpSlot2HomePos)
		helpSlot2.Visible = true
		TweenService:Create(helpSlot2, SLIDE_IN, { Position = helpSlot2HomePos }):Play()
	elseif helpSlot2 then
		helpSlot2.Visible = false
	end

	local tw = TweenService:Create(slot2, SLIDE_IN, { Position = home })
	tw:Play()
	tw.Completed:Wait()
	if token ~= slot2SlideToken then
		return
	end
	slot2.Position = home
	if showHelp and helpSlot2 and helpSlot2HomePos then
		helpSlot2.Position = helpSlot2HomePos
	end
end

function ClearPlotSlot.playHide()
	if not slot2 or not slot2HomePos then
		return
	end
	slot2SlideToken += 1
	local token = slot2SlideToken
	local home = slot2HomePos
	local hidden = slot2HiddenPos(home)

	ClearPlotSlot.hideConfirm()
	stopSlot2IdleCycle()
	slot2PressToken += 1
	if not slot2.Visible then
		if helpSlot2 then
			helpSlot2.Visible = false
			if helpSlot2HomePos then
				helpSlot2.Position = helpSlot2HomePos
			end
		end
		slot2.Position = home
		if slot2Stroke then
			slot2Stroke.Enabled = false
		end
		return
	end

	slot2.Position = home
	local tw = TweenService:Create(slot2, SLIDE_OUT, { Position = hidden })
	tw:Play()
	if helpSlot2 and helpSlot2.Visible and helpSlot2HomePos then
		helpSlot2.Position = helpSlot2HomePos
		TweenService:Create(helpSlot2, SLIDE_OUT, { Position = slot2HiddenPos(helpSlot2HomePos) }):Play()
	end
	tw.Completed:Wait()
	if token ~= slot2SlideToken then
		return
	end
	slot2.Visible = false
	slot2.Position = home
	if slot2Stroke then
		slot2Stroke.Enabled = false
	end
	if helpSlot2 then
		helpSlot2.Visible = false
		if helpSlot2HomePos then
			helpSlot2.Position = helpSlot2HomePos
		end
	end
end

function ClearPlotSlot.syncVisibility()
	if InventoryState.isOpen() then
		if slot2 and slot2HomePos then
			slot2.Position = slot2HomePos
			slot2.Visible = true
			startSlot2IdleCycle()
		end
		if styleSlot2HelpBadge() and helpSlot2 and helpSlot2HomePos then
			helpSlot2.Position = helpSlot2HomePos
			helpSlot2.Visible = true
		elseif helpSlot2 then
			helpSlot2.Visible = false
		end
	else
		ClearPlotSlot.hideConfirm()
		stopSlot2IdleCycle()
		if slot2 and slot2HomePos then
			slot2.Visible = false
			slot2.Position = slot2HomePos
		end
		if slot2Stroke then
			slot2Stroke.Enabled = false
		end
		if helpSlot2 then
			helpSlot2.Visible = false
			if helpSlot2HomePos then
				helpSlot2.Position = helpSlot2HomePos
			end
		end
	end
end

function ClearPlotSlot.onCharacterRemoving()
	ClearPlotVfx.cancel()
	InventoryState.setClearPlotBusy(false)
	ClearPlotSlot.hideConfirm()
end

function ClearPlotSlot.mount(d: Deps)
	deps = d
	local quickbar = d.mainHUD:FindFirstChild("Quickbar")
	local found = if quickbar then quickbar:FindFirstChild("Slot2") else nil
	if found and found:IsA("GuiObject") then
		slot2 = found
		slot2HomePos = slot2.Position
		slot2Button = d.ensureButton(slot2)
		d.passthroughDecor(slot2, slot2Button)
		slot2Circle = d.ensureCircle(slot2)
		UiCircles.forceOnDescendants(slot2)
		if slot2Circle:IsA("ImageLabel") or slot2Circle:IsA("ImageButton") then
			slot2OriginalImage = (slot2Circle :: any).Image
		end
		slot2OriginalBg = slot2Circle.BackgroundColor3
		slot2OriginalBgTrans = slot2Circle.BackgroundTransparency
		slot2Stroke = d.ensureStroke(slot2Circle, "_OceanTD_ClearRing", Color3.new(1, 1, 1), 2)
		slot2Stroke.Enabled = false

		local existingClear = slot2Circle:FindFirstChild("_OceanTD_ClearLabel")
		if existingClear and existingClear:IsA("TextLabel") then
			slot2ClearLabel = existingClear
		else
			if existingClear then
				existingClear:Destroy()
			end
			local lbl = Instance.new("TextLabel")
			lbl.Name = "_OceanTD_ClearLabel"
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.Font = UiTheme.Font
			lbl.Text = "CLEAR\nPLOT"
			lbl.TextColor3 = Color3.new(1, 1, 1)
			lbl.TextScaled = true
			lbl.TextWrapped = true
			lbl.Visible = false
			lbl.ZIndex = slot2Circle.ZIndex + 2
			lbl.Active = false
			lbl.Parent = slot2Circle
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0.12, 0)
			pad.PaddingBottom = UDim.new(0.12, 0)
			pad.PaddingLeft = UDim.new(0.06, 0)
			pad.PaddingRight = UDim.new(0.06, 0)
			pad.Parent = lbl
			slot2ClearLabel = lbl
		end
		slot2.Visible = false
		d.log("Slot2 clear-plot button ready")
	else
		warn("[INV] MainHUD.Quickbar.Slot2 missing — clear plot unavailable")
	end

	local quickbarHelp = d.mainHUD:FindFirstChild("QuickbarHelp")
	if quickbarHelp then
		local hs2 = quickbarHelp:FindFirstChild("Slot2")
		if hs2 and hs2:IsA("GuiObject") then
			helpSlot2 = hs2
			helpSlot2.Active = false
			helpSlot2.Visible = false
			for _, desc in ipairs(helpSlot2:GetDescendants()) do
				if desc:IsA("GuiObject") and desc.Name ~= "_OceanTD_HelpHit" then
					desc.Active = false
				end
			end
			local existingLetter = helpSlot2:FindFirstChild("_OceanTD_HelpLetter")
			if existingLetter and existingLetter:IsA("TextLabel") then
				helpSlot2Letter = existingLetter
			else
				if existingLetter then
					existingLetter:Destroy()
				end
				local letter = Instance.new("TextLabel")
				letter.Name = "_OceanTD_HelpLetter"
				letter.BackgroundTransparency = 1
				letter.Size = UDim2.fromScale(1, 1)
				letter.Font = UiTheme.Font
				letter.Text = "C"
				letter.TextColor3 = Color3.new(1, 1, 1)
				letter.TextScaled = true
				letter.Active = false
				letter.ZIndex = helpSlot2.ZIndex + 5
				letter.Parent = helpSlot2
				local pad = Instance.new("UIPadding")
				pad.PaddingTop = UDim.new(0.15, 0)
				pad.PaddingBottom = UDim.new(0.15, 0)
				pad.PaddingLeft = UDim.new(0.15, 0)
				pad.PaddingRight = UDim.new(0.15, 0)
				pad.Parent = letter
				helpSlot2Letter = letter
			end
			local existingHit = helpSlot2:FindFirstChild("_OceanTD_HelpHit")
			if existingHit and existingHit:IsA("GuiButton") then
				helpSlot2Hit = existingHit
			else
				if existingHit then
					existingHit:Destroy()
				end
				local hit = Instance.new("ImageButton")
				hit.Name = "_OceanTD_HelpHit"
				hit.BackgroundTransparency = 1
				hit.Image = ""
				hit.AutoButtonColor = false
				hit.Size = UDim2.fromScale(1, 1)
				hit.ZIndex = helpSlot2.ZIndex + 10
				hit.Parent = helpSlot2
				helpSlot2Hit = hit
			end
			UiCircles.ensure(helpSlot2)
			helpSlot2HomePos = helpSlot2.Position
		end
	end

	if slot2Button then
		slot2Button.Activated:Connect(function()
			ClearPlotSlot.beginConfirm()
		end)
	end
	if helpSlot2Hit then
		helpSlot2Hit.Activated:Connect(function()
			ClearPlotSlot.beginConfirm()
		end)
	end
end

return ClearPlotSlot
