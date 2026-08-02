--!strict
--[[
	Backpack / inventory UI — owner script.

	Studio contract: StarterGui.MainHUD.Quickbar.Slot4 (backpack button).
	Panel is built in code under MainHUD so it can grow (tabs, filters, etc.).
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local LocalShovel = require(script.Parent:WaitForChild("LocalShovel"))
local HandOrb = require(script.Parent:WaitForChild("HandOrb"))
local Remotes = require(oceanRoot:WaitForChild("Remotes"))

local TWEEN_OPEN = TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TWEEN_CLOSE = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local RED = Color3.fromRGB(220, 50, 55)
local DARK_RED = Color3.fromRGB(120, 10, 20)
local ORANGE = Color3.fromRGB(230, 120, 40)
local GREEN = Color3.fromRGB(40, 220, 110)
local PANEL_WIDTH_SCALE = 0.33
local SLOT4_GAP_PX = 8

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
	local hud = playerGui:WaitForChild("MainHUD", 60)
	assert(hud and hud:IsA("ScreenGui"), "[INV] StarterGui.MainHUD ScreenGui missing — author in Studio")
	return hud
end

local function findQuickbarSlot4(mainHUD: Instance): GuiObject
	local quickbar = mainHUD:WaitForChild("Quickbar", 30)
	assert(quickbar, "[INV] MainHUD.Quickbar missing")
	local slot4 = quickbar:WaitForChild("Slot4", 30)
	assert(slot4 and slot4:IsA("GuiObject"), "[INV] MainHUD.Quickbar.Slot4 missing")
	return slot4 :: GuiObject
end

local function findQuickbarSlot3(mainHUD: Instance): GuiObject?
	local quickbar = mainHUD:FindFirstChild("Quickbar")
	if not quickbar then
		return nil
	end
	local slot3 = quickbar:FindFirstChild("Slot3")
	if slot3 and slot3:IsA("GuiObject") then
		return slot3
	end
	return nil
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
		return slot
	end

	local existing = slot:FindFirstChild("_OceanTD_Hit")
	if existing and existing:IsA("GuiButton") then
		existing.Active = true
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
mainHUD.DisplayOrder = math.max(mainHUD.DisplayOrder, 50)

local slot4 = findQuickbarSlot4(mainHUD)
local slotButton = ensureSlot4GuiButton(slot4)
local circle = ensureCircle(slot4)
UiCircles.forceOnDescendants(slot4)
passthroughDecor(slot4, slotButton)
disarmTouchBlockingOverlays(mainHUD, slot4)

-- Slot3 = session undo (place / move / recycle). Visible only while backpack is open.
local slot3 = findQuickbarSlot3(mainHUD)
local slot3Button: GuiButton? = nil
local slot3Circle: GuiObject? = nil
local slot3Stroke: UIStroke? = nil
local slot3UndoLabel: TextLabel? = nil
local slot3IdleConn: RBXScriptConnection? = nil
local slot3OriginalImage = ""
local slot3OriginalBg = Color3.fromRGB(20, 30, 45)
local slot3OriginalBgTrans = 0.15
local slot3HomePos: UDim2? = nil
local helpSlot3HomePos: UDim2? = nil
local slot3SlideToken = 0
local slot3PressToken = 0
local SLOT3_SLIDE_PX = 88 -- toward backpack (right) so they emerge from behind the panel
local SLOT3_SLIDE_IN = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SLOT3_SLIDE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
if slot3 then
	slot3HomePos = slot3.Position
	slot3Button = ensureSlot4GuiButton(slot3)
	passthroughDecor(slot3, slot3Button)
	slot3Circle = ensureCircle(slot3)
	UiCircles.forceOnDescendants(slot3)
	if slot3Circle:IsA("ImageLabel") or slot3Circle:IsA("ImageButton") then
		slot3OriginalImage = (slot3Circle :: any).Image
	end
	slot3OriginalBg = slot3Circle.BackgroundColor3
	slot3OriginalBgTrans = slot3Circle.BackgroundTransparency
	slot3Stroke = ensureStroke(slot3Circle, "_OceanTD_UndoRing", Color3.new(1, 1, 1), 2)
	slot3Stroke.Enabled = false

	local existingUndo = slot3Circle:FindFirstChild("_OceanTD_UndoLabel")
	if existingUndo and existingUndo:IsA("TextLabel") then
		slot3UndoLabel = existingUndo
	else
		if existingUndo then
			existingUndo:Destroy()
		end
		local lbl = Instance.new("TextLabel")
		lbl.Name = "_OceanTD_UndoLabel"
		lbl.BackgroundTransparency = 1
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.Font = Enum.Font.GothamBold
		lbl.Text = "UNDO"
		lbl.TextColor3 = Color3.new(1, 1, 1)
		lbl.TextScaled = true
		lbl.Visible = false
		lbl.ZIndex = slot3Circle.ZIndex + 2
		lbl.Active = false
		lbl.Parent = slot3Circle
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0.22, 0)
		pad.PaddingBottom = UDim.new(0.22, 0)
		pad.PaddingLeft = UDim.new(0.08, 0)
		pad.PaddingRight = UDim.new(0.08, 0)
		pad.Parent = lbl
		slot3UndoLabel = lbl
	end
	slot3.Visible = false
	log("Slot3 undo button ready")
else
	warn("[INV] MainHUD.Quickbar.Slot3 missing — undo button unavailable")
end

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

-- QuickbarHelp.Slot3 — undo shortcut badge (Z / L2). Orange; only while backpack open.
local helpSlot3: GuiObject? = nil
local helpSlot3Letter: TextLabel? = nil
if quickbarHelp then
	local hs3 = quickbarHelp:FindFirstChild("Slot3")
	if hs3 and hs3:IsA("GuiObject") then
		helpSlot3 = hs3
		helpSlot3.Active = false
		helpSlot3.Visible = false
		for _, d in ipairs(helpSlot3:GetDescendants()) do
			if d:IsA("GuiObject") then
				d.Active = false
			end
		end
		local existingLetter = helpSlot3:FindFirstChild("_OceanTD_HelpLetter")
		if existingLetter and existingLetter:IsA("TextLabel") then
			helpSlot3Letter = existingLetter
		else
			if existingLetter then
				existingLetter:Destroy()
			end
			local letter = Instance.new("TextLabel")
			letter.Name = "_OceanTD_HelpLetter"
			letter.BackgroundTransparency = 1
			letter.Size = UDim2.fromScale(1, 1)
			letter.Font = UiTheme.Font
			letter.Text = "Z"
			letter.TextColor3 = Color3.new(1, 1, 1)
			letter.TextScaled = true
			letter.Active = false
			letter.ZIndex = helpSlot3.ZIndex + 5
			letter.Parent = helpSlot3
			local pad = Instance.new("UIPadding")
			pad.PaddingTop = UDim.new(0.15, 0)
			pad.PaddingBottom = UDim.new(0.15, 0)
			pad.PaddingLeft = UDim.new(0.15, 0)
			pad.PaddingRight = UDim.new(0.15, 0)
			pad.Parent = letter
			helpSlot3Letter = letter
		end
		UiCircles.ensure(helpSlot3)
		helpSlot3HomePos = helpSlot3.Position
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

local closedStroke = ensureStroke(circle, "_OceanTD_ClosedRing", RED, 3)
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

local closeXPulseConn: RBXScriptConnection? = nil
local closeLabelCycleConn: RBXScriptConnection? = nil
local closedIdleConn: RBXScriptConnection? = nil
local SLOT_IDLE_PERIOD = 2 -- shovel graphic ↔ "BUILD" / undo icon ↔ "UNDO"

local buildLabel = circle:FindFirstChild("_OceanTD_BuildLabel") :: TextLabel?
if not buildLabel then
	buildLabel = Instance.new("TextLabel")
	buildLabel.Name = "_OceanTD_BuildLabel"
	buildLabel.BackgroundTransparency = 1
	buildLabel.Size = UDim2.fromScale(1, 1)
	buildLabel.Font = Enum.Font.GothamBold
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
	if closeLabelCycleConn then
		closeLabelCycleConn:Disconnect()
		closeLabelCycleConn = nil
	end
end

local function stopClosedIdleCycle()
	if closedIdleConn then
		closedIdleConn:Disconnect()
		closedIdleConn = nil
	end
	if buildLabel then
		buildLabel.Visible = false
	end
end

local function stopCloseXPulse()
	if closeXPulseConn then
		closeXPulseConn:Disconnect()
		closeXPulseConn = nil
	end
	closeXStroke.Enabled = false
	closeXStroke.Transparency = 0
	closeXStroke.Thickness = 2
end

local function startCloseXPulse()
	stopCloseXPulse()
	closeXStroke.Enabled = true
	closeXStroke.Color = DARK_RED
	local t0 = os.clock()
	closeXPulseConn = RunService.RenderStepped:Connect(function()
		local wave = (math.sin((os.clock() - t0) * 6) + 1) * 0.5
		-- Max thickness ~7 (was ~3.5) — twice as thick at peak.
		closeXStroke.Thickness = 1.5 + wave * 5.5
		closeXStroke.Transparency = 0.05 + wave * 0.35
	end)
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
	local t0 = os.clock()
	applyClosedIdleFrame(false) -- shovel first
	closedIdleConn = RunService.Heartbeat:Connect(function()
		if InventoryState.isOpen() then
			return
		end
		-- 0s shovel, 2s BUILD, repeat
		local showBuild = (math.floor((os.clock() - t0) / SLOT_IDLE_PERIOD) % 2) == 1
		applyClosedIdleFrame(showBuild)
	end)
end

local function applySlotClosedChrome()
	stopCloseXPulse()
	stopCloseLabelCycle()
	closedStroke.Enabled = true
	closedStroke.Color = RED
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
panelStroke.Color = RED
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

local function refreshGridCellSize()
	local width = scroll.AbsoluteSize.X
	if width <= 1 then
		return
	end
	local pad = 22
	local cell = math.floor((width - pad * 2) / 3)
	cell = math.clamp(cell, 56, 120)
	grid.CellSize = UDim2.fromOffset(cell, cell + 18)
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

local itemButtons: { ImageButton } = {}
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
	glyph.Font = Enum.Font.GothamBold
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
	if mode == "touch" or closeX.Visible or InventoryState.isOpen() then
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

local function styleSlot3HelpBadge(): boolean
	if not helpSlot3 or not helpSlot3Letter then
		return false
	end
	local mode = getShortcutMode()
	if mode == "touch" then
		return false
	end
	if helpSlot3:IsA("ImageLabel") or helpSlot3:IsA("ImageButton") then
		(helpSlot3 :: any).Image = ""
	end
	helpSlot3.BackgroundColor3 = ORANGE
	helpSlot3.BackgroundTransparency = 0
	helpSlot3.Active = false
	UiCircles.ensure(helpSlot3)
	helpSlot3Letter.Text = if mode == "gamepad" then "L2" else "Z"
	helpSlot3Letter.TextColor3 = Color3.new(1, 1, 1)
	helpSlot3Letter.Visible = true
	return true
end

local function refreshSlot3HelpBadge()
	-- Visibility is owned by slide in/out; this only refreshes glyph while already shown.
	if not helpSlot3 or not helpSlot3.Visible then
		return
	end
	if not styleSlot3HelpBadge() then
		helpSlot3.Visible = false
	end
end

local function stopSlot3IdleCycle()
	if slot3IdleConn then
		slot3IdleConn:Disconnect()
		slot3IdleConn = nil
	end
	if slot3UndoLabel then
		slot3UndoLabel.Visible = false
	end
end

local function applySlot3IdleFrame(showUndoText: boolean)
	if not slot3Circle then
		return
	end
	if showUndoText then
		if slot3Circle:IsA("ImageLabel") or slot3Circle:IsA("ImageButton") then
			(slot3Circle :: any).Image = ""
		end
		slot3Circle.BackgroundColor3 = Color3.new(0, 0, 0)
		slot3Circle.BackgroundTransparency = 0
		if slot3UndoLabel then
			slot3UndoLabel.Visible = true
		end
	else
		if slot3Circle:IsA("ImageLabel") or slot3Circle:IsA("ImageButton") then
			(slot3Circle :: any).Image = slot3OriginalImage
		end
		slot3Circle.BackgroundColor3 = slot3OriginalBg
		slot3Circle.BackgroundTransparency = slot3OriginalBgTrans
		if slot3UndoLabel then
			slot3UndoLabel.Visible = false
		end
	end
end

local function startSlot3IdleCycle()
	if not slot3 or not slot3Circle then
		return
	end
	stopSlot3IdleCycle()
	if slot3Stroke then
		slot3Stroke.Enabled = true
		slot3Stroke.Color = Color3.new(1, 1, 1)
		slot3Stroke.Thickness = 2
	end
	UiCircles.ensure(slot3Circle)
	local t0 = os.clock()
	applySlot3IdleFrame(false) -- undo icon first
	slot3IdleConn = RunService.Heartbeat:Connect(function()
		if not InventoryState.isOpen() or not slot3 or not slot3.Visible then
			return
		end
		local showUndoText = (math.floor((os.clock() - t0) / SLOT_IDLE_PERIOD) % 2) == 1
		applySlot3IdleFrame(showUndoText)
	end)
end

local function slot3HiddenPos(home: UDim2): UDim2
	-- Offset toward the backpack (right) so the control starts/ends behind the panel.
	return home + UDim2.fromOffset(SLOT3_SLIDE_PX, 0)
end

local function playSlot3Reveal()
	if not slot3 or not slot3HomePos then
		return
	end
	slot3SlideToken += 1
	local token = slot3SlideToken
	local home = slot3HomePos
	local hidden = slot3HiddenPos(home)

	slot3.Position = hidden
	slot3.Visible = true
	if slot3Stroke then
		slot3Stroke.Enabled = true
		slot3Stroke.Color = Color3.new(1, 1, 1)
		slot3Stroke.Thickness = 2
	end
	startSlot3IdleCycle()

	local showHelp = styleSlot3HelpBadge()
	if showHelp and helpSlot3 and helpSlot3HomePos then
		helpSlot3.Position = slot3HiddenPos(helpSlot3HomePos)
		helpSlot3.Visible = true
		TweenService:Create(helpSlot3, SLOT3_SLIDE_IN, { Position = helpSlot3HomePos }):Play()
	elseif helpSlot3 then
		helpSlot3.Visible = false
	end

	local tw = TweenService:Create(slot3, SLOT3_SLIDE_IN, { Position = home })
	tw:Play()
	tw.Completed:Wait()
	if token ~= slot3SlideToken then
		return
	end
	slot3.Position = home
	if showHelp and helpSlot3 and helpSlot3HomePos then
		helpSlot3.Position = helpSlot3HomePos
	end
end

local function playSlot3Hide()
	if not slot3 or not slot3HomePos then
		return
	end
	slot3SlideToken += 1
	local token = slot3SlideToken
	local home = slot3HomePos
	local hidden = slot3HiddenPos(home)

	stopSlot3IdleCycle()
	slot3PressToken += 1 -- cancel in-flight undo press flash
	if not slot3.Visible then
		if helpSlot3 then
			helpSlot3.Visible = false
			if helpSlot3HomePos then
				helpSlot3.Position = helpSlot3HomePos
			end
		end
		slot3.Position = home
		if slot3Stroke then
			slot3Stroke.Enabled = false
		end
		return
	end

	slot3.Position = home
	local tw = TweenService:Create(slot3, SLOT3_SLIDE_OUT, { Position = hidden })
	tw:Play()
	if helpSlot3 and helpSlot3.Visible and helpSlot3HomePos then
		helpSlot3.Position = helpSlot3HomePos
		TweenService:Create(helpSlot3, SLOT3_SLIDE_OUT, { Position = slot3HiddenPos(helpSlot3HomePos) }):Play()
	end
	tw.Completed:Wait()
	if token ~= slot3SlideToken then
		return
	end
	slot3.Visible = false
	slot3.Position = home
	if slot3Stroke then
		slot3Stroke.Enabled = false
	end
	if helpSlot3 then
		helpSlot3.Visible = false
		if helpSlot3HomePos then
			helpSlot3.Position = helpSlot3HomePos
		end
	end
end

local function syncSlot3Visibility()
	-- Instant sync for boot / edge cases (no tween).
	if InventoryState.isOpen() then
		if slot3 and slot3HomePos then
			slot3.Position = slot3HomePos
			slot3.Visible = true
			startSlot3IdleCycle()
		end
		if styleSlot3HelpBadge() and helpSlot3 and helpSlot3HomePos then
			helpSlot3.Position = helpSlot3HomePos
			helpSlot3.Visible = true
		elseif helpSlot3 then
			helpSlot3.Visible = false
		end
	else
		stopSlot3IdleCycle()
		if slot3 and slot3HomePos then
			slot3.Visible = false
			slot3.Position = slot3HomePos
		end
		if slot3Stroke then
			slot3Stroke.Enabled = false
		end
		if helpSlot3 then
			helpSlot3.Visible = false
			if helpSlot3HomePos then
				helpSlot3.Position = helpSlot3HomePos
			end
		end
	end
end

local UNDO_SOUND_ID = "rbxassetid://17612245730"
local UNDO_STREAK_WINDOW = 3
local UNDO_PITCH_MIN = 0.9
local UNDO_PITCH_MAX = 1.55
local UNDO_PITCH_STEP = 0.07
local UNDO_FLASH_HOLD = 1
local UNDO_FLASH_FADE = 0.35
local UNDO_GLOW = Color3.fromRGB(255, 140, 40)

local undoSoundTemplate = Instance.new("Sound")
undoSoundTemplate.Name = "OceanTD_UndoSound"
undoSoundTemplate.SoundId = UNDO_SOUND_ID
undoSoundTemplate.Volume = 0.9
undoSoundTemplate.Parent = SoundService
task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ undoSoundTemplate })
	end)
