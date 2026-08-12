--!strict
--[[
	Backpack / inventory UI — owner script.

	Studio contract: PlayerGui ScreenGui with Quickbar.Slot4 (backpack button).
	Main HUD is split by resolution — tag variants Mobile / 720p (optional MainHUD).
	Panel is built in code under the active Main HUD.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local UiIdleCycle = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiIdleCycle"))
local UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics"))
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local LocalShovel = require(script.Parent:WaitForChild("LocalShovel"))
local HandOrb = require(script.Parent:WaitForChild("HandOrb"))
local ClearPlotSlot = require(script.Parent:WaitForChild("ClearPlotSlot"))
local UndoSlot = require(script.Parent:WaitForChild("UndoSlot"))
local SavePlotSlot = require(script.Parent:WaitForChild("SavePlotSlot"))
local WaveSlot = require(script.Parent:WaitForChild("WaveSlot"))
local SkipWaveSlot = require(script.Parent:WaitForChild("SkipWaveSlot"))
local WaveSpeedSlot = require(script.Parent:WaitForChild("WaveSpeedSlot"))
local WaveSign = require(script.Parent:WaitForChild("WaveSign"))

local TWEEN_OPEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TWEEN_CLOSE = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local RED = Color3.fromRGB(220, 50, 55)
local DARK_RED = Color3.fromRGB(120, 10, 20)
local BRIGHT_YELLOW = Color3.fromRGB(255, 230, 40)
local GREEN = Color3.fromRGB(40, 220, 110)
local PANEL_WIDTH_SCALE = 0.33
local SLOT4_GAP_PX = 8

-- Left HUD chrome hidden while backpack is open (dPadIcon is owned by FreeCam).
local hiddenLeftUiForBackpack: { { gui: GuiObject, wasVisible: boolean } } = {}

local function rememberHideLeftForBackpack(gui: GuiObject)
	for _, entry in ipairs(hiddenLeftUiForBackpack) do
		if entry.gui == gui then
			return
		end
	end
	table.insert(hiddenLeftUiForBackpack, {
		gui = gui,
		wasVisible = gui.Visible,
	})
	gui.Visible = false
end

local function setLeftUiHiddenForBackpack(hide: boolean)
	if hide then
		if #hiddenLeftUiForBackpack > 0 then
			return
		end
		local left = playerGui:FindFirstChild("MobileLeftUI")
		if not left then
			return
		end
		local dPad = left:FindFirstChild("dPad")
		if dPad then
			for _, ch in ipairs(dPad:GetChildren()) do
				-- FreeCam syncs dPadIcon from InventoryState.isOpen().
				if ch:IsA("GuiObject") and ch.Name ~= "dPadIcon" and ch.Name ~= "$DCount" then
					rememberHideLeftForBackpack(ch)
				end
			end
		end
		for _, ch in ipairs(left:GetChildren()) do
			if ch:IsA("GuiObject") and ch.Name ~= "dPad" then
				rememberHideLeftForBackpack(ch)
			end
		end
	else
		-- Skills owns left UI while bubbles are open — don't fight that restore.
		if playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true then
			table.clear(hiddenLeftUiForBackpack)
			return
		end
		for _, entry in ipairs(hiddenLeftUiForBackpack) do
			if entry.gui.Parent then
				entry.gui.Visible = entry.wasVisible
			end
		end
		table.clear(hiddenLeftUiForBackpack)
	end
end

-- TEMP layout fill only. Set to 0 to show real ItemCatalog entries.
-- Does not register fake items in ItemCatalog.
local TEMP_BRAIN_CORAL_SLOT_COUNT = 24

local function log(...: any)
	print("[INV]", ...)
end

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end)

local function waitMainHUD(): ScreenGui
	local hud = UiViewportTags.waitMainHud(playerGui :: PlayerGui, 60)
	local is720 = UiViewportTags.is720p(UiViewportTags.readViewport())
	local vp = UiViewportTags.readViewport()
	-- Don't rely on ViewportHudTags script order — force the known right HUDs now.
	local mobile = playerGui:FindFirstChild(UiViewportTags.MOBILE_RIGHT_HUD)
	if mobile and mobile:IsA("ScreenGui") then
		mobile.Enabled = not is720
	end
	local p720 = playerGui:FindFirstChild(UiViewportTags.P720_RIGHT_HUD)
	if p720 and p720:IsA("ScreenGui") then
		p720.Enabled = is720
	end
	log(
		"Main HUD:",
		hud:GetFullName(),
		if is720 then "(720p)" else "(Mobile)",
		string.format("viewport=%.0fx%.0f", vp.X, vp.Y)
	)
	return hud
end

local function findQuickbarSlot4(mainHUD: Instance): GuiObject
	local quickbar = mainHUD:WaitForChild("Quickbar", 30)
	assert(quickbar, "[INV] MainHUD.Quickbar missing")
	local slot4 = quickbar:WaitForChild("Slot4", 30)
	assert(slot4 and slot4:IsA("GuiObject"), "[INV] MainHUD.Quickbar.Slot4 missing")
	return slot4 :: GuiObject
end

local function rectsOverlap(aPos: Vector2, aSize: Vector2, bPos: Vector2, bSize: Vector2): boolean
	return aPos.X < bPos.X + bSize.X
		and aPos.X + aSize.X > bPos.X
		and aPos.Y < bPos.Y + bSize.Y
		and aPos.Y + aSize.Y > bPos.Y
end

--[[
	Old-game lesson (PC works / phone doesn't):
	Invisible overlays (QuickbarHelp, key hints, full-HUD frames) with Active=true sit above
	Quickbar and eat touches even when children are hidden. Hide + Active=false on touch.
]]
local function disarmTouchBlockingOverlays(mainHUD: Instance, slot: GuiObject)
	if not UserInputService.TouchEnabled then
		return
	end

	local named = { "QuickbarHelp", "KeyHints", "QuickbarHints", "MobileBlocker", "TouchBlocker" }
	for _, name in ipairs(named) do
		local o = mainHUD:FindFirstChild(name)
		if o and o:IsA("GuiObject") then
			-- Keep QuickbarHelp visible for Y/Q badge; only disable hit-testing.
			if name == "QuickbarHelp" then
				o.Active = false
				for _, d in ipairs(o:GetDescendants()) do
					if d:IsA("GuiObject") then
						d.Active = false
					end
				end
			else
				o.Visible = false
				o.Active = false
			end
			log("Touch disarm:", o:GetFullName())
		end
	end

	local slotPos = slot.AbsolutePosition
	local slotSize = slot.AbsoluteSize
	if slotSize.X < 1 or slotSize.Y < 1 then
		return
	end

	local keepName: { [string]: boolean } = {
		Quickbar = true,
		BackpackHost = true,
	}

	for _, child in ipairs(mainHUD:GetChildren()) do
		if child:IsA("GuiObject") and not keepName[child.Name] then
			local go = child :: GuiObject
			-- Active parent still receives hits even if descendants are hidden.
			if go.Active and rectsOverlap(go.AbsolutePosition, go.AbsoluteSize, slotPos, slotSize) then
				-- Only disarm non-interactive chrome / large overlays — never the quickbar itself.
				go.Active = false
				log("Touch disarm Active overlay:", go:GetFullName())
			end
		end
	end

	-- Quickbar children other than slots sometimes include hint layers.
	local quickbar = mainHUD:FindFirstChild("Quickbar")
	if quickbar then
		for _, child in ipairs(quickbar:GetChildren()) do
			if child:IsA("GuiObject") and not string.match(child.Name, "^Slot%d+$") then
				local go = child :: GuiObject
				if go.Active then
					go.Active = false
					log("Touch disarm under Quickbar:", go:GetFullName())
				end
			end
		end
	end
end

--[[
	Ensure Slot4 itself (or a full-size child) is a GuiButton so Activated works on mobile.
	Prefer promoting/creating one ImageButton covering the slot — old game used Slot4.Activated.
]]
local function ensureSlot4GuiButton(slot: GuiObject): GuiButton
	if slot:IsA("GuiButton") then
		slot.Active = true
		slot.Visible = true
		slot.Selectable = false
		return slot
	end

	local existing = slot:FindFirstChild("_OceanTD_Hit")
	if existing and existing:IsA("GuiButton") then
		existing.Active = true
		existing.Selectable = false
		existing.Size = UDim2.fromScale(1, 1)
		existing.ZIndex = 100
		return existing
	end

	-- TextButton empty hits are reliable on touch; Image="" ImageButtons often are not.
	local hit = Instance.new("TextButton")
	hit.Name = "_OceanTD_Hit"
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.BackgroundColor3 = Color3.new(1, 1, 1)
	hit.BackgroundTransparency = 0.99
	hit.BorderSizePixel = 0
	hit.Size = UDim2.fromScale(1, 1)
	hit.Position = UDim2.fromScale(0, 0)
	hit.ZIndex = 100
	hit.Active = true
	hit.Selectable = false
	hit.Parent = slot
	return hit
end

-- Non-button chrome must not swallow touches.
local function passthroughDecor(slot: GuiObject, hit: GuiButton)
	hit.Active = true
	hit.Visible = true
	hit.ZIndex = math.max(hit.ZIndex, 100)
	for _, d in ipairs(slot:GetDescendants()) do
		if d:IsA("GuiObject") and d ~= hit then
			d.Active = false
		end
	end
	if slot:IsA("GuiObject") and slot ~= hit then
		-- Frame parent should not eat hits; the GuiButton child receives them.
		slot.Active = false
	end
end

local function ensureCircle(slot: GuiObject): GuiObject
	local circle = slot:FindFirstChild("Circle")
	if circle and circle:IsA("GuiObject") then
		UiCircles.ensure(circle)
		UiCircles.forceOnDescendants(slot)
		return circle
	end
	local created = Instance.new("ImageLabel")
	created.Name = "Circle"
	created.BackgroundTransparency = 1
	created.Size = UDim2.fromScale(1, 1)
	created.ScaleType = Enum.ScaleType.Fit
	if slot:IsA("ImageLabel") or slot:IsA("ImageButton") then
		created.Image = (slot :: any).Image
		;(slot :: any).Image = ""
	end
	created.Parent = slot
	UiCircles.ensure(created)
	return created
end

local function ensureStroke(gui: GuiObject, name: string, color: Color3, thickness: number): UIStroke
	local stroke = gui:FindFirstChild(name)
	if not (stroke and stroke:IsA("UIStroke")) then
		if stroke then
			stroke:Destroy()
		end
		stroke = Instance.new("UIStroke")
		stroke.Name = name
		stroke.Parent = gui
	end
	local s = stroke :: UIStroke
	s.Color = color
	s.Thickness = thickness
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	return s
end

----------------------------------------------------------------
-- Slot4 closed / open chrome
----------------------------------------------------------------

local mainHUD = waitMainHUD()
mainHUD.DisplayOrder = math.max(mainHUD.DisplayOrder, UiViewportTags.RIGHT_HUD_DISPLAY_ORDER)

local slot4 = findQuickbarSlot4(mainHUD)
local slotButton = ensureSlot4GuiButton(slot4)
local circle = ensureCircle(slot4)
UiCircles.forceOnDescendants(slot4)
passthroughDecor(slot4, slotButton)
disarmTouchBlockingOverlays(mainHUD, slot4)


-- QuickbarHelp.Slot4 — shortcut badge (Y / Q). Click/tap opens backpack like Slot4.
local quickbarHelp = mainHUD:FindFirstChild("QuickbarHelp")
local helpSlot4: GuiObject? = nil
local helpLetter: TextLabel? = nil
local helpHitButton: GuiButton? = nil
if quickbarHelp then
	local hs = quickbarHelp:FindFirstChild("Slot4")
	if hs and hs:IsA("GuiObject") then
		helpSlot4 = hs
		helpSlot4.Active = true
		for _, d in ipairs(helpSlot4:GetDescendants()) do
			if d:IsA("GuiObject") and d.Name ~= "_OceanTD_HelpHit" then
				d.Active = false
			end
		end
		local existingLetter = helpSlot4:FindFirstChild("_OceanTD_HelpLetter")
		if existingLetter and existingLetter:IsA("TextLabel") then
			helpLetter = existingLetter
		else
			if existingLetter then
				existingLetter:Destroy()
			end
			local letter = Instance.new("TextLabel")
			letter.Name = "_OceanTD_HelpLetter"
			letter.BackgroundTransparency = 1
			letter.Size = UDim2.fromScale(1, 1)
			letter.Font = UiTheme.Font
			letter.Text = "Q"
			letter.TextColor3 = Color3.new(0, 0, 0)
			letter.TextScaled = true
			letter.Active = false
			letter.ZIndex = helpSlot4.ZIndex + 5
			letter.Parent = helpSlot4
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0.15, 0)
			pad.PaddingBottom = UDim.new(0.15, 0)
			pad.PaddingLeft = UDim.new(0.15, 0)
			pad.PaddingRight = UDim.new(0.15, 0)
			pad.Parent = letter
			helpLetter = letter
		end
		local existingHit = helpSlot4:FindFirstChild("_OceanTD_HelpHit")
		if existingHit and existingHit:IsA("GuiButton") then
			helpHitButton = existingHit
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
			hit.ZIndex = helpSlot4.ZIndex + 10
			hit.Parent = helpSlot4
			helpHitButton = hit
		end
		UiCircles.ensure(helpSlot4)
	end
end


-- Re-run after layout settles (mobile rescale) and if Studio adds QuickbarHelp later.
task.defer(function()
	disarmTouchBlockingOverlays(mainHUD, slot4)
end)
mainHUD.ChildAdded:Connect(function()
	task.defer(function()
		disarmTouchBlockingOverlays(mainHUD, slot4)
	end)
end)
slot4:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	disarmTouchBlockingOverlays(mainHUD, slot4)
end)