end)

local undoLastPressAt = 0
local undoPitchStreak = 0

local function playUndoSound()
	local now = os.clock()
	if now - undoLastPressAt <= UNDO_STREAK_WINDOW then
		undoPitchStreak += 1
	else
		undoPitchStreak = 0
	end
	undoLastPressAt = now

	local base = UNDO_PITCH_MIN + math.random() * (1.15 - UNDO_PITCH_MIN)
	local pitch = math.clamp(base + undoPitchStreak * UNDO_PITCH_STEP, UNDO_PITCH_MIN, UNDO_PITCH_MAX)

	local sound = undoSoundTemplate:Clone()
	sound.PlaybackSpeed = pitch
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(4, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

local function playSlot3UndoPressFeedback()
	if not slot3Circle then
		return
	end
	slot3PressToken += 1
	local token = slot3PressToken
	stopSlot3IdleCycle()

	if slot3Circle:IsA("ImageLabel") or slot3Circle:IsA("ImageButton") then
		(slot3Circle :: any).Image = ""
	end
	slot3Circle.BackgroundColor3 = UNDO_GLOW
	slot3Circle.BackgroundTransparency = 0
	if slot3UndoLabel then
		slot3UndoLabel.TextColor3 = Color3.new(1, 1, 1)
		slot3UndoLabel.Visible = true
	end

	task.delay(UNDO_FLASH_HOLD, function()
		if token ~= slot3PressToken or not slot3Circle then
			return
		end
		local fade = TweenService:Create(slot3Circle, TweenInfo.new(UNDO_FLASH_FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			BackgroundColor3 = Color3.new(0, 0, 0),
		})
		fade:Play()
		fade.Completed:Wait()
		if token ~= slot3PressToken then
			return
		end
		if InventoryState.isOpen() and slot3 and slot3.Visible then
			startSlot3IdleCycle()
		end
	end)
end

local undoBusy = false
local function requestUndo()
	if not InventoryState.isOpen() then
		return
	end
	playUndoSound()
	playSlot3UndoPressFeedback()
	if undoBusy then
		return
	end
	undoBusy = true
	if RelocateController.isActive() then
		RelocateController.cancel(true)
	end
	local ok, result = pcall(function()
		return Remotes.getFunction("RequestUndo"):InvokeServer()
	end)
	undoBusy = false
	if ok and typeof(result) == "table" and result.ok then
		log("Undo", result.kind)
	else
		local code = if ok and typeof(result) == "table" then result.errorCode else "Fail"
		log("Undo rejected", code)
	end
end

local function refreshGamepadCloseLabel()
	stopCloseLabelCycle()
	refreshHelpSlotBadge()
	refreshSlot3HelpBadge()
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
	-- Cycle: shortcut letter for 1s, then "CLOSE" for 2s.
	local t0 = os.clock()
	closeX.Text = letter
	closeLabelCycleConn = RunService.Heartbeat:Connect(function()
		if not closeX.Visible then
			stopCloseLabelCycle()
			return
		end
		local phase = (os.clock() - t0) % 3
		closeX.Text = if phase < 1 then letter else "CLOSE"
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
	label.Size = UDim2.new(1, -4, 0, 14)
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
			end		end)
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
	if isOpen then
		task.spawn(function()
			-- Reveal Slot3 as the backpack opens so it slides out from behind the panel.
			task.spawn(playSlot3Reveal)
			playOpen()
			if openWithGamepadPending then
				enableGamepadSelect(true)
			end
			refreshGamepadCloseLabel()
		end)
	else
		unequipBackpackShovel()
		disableGamepadSelect()
		task.spawn(function()
			-- Slide Slot3 back behind the backpack while the panel closes.
			task.spawn(playSlot3Hide)
			playClose()
			refreshHelpSlotBadge()
			refreshSlot3HelpBadge()
		end)
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

-- Help circle (Y / Q) — same toggle as Slot4; gamepad badge uses gamepad open path.
if helpHitButton then
	helpHitButton.Activated:Connect(function()
		toggleFromUser(getShortcutMode() == "gamepad")
	end)
end

if slot3Button then
	slot3Button.Activated:Connect(function()
		requestUndo()
	end)
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if input.KeyCode == Enum.KeyCode.ButtonY then
		toggleFromUser(true)
		return
	end
	-- Undo: Z (keyboard) / L2 (gamepad) while backpack open.
	if input.KeyCode == Enum.KeyCode.Z or input.KeyCode == Enum.KeyCode.ButtonL2 then
		if InventoryState.isOpen() then
			requestUndo()
			return
		end
	end
	-- B closes backpack when in list select (placement/relocate own B while active).
	if input.KeyCode == Enum.KeyCode.ButtonB then
		if PlacementController.isActive() or RelocateController.isActive() then
			return
		end
		if InventoryState.isOpen() and (gamepadSelectActive or openWithGamepadPending) then
			toggleFromUser(true)
			return
		end
	end

	-- D-pad browses list; A arms coral. Left stick is free for walking until placement freezes.
	if gamepadSelectActive and not PlacementController.isActive() and not RelocateController.isActive() then
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
end)

applySlotClosedChrome()
refreshHelpSlotBadge()
syncSlot3Visibility()
UserInputService.LastInputTypeChanged:Connect(function()
	refreshGamepadCloseLabel()
end)
log("Backpack UI ready — shortcuts: Y/Q backpack; Z/L2 undo; help badges hidden on touch")