local closedStroke = ensureStroke(circle, "_OceanTD_ClosedRing", BRIGHT_YELLOW, 3)
closedStroke.Enabled = true

local originalCircleImage = ""
if circle:IsA("ImageLabel") or circle:IsA("ImageButton") then
	originalCircleImage = (circle :: any).Image
end
local originalCircleBg = circle.BackgroundColor3
local originalCircleBgTrans = circle.BackgroundTransparency

local closeX = circle:FindFirstChild("_OceanTD_CloseX") :: TextLabel?
if not closeX then
	closeX = Instance.new("TextLabel")
	closeX.Name = "_OceanTD_CloseX"
	closeX.BackgroundTransparency = 1
	closeX.Size = UDim2.fromScale(1, 1)
	closeX.Font = UiTheme.Font
	closeX.Text = "X"
	closeX.TextColor3 = Color3.new(1, 1, 1)
	closeX.TextScaled = true
	closeX.Visible = false
	closeX.ZIndex = circle.ZIndex + 2
	closeX.Active = false
	closeX.Parent = circle
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.18, 0)
	pad.PaddingBottom = UDim.new(0.18, 0)
	pad.PaddingLeft = UDim.new(0.18, 0)
	pad.PaddingRight = UDim.new(0.18, 0)
	pad.Parent = closeX
end

local closeXStroke = closeX:FindFirstChild("_OceanTD_CloseXStroke") :: UIStroke?
if not (closeXStroke and closeXStroke:IsA("UIStroke")) then
	if closeXStroke then
		closeXStroke:Destroy()
	end
	closeXStroke = Instance.new("UIStroke")
	closeXStroke.Name = "_OceanTD_CloseXStroke"
	closeXStroke.Parent = closeX
end
closeXStroke.Color = DARK_RED
closeXStroke.Thickness = 2
closeXStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
closeXStroke.Enabled = false

local closeXPulseTween: Tween? = nil
local closeLabelStop: UiIdleCycle.StopFn? = nil
local closedIdleStop: UiIdleCycle.StopFn? = nil
local SLOT_IDLE_PERIOD = 2 -- shovel / BUILD and undo / UNDO idle cycle

local buildLabel = circle:FindFirstChild("_OceanTD_BuildLabel") :: TextLabel?
if not buildLabel then
	buildLabel = Instance.new("TextLabel")
	buildLabel.Name = "_OceanTD_BuildLabel"
	buildLabel.BackgroundTransparency = 1
	buildLabel.Size = UDim2.fromScale(1, 1)
	buildLabel.Font = UiTheme.Font
	buildLabel.Text = "BUILD"
	buildLabel.TextColor3 = Color3.new(1, 1, 1)
	buildLabel.TextScaled = true
	buildLabel.Visible = false
	buildLabel.ZIndex = circle.ZIndex + 2
	buildLabel.Active = false
	buildLabel.Parent = circle
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.22, 0)
	pad.PaddingBottom = UDim.new(0.22, 0)
	pad.PaddingLeft = UDim.new(0.08, 0)
	pad.PaddingRight = UDim.new(0.08, 0)
	pad.Parent = buildLabel
end

local function stopCloseLabelCycle()
	if closeLabelStop then
		closeLabelStop()
		closeLabelStop = nil
	end
end

local function stopClosedIdleCycle()
	if closedIdleStop then
		closedIdleStop()
		closedIdleStop = nil
	end
	if buildLabel then
		buildLabel.Visible = false
	end
end

local function stopCloseXPulse()
	if closeXPulseTween then
		closeXPulseTween:Cancel()
		closeXPulseTween = nil
	end
	closeXStroke.Enabled = false
	closeXStroke.Transparency = 0
	closeXStroke.Thickness = 2
end

local function startCloseXPulse()
	stopCloseXPulse()
	closeXStroke.Enabled = true
	closeXStroke.Color = DARK_RED
	closeXStroke.Thickness = 1.5
	closeXStroke.Transparency = 0.05
	-- Engine tween loop (~0.55s half-cycle) — no per-frame Lua.
	local info = TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
	closeXPulseTween = TweenService:Create(closeXStroke, info, {
		Thickness = 7,
		Transparency = 0.4,
	})
	closeXPulseTween:Play()
end

local function applyClosedIdleFrame(showBuild: boolean)
	if showBuild then
		if circle:IsA("ImageLabel") or circle:IsA("ImageButton") then
			(circle :: any).Image = ""
		end
		circle.BackgroundColor3 = Color3.new(0, 0, 0)
		circle.BackgroundTransparency = 0
		buildLabel.Visible = true
		closeX.Visible = false
	else
		if circle:IsA("ImageLabel") or circle:IsA("ImageButton") then
			(circle :: any).Image = originalCircleImage
		end
		circle.BackgroundColor3 = originalCircleBg
		circle.BackgroundTransparency = originalCircleBgTrans
		buildLabel.Visible = false
		closeX.Visible = false
	end
end

local function startClosedIdleCycle()
	stopClosedIdleCycle()
	closedIdleStop = UiIdleCycle.subscribeSharedToggle(SLOT_IDLE_PERIOD, applyClosedIdleFrame, function()
		return not InventoryState.isOpen()
	end)
end

local function applySlotClosedChrome()
	stopCloseXPulse()
	stopCloseLabelCycle()
	closedStroke.Enabled = true
	closedStroke.Color = BRIGHT_YELLOW
	closedStroke.Thickness = 3
	closeX.Visible = false
	closeX.Text = "X"
	startClosedIdleCycle()
end

local function applySlotOpenChrome()
	stopClosedIdleCycle()
	closedStroke.Enabled = true
	closedStroke.Color = Color3.new(1, 1, 1)
	closedStroke.Thickness = 2
	closeX.Visible = true
	buildLabel.Visible = false
	-- Letter set by refreshShortcutHints (Y / Q / X).
	closeX.Text = "X"
	if circle:IsA("ImageLabel") or circle:IsA("ImageButton") then
		(circle :: any).Image = ""
	end
	circle.BackgroundColor3 = RED
	circle.BackgroundTransparency = 0
	UiCircles.ensure(circle)
	startCloseXPulse()
end

----------------------------------------------------------------
-- Backpack panel — docks under Slot4 bottom, right 33%
----------------------------------------------------------------

local host = mainHUD:FindFirstChild("BackpackHost")
if host then
	host:Destroy()
end
host = Instance.new("Frame")
host.Name = "BackpackHost"
host.BackgroundTransparency = 1
host.Active = false -- must stay false or it blocks Slot4 / world UI when open
host.Size = UDim2.fromScale(1, 1)
host.Position = UDim2.fromScale(0, 0)
host.Visible = false
host.ZIndex = 50
host.Parent = mainHUD

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(1, 0)
panel.BackgroundColor3 = Color3.fromRGB(12, 18, 28)
panel.BackgroundTransparency = 0.12
panel.BorderSizePixel = 0
panel.ClipsDescendants = true
panel.Parent = host

Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = BRIGHT_YELLOW
panelStroke.Thickness = 1.5
panelStroke.Parent = panel

local uiScale = Instance.new("UIScale")
uiScale.Scale = 0.05
uiScale.Parent = panel

local scrollRoot = Instance.new("Frame")
scrollRoot.Name = "ScrollRoot"
scrollRoot.BackgroundTransparency = 1
scrollRoot.Position = UDim2.new(0, 8, 0, 8)
scrollRoot.Size = UDim2.new(1, -16, 1, -16)
scrollRoot.Parent = panel

local scroll = Instance.new("ScrollingFrame")
scroll.Name = "ItemScroll"
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.Size = UDim2.fromScale(1, 1)
scroll.ScrollBarThickness = 6
scroll.ScrollBarImageColor3 = Color3.fromRGB(120, 160, 200)
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.ScrollingDirection = Enum.ScrollingDirection.Y
scroll.Active = true
scroll.ScrollingEnabled = true
scroll.ElasticBehavior = Enum.ElasticBehavior.Always
scroll.Parent = scrollRoot

local grid = Instance.new("UIGridLayout")
grid.Name = "Grid3"
grid.CellPadding = UDim2.fromOffset(10, 14)
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.FillDirectionMaxCells = 3
grid.Parent = scroll

local gridPad = Instance.new("UIPadding")
gridPad.PaddingTop = UDim.new(0, 6)
gridPad.PaddingBottom = UDim.new(0, 6)
gridPad.PaddingLeft = UDim.new(0, 6)
gridPad.PaddingRight = UDim.new(0, 6)
gridPad.Parent = scroll

local itemButtons: { ImageButton } = {}

local function backpackItemLabelHeight(): number
	-- Mobile (<720): fixed 14px — looks correct; do not change.
	if not UiViewportTags.is720p(UiViewportTags.readViewport()) then
		return 14
	end
	return math.clamp(math.floor(14 * UiPopupScale.get()), 20, 40)
end

local function backpackItemLabelRoom(): number
	-- Extra cell height under the icon for the name label.
	if not UiViewportTags.is720p(UiViewportTags.readViewport()) then
		return 18
	end
	return math.clamp(math.floor(18 * UiPopupScale.get()), 26, 52)
end

local function refreshGridCellSize()
	local width = scroll.AbsoluteSize.X
	if width <= 1 then
		return
	end
	-- 3 columns: padding L/R (6 each) + 2 horizontal gaps (CellPadding 10).
	local hPad = 12
	local gap = 10
	local bar = scroll.ScrollBarThickness
	local usable = width - hPad - gap * 2 - bar
	local cell = math.floor(usable / 3)
	if UiViewportTags.is720p(UiViewportTags.readViewport()) then
		-- Stretch cells to fill the wider 720p panel (no 120px cap).
		cell = math.max(56, cell)
	else
		-- Mobile: keep compact capped cells (looks correct under 720p).
		cell = math.clamp(cell, 56, 120)
	end
	local labelRoom = backpackItemLabelRoom()
	grid.CellSize = UDim2.fromOffset(cell, cell + labelRoom)
	local labelH = backpackItemLabelHeight()
	for _, btn in ipairs(itemButtons) do
		local nameLbl = btn:FindFirstChild("Name")
		if nameLbl and nameLbl:IsA("TextLabel") then
			nameLbl.Size = UDim2.new(1, -4, 0, labelH)
		end
	end
end

scroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(refreshGridCellSize)

local animating = false

local function dockRect(): (number, number, number, number)
	local hostSize = host.AbsoluteSize
	if hostSize.X < 1 then
		local cam = workspace.CurrentCamera
		hostSize = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	end
	local topScreen = slot4.AbsolutePosition.Y + slot4.AbsoluteSize.Y + SLOT4_GAP_PX
	local localTop = topScreen - host.AbsolutePosition.Y
	local width = hostSize.X * PANEL_WIDTH_SCALE
	local height = math.max(hostSize.Y - localTop - 4, 120)
	return hostSize.X, localTop, width, height
end

local function applyDockedLayout()
	local right, top, width, height = dockRect()
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.fromOffset(right, top)
	panel.Size = UDim2.fromOffset(width, height)
	uiScale.Scale = 1
	refreshGridCellSize()
end

host:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
	if host.Visible and not animating then
		applyDockedLayout()
	end
end)

local pulseConn: RBXScriptConnection? = nil
local pulsedStroke: UIStroke? = nil
local focusPulseConn: RBXScriptConnection? = nil
local focusPulseStroke: UIStroke? = nil
-- Gamepad list: D-pad only (left stick keeps moving the player until a coral is armed).
local gamepadSelectActive = false
local openWithGamepadPending = false
local gamepadFocusIndex = 1
local GRID_COLS = 3
local FOCUS_STROKE_BASE = 3
local FOCUS_STROKE_PEAK = FOCUS_STROKE_BASE * 3 -- pulse grows to 3x thickness
local MOVE_ICON_IMAGE = "rbxassetid://345081302"
local GAMEPAD_INTRO_SCROLL_SEC = 1
local GAMEPAD_INTRO_HOLD_SEC = 1

local pulsedLabel: TextLabel? = nil
local LABEL_IDLE_COLOR = Color3.fromRGB(200, 220, 240)
local gamepadIntroConn: RBXScriptConnection? = nil
local gamepadIntroActive = false
local gamepadDpadPromptUntil = 0 -- show move icon + "D-Pad" until this clock time
local focusPromptRoot: Frame? = nil
local focusPromptMove: ImageLabel? = nil
local focusPromptGlyph: TextLabel? = nil

local function stopPulse()
	if pulseConn then
		pulseConn:Disconnect()
		pulseConn = nil
	end
	if pulsedStroke then
		pulsedStroke.Enabled = false
		pulsedStroke = nil
	end
	if pulsedLabel then
		pulsedLabel.TextColor3 = LABEL_IDLE_COLOR
		pulsedLabel = nil
	end
end

local function clearAllPulses()
	stopPulse()
	for _, btn in ipairs(itemButtons) do
		local icon = btn:FindFirstChild("Circle")
		local stroke = icon and icon:FindFirstChild("_SelectPulse")
		if stroke and stroke:IsA("UIStroke") then
			stroke.Enabled = false
		end
		local nameLbl = btn:FindFirstChild("Name")
		if nameLbl and nameLbl:IsA("TextLabel") then
			nameLbl.TextColor3 = LABEL_IDLE_COLOR
		end
	end
end

local function startPulse(stroke: UIStroke)
	stopPulse()
	pulsedStroke = stroke
	stroke.Enabled = true
	stroke.Color = GREEN
	local icon = stroke.Parent
	local btn = icon and icon.Parent
	local nameLbl = btn and btn:FindFirstChild("Name")
	if nameLbl and nameLbl:IsA("TextLabel") then
		pulsedLabel = nameLbl
	end
	local t0 = os.clock()
	pulseConn = RunService.RenderStepped:Connect(function()
		if pulsedStroke ~= stroke then
			return
		end
		local wave = (math.sin((os.clock() - t0) * 6) + 1) * 0.5
		stroke.Thickness = 1.5 + wave * 1.5
		stroke.Transparency = 0.05 + wave * 0.3
		if pulsedLabel then
			-- Flash name green ↔ white with the armed ring.
			pulsedLabel.TextColor3 = GREEN:Lerp(Color3.new(1, 1, 1), wave)
		end
	end)
end

local function clearFocusOutlines()
	if focusPulseConn then
		focusPulseConn:Disconnect()
		focusPulseConn = nil
	end
	focusPulseStroke = nil
	focusPromptRoot = nil
	focusPromptMove = nil
	focusPromptGlyph = nil
	for _, b in ipairs(itemButtons) do
		local icon = b:FindFirstChild("Circle")
		local focus = icon and icon:FindFirstChild("_FocusOutline")
		if focus and focus:IsA("UIStroke") then
			focus.Enabled = false
			focus.Thickness = FOCUS_STROKE_BASE
		end
		local prompt = b:FindFirstChild("_GamepadPrompt")
		if prompt and prompt:IsA("GuiObject") then
			prompt.Visible = false
		end
		-- Legacy A label (child of btn or Circle).
		local aPrompt = b:FindFirstChild("_GamepadA")
		if aPrompt then
			aPrompt:Destroy()
		end
		local iconA = icon and icon:FindFirstChild("_GamepadA")
		if iconA then
			iconA:Destroy()
		end
	end
end

local function isDpadPromptActive(): boolean
	return gamepadIntroActive or os.clock() < gamepadDpadPromptUntil
end

local function applyFocusPromptMode()
	if not focusPromptRoot or not focusPromptGlyph then
		return
	end
	if isDpadPromptActive() then
		if focusPromptMove then
			focusPromptMove.Visible = true
		end
		focusPromptGlyph.Text = "D-Pad"
		focusPromptGlyph.TextColor3 = Color3.new(0, 0, 0)
		focusPromptGlyph.Size = UDim2.fromScale(0.72, 0.22)
		local stroke = focusPromptGlyph:FindFirstChild("Outline")
		if stroke and stroke:IsA("UIStroke") then
			stroke.Enabled = false
		end
	else
		if focusPromptMove then
			focusPromptMove.Visible = false
		end
		focusPromptGlyph.Text = "A"
		focusPromptGlyph.TextColor3 = Color3.new(1, 1, 1)
		focusPromptGlyph.Size = UDim2.fromScale(0.42, 0.42)
		local stroke = focusPromptGlyph:FindFirstChild("Outline")
		if stroke and stroke:IsA("UIStroke") then
			stroke.Enabled = true
		end
	end
end

local function ensureGamepadPrompt(btn: GuiButton, icon: GuiObject): Frame
	local existing = btn:FindFirstChild("_GamepadPrompt")
	if existing and existing:IsA("Frame") then
		focusPromptRoot = existing
		local move = existing:FindFirstChild("MoveIcon")
		local glyph = existing:FindFirstChild("Glyph")
		focusPromptMove = if move and move:IsA("ImageLabel") then move else nil
		focusPromptGlyph = if glyph and glyph:IsA("TextLabel") then glyph else nil
		return existing
	end

	-- Sibling of Circle so the coral ImageLabel can't cover the prompt.
	local root = Instance.new("Frame")
	root.Name = "_GamepadPrompt"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.new(0.5, 0, 0, 2)
	root.Size = UDim2.fromOffset(40, 40)
	root.ZIndex = math.max(icon.ZIndex, btn.ZIndex) + 20
	root.Visible = false
	root.Parent = btn

	local move = Instance.new("ImageLabel")
	move.Name = "MoveIcon"
	move.BackgroundTransparency = 1
	move.AnchorPoint = Vector2.new(0.5, 0.5)
	move.Position = UDim2.fromScale(0.5, 0.5)
	move.Size = UDim2.fromScale(1, 1)
	move.Image = MOVE_ICON_IMAGE
	move.ScaleType = Enum.ScaleType.Fit
	move.Visible = false
	move.ZIndex = root.ZIndex
	move.Parent = root

	local glyph = Instance.new("TextLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.AnchorPoint = Vector2.new(0.5, 0.5)
	glyph.Position = UDim2.fromScale(0.5, 0.5)
	glyph.Size = UDim2.fromScale(0.85, 0.45)
	glyph.Font = UiTheme.Font
	glyph.Text = "A"
	glyph.TextColor3 = Color3.new(1, 1, 1)
	glyph.TextScaled = true
	glyph.ZIndex = root.ZIndex + 1
	glyph.Parent = root
	local edge = Instance.new("UIStroke")
	edge.Name = "Outline"
	edge.Color = Color3.new(0, 0, 0)
	edge.Thickness = 2
	edge.Parent = glyph

	local function syncOverIcon()
		local h = icon.AbsoluteSize.Y
		if h < 1 then
			return
		end
		root.Position = UDim2.new(0.5, 0, 0, 2 + h * 0.5)
		root.Size = UDim2.fromOffset(h, h)
	end
	icon:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncOverIcon)
	task.defer(syncOverIcon)

	focusPromptRoot = root
	focusPromptMove = move
	focusPromptGlyph = glyph
	return root
end

local function setFocusOutline(btn: GuiButton?)
	clearFocusOutlines()
	if not btn then
		return
	end
	local icon = btn:FindFirstChild("Circle")
	if not icon or not icon:IsA("GuiObject") then
		return
	end
	-- White outline = D-pad focused, not armed yet. Pulses up to 3x thickness.
	local focus = ensureStroke(icon, "_FocusOutline", Color3.new(1, 1, 1), FOCUS_STROKE_BASE)
	focus.Enabled = true
	focus.Transparency = 0
	focusPulseStroke = focus
	local prompt = ensureGamepadPrompt(btn, icon)
	prompt.Visible = true
	applyFocusPromptMode()
	local t0 = os.clock()
	focusPulseConn = RunService.RenderStepped:Connect(function()
		if focusPulseStroke ~= focus or not focus.Enabled then
			return
		end
		local wave = (math.sin((os.clock() - t0) * 5) + 1) * 0.5 -- 0..1
		focus.Thickness = FOCUS_STROKE_BASE + (FOCUS_STROKE_PEAK - FOCUS_STROKE_BASE) * wave
		focus.Transparency = 0.05 + wave * 0.2
		applyFocusPromptMode()
	end)
end

local function stopGamepadOpenIntro()
	if gamepadIntroConn then
		gamepadIntroConn:Disconnect()
		gamepadIntroConn = nil
	end
	gamepadIntroActive = false
end

local function bottomLeftListIndex(): number
	local n = #itemButtons
	if n <= 0 then
		return 1
	end
	-- Last row, first column (leftmost cell of the bottom row).
	return math.floor((n - 1) / GRID_COLS) * GRID_COLS + 1
end

local function startGamepadOpenIntro()
	stopGamepadOpenIntro()
	if #itemButtons == 0 then
		return
	end
	gamepadIntroActive = true
	local bottomIdx = bottomLeftListIndex()
	-- Left column from bottom → top (simulates D-pad Up through the list).
	local path: { number } = {}
	local idx = bottomIdx
	while idx >= 1 do
		table.insert(path, idx)
		idx -= GRID_COLS
	end
	if #path == 0 then
		table.insert(path, 1)
	end
	gamepadFocusIndex = path[1]
	gamepadDpadPromptUntil = os.clock() + GAMEPAD_INTRO_SCROLL_SEC + GAMEPAD_INTRO_HOLD_SEC

	-- Wait a frame so canvas/window sizes are valid after open layout.
	task.defer(function()
		if not gamepadSelectActive or not gamepadIntroActive then
			return
		end
		local windowY = scroll.AbsoluteWindowSize.Y
		if windowY < 1 then
			windowY = scroll.AbsoluteSize.Y
		end
		local maxY = math.max(0, scroll.AbsoluteCanvasSize.Y - windowY)
		scroll.CanvasPosition = Vector2.new(0, maxY)
		local startBtn = itemButtons[path[1]]
		if startBtn then
			setFocusOutline(startBtn)
		end

		local startY = maxY
		local endY = 0
		local t0 = os.clock()
		local lastPathStep = 1
		gamepadDpadPromptUntil = t0 + GAMEPAD_INTRO_SCROLL_SEC + GAMEPAD_INTRO_HOLD_SEC

		gamepadIntroConn = RunService.RenderStepped:Connect(function()
			if not gamepadSelectActive then
				stopGamepadOpenIntro()
				return
			end
			local elapsed = os.clock() - t0
			if elapsed < GAMEPAD_INTRO_SCROLL_SEC then
				local u = math.clamp(elapsed / GAMEPAD_INTRO_SCROLL_SEC, 0, 1)
				local a = 1 - (1 - u) * (1 - u)
				scroll.CanvasPosition = Vector2.new(0, startY + (endY - startY) * a)

				-- Step highlight through each left-column slot in sync with scroll progress.
				local steps = #path
				local step = if steps <= 1 then 1 else math.clamp(math.floor(a * (steps - 1) + 0.0001) + 1, 1, steps)
				if step ~= lastPathStep then
					lastPathStep = step
					local focusIdx = path[step]
					gamepadFocusIndex = focusIdx
					local btn = itemButtons[focusIdx]
					if btn then
						setFocusOutline(btn)
					end
				end
			else
				scroll.CanvasPosition = Vector2.new(0, 0)
				if gamepadFocusIndex ~= 1 or lastPathStep ~= #path then
					lastPathStep = #path
					gamepadFocusIndex = 1
					local first = itemButtons[1]
					if first then
						setFocusOutline(first)
					end
				end
				if elapsed >= GAMEPAD_INTRO_SCROLL_SEC + GAMEPAD_INTRO_HOLD_SEC then
					stopGamepadOpenIntro()
					gamepadDpadPromptUntil = 0
					local first = itemButtons[1]
					if first and gamepadSelectActive then
						setFocusOutline(first)
					end
				end
			end
		end)
	end)
end

local function pulseForButton(btn: GuiButton)
	local icon = btn:FindFirstChild("Circle")
	local stroke = icon and icon:FindFirstChild("_SelectPulse")
	if stroke and stroke:IsA("UIStroke") then
		clearAllPulses()
		startPulse(stroke)
	end
end

local function getShortcutMode(): string
	-- touch | gamepad | keyboard
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		return "touch"
	end
	if last == Enum.UserInputType.Gamepad1
		or last == Enum.UserInputType.Gamepad2
		or last == Enum.UserInputType.Gamepad3
		or last == Enum.UserInputType.Gamepad4
	then
		return "gamepad"
	end
	if last == Enum.UserInputType.Keyboard
		or last == Enum.UserInputType.MouseButton1
		or last == Enum.UserInputType.MouseMovement
		or last == Enum.UserInputType.MouseWheel
	then
		return "keyboard"
	end
	-- Fallback from device caps when last input is unknown.
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch"
	end
	if gamepadSelectActive or PlacementController.isGamepadPlacement() then
		return "gamepad"
	end
	return "keyboard"
end

local function refreshHelpSlotBadge()
	if not helpSlot4 or not helpLetter then
		return
	end
	local mode = getShortcutMode()
	-- Hide help badge on touch, and while backpack is open (Slot4 shows the close letter).
	if mode == "touch" or closeX.Visible or InventoryState.isOpen()
		or playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true
	then
		helpSlot4.Visible = false
		return
	end
	helpSlot4.Visible = true
	helpSlot4.Active = true
	if helpHitButton then
		helpHitButton.Active = true
		helpHitButton.Visible = true
	end
	if helpSlot4:IsA("ImageLabel") or helpSlot4:IsA("ImageButton") then
		(helpSlot4 :: any).Image = ""
	end
	helpSlot4.BackgroundColor3 = RED
	helpSlot4.BackgroundTransparency = 0
	UiCircles.ensure(helpSlot4)
	helpLetter.Text = if mode == "gamepad" then "Y" else "Q"
	helpLetter.TextColor3 = Color3.new(1, 1, 1)
	helpLetter.Visible = true
end


-- Slot1 / Slot2 / Slot3 live in SavePlotSlot / ClearPlotSlot / UndoSlot (Luau 200-local limit).
local focusBackpackAfterSaveClose: (() -> ())? = nil
local clearBackpackFocusForSave: (() -> ())? = nil
local function mountSideSlots()
	local function mountOne(hud: ScreenGui)
		local depsShared = {
			mainHUD = hud,
			ensureButton = ensureSlot4GuiButton,
			passthroughDecor = passthroughDecor,
			ensureCircle = ensureCircle,
			ensureStroke = ensureStroke,
			getShortcutMode = getShortcutMode,
			getIdlePeriod = function()
				return SLOT_IDLE_PERIOD
			end,
			log = log,
		}
		UndoSlot.mount(depsShared)
		ClearPlotSlot.mount({
			mainHUD = hud,
			playerGui = playerGui :: PlayerGui,
			ensureButton = ensureSlot4GuiButton,
			passthroughDecor = passthroughDecor,
			ensureCircle = ensureCircle,
			ensureStroke = ensureStroke,
			getShortcutMode = getShortcutMode,
			getIdlePeriod = function()
				return SLOT_IDLE_PERIOD
			end,
			red = RED,
			green = GREEN,
			log = log,
		})
		SavePlotSlot.mount({
			mainHUD = hud,
			playerGui = playerGui :: PlayerGui,
			ensureButton = ensureSlot4GuiButton,
			passthroughDecor = passthroughDecor,
			ensureCircle = ensureCircle,
			ensureStroke = ensureStroke,
			getShortcutMode = getShortcutMode,
			getIdlePeriod = function()
				return SLOT_IDLE_PERIOD
			end,
			onClosedWithGamepad = function()
				if focusBackpackAfterSaveClose then
					focusBackpackAfterSaveClose()
				end
			end,
			onOpenedWithGamepad = function()
				if clearBackpackFocusForSave then
					clearBackpackFocusForSave()
				end
			end,
			log = log,
		})
		WaveSlot.mount({
			mainHUD = hud,
			playerGui = playerGui :: PlayerGui,
			ensureButton = ensureSlot4GuiButton,
			passthroughDecor = passthroughDecor,
			ensureCircle = ensureCircle,
			ensureStroke = ensureStroke,
			getShortcutMode = getShortcutMode,
			red = RED,
			green = GREEN,
			log = log,
		})
		SkipWaveSlot.mount({
			mainHUD = hud,
			playerGui = playerGui :: PlayerGui,
			ensureButton = ensureSlot4GuiButton,
			passthroughDecor = passthroughDecor,
			ensureCircle = ensureCircle,
			ensureStroke = ensureStroke,
			getShortcutMode = getShortcutMode,
			isWaveSummaryOpen = WaveSlot.isSummaryOpen,
			isSavePlotsOpen = SavePlotSlot.isOpen,
			isClearConfirmActive = ClearPlotSlot.isConfirmActive,
			red = RED,
			green = GREEN,
			log = log,
		})
		WaveSpeedSlot.mount({
			mainHUD = hud,
			playerGui = playerGui :: PlayerGui,
			ensureButton = ensureSlot4GuiButton,
			passthroughDecor = passthroughDecor,
			ensureCircle = ensureCircle,
			ensureStroke = ensureStroke,
			getShortcutMode = getShortcutMode,
			log = log,
		})
	end
	-- Mount the inactive right HUD first (if present), then the active one last so
	-- module deps.mainHUD / slot refs match layout. Bind-once attrs avoid double fire.
	local otherName = if mainHUD.Name == UiViewportTags.P720_RIGHT_HUD
		then UiViewportTags.MOBILE_RIGHT_HUD
		else UiViewportTags.P720_RIGHT_HUD
	local other = playerGui:FindFirstChild(otherName)
	if other and other:IsA("ScreenGui") and other ~= mainHUD and UiViewportTags.hasQuickbarSlot4(other) then
		mountOne(other)
	end
	mountOne(mainHUD)
end
mountSideSlots()
WaveSign.mount()

-- Own L3 (stick click): PlayerModule / other binds often mark it gameProcessed.
-- Backpack open → Save Plots; waves running + backpack closed → Reef Heal.
local L3_ACTION = "OceanTD_GamepadL3"
local L3_PRIORITY = Enum.ContextActionPriority.High.Value
ContextActionService:BindActionAtPriority(L3_ACTION, function(_name, state, _input)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if InventoryState.isOpen() then
		SavePlotSlot.toggle()
		return Enum.ContextActionResult.Sink
	end
	if WaveSlot.tryOpenReefHealFromShortcut() then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end, false, L3_PRIORITY, Enum.KeyCode.ButtonL3)

local function refreshGamepadCloseLabel()
	stopCloseLabelCycle()
	refreshHelpSlotBadge()
	UndoSlot.refreshHelpBadge()
	ClearPlotSlot.refreshHelpBadge()
	SavePlotSlot.refreshHelpBadge()
	WaveSlot.refreshHelpBadge()
	SkipWaveSlot.refreshHelpBadge()
	WaveSpeedSlot.refreshHelpBadge()
	ClearPlotSlot.layoutConfirmIfActive()
	if not closeX.Visible then
		closeX.Text = "X"
		return
	end
	local mode = getShortcutMode()
	if mode == "touch" then
		closeX.Text = "X"
		return
	end
	local letter = if mode == "gamepad" then "Y" else "Q"
	-- Same shared 2s clock as Slot1/3/4: letter with graphics, CLOSE with text labels.
	stopCloseLabelCycle()
	closeLabelStop = UiIdleCycle.subscribeSharedToggle(SLOT_IDLE_PERIOD, function(showClose)
		closeX.Text = if showClose then "CLOSE" else letter
	end, function()
		return closeX.Visible and InventoryState.isOpen()
	end)
end

local function scrollFocusIntoView(btn: GuiObject)
	local btnTop = btn.AbsolutePosition.Y
	local btnBottom = btnTop + btn.AbsoluteSize.Y
	local scrollTop = scroll.AbsolutePosition.Y
	local scrollBottom = scrollTop + scroll.AbsoluteSize.Y
	local canvas = scroll.CanvasPosition
	if btnTop < scrollTop then
		scroll.CanvasPosition = Vector2.new(canvas.X, math.max(0, canvas.Y - (scrollTop - btnTop) - 8))
	elseif btnBottom > scrollBottom then
		scroll.CanvasPosition = Vector2.new(canvas.X, canvas.Y + (btnBottom - scrollBottom) + 8)
	end
end

local function setGamepadFocus(index: number)
	if #itemButtons == 0 then
		return
	end
	if gamepadIntroActive then
		return
	end
	gamepadFocusIndex = math.clamp(index, 1, #itemButtons)
	local btn = itemButtons[gamepadFocusIndex]
	-- White focus outline while browsing; green pulse only after arming.
	clearAllPulses()
	setFocusOutline(btn)
	scrollFocusIntoView(btn)
end

local function disableGamepadSelect()
	openWithGamepadPending = false
	gamepadSelectActive = false
	stopGamepadOpenIntro()
	gamepadDpadPromptUntil = 0
	-- Never leave GuiService selection active — that steals the left stick from movement.
	GuiService.SelectedObject = nil
	clearFocusOutlines()
	for _, btn in ipairs(itemButtons) do
		btn.Selectable = false
	end
	refreshGamepadCloseLabel()
	log("Gamepad select off")
end

local function activateGamepadFocusedItem()
	if gamepadIntroActive then
		return
	end
	if InventoryState.isBuildModalBlocking() then
		return
	end
	local btn = itemButtons[gamepadFocusIndex]
	if not btn then
		return
	end
	local itemId = btn:GetAttribute("OceanTD_ItemId")
	if typeof(itemId) ~= "string" then
		return
	end
	local icon = btn:FindFirstChild("Circle")
	local stroke = icon and icon:FindFirstChild("_SelectPulse")
	disableGamepadSelect()
	PlacementController.setGamepadPlacement(true)
	clearAllPulses()
	if stroke and stroke:IsA("UIStroke") then
		startPulse(stroke)
	end
	InventoryState.setSelected(itemId)
	refreshGamepadCloseLabel()
end

local function enableGamepadSelect(withOpenIntro: boolean?)
	if #itemButtons == 0 then
		return
	end
	gamepadSelectActive = true
	openWithGamepadPending = false
	-- D-pad highlight only — do NOT set SelectedObject (thumbstick must still move the avatar).
	GuiService.SelectedObject = nil
	for _, btn in ipairs(itemButtons) do
		btn.Selectable = false
	end
	if withOpenIntro then
		startGamepadOpenIntro()
	else
		stopGamepadOpenIntro()
		gamepadDpadPromptUntil = 0
		setGamepadFocus(1)
	end
	refreshGamepadCloseLabel()
	log("Gamepad select on — D-pad list, stick moves player", if withOpenIntro then "intro" else "focus1")
end

focusBackpackAfterSaveClose = function()
	if InventoryState.isOpen() then
		enableGamepadSelect(false)
	end
end

clearBackpackFocusForSave = function()
	clearFocusOutlines()
	GuiService.SelectedObject = nil
end

local function makeItemButton(def, layoutOrder: number, instanceSuffix: string?): ImageButton
	local btnName = if instanceSuffix then def.id .. instanceSuffix else def.id
	local btn = Instance.new("ImageButton")
	btn.Name = btnName
	btn.BackgroundTransparency = 1
	btn.AutoButtonColor = true
	btn.LayoutOrder = layoutOrder
	btn.Image = ""
	btn.Selectable = false -- D-pad focus is manual; keep stick free for movement
	btn:SetAttribute("OceanTD_ItemId", def.id)

	-- Square icon (cell is taller than wide for the label — scale Y alone made a pill).
	local icon = Instance.new("ImageLabel")
	icon.Name = "Circle"
	icon.BackgroundColor3 = Color3.fromRGB(20, 30, 45)
	icon.BackgroundTransparency = 0.15
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.new(0.5, 0, 0, 2)
	icon.Size = UDim2.new(0.72, 0, 0.72, 0)
	icon.Image = def.icon
	icon.ScaleType = Enum.ScaleType.Fit
	icon.Parent = btn
	UiCircles.ensure(icon)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.DominantAxis = Enum.DominantAxis.Width
	aspect.Parent = icon

	local label = Instance.new("TextLabel")
	label.Name = "Name"
	label.BackgroundTransparency = 1
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0, 0)
	label.Size = UDim2.new(1, -4, 0, backpackItemLabelHeight())
	label.Font = UiTheme.Font
	label.Text = def.displayName
	label.TextColor3 = Color3.fromRGB(200, 220, 240)
	label.TextScaled = true
	label.Parent = btn

	-- Keep label snug under the square icon as AbsoluteSize settles.
	local function placeLabelUnderIcon()
		local y = icon.AbsoluteSize.Y
		if y < 1 then
			return
		end
		-- Position is relative to btn; icon is at top with 2px pad.
		label.Position = UDim2.new(0.5, 0, 0, 2 + y + 2)
	end
	icon:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeLabelUnderIcon)
	task.defer(placeLabelUnderIcon)

	local stroke = ensureStroke(icon, "_SelectPulse", GREEN, 2)
	stroke.Enabled = false

	-- Tap = arm placement; vertical drag = scroll list; drag out = placement pull.
	local DRAG = 14
	btn.Active = true

	btn.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		PlacementController.setGamepadPlacement(false)
		refreshGamepadCloseLabel()
		local start = Vector2.new(input.Position.X, input.Position.Y)
		local startCanvas = scroll.CanvasPosition
		local gesture = "pending" -- pending | scroll | pull
		local moveConn: RBXScriptConnection
		local endConn: RBXScriptConnection

		local function insideScroll(screen: Vector2): boolean
			local p = scroll.AbsolutePosition
			local s = scroll.AbsoluteSize
			return screen.X >= p.X and screen.X <= p.X + s.X and screen.Y >= p.Y and screen.Y <= p.Y + s.Y
		end

		moveConn = UserInputService.InputChanged:Connect(function(chg)
			if input.UserInputType == Enum.UserInputType.Touch then
				if chg.UserInputType ~= Enum.UserInputType.Touch then
					return
				end
			else
				if chg.UserInputType ~= Enum.UserInputType.MouseMovement then
					return
				end
			end
			local now = Vector2.new(chg.Position.X, chg.Position.Y)
			local delta = now - start
			if gesture == "pending" then
				if math.abs(delta.Y) >= DRAG and math.abs(delta.Y) >= math.abs(delta.X) then
					gesture = "scroll"
				elseif math.abs(delta.X) >= DRAG or not insideScroll(now) then
					gesture = "pull"
					clearAllPulses()
					startPulse(stroke)
					PlacementController.notifyPointerDownFromBackpack(def.id, now)
				end
			end
			if gesture == "scroll" then
				scroll.CanvasPosition = Vector2.new(startCanvas.X, math.max(0, startCanvas.Y - (now.Y - start.Y)))
			elseif gesture == "pull" then
				PlacementController.notifyPointerMove(now)
			end
		end)

		endConn = UserInputService.InputEnded:Connect(function(ended)
			if input.UserInputType == Enum.UserInputType.Touch then
				if ended.UserInputType ~= Enum.UserInputType.Touch then
					return
				end
			else
				if ended.UserInputType ~= Enum.UserInputType.MouseButton1 then
					return
				end
			end
			moveConn:Disconnect()
			endConn:Disconnect()
			local endPos = Vector2.new(ended.Position.X, ended.Position.Y)
			if gesture == "pull" then
				PlacementController.notifyPointerUp(endPos)
				return
			end
			if gesture == "scroll" then
				return
			end
			-- Tap: select / toggle pulse + start placement aim
			if InventoryState.isBuildModalBlocking() then
				return
			end
			local cur = InventoryState.getSelectedId()
			if cur == def.id and pulsedStroke == stroke then
				clearAllPulses()
				PlacementController.cancel()
				return
			end

			-- Snapshot the currently armed cell BEFORE the pulse moves (TEMP grid shares ids).
			local fromScreen: Vector2? = nil
			if PlacementController.isActive() and cur then
				fromScreen = InventoryState.getItemSlotScreenCenter(cur)
			end

			clearAllPulses()
			startPulse(stroke)

			local btnPos = btn.AbsolutePosition
			local btnSize = btn.AbsoluteSize
			local toScreen = Vector2.new(btnPos.X + btnSize.X * 0.5, btnPos.Y + btnSize.Y * 0.5)

			if PlacementController.isActive() then
				PlacementController.setSwitchSlotScreens(fromScreen, toScreen)
				-- force: same catalog id on another cell still re-fires placement (disarm → arm).
				InventoryState.setSelected(def.id, true)
			else
				InventoryState.setSelected(def.id)
			end
		end)
	end)

	table.insert(itemButtons, btn)
	btn.Parent = scroll
	return btn
end

local function rebuildItems()
	for _, child in ipairs(scroll:GetChildren()) do
		if child:IsA("GuiButton") then
			child:Destroy()
		end
	end
	table.clear(itemButtons)
	clearAllPulses()

	if TEMP_BRAIN_CORAL_SLOT_COUNT > 0 then
		local brain = ItemCatalog.get("BrainCoral")
		assert(brain, "[INV] TEMP fill needs BrainCoral in ItemCatalog")
		for i = 1, TEMP_BRAIN_CORAL_SLOT_COUNT do
			makeItemButton(brain, i, "_temp" .. tostring(i))
		end
		log("TEMP grid fill", TEMP_BRAIN_CORAL_SLOT_COUNT, "x BrainCoral — set TEMP_BRAIN_CORAL_SLOT_COUNT=0 for real catalog")
	else
		for _, def in ipairs(ItemCatalog.all()) do
			makeItemButton(def, def.sortOrder, nil)
		end
	end
	refreshGridCellSize()
end

rebuildItems()

InventoryState.setItemSlotScreenPosProvider(function(itemId: string): Vector2?
	-- Prefer the pulsed/selected cell when several share an id (TEMP fill).
	local pulsed: ImageButton? = nil
	local first: ImageButton? = nil
	for _, btn in ipairs(itemButtons) do
		if btn:GetAttribute("OceanTD_ItemId") == itemId then
			if not first then
				first = btn
			end
			local icon = btn:FindFirstChild("Circle")
			local stroke = icon and icon:FindFirstChild("_SelectPulse")
			if stroke and stroke:IsA("UIStroke") and stroke.Enabled then
				pulsed = btn
				break
			end
		end
	end
	local btn = pulsed or first
	if not btn or not btn.Parent then
		return nil
	end
	local pos = btn.AbsolutePosition
	local size = btn.AbsoluteSize
	return Vector2.new(pos.X + size.X * 0.5, pos.Y + size.Y * 0.5)
end)

InventoryState.setScrollCenterProvider(function(): Vector2?
	if not scroll.Parent then
		return nil
	end
	local pos = scroll.AbsolutePosition
	local size = scroll.AbsoluteSize
	return Vector2.new(pos.X + size.X * 0.5, pos.Y + size.Y * 0.5)
end)

-- Placement ignores world-aim when the finger is on the open backpack panel.
InventoryState.setBackpackHitTest(function(screenPos: Vector2): boolean
	if not host.Visible or not panel.Parent then
		return false
	end
	local function inPanel(pos: Vector2): boolean
		local p = panel.AbsolutePosition
		local s = panel.AbsoluteSize
		return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
	end
	if inPanel(screenPos) then
		return true
	end
	-- GetMouseLocation is inset-inclusive; AbsolutePosition often is not.
	local inset = GuiService:GetGuiInset()
	if inset.X ~= 0 or inset.Y ~= 0 then
		if inPanel(Vector2.new(screenPos.X - inset.X, screenPos.Y - inset.Y)) then
			return true
		end
	end
	return false
end)

----------------------------------------------------------------
-- Open / close
----------------------------------------------------------------

local function slotCenterLocal(): Vector2
	local pos = slot4.AbsolutePosition
	local size = slot4.AbsoluteSize
	local hostPos = host.AbsolutePosition
	return Vector2.new(pos.X + size.X * 0.5 - hostPos.X, pos.Y + size.Y * 0.5 - hostPos.Y)
end

-- Client-only shovel (other players never see it).
local function unequipBackpackShovel()
	LocalShovel.unequip()
end

local function equipBackpackShovel()
	LocalShovel.equip()
end

local function playOpen()
	if animating then
		return
	end
	animating = true
	UiHaptics.rampOpen(1)
	host.Visible = true
	applySlotOpenChrome()
	equipBackpackShovel()

	local center = slotCenterLocal()
	local right, top, width, height = dockRect()

	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromOffset(center.X, center.Y)
	panel.Size = UDim2.fromOffset(math.max(slot4.AbsoluteSize.X, 48), math.max(slot4.AbsoluteSize.Y, 48))
	uiScale.Scale = 0.08

	local t1 = TweenService:Create(uiScale, TWEEN_OPEN, { Scale = 1 })
	local t2 = TweenService:Create(panel, TWEEN_OPEN, {
		Position = UDim2.fromOffset(right - width * 0.5, top + height * 0.5),
		Size = UDim2.fromOffset(width, height),
	})
	t1:Play()
	t2:Play()
	t2.Completed:Wait()

	applyDockedLayout()
	animating = false
end

local function playClose()
	if animating then
		return
	end
	animating = true
	UiHaptics.rampClose(1)
	unequipBackpackShovel()
	local center = slotCenterLocal()
	local right, top, width, height = dockRect()

	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromOffset(right - width * 0.5, top + height * 0.5)
	panel.Size = UDim2.fromOffset(width, height)

	local t1 = TweenService:Create(uiScale, TWEEN_CLOSE, { Scale = 0.08 })
	local t2 = TweenService:Create(panel, TWEEN_CLOSE, {
		Position = UDim2.fromOffset(center.X, center.Y),
		Size = UDim2.fromOffset(math.max(slot4.AbsoluteSize.X, 48), math.max(slot4.AbsoluteSize.Y, 48)),
	})
	t1:Play()
	t2:Play()
	t2.Completed:Wait()

	host.Visible = false
	applySlotClosedChrome()
	uiScale.Scale = 0.05
	animating = false
end

InventoryState.onOpenChanged(function(isOpen)
	setLeftUiHiddenForBackpack(isOpen)
	if isOpen then
		if SkipWaveSlot.isConfirmActive() then
			SkipWaveSlot.cancelConfirm()
		end
		if WaveSlot.isStopConfirmActive() then
			WaveSlot.cancelStopConfirm()
		end
		if WaveSlot.isReefHealOpen() then
			WaveSlot.cancelReefHeal()
		end
		task.spawn(function()
			-- Reveal Slot1/2/3 as the backpack opens so they slide out from behind the panel.
			task.spawn(SavePlotSlot.playReveal)
			task.spawn(ClearPlotSlot.playReveal)
			task.spawn(UndoSlot.playReveal)
			playOpen()
			if openWithGamepadPending then
				enableGamepadSelect(true)
			end
			refreshGamepadCloseLabel()
		end)
	else
		unequipBackpackShovel()
		disableGamepadSelect()
		ClearPlotSlot.hideConfirm()
		SavePlotSlot.hide()
		task.spawn(function()
			-- Slide Slot1/2/3 back behind the backpack while the panel closes.
			task.spawn(SavePlotSlot.playHide)
			task.spawn(ClearPlotSlot.playHide)
			task.spawn(UndoSlot.playHide)
			playClose()
			refreshHelpSlotBadge()
			UndoSlot.refreshHelpBadge()
			ClearPlotSlot.refreshHelpBadge()
			SavePlotSlot.refreshHelpBadge()
			WaveSlot.refreshHelpBadge()
			SkipWaveSlot.refreshHelpBadge()
			WaveSpeedSlot.refreshHelpBadge()
		end)
	end
end)

playerGui:GetAttributeChangedSignal("OceanTD_SkillsBubblesOpen"):Connect(function()
	local skillsOpen = playerGui:GetAttribute("OceanTD_SkillsBubblesOpen") == true
	if skillsOpen then
		slot4.Visible = false
		refreshHelpSlotBadge()
		-- From build mode + Place More: keep InventoryState open, but hide backpack chrome
		-- so skills bubbles + top-left close can show.
		if InventoryState.isOpen() then
			host.Visible = false
			task.spawn(SavePlotSlot.playHide)
			task.spawn(ClearPlotSlot.playHide)
			task.spawn(UndoSlot.playHide)
			local left = playerGui:FindFirstChild("MobileLeftUI")
			local dPad = left and left:FindFirstChild("dPad")
			local skills = dPad and dPad:FindFirstChild("Skills")
			if skills and skills:IsA("GuiObject") then
				skills.Visible = true
				for i = #hiddenLeftUiForBackpack, 1, -1 do
					if hiddenLeftUiForBackpack[i].gui == skills then
						table.remove(hiddenLeftUiForBackpack, i)
						break
					end
				end
			end
		end
	else
		slot4.Visible = true
		refreshHelpSlotBadge()
		if InventoryState.isOpen() then
			host.Visible = true
			applyDockedLayout()
			task.spawn(SavePlotSlot.playReveal)
			task.spawn(ClearPlotSlot.playReveal)
			task.spawn(UndoSlot.playReveal)
			-- Re-hide Skills with the rest of left UI while backpack stays open.
			local left = playerGui:FindFirstChild("MobileLeftUI")
			local dPad = left and left:FindFirstChild("dPad")
			local skills = dPad and dPad:FindFirstChild("Skills")
			if skills and skills:IsA("GuiObject") then
				rememberHideLeftForBackpack(skills)
			end
		end
	end
end)

InventoryState.onSelectionChanged(function(id)
	if id == nil then
		clearAllPulses()
		log("Selection cleared")
	else
		log("Selected", id)
	end
	refreshGamepadCloseLabel()
end)

PlacementController.onGamepadReturnToList(function()
	if not InventoryState.isOpen() then
		return
	end
	-- B from placement: back to list with first item highlighted for D-pad.
	enableGamepadSelect()
end)

local lastToggleClock = 0
local function toggleFromUser(fromGamepad: boolean?)
	if animating then
		return
	end
	local now = os.clock()
	if now - lastToggleClock < 0.3 then
		return
	end
	lastToggleClock = now
	-- Overlays can reappear after layout; clear again before toggle on touch.
	disarmTouchBlockingOverlays(mainHUD, slot4)
	if fromGamepad then
		if InventoryState.isOpen() then
			-- Closing with joystick: select mode cleared in onOpenChanged.
			openWithGamepadPending = false
		else
			openWithGamepadPending = true
		end
	else
		openWithGamepadPending = false
		if InventoryState.isOpen() then
			disableGamepadSelect()
		end
	end
	log("Slot4 Activated toggle", if fromGamepad then "gamepad" else "pointer")
	InventoryState.toggleOpen()
end

-- Old-game pattern: GuiButton.Activated is the primary toggle (works PC + mobile once overlays are disarmed).
slotButton.Activated:Connect(function()
	toggleFromUser(false)
end)

-- Other resolution HUD's Slot4 (so resize / wrong early bind still opens backpack).
do
	local otherName = if mainHUD.Name == UiViewportTags.P720_RIGHT_HUD
		then UiViewportTags.MOBILE_RIGHT_HUD
		else UiViewportTags.P720_RIGHT_HUD
	local otherHud = playerGui:FindFirstChild(otherName)
	if otherHud and otherHud:IsA("ScreenGui") and UiViewportTags.hasQuickbarSlot4(otherHud) then
		local otherSlot4 = findQuickbarSlot4(otherHud)
		local otherBtn = ensureSlot4GuiButton(otherSlot4)
		passthroughDecor(otherSlot4, otherBtn)
		otherBtn.Activated:Connect(function()
			toggleFromUser(false)
		end)
		log("Also bound Slot4 on", otherHud.Name)
	end
end

-- Help circle (Y / Q) — same toggle as Slot4; gamepad badge uses gamepad open path.
if helpHitButton then
	helpHitButton.Activated:Connect(function()
		toggleFromUser(getShortcutMode() == "gamepad")
	end)
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if input.KeyCode == Enum.KeyCode.ButtonY then
		toggleFromUser(true)
		return
	end
	-- Wave summary: A / Enter activates selected (default CONTINUE); B / Esc = FINISH.
	if WaveSlot.isSummaryOpen() then
		if input.KeyCode == Enum.KeyCode.ButtonA
			or input.KeyCode == Enum.KeyCode.Return
			or input.KeyCode == Enum.KeyCode.KeypadEnter
		then
			WaveSlot.handleSummaryPrimaryConfirm()
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape then
			WaveSlot.dismissSummary()
			return
		end
	end
	-- Save plots: A/Enter confirm overwrite; B/Esc close overwrite or main UI.
	if SavePlotSlot.isOpen() then
		if input.KeyCode == Enum.KeyCode.ButtonA or input.KeyCode == Enum.KeyCode.Return then
			if SavePlotSlot.handleConfirmInput() then
				return
			end
		end
		if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape then
			SavePlotSlot.handleCancelInput()
			return
		end
	end
	-- Clear plot confirm: A / Enter activates selected button; B / Esc cancels.
	if ClearPlotSlot.isConfirmActive() then
		if input.KeyCode == Enum.KeyCode.ButtonA or input.KeyCode == Enum.KeyCode.Return then
			ClearPlotSlot.handlePrimaryConfirm()
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape then
			ClearPlotSlot.cancelConfirm()
			return
		end
	end
	-- Skip wave confirm: A / Enter / B / Esc (backpack must stay closed).
	if SkipWaveSlot.isConfirmActive() then
		if input.KeyCode == Enum.KeyCode.ButtonA or input.KeyCode == Enum.KeyCode.Return then
			SkipWaveSlot.handlePrimaryConfirm()
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape then
			SkipWaveSlot.cancelConfirm()
			return
		end
	end
	-- Stop waves confirm: A / Enter / B / Esc.
	if WaveSlot.isStopConfirmActive() then
		if input.KeyCode == Enum.KeyCode.ButtonA
			or input.KeyCode == Enum.KeyCode.Return
			or input.KeyCode == Enum.KeyCode.KeypadEnter
		then
			WaveSlot.handleStopPrimaryConfirm()
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape then
			WaveSlot.cancelStopConfirm()
			return
		end
	end
	-- Reef heal popup: B / Esc closes; A/Enter activates selected (default +1).
	if WaveSlot.isReefHealOpen() then
		if input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.Escape then
			WaveSlot.cancelReefHeal()
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonA
			or input.KeyCode == Enum.KeyCode.Return
			or input.KeyCode == Enum.KeyCode.KeypadEnter
		then
			WaveSlot.handleReefHealPrimaryConfirm()
			return
		end
	end
	-- Finish wave early: Enter (keyboard) / R2 (gamepad); backpack must be closed.
	if input.KeyCode == Enum.KeyCode.Return
		or input.KeyCode == Enum.KeyCode.KeypadEnter
		or input.KeyCode == Enum.KeyCode.ButtonR2
	then
		if WaveSlot.tryFinishFromShortcut() then
			return
		end
	end
	-- Save plots: V while backpack open (L3 is ContextAction — see L3_ACTION bind).
	if input.KeyCode == Enum.KeyCode.V then
		if InventoryState.isOpen() then
			SavePlotSlot.toggle()
			return
		end
	end
	-- Clear plot: C / R3 while backpack open.
	if input.KeyCode == Enum.KeyCode.C or input.KeyCode == Enum.KeyCode.ButtonR3 then
		if InventoryState.isOpen() and not SavePlotSlot.isOpen() then
			ClearPlotSlot.beginConfirm()
			return
		end
		-- Skip Wave: R3 gamepad while closed (waves running).
		if not InventoryState.isOpen() and input.KeyCode == Enum.KeyCode.ButtonR3 then
			SkipWaveSlot.beginConfirm()
			return
		end
	end
	-- Reef heal: H while backpack closed (L3 via ContextAction bind).
	if input.KeyCode == Enum.KeyCode.H then
		if not InventoryState.isOpen() and WaveSlot.tryOpenReefHealFromShortcut() then
			return
		end
	end
	if input.KeyCode == Enum.KeyCode.Z then
		if InventoryState.isOpen() and not SavePlotSlot.isOpen() then
			UndoSlot.requestUndo()
			return
		end
		if not InventoryState.isOpen() then
			SkipWaveSlot.beginConfirm()
			return
		end
	end
	-- Undo L2 while backpack open; Wave Speed L2 / T while closed.
	if input.KeyCode == Enum.KeyCode.ButtonL2 then
		if InventoryState.isOpen() and not SavePlotSlot.isOpen() then
			UndoSlot.requestUndo()
			return
		end
		if not InventoryState.isOpen() then
			WaveSpeedSlot.cycle()
			return
		end
	end
	if input.KeyCode == Enum.KeyCode.T then
		if not InventoryState.isOpen() then
			WaveSpeedSlot.cycle()
			return
		end
	end
	-- Waves: R (keyboard) / ButtonX (gamepad Square). Closed backpack only (Slot5 inert while open).
	if input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.ButtonX then
		if gameProcessed then
			return
		end
		if InventoryState.isOpen()
			or WaveSlot.isSummaryOpen()
			or SavePlotSlot.isOpen()
			or ClearPlotSlot.isConfirmActive()
			or SkipWaveSlot.isConfirmActive()
			or WaveSlot.isStopConfirmActive()
			or WaveSlot.isReefHealOpen()
		then
			return
		end
		WaveSlot.toggle()
		return
	end
	-- B closes backpack when in list select (placement/relocate own B while active).
	if input.KeyCode == Enum.KeyCode.ButtonB then
		if PlacementController.isActive() or RelocateController.isActive() then
			return
		end
		if SavePlotSlot.isOpen() then
			SavePlotSlot.hide()
			return
		end
		if InventoryState.isOpen() and (gamepadSelectActive or openWithGamepadPending) then
			toggleFromUser(true)
			return
		end
	end

	-- D-pad browses backpack list only when save-plots modal is closed.
	if gamepadSelectActive
		and not PlacementController.isActive()
		and not RelocateController.isActive()
		and not InventoryState.isBuildModalBlocking()
		and not SavePlotSlot.isOpen()
	then
		if input.KeyCode == Enum.KeyCode.DPadLeft then
			setGamepadFocus(gamepadFocusIndex - 1)
			return
		elseif input.KeyCode == Enum.KeyCode.DPadRight then
			setGamepadFocus(gamepadFocusIndex + 1)
			return
		elseif input.KeyCode == Enum.KeyCode.DPadUp then
			setGamepadFocus(gamepadFocusIndex - GRID_COLS)
			return
		elseif input.KeyCode == Enum.KeyCode.DPadDown then
			setGamepadFocus(gamepadFocusIndex + GRID_COLS)
			return
		elseif input.KeyCode == Enum.KeyCode.ButtonA then
			activateGamepadFocusedItem()
			return
		end
	end

	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.Q then
		toggleFromUser(false)
	end
end)

player.CharacterRemoving:Connect(function()
	unequipBackpackShovel()
	HandOrb.clear()
	ClearPlotSlot.onCharacterRemoving()
	if SkipWaveSlot.isConfirmActive() then
		SkipWaveSlot.cancelConfirm()
	end
	if WaveSlot.isStopConfirmActive() then
		WaveSlot.cancelStopConfirm()
	end
	if WaveSlot.isReefHealOpen() then
		WaveSlot.cancelReefHeal()
	end
end)

applySlotClosedChrome()
refreshHelpSlotBadge()
UndoSlot.syncVisibility()
ClearPlotSlot.syncVisibility()
SavePlotSlot.syncVisibility()
UserInputService.LastInputTypeChanged:Connect(function()
	refreshGamepadCloseLabel()
end)
log("Backpack UI ready — shortcuts: Y/Q backpack; Z/L2 undo (open); Z/R3 skip (closed); T/L2 wave speed (closed); C/R3 clear; R/X waves")