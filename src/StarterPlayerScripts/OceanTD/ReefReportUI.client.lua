--!strict
--[[
	Reef Report — fullscreen coral breakdown UI (separate from skills).

	Studio: MobileLeftUI.dPad.Cart (also CartBTN / Report / ReefReport).
	While open: Cart becomes pulsing red close (X / B), same look as Skills.
	Shortcuts: DPadUp toggle; X / ButtonB close; Cart button toggle.
	Title shows live reef score N (abundance + mix bonuses); S/M/L bars tint by size balance.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD")
local ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local PlotOutlineColors = require(oceanRoot:WaitForChild("Shared"):WaitForChild("PlotOutlineColors"))
local CoralSize = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralSize"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))
local UiCircles = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiCircles"))
local UiPieChart = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPieChart"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local ReefScore = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ReefScore"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local PlacedCoralIndex = require(script.Parent:WaitForChild("PlacedCoralIndex"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local RelocateMultiSelect = require(script.Parent:WaitForChild("RelocateMultiSelect"))

local REPORT_OPEN_ATTR = "OceanTD_ReefReportOpen"
local FORCE_CLOSE_ATTR = "OceanTD_ForceCloseReefReport"
local SKILLS_OPEN_ATTR = "OceanTD_SkillsBubblesOpen"
local TOGGLE_COOLDOWN = 0.35
local COLUMN_WIDTH = 200
local COLUMN_GAP = 16
local SCROLL_PAD_BOTTOM = 14 -- keep column stroke clear of horizontal scrollbar
local INTRO_SCROLL_SEC = 1.0
local STICK_DEADZONE = 0.22
local STICK_SCROLL_SPEED = 980 -- canvas px/sec at full stick
local SIZE_BAR_EMPTY = Color3.fromHex("01021a")
local SIZE_BAR_MIN_FRAC = 0.06 -- tiny sliver even when count is 0
local LETTERS = { "S", "M", "L" }
local WAVE_HUD_NAMES = {
	OceanTD_WaveHud = true,
	OceanTD_WatchHud = true,
}

local CART_NAMES = {
	Cart = true,
	CartBTN = true,
	CartBtn = true,
	cart = true,
	Report = true,
	ReefReport = true,
	ShoppingCart = true,
}

local open = false
local lastToggleAt = 0
local cartBtn: GuiObject? = nil
local leftGui: ScreenGui? = nil
local leftOrderBase = 0
local reportGui: ScreenGui? = nil
local scroll: ScrollingFrame? = nil
local columnsHost: Frame? = nil
local scoreLabel: TextLabel? = nil
local helpBtn: GuiButton? = nil
local helpGui: ScreenGui? = nil
local helpPanel: Frame? = nil
local helpCloseBtn: TextButton? = nil
local helpOpen = false
local helpCloseToken = 0
local prevGuiSelected: GuiObject? = nil
local closeChrome: GuiObject? = nil
local closeLabel: TextLabel? = nil
local closeScale: UIScale? = nil
local closeSyncConn: RBXScriptConnection? = nil
local introScrollConn: RBXScriptConnection? = nil
local stickScrollConn: RBXScriptConnection? = nil
local introScrolling = false
local pulseToken = 0
local hiddenCartKids: { GuiObject } = {}
local columnRefreshFns: { () -> () } = {}
local placedConn: RBXScriptConnection? = nil
local plotConn: RBXScriptConnection? = nil
local hiddenGuiEntries: { { gui: GuiObject, wasVisible: boolean } } = {}
local hiddenScreenEntries: { { sg: ScreenGui, wasEnabled: boolean } } = {}
local cartHitWasActive: boolean? = nil
local cartBtnWasActive: boolean? = nil

local REPORT_DISPLAY_ORDER = 120
local EDGE_MARGIN = 16 -- bottom gap like $D from screen edge
local TITLE_HEIGHT = 40
local TITLE_TOP = 8
local SCROLL_TOP = TITLE_TOP + TITLE_HEIGHT + 4 -- ~52; keeps prior list height

local applyOpen: (boolean) -> ()

local function isGamepadMode(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function findCartButton(dPad: Instance): GuiObject?
	for name in pairs(CART_NAMES) do
		local ch = dPad:FindFirstChild(name)
		if ch and ch:IsA("GuiObject") then
			return ch
		end
	end
	for _, ch in ipairs(dPad:GetChildren()) do
		if ch:IsA("GuiObject") then
			local n = string.lower(ch.Name)
			if string.find(n, "cart", 1, true) or n == "report" or string.find(n, "reefreport", 1, true) then
				return ch
			end
		end
	end
	return nil
end

local function ensureHitOverlay(btn: GuiObject): GuiButton
	local existing = btn:FindFirstChild("_OceanTD_CartHit")
	if existing and existing:IsA("GuiButton") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local hit = Instance.new("TextButton")
	hit.Name = "_OceanTD_CartHit"
	hit.Text = ""
	hit.BackgroundTransparency = 1
	hit.Size = UDim2.fromScale(1, 1)
	hit.Position = UDim2.fromScale(0, 0)
	hit.ZIndex = btn.ZIndex + 20
	hit.AutoButtonColor = false
	hit.Parent = btn
	return hit
end

local function syncCloseLabel()
	if closeLabel then
		closeLabel.Text = if isGamepadMode() then "B" else "X"
	end
end

local function stopClosePulse()
	pulseToken += 1
	if closeScale then
		closeScale.Scale = 1
	end
end

local function startClosePulse()
	pulseToken += 1
	local my = pulseToken
	task.spawn(function()
		while my == pulseToken and open and closeScale and closeChrome and closeChrome.Parent do
			local up = TweenService:Create(
				closeScale,
				TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Scale = 1.14 }
			)
			up:Play()
			up.Completed:Wait()
			if my ~= pulseToken then
				return
			end
			local down = TweenService:Create(
				closeScale,
				TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Scale = 1 }
			)
			down:Play()
			down.Completed:Wait()
		end
	end)
end

local function hideCartBtnContent(hide: boolean)
	if not cartBtn then
		return
	end
	if hide then
		table.clear(hiddenCartKids)
		for _, ch in ipairs(cartBtn:GetChildren()) do
			if ch:IsA("GuiObject") and ch.Name ~= "_OceanTD_CartHit" then
				if ch.Visible then
					table.insert(hiddenCartKids, ch)
					ch.Visible = false
				end
			end
		end
		if cartBtn:IsA("ImageButton") or cartBtn:IsA("ImageLabel") then
			(cartBtn :: ImageButton).ImageTransparency = 1
		end
	else
		for _, ch in ipairs(hiddenCartKids) do
			if ch.Parent then
				ch.Visible = true
			end
		end
		table.clear(hiddenCartKids)
		if cartBtn:IsA("ImageButton") or cartBtn:IsA("ImageLabel") then
			(cartBtn :: ImageButton).ImageTransparency = 0
		end
	end
end

local function stopCloseSync()
	if closeSyncConn then
		closeSyncConn:Disconnect()
		closeSyncConn = nil
	end
end

local function restoreCartHitForToggle()
	if not cartBtn then
		cartHitWasActive = nil
		cartBtnWasActive = nil
		return
	end
	if cartBtnWasActive ~= nil then
		cartBtn.Active = cartBtnWasActive
		cartBtnWasActive = nil
	end
	local hitBtn = cartBtn:FindFirstChild("_OceanTD_CartHit")
	if hitBtn and hitBtn:IsA("GuiObject") then
		hitBtn.Visible = true
		if cartHitWasActive ~= nil then
			hitBtn.Active = cartHitWasActive
			cartHitWasActive = nil
		else
			hitBtn.Active = true
		end
	end
end

local function syncCloseToCart()
	if not closeChrome or not cartBtn then
		return
	end
	local ap = cartBtn.AbsolutePosition
	local as = cartBtn.AbsoluteSize
	if as.X < 4 or as.Y < 4 then
		return
	end
	local side = math.max(as.X, as.Y)
	closeChrome.AnchorPoint = Vector2.new(0.5, 0.5)
	closeChrome.Position = UDim2.fromOffset(ap.X + as.X * 0.5, ap.Y + as.Y * 0.5)
	closeChrome.Size = UDim2.fromOffset(side, side)
end

local function destroyCloseChrome()
	stopClosePulse()
	stopCloseSync()
	if closeChrome then
		closeChrome:Destroy()
		closeChrome = nil
	end
	closeLabel = nil
	closeScale = nil
	hideCartBtnContent(false)
	restoreCartHitForToggle()
end

local function ensureCloseChrome()
	if not cartBtn or not reportGui then
		return
	end
	destroyCloseChrome()
	hideCartBtnContent(true)

	-- Keep left HUD under the report so dPad/cart cannot steal column pie hits.
	-- Close chrome lives on the report ScreenGui and tracks the cart each frame.
	cartBtnWasActive = cartBtn.Active
	cartBtn.Active = false
	local cartHit = cartBtn:FindFirstChild("_OceanTD_CartHit")
	if cartHit and cartHit:IsA("GuiObject") then
		cartHitWasActive = cartHit.Active
		cartHit.Active = false
		cartHit.Visible = false
	end

	local chrome = Instance.new("TextButton")
	chrome.Name = "_OceanTD_ReefReportClose"
	chrome.Text = ""
	chrome.AutoButtonColor = false
	chrome.BackgroundColor3 = Color3.fromRGB(220, 40, 50)
	chrome.BorderSizePixel = 0
	chrome.AnchorPoint = Vector2.new(0.5, 0.5)
	chrome.Position = UDim2.fromOffset(0, 0)
	chrome.Size = UDim2.fromOffset(48, 48)
	chrome.ZIndex = 200
	chrome.Active = true
	chrome.Parent = reportGui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = chrome
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(255, 255, 255)
	stroke.Transparency = 0.15
	stroke.Parent = chrome

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = chrome

	local lbl = Instance.new("TextLabel")
	lbl.Name = "Glyph"
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextScaled = true
	lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
	lbl.TextStrokeTransparency = 0.6
	lbl.ZIndex = chrome.ZIndex + 1
	lbl.Active = false
	lbl.Parent = chrome
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.18, 0)
	pad.PaddingBottom = UDim.new(0.18, 0)
	pad.PaddingLeft = UDim.new(0.18, 0)
	pad.PaddingRight = UDim.new(0.18, 0)
	pad.Parent = lbl

	chrome.Activated:Connect(function()
		lastToggleAt = os.clock()
		if open then
			applyOpen(false)
		end
	end)

	closeChrome = chrome
	closeLabel = lbl
	closeScale = scale
	syncCloseLabel()
	syncCloseToCart()
	stopCloseSync()
	closeSyncConn = RunService.RenderStepped:Connect(syncCloseToCart)
	startClosePulse()
end

local function rememberHideGui(gui: GuiObject)
	for _, entry in ipairs(hiddenGuiEntries) do
		if entry.gui == gui then
			return
		end
	end
	table.insert(hiddenGuiEntries, { gui = gui, wasVisible = gui.Visible })
	gui.Visible = false
end

local function rememberHideScreen(sg: ScreenGui)
	for _, entry in ipairs(hiddenScreenEntries) do
		if entry.sg == sg then
			return
		end
	end
	table.insert(hiddenScreenEntries, { sg = sg, wasEnabled = sg.Enabled })
	sg.Enabled = false
end

local function restoreHiddenHud()
	for _, entry in ipairs(hiddenGuiEntries) do
		if entry.gui.Parent then
			entry.gui.Visible = entry.wasVisible
		end
	end
	table.clear(hiddenGuiEntries)
	for _, entry in ipairs(hiddenScreenEntries) do
		if entry.sg.Parent then
			entry.sg.Enabled = entry.wasEnabled
		end
	end
	table.clear(hiddenScreenEntries)
end

local function hideLeftUiExceptCart()
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if not left then
		return
	end
	local dPad = left:FindFirstChild("dPad")
	if dPad then
		for _, ch in ipairs(dPad:GetChildren()) do
			if ch:IsA("GuiObject") then
				-- Keep only the bound cart (close chrome anchors to it). Hides Skills, cams, etc.
				if cartBtn and ch == cartBtn then
					continue
				end
				rememberHideGui(ch)
			end
		end
	end
	for _, ch in ipairs(left:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "dPad" then
			rememberHideGui(ch)
		end
	end
	-- Hide $D / $DCount (and 720p sand-dollar row).
	local dCount = LeftHudLayout.findDCount(left)
	local dLabel = LeftHudLayout.findDLabel(left)
	if dCount then
		rememberHideGui(dCount)
	end
	if dLabel then
		rememberHideGui(dLabel)
	end
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row and row:IsA("GuiObject") then
		rememberHideGui(row)
	end
end

-- Match skills open: hide backpack / wave quickbar on the right HUD (not the whole ScreenGui).
local QUICKBAR_HIDE_SLOTS = {
	Slot1 = true,
	Slot2 = true,
	Slot3 = true,
	Slot4 = true,
	Slot5 = true,
	Slot6 = true,
	Slot7 = true,
}

local function hideQuickbarSlotsOnHud(hud: Instance)
	local quickbar = hud:FindFirstChild("Quickbar")
	if quickbar then
		for _, ch in ipairs(quickbar:GetChildren()) do
			if ch:IsA("GuiObject") and QUICKBAR_HIDE_SLOTS[ch.Name] then
				rememberHideGui(ch)
			end
		end
	end
	local help = hud:FindFirstChild("QuickbarHelp")
	if help and help:IsA("GuiObject") then
		rememberHideGui(help)
	elseif help then
		for _, ch in ipairs(help:GetChildren()) do
			if ch:IsA("GuiObject") and QUICKBAR_HIDE_SLOTS[ch.Name] then
				rememberHideGui(ch)
			end
		end
	end
	for _, d in ipairs(hud:GetDescendants()) do
		if d:IsA("GuiObject") and WAVE_HUD_NAMES[d.Name] then
			rememberHideGui(d)
		end
	end
end

local function hideRightHud()
	local mobile = playerGui:FindFirstChild(UiViewportTags.MOBILE_RIGHT_HUD)
	local p720 = playerGui:FindFirstChild(UiViewportTags.P720_RIGHT_HUD)
	if mobile then
		hideQuickbarSlotsOnHud(mobile)
	end
	if p720 then
		hideQuickbarSlotsOnHud(p720)
	end
	for _, ch in ipairs(playerGui:GetChildren()) do
		if ch:IsA("GuiObject") and WAVE_HUD_NAMES[ch.Name] then
			rememberHideGui(ch)
		elseif ch:IsA("ScreenGui") and WAVE_HUD_NAMES[ch.Name] then
			rememberHideScreen(ch)
		end
	end
end

local function hideSkillsButton()
	local left = playerGui:FindFirstChild("MobileLeftUI")
	local dPad = left and left:FindFirstChild("dPad")
	if not dPad then
		return
	end
	local skills = dPad:FindFirstChild("Skills")
	if skills and skills:IsA("GuiObject") then
		rememberHideGui(skills)
		skills.Visible = false
	end
end

local function pushSeedWheelUnderReport()
	local wheel = playerGui:FindFirstChild("OceanTD_SeedWheel")
	if wheel and wheel:IsA("ScreenGui") and reportGui then
		wheel.DisplayOrder = math.max(0, reportGui.DisplayOrder - 1)
	end
end

local function raiseCloseLayer()
	-- Report must stay above left HUD so column pies receive clicks. Close chrome is
	-- parented to the report and synced to the cart (see ensureCloseChrome).
	if reportGui then
		local leftOrder = if leftGui then leftGui.DisplayOrder else leftOrderBase
		reportGui.DisplayOrder = math.max(REPORT_DISPLAY_ORDER, leftOrder + 40)
	end
	if leftGui then
		leftGui.DisplayOrder = leftOrderBase
		leftGui.IgnoreGuiInset = true
		leftGui.ClipToDeviceSafeArea = false
	end
	local dPad = leftGui and leftGui:FindFirstChild("dPad")
	if dPad and dPad:IsA("GuiObject") then
		dPad.Active = false
	end
	pushSeedWheelUnderReport()
	hideSkillsButton()
end

local function setReportOpenHud(hide: boolean)
	if hide then
		restoreHiddenHud()
		hideLeftUiExceptCart()
		hideSkillsButton()
		hideRightHud()
	else
		restoreHiddenHud()
	end
end

local function stopIntroScroll()
	introScrolling = false
	if introScrollConn then
		introScrollConn:Disconnect()
		introScrollConn = nil
	end
end

local function startIntroScroll()
	stopIntroScroll()
	if not scroll then
		return
	end
	task.defer(function()
		if not open or not scroll then
			return
		end
		local windowX = scroll.AbsoluteWindowSize.X
		if windowX < 1 then
			windowX = scroll.AbsoluteSize.X
		end
		local maxX = math.max(0, scroll.AbsoluteCanvasSize.X - windowX)
		if maxX < 1 then
			scroll.CanvasPosition = Vector2.new(0, 0)
			return
		end
		scroll.CanvasPosition = Vector2.new(maxX, 0)
		local startX = maxX
		local endX = 0
		local t0 = os.clock()
		introScrolling = true
		introScrollConn = RunService.RenderStepped:Connect(function()
			if not open or not scroll then
				stopIntroScroll()
				return
			end
			local elapsed = os.clock() - t0
			if elapsed < INTRO_SCROLL_SEC then
				local u = math.clamp(elapsed / INTRO_SCROLL_SEC, 0, 1)
				local a = 1 - (1 - u) * (1 - u)
				scroll.CanvasPosition = Vector2.new(startX + (endX - startX) * a, 0)
			else
				scroll.CanvasPosition = Vector2.new(0, 0)
				stopIntroScroll()
			end
		end)
	end)
end

local function thumbstick1X(): number
	local ok, state = pcall(function()
		return UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
	end)
	if not ok or typeof(state) ~= "table" then
		return 0
	end
	for _, input in ipairs(state :: { InputObject }) do
		if input.KeyCode == Enum.KeyCode.Thumbstick1 then
			return input.Position.X
		end
	end
	return 0
end

local function bindStickScroll(on: boolean)
	if stickScrollConn then
		stickScrollConn:Disconnect()
		stickScrollConn = nil
	end
	if not on then
		return
	end
	stickScrollConn = RunService.RenderStepped:Connect(function(dt)
		if not open or not scroll or introScrolling then
			return
		end
		local x = thumbstick1X()
		if math.abs(x) < STICK_DEADZONE then
			return
		end
		local windowX = scroll.AbsoluteWindowSize.X
		if windowX < 1 then
			windowX = scroll.AbsoluteSize.X
		end
		local maxX = math.max(0, scroll.AbsoluteCanvasSize.X - windowX)
		local nextX = math.clamp(scroll.CanvasPosition.X + x * STICK_SCROLL_SPEED * dt, 0, maxX)
		scroll.CanvasPosition = Vector2.new(nextX, 0)
	end)
end

local function beginRelocateMatches(matches: { BasePart }, debugTag: string?)
	local tag = debugTag or "size"
	if #matches == 0 then
		print(string.format("[ReefReport][%s] beginRelocateMatches ABORT: 0 matches", tag))
		return
	end
	print(string.format(
		"[ReefReport][%s] beginRelocateMatches ok matches=%d primary=%s relocateActive=%s backpackOpen=%s",
		tag,
		#matches,
		matches[1].Name,
		tostring(RelocateController.isActive()),
		tostring(InventoryState.isOpen())
	))
	lastToggleAt = os.clock()
	applyOpen(false)
	-- Inspect / upgrade / hue UI lives in the backpack panel — open build mode.
	InventoryState.clearSelection()
	if RelocateController.isActive() then
		print(string.format("[ReefReport][%s] canceling existing relocate before begin", tag))
		RelocateController.cancel(true)
	end
	InventoryState.setOpen(true)
	-- Wait until press is fully released and backpack host is visible.
	task.delay(0.1, function()
		local primary = matches[1]
		if not primary or not primary.Parent then
			print(string.format("[ReefReport][%s] delayed begin ABORT: primary missing/parent nil", tag))
			return
		end
		if not InventoryState.isOpen() then
			print(string.format("[ReefReport][%s] backpack was closed; reopening", tag))
			InventoryState.setOpen(true)
		end
		if RelocateController.isActive() then
			print(string.format("[ReefReport][%s] canceling relocate again before begin", tag))
			RelocateController.cancel(true)
		end
		print(string.format(
			"[ReefReport][%s] RelocateController.begin(%s) backpackOpen=%s",
			tag,
			primary.Name,
			tostring(InventoryState.isOpen())
		))
		RelocateController.begin(primary)
		local added = 0
		for i = 2, #matches do
			local p = matches[i]
			if p.Parent then
				CoralVisual.applyRestLook(p)
				local m, c = CoralVisual.readRestLook(p)
				RelocateMultiSelect.ensureMembership(p, m, c)
				added += 1
			end
		end
		print(string.format(
			"[ReefReport][%s] after begin: relocateActive=%s multiExtra=%d",
			tag,
			tostring(RelocateController.isActive()),
			added
		))
	end)
end

local function selectSizeAndRelocate(itemId: string, sizeTier: number)
	local plot = ClientPlot.get()
	if not plot then
		print("[ReefReport][size] ABORT: no plot")
		return
	end
	local matches: { BasePart } = {}
	for _, p in ipairs(PlacedCoralIndex.getParts(plot.plotId)) do
		if p.Parent and p:GetAttribute("OceanTD_ItemId") == itemId then
			local _d, class = CoralSize.readFromPart(p)
			if CoralSize.clampTier(class) == sizeTier then
				table.insert(matches, p)
			end
		end
	end
	print(string.format("[ReefReport][size] item=%s tier=%d matches=%d", itemId, sizeTier, #matches))
	beginRelocateMatches(matches, "size:" .. itemId)
end

local function selectHueAndRelocate(itemId: string, hue: number)
	local plot = ClientPlot.get()
	if not plot then
		print("[ReefReport][hue] ABORT: no plot")
		return
	end
	local want = PlotOutlineColors.clampCoralIndex(hue)
	local allForItem = 0
	local hueHist: { [number]: number } = {}
	local matches: { BasePart } = {}
	for _, p in ipairs(PlacedCoralIndex.getParts(plot.plotId)) do
		if p.Parent and p:GetAttribute("OceanTD_ItemId") == itemId then
			allForItem += 1
			local resolved = PlacedCoralIndex.hueOfPart(p, itemId)
			hueHist[resolved] = (hueHist[resolved] or 0) + 1
			if resolved == want then
				table.insert(matches, p)
			end
		end
	end
	local histParts: { string } = {}
	for h, n in pairs(hueHist) do
		table.insert(histParts, string.format("%d=%d", h, n))
	end
	table.sort(histParts)
	print(string.format(
		"[ReefReport][hue] item=%s wantHue=%d (raw=%s) placedOfItem=%d primaryMatches=%d hist={%s}",
		itemId,
		want,
		tostring(hue),
		allForItem,
		#matches,
		table.concat(histParts, ", ")
	))
	-- Fallback: attribute may lag server confirm — also match raw ColorIndex / SeedHue.
	if #matches == 0 then
		for _, p in ipairs(PlacedCoralIndex.getParts(plot.plotId)) do
			if p.Parent and p:GetAttribute("OceanTD_ItemId") == itemId then
				local painted = p:GetAttribute("OceanTD_ColorIndex")
				local seed = p:GetAttribute("OceanTD_SeedHue")
				if (typeof(painted) == "number" and PlotOutlineColors.clampCoralIndex(painted) == want)
					or (typeof(seed) == "number" and PlotOutlineColors.clampCoralIndex(seed) == want)
				then
					table.insert(matches, p)
				end
			end
		end
		print(string.format("[ReefReport][hue] fallback attrMatches=%d", #matches))
		if #matches == 0 and allForItem > 0 then
			-- Dump first few parts' attrs to explain miss.
			local dumped = 0
			for _, p in ipairs(PlacedCoralIndex.getParts(plot.plotId)) do
				if p.Parent and p:GetAttribute("OceanTD_ItemId") == itemId then
					print(string.format(
						"[ReefReport][hue] miss sample part=%s ColorIndex=%s SeedHue=%s resolved=%s",
						p.Name,
						tostring(p:GetAttribute("OceanTD_ColorIndex")),
						tostring(p:GetAttribute("OceanTD_SeedHue")),
						tostring(PlacedCoralIndex.hueOfPart(p, itemId))
					))
					dumped += 1
					if dumped >= 5 then
						break
					end
				end
			end
		end
	end
	beginRelocateMatches(matches, "hue:" .. itemId .. ":" .. tostring(want))
end
local function placedCount(plotId: string, itemId: string): number
	local n = 0
	for _, part in ipairs(PlacedCoralIndex.getParts(plotId)) do
		if part.Parent and part:GetAttribute("OceanTD_ItemId") == itemId then
			n += 1
		end
	end
	return n
end

local function makeCoralColumn(def: ItemCatalog.ItemDef, layoutOrder: number): Frame
	local col = Instance.new("Frame")
	col.Name = "Column_" .. def.id
	col.BackgroundColor3 = Color3.fromRGB(12, 22, 36)
	col.BackgroundTransparency = 0.18
	col.BorderSizePixel = 0
	col.Size = UDim2.new(0, COLUMN_WIDTH, 1, 0)
	col.LayoutOrder = layoutOrder
	col.ClipsDescendants = true
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 14)
	corner.Parent = col
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(70, 110, 140)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.35
	stroke.Parent = col
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 12)
	pad.PaddingBottom = UDim.new(0, 12)
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = col
	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Vertical
	lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	lay.VerticalAlignment = Enum.VerticalAlignment.Top
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Padding = UDim.new(0, 8)
	lay.Parent = col

	-- Row 1: centered stack — hue pie fills dark circle; coral photo on top.
	local photoRow = Instance.new("Frame")
	photoRow.Name = "PhotoRow"
	photoRow.BackgroundTransparency = 1
	photoRow.Size = UDim2.new(1, 0, 0, 120)
	photoRow.LayoutOrder = 1
	photoRow.Parent = col

	local stack = Instance.new("Frame")
	stack.Name = "IconStack"
	stack.BackgroundTransparency = 1
	stack.AnchorPoint = Vector2.new(0.5, 0.5)
	stack.Position = UDim2.fromScale(0.5, 0.5)
	stack.Size = UDim2.fromOffset(112, 112)
	stack.Parent = photoRow
	local stackAspect = Instance.new("UIAspectRatioConstraint")
	stackAspect.AspectRatio = 1
	stackAspect.Parent = stack

	-- Square CanvasGroup pie fills the dark circle edge-to-edge (including bottom).
	local huePie = UiPieChart.ensure(stack, 1)
	huePie.AnchorPoint = Vector2.new(0.5, 0.5)
	huePie.Position = UDim2.fromScale(0.5, 0.5)
	huePie.Size = UDim2.fromScale(1, 1)
	huePie.ZIndex = 1

	local icon = Instance.new("ImageLabel")
	icon.Name = "Circle"
	icon.BackgroundColor3 = Color3.fromRGB(20, 30, 45)
	icon.BackgroundTransparency = 0.1
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(0.68, 0.68)
	icon.Image = def.icon
	icon.ScaleType = Enum.ScaleType.Fit
	icon.ZIndex = 3
	icon.Parent = stack
	UiCircles.ensure(icon)

	-- Invisible hit layer — pie look unchanged. Local spokeHueIds stay in sync with
	-- refresh even if the pie module's pendingIds table gets out of date.
	local pieHit = Instance.new("TextButton")
	pieHit.Name = "HuePieHit"
	pieHit.Text = ""
	pieHit.BackgroundTransparency = 1
	pieHit.Size = UDim2.fromScale(1, 1)
	pieHit.Position = UDim2.fromScale(0, 0)
	pieHit.ZIndex = 8
	pieHit.AutoButtonColor = false
	pieHit.Active = true
	huePie.Active = false
	icon.Active = false
	pieHit.Parent = stack
	local spokeHueIds: { number? } = table.create(UiPieChart.spokeCount())
	local lastPiePtr: Vector2? = nil

	local function rebuildSpokeHueIds(slices: { UiPieChart.Slice })
		table.clear(spokeHueIds)
		local total = 0
		for _, s in ipairs(slices) do
			if s.weight > 0 and typeof(s.id) == "number" then
				total += s.weight
			end
		end
		local nSpokes = UiPieChart.spokeCount()
		if total <= 0 then
			for i = 1, nSpokes do
				spokeHueIds[i] = nil
			end
			return
		end
		local cursor = 0
		for _, s in ipairs(slices) do
			if s.weight <= 0 or typeof(s.id) ~= "number" then
				continue
			end
			local n = math.max(1, math.floor((s.weight / total) * nSpokes + 0.5))
			for _ = 1, n do
				if cursor >= nSpokes then
					break
				end
				cursor += 1
				spokeHueIds[cursor] = PlotOutlineColors.clampCoralIndex(s.id)
			end
		end
		local lastId = nil
		for i = #slices, 1, -1 do
			if typeof(slices[i].id) == "number" then
				lastId = PlotOutlineColors.clampCoralIndex(slices[i].id)
				break
			end
		end
		while cursor < nSpokes do
			cursor += 1
			spokeHueIds[cursor] = lastId
		end
	end

	local function resolveHueFromPointer(screen: Vector2): (number?, string)
		local inset = GuiService:GetGuiInset()
		local ap = pieHit.AbsolutePosition
		local as = pieHit.AbsoluteSize
		local candidates = {
			{ name = "raw", p = screen },
			{ name = "minusInset", p = Vector2.new(screen.X - inset.X, screen.Y - inset.Y) },
			{ name = "plusInset", p = Vector2.new(screen.X + inset.X, screen.Y + inset.Y) },
		}
		local uniqueIds: { [number]: boolean } = {}
		local filled = 0
		for i = 1, #spokeHueIds do
			local id = spokeHueIds[i]
			if typeof(id) == "number" then
				uniqueIds[id] = true
				filled += 1
			end
		end
		local uniqList: { string } = {}
		for id in pairs(uniqueIds) do
			table.insert(uniqList, tostring(id))
		end
		table.sort(uniqList)
		print(string.format(
			"[ReefReport][pieClick] item=%s (%s) screen=(%.0f,%.0f) inset=(%.0f,%.0f) hitAbs=(%.0f,%.0f) hitSize=(%.0f,%.0f) spokeFilled=%d/%d uniqueHues={%s}",
			def.id,
			def.displayName,
			screen.X,
			screen.Y,
			inset.X,
			inset.Y,
			ap.X,
			ap.Y,
			as.X,
			as.Y,
			filled,
			UiPieChart.spokeCount(),
			table.concat(uniqList, ",")
		))
		for _, c in ipairs(candidates) do
			local dx = c.p.X - (ap.X + as.X * 0.5)
			local dy = c.p.Y - (ap.Y + as.Y * 0.5)
			local dist = math.sqrt(dx * dx + dy * dy)
			local radius = math.min(as.X, as.Y) * 0.5
			local viaGui = UiPieChart.hitTestIdOnGui(pieHit, spokeHueIds, c.p)
			local viaPie = UiPieChart.hitTestId(huePie, c.p)
			print(string.format(
				"[ReefReport][pieClick]  try %s pos=(%.0f,%.0f) dCenter=%.1f radius=%.1f viaGui=%s viaPie=%s",
				c.name,
				c.p.X,
				c.p.Y,
				dist,
				radius,
				tostring(viaGui),
				tostring(viaPie)
			))
			if typeof(viaGui) == "number" then
				return viaGui, "viaGui:" .. c.name
			end
			if typeof(viaPie) == "number" then
				return viaPie, "viaPie:" .. c.name
			end
		end
		return nil, "miss"
	end

	pieHit.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		print(string.format(
			"[ReefReport][pieClick] InputBegan item=%s input=%s",
			def.id,
			tostring(input.UserInputType)
		))
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			lastPiePtr = UserInputService:GetMouseLocation()
		else
			lastPiePtr = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)
	pieHit.Activated:Connect(function()
		local screen = lastPiePtr or UserInputService:GetMouseLocation()
		local usedStored = lastPiePtr ~= nil
		lastPiePtr = nil
		print(string.format(
			"[ReefReport][pieClick] Activated item=%s usedStoredPtr=%s",
			def.id,
			tostring(usedStored)
		))
		local hue, how = resolveHueFromPointer(screen)
		if typeof(hue) == "number" then
			print(string.format("[ReefReport][pieClick] RESOLVED hue=%d via %s → selectHueAndRelocate", hue, how))
			selectHueAndRelocate(def.id, hue)
		else
			print(string.format("[ReefReport][pieClick] NO HUE (%s) — click ignored for item=%s", how, def.id))
		end
	end)

	-- Row 2: name
	local name = Instance.new("TextLabel")
	name.Name = "Name"
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0, 26)
	name.LayoutOrder = 2
	name.Font = UiTheme.Font
	name.Text = def.displayName
	name.TextColor3 = Color3.fromRGB(230, 240, 255)
	name.TextScaled = true
	name.Parent = col

	-- Row 3: placed count
	local countLbl = Instance.new("TextLabel")
	countLbl.Name = "PlacedCount"
	countLbl.BackgroundTransparency = 1
	countLbl.Size = UDim2.new(1, 0, 0, 20)
	countLbl.LayoutOrder = 3
	countLbl.Font = UiTheme.Font
	countLbl.Text = "Placed: 0"
	countLbl.TextColor3 = Color3.fromRGB(160, 190, 210)
	countLbl.TextScaled = true
	countLbl.Parent = col

	-- Row 4: size bars with S/M/L labels centered on each bar (same row).
	local sizeRow = Instance.new("Frame")
	sizeRow.Name = "SizeBarRow"
	sizeRow.BackgroundTransparency = 1
	sizeRow.Size = UDim2.new(1, 0, 0, 88)
	sizeRow.LayoutOrder = 4
	sizeRow.Parent = col
	-- Fill leftover column height when the viewport is taller; never grow past parent.
	local sizeFlex = Instance.new("UIFlexItem")
	sizeFlex.FlexMode = Enum.UIFlexMode.Fill
	sizeFlex.Parent = sizeRow

	local barsHost = Instance.new("Frame")
	barsHost.Name = "Bars"
	barsHost.BackgroundTransparency = 1
	barsHost.Size = UDim2.fromScale(1, 1)
	barsHost.Parent = sizeRow
	local barsLay = Instance.new("UIListLayout")
	barsLay.FillDirection = Enum.FillDirection.Horizontal
	barsLay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	barsLay.VerticalAlignment = Enum.VerticalAlignment.Center
	barsLay.Padding = UDim.new(0, 10)
	barsLay.SortOrder = Enum.SortOrder.LayoutOrder
	barsLay.Parent = barsHost

	local barFills: { Frame } = {}
	for i = 1, 3 do
		local cell = Instance.new("Frame")
		cell.Name = "Bar" .. LETTERS[i]
		cell.BackgroundTransparency = 1
		cell.Size = UDim2.new(0, 42, 1, 0)
		cell.LayoutOrder = i
		cell.Parent = barsHost

		local track = Instance.new("Frame")
		track.Name = "Track"
		track.BackgroundColor3 = SIZE_BAR_EMPTY
		track.BackgroundTransparency = 0
		track.BorderSizePixel = 0
		track.AnchorPoint = Vector2.new(0.5, 0.5)
		track.Position = UDim2.fromScale(0.5, 0.5)
		track.Size = UDim2.new(0.55, 0, 1, -4)
		track.Parent = cell
		local trackCorner = Instance.new("UICorner")
		trackCorner.CornerRadius = UDim.new(0, 6)
		trackCorner.Parent = track

		local fill = Instance.new("Frame")
		fill.Name = "Fill"
		fill.BackgroundColor3 = ReefScore.meterColor(0)
		fill.BorderSizePixel = 0
		fill.AnchorPoint = Vector2.new(0.5, 1)
		fill.Position = UDim2.new(0.5, 0, 1, 0)
		fill.Size = UDim2.new(1, 0, 0, 0)
		fill.ZIndex = 1
		fill.Parent = track
		local fillCorner = Instance.new("UICorner")
		fillCorner.CornerRadius = UDim.new(0, 6)
		fillCorner.Parent = fill
		barFills[i] = fill

		-- White S/M/L centered on the bar (same horizontal row across columns).
		local lbl = Instance.new("TextLabel")
		lbl.Name = "SizeLabel"
		lbl.BackgroundTransparency = 1
		lbl.AnchorPoint = Vector2.new(0.5, 0.5)
		lbl.Position = UDim2.fromScale(0.5, 0.5)
		lbl.Size = UDim2.new(1, 4, 0, 22)
		lbl.Font = UiTheme.Font
		lbl.Text = LETTERS[i]
		lbl.TextColor3 = Color3.fromRGB(255, 255, 255)
		lbl.TextStrokeTransparency = 0.55
		lbl.TextScaled = true
		lbl.ZIndex = 3
		lbl.Parent = cell

		-- Click S/M/L → close report, enter relocate multi-select for that size.
		local hit = Instance.new("TextButton")
		hit.Name = "SizeHit"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.fromScale(1, 1)
		hit.ZIndex = 6
		hit.AutoButtonColor = false
		hit.Parent = cell
		local sizeTier = i
		hit.Activated:Connect(function()
			selectSizeAndRelocate(def.id, sizeTier)
		end)
	end

	local function refresh()
		local plot = ClientPlot.get()
		local hueSlices: { UiPieChart.Slice } = {}
		local nPlaced = 0
		local sizes = { [1] = 0, [2] = 0, [3] = 0 }
		if plot then
			nPlaced = placedCount(plot.plotId, def.id)
			local hues = PlacedCoralIndex.hueCountsForItem(plot.plotId, def.id)
			for hue, n in pairs(hues) do
				if typeof(n) == "number" and n > 0 then
					local hueId = PlotOutlineColors.clampCoralIndex(hue)
					table.insert(hueSlices, {
						color = PlotOutlineColors.coralColor(hueId),
						weight = n,
						id = hueId,
					})
				end
			end
			table.sort(hueSlices, function(a, b)
				return a.weight > b.weight
			end)
			sizes = PlacedCoralIndex.sizeCountsForItem(plot.plotId, def.id)
		end
		countLbl.Text = "Placed: " .. tostring(nPlaced)
		rebuildSpokeHueIds(hueSlices)
		UiPieChart.setSlices(huePie, hueSlices)

		local sizeTotal = 0
		for i = 1, 3 do
			sizeTotal += sizes[i] or 0
		end
		for i = 1, 3 do
			local n = sizes[i] or 0
			local frac = ReefScore.sizeBarFillFrac(n, sizeTotal, SIZE_BAR_MIN_FRAC)
			barFills[i].Size = UDim2.new(1, 0, frac, 0)
			barFills[i].BackgroundColor3 = ReefScore.sizeBarColorFromFill(frac)
		end
	end

	table.insert(columnRefreshFns, refresh)
	task.defer(refresh)
	return col
end

local function rebuildColumns()
	table.clear(columnRefreshFns)
	if not columnsHost then
		return
	end
	for _, ch in ipairs(columnsHost:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "UIListLayout" and ch.Name ~= "UIPadding" then
			ch:Destroy()
		end
	end
	local order = 1
	for _, def in ipairs(ItemCatalog.all()) do
		makeCoralColumn(def, order).Parent = columnsHost
		order += 1
	end
	if columnsHost and scroll then
		local n = math.max(0, order - 1)
		local w = n * COLUMN_WIDTH + math.max(0, n - 1) * COLUMN_GAP + 32
		scroll.CanvasSize = UDim2.fromOffset(w, 0)
	end
end

local function refreshReefScore()
	if not scoreLabel then
		return
	end
	local plot = ClientPlot.get()
	local parts: { BasePart } = {}
	if plot then
		parts = PlacedCoralIndex.getParts(plot.plotId)
	end
	local breakdown = ReefScore.compute(if plot then plot.plotId else nil, parts)
	scoreLabel.Text = tostring(breakdown.total)
	scoreLabel.TextColor3 = ReefScore.meterColor(breakdown.quality)
end

local HELP_BODY = "Add MORE Coral & Create Biodiversity:\n-Equal Amount of All Species Planted\n-Balanced Amount Of All Colors & Sizes For Each"
local HELP_STROKE = Color3.fromRGB(55, 200, 90)
local HELP_PANEL_BG = Color3.fromRGB(8, 14, 24)
local HELP_SCALE_IN = TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local HELP_SCALE_OUT = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local function hideHelpPopup()
	if not helpOpen then
		return
	end
	helpOpen = false
	helpCloseToken += 1
	local token = helpCloseToken
	if prevGuiSelected ~= nil or isGamepadMode() then
		GuiService.SelectedObject = nil
		prevGuiSelected = nil
	end
	local panel = helpPanel
	local btn = helpBtn
	local sg = helpGui
	if panel and btn and sg and sg.Enabled then
		local dim = sg:FindFirstChild("Dim")
		if dim and dim:IsA("GuiObject") then
			dim.Visible = false
		end
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
		local ap = btn.AbsolutePosition
		local as = btn.AbsoluteSize
		local endX = (ap.X + as.X * 0.5) / math.max(1, vp.X)
		local endY = (ap.Y + as.Y * 0.5) / math.max(1, vp.Y)
		local tw = TweenService:Create(panel, HELP_SCALE_OUT, {
			Position = UDim2.fromScale(endX, endY),
			Size = UDim2.fromOffset(36, 36),
		})
		tw:Play()
		tw.Completed:Connect(function()
			if token ~= helpCloseToken then
				return
			end
			if helpGui then
				helpGui.Enabled = false
			end
			if dim and dim:IsA("GuiObject") then
				dim.Visible = true
			end
		end)
	elseif helpGui then
		helpGui.Enabled = false
	end
end

local function dismissHelpImmediate()
	helpOpen = false
	helpCloseToken += 1
	prevGuiSelected = nil
	if GuiService.SelectedObject == helpCloseBtn or GuiService.SelectedObject == helpBtn then
		GuiService.SelectedObject = nil
	end
	if helpGui then
		helpGui.Enabled = false
	end
end

local function ensureHelpPopup()
	if helpGui and helpGui.Parent then
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_ReefReportHelp"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = REPORT_DISPLAY_ORDER + 40
	sg.Enabled = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui
	helpGui = sg

	local dim = Instance.new("TextButton")
	dim.Name = "Dim"
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BackgroundColor3 = Color3.fromRGB(0, 8, 16)
	dim.BackgroundTransparency = 0.4
	dim.Size = UDim2.fromScale(1, 1)
	dim.Selectable = false
	dim.ZIndex = 1
	dim.Parent = sg
	dim.Activated:Connect(hideHelpPopup)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(360, 260)
	panel.BackgroundColor3 = HELP_PANEL_BG
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Selectable = false
	panel.Parent = sg
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 14)
	pc.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = HELP_STROKE
	stroke.Transparency = 0.05
	stroke.Parent = panel
	helpPanel = panel

	local body = Instance.new("TextLabel")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.fromOffset(18, 18)
	body.Size = UDim2.new(1, -36, 1, -90)
	body.Font = UiTheme.Font
	body.Text = HELP_BODY
	body.TextColor3 = Color3.fromRGB(255, 255, 255)
	body.TextWrapped = true
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.TextSize = 22
	body.ZIndex = 3
	body.Parent = panel

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.Text = "CLOSE"
	closeBtn.Font = UiTheme.Font
	closeBtn.TextSize = 20
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.TextXAlignment = Enum.TextXAlignment.Center
	closeBtn.TextYAlignment = Enum.TextYAlignment.Center
	closeBtn.BackgroundColor3 = Color3.fromRGB(220, 45, 55)
	closeBtn.BorderSizePixel = 0
	closeBtn.AutoButtonColor = true
	closeBtn.Selectable = true
	closeBtn.Size = UDim2.new(1, -36, 0, 48)
	closeBtn.AnchorPoint = Vector2.new(0.5, 1)
	closeBtn.Position = UDim2.new(0.5, 0, 1, -16)
	closeBtn.ZIndex = 3
	closeBtn.Parent = panel
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 10)
	cc.Parent = closeBtn
	local closeStroke = Instance.new("UIStroke")
	closeStroke.Thickness = 2
	closeStroke.Color = Color3.fromRGB(255, 255, 255)
	closeStroke.Transparency = 0.35
	closeStroke.Parent = closeBtn
	closeBtn.Activated:Connect(hideHelpPopup)
	helpCloseBtn = closeBtn
	helpCloseBtn.Text = if isGamepadMode() then "B" else "CLOSE"
end

local function showHelpPopup()
	if not open then
		return
	end
	ensureHelpPopup()
	if not helpGui or not helpPanel or not helpBtn then
		return
	end
	helpCloseToken += 1
	UiPopupScale.attach(helpPanel)
	if helpCloseBtn then
		helpCloseBtn.Text = if isGamepadMode() then "B" else "CLOSE"
	end
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1920, 1080)
	local ap = helpBtn.AbsolutePosition
	local as = helpBtn.AbsoluteSize
	local startX = (ap.X + as.X * 0.5) / math.max(1, vp.X)
	local startY = (ap.Y + as.Y * 0.5) / math.max(1, vp.Y)
	local targetW = 360
	local targetH = 260
	helpPanel.AnchorPoint = Vector2.new(0.5, 0.5)
	helpPanel.Position = UDim2.fromScale(startX, startY)
	helpPanel.Size = UDim2.fromOffset(36, 36)
	helpGui.Enabled = true
	helpOpen = true
	local dim = helpGui:FindFirstChild("Dim")
	if dim and dim:IsA("GuiObject") then
		dim.Visible = true
	end
	TweenService:Create(helpPanel, HELP_SCALE_IN, {
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(targetW, targetH),
	}):Play()
	if isGamepadMode() and helpCloseBtn then
		prevGuiSelected = GuiService.SelectedObject
		GuiService.SelectedObject = helpCloseBtn
	end
end

local function refreshAllColumns()
	for _, fn in ipairs(columnRefreshFns) do
		fn()
	end
	refreshReefScore()
end

local function buildTitleRow(parent: Instance): Frame
	local existing = parent:FindFirstChild("TitleRow")
	if existing then
		existing:Destroy()
	end
	-- Migrate old loose title/score nodes.
	local oldTitle = parent:FindFirstChild("Title")
	if oldTitle and oldTitle.Parent == parent then
		oldTitle:Destroy()
	end
	local oldScore = parent:FindFirstChild("ReefScore")
	if oldScore and oldScore.Parent == parent then
		oldScore:Destroy()
	end
	local oldHelp = parent:FindFirstChild("ReefScoreHelp")
	if oldHelp and oldHelp.Parent == parent then
		oldHelp:Destroy()
	end

	local row = Instance.new("Frame")
	row.Name = "TitleRow"
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(0.5, 0)
	row.Position = UDim2.new(0.5, 0, 0, TITLE_TOP)
	row.Size = UDim2.new(0, 0, 0, TITLE_HEIGHT)
	row.AutomaticSize = Enum.AutomaticSize.X
	row.ZIndex = 3
	row.Parent = parent
	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Horizontal
	lay.HorizontalAlignment = Enum.HorizontalAlignment.Center
	lay.VerticalAlignment = Enum.VerticalAlignment.Center
	lay.Padding = UDim.new(0, 12)
	lay.SortOrder = Enum.SortOrder.LayoutOrder
	lay.Parent = row

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromOffset(210, TITLE_HEIGHT)
	title.Font = UiTheme.Font
	title.Text = "Reef Report"
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.TextYAlignment = Enum.TextYAlignment.Center
	title.TextColor3 = Color3.fromRGB(235, 245, 255)
	title.TextScaled = true
	title.LayoutOrder = 1
	title.ZIndex = 3
	title.Parent = row
	local titleSize = Instance.new("UITextSizeConstraint")
	titleSize.MaxTextSize = 34
	titleSize.MinTextSize = 18
	titleSize.Parent = title

	local score = Instance.new("TextLabel")
	score.Name = "ReefScore"
	score.BackgroundTransparency = 1
	score.Size = UDim2.fromOffset(84, TITLE_HEIGHT)
	score.Font = UiTheme.Font
	score.Text = "0"
	score.TextXAlignment = Enum.TextXAlignment.Center
	score.TextYAlignment = Enum.TextYAlignment.Center
	score.TextColor3 = ReefScore.meterColor(0)
	score.TextScaled = true
	score.TextStrokeTransparency = 0.55
	score.LayoutOrder = 2
	score.ZIndex = 3
	score.Parent = row
	local scoreSize = Instance.new("UITextSizeConstraint")
	scoreSize.MaxTextSize = 34
	scoreSize.MinTextSize = 18
	scoreSize.Parent = score
	scoreLabel = score

	local help = Instance.new("TextButton")
	help.Name = "ReefScoreHelp"
	help.Text = "?"
	help.Font = Enum.Font.GothamBold
	help.TextScaled = true
	help.TextColor3 = Color3.fromRGB(255, 255, 255)
	help.BackgroundColor3 = HELP_STROKE
	help.BorderSizePixel = 0
	help.AutoButtonColor = true
	help.Selectable = true
	help.Size = UDim2.fromOffset(34, 34)
	help.LayoutOrder = 3
	help.ZIndex = 3
	help.Parent = row
	local helpCorner = Instance.new("UICorner")
	helpCorner.CornerRadius = UDim.new(1, 0)
	helpCorner.Parent = help
	local helpPad = Instance.new("UIPadding")
	helpPad.PaddingTop = UDim.new(0.12, 0)
	helpPad.PaddingBottom = UDim.new(0.12, 0)
	helpPad.PaddingLeft = UDim.new(0.12, 0)
	helpPad.PaddingRight = UDim.new(0.12, 0)
	helpPad.Parent = help
	help.Activated:Connect(showHelpPopup)
	helpBtn = help

	refreshReefScore()
	return row
end

local function hardenFullBleed(sg: ScreenGui)
	sg.IgnoreGuiInset = true
	sg.ClipToDeviceSafeArea = false
	pcall(function()
		(sg :: any).ScreenInsets = Enum.ScreenInsets.None
	end)
end

local function ensureReportGui(): ScreenGui
	if reportGui and reportGui.Parent then
		hardenFullBleed(reportGui)
		local root = reportGui:FindFirstChild("Root")
		if root and root:IsA("GuiObject") then
			local row = root:FindFirstChild("TitleRow")
			if not row then
				buildTitleRow(root)
			else
				local score = row:FindFirstChild("ReefScore")
				if score and score:IsA("TextLabel") then
					scoreLabel = score
				end
				local help = row:FindFirstChild("ReefScoreHelp")
				if help and help:IsA("GuiButton") then
					helpBtn = help
				end
				refreshReefScore()
			end
			local sc = root:FindFirstChild("ColumnsScroll")
			if sc and sc:IsA("ScrollingFrame") then
				sc.Position = UDim2.new(0, 0, 0, SCROLL_TOP)
				sc.Size = UDim2.new(1, 0, 1, -(SCROLL_TOP + EDGE_MARGIN))
				scroll = sc
			end
		end
		return reportGui
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_ReefReport"
	sg.ResetOnSpawn = false
	hardenFullBleed(sg)
	sg.DisplayOrder = REPORT_DISPLAY_ORDER
	sg.Enabled = false
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui
	reportGui = sg

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.fromRGB(4, 10, 18)
	dim.BackgroundTransparency = 0.28
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	dim.Parent = sg

	-- Full-bleed root (no HUD scale / no safe-area inset) so list is edge-to-edge on mobile.
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Position = UDim2.fromScale(0, 0)
	root.ZIndex = 2
	root.Parent = sg

	buildTitleRow(root)

	local sc = Instance.new("ScrollingFrame")
	sc.Name = "ColumnsScroll"
	sc.BackgroundTransparency = 1
	sc.BorderSizePixel = 0
	sc.AnchorPoint = Vector2.new(0, 0)
	sc.Position = UDim2.new(0, 0, 0, SCROLL_TOP)
	-- Full width; bottom EDGE_MARGIN from screen edge.
	sc.Size = UDim2.new(1, 0, 1, -(SCROLL_TOP + EDGE_MARGIN))
	sc.ScrollBarThickness = 8
	sc.ScrollBarImageColor3 = Color3.fromRGB(140, 180, 210)
	sc.ScrollingDirection = Enum.ScrollingDirection.X
	sc.CanvasSize = UDim2.new(0, 0, 0, 0)
	sc.ClipsDescendants = true
	sc.HorizontalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	sc.ZIndex = 2
	sc.Parent = root
	scroll = sc

	local host = Instance.new("Frame")
	host.Name = "Columns"
	host.BackgroundTransparency = 1
	host.Size = UDim2.new(0, 0, 1, 0)
	host.AutomaticSize = Enum.AutomaticSize.X
	host.Parent = sc
	columnsHost = host
	local hostLay = Instance.new("UIListLayout")
	hostLay.FillDirection = Enum.FillDirection.Horizontal
	hostLay.VerticalAlignment = Enum.VerticalAlignment.Center
	hostLay.SortOrder = Enum.SortOrder.LayoutOrder
	hostLay.Padding = UDim.new(0, COLUMN_GAP)
	hostLay.Parent = host
	local hostPad = Instance.new("UIPadding")
	hostPad.PaddingLeft = UDim.new(0, 0)
	hostPad.PaddingRight = UDim.new(0, 0)
	hostPad.PaddingTop = UDim.new(0, 4)
	hostPad.PaddingBottom = UDim.new(0, SCROLL_PAD_BOTTOM)
	hostPad.Parent = host

	rebuildColumns()
	return sg
end

local function bindLiveRefresh(on: boolean)
	if placedConn then
		placedConn:Disconnect()
		placedConn = nil
	end
	if plotConn then
		plotConn:Disconnect()
		plotConn = nil
	end
	if not on then
		return
	end
	placedConn = PlacedCoralIndex.onChanged(refreshAllColumns)
	plotConn = ClientPlot.onChanged(function()
		refreshAllColumns()
	end)
end

applyOpen = function(want: boolean)
	open = want
	playerGui:SetAttribute(REPORT_OPEN_ATTR, want == true)
	local sg = ensureReportGui()
	sg.DisplayOrder = REPORT_DISPLAY_ORDER
	hardenFullBleed(sg)
	if want then
		-- Close skills first — it forces Skills.Visible=true and resets left DisplayOrder.
		playerGui:SetAttribute("OceanTD_ForceCloseSkills", os.clock())
		setReportOpenHud(true)
		raiseCloseLayer()
		if cartBtn then
			cartBtn.Visible = true
		end
		ensureCloseChrome()
		rebuildColumns()
		sg.Enabled = true
		bindLiveRefresh(true)
		refreshAllColumns()
		startIntroScroll()
		bindStickScroll(true)
		-- Skills close + bubble stop can re-show Skills a frame later.
		task.defer(function()
			if not open then
				return
			end
			raiseCloseLayer()
			hideLeftUiExceptCart()
			if cartBtn then
				cartBtn.Visible = true
			end
			if not closeChrome or not closeChrome.Parent then
				ensureCloseChrome()
			end
		end)
		task.delay(0.15, function()
			if open then
				raiseCloseLayer()
				hideSkillsButton()
			end
		end)
	else
		dismissHelpImmediate()
		stopIntroScroll()
		bindStickScroll(false)
		bindLiveRefresh(false)
		destroyCloseChrome()
		sg.Enabled = false
		setReportOpenHud(false)
		if leftGui then
			leftGui.DisplayOrder = leftOrderBase
		end
		if cartBtn then
			cartBtn.Visible = true
		end
		hideCartBtnContent(false)
	end
end

local function canToggle(): boolean
	local now = os.clock()
	if now - lastToggleAt < TOGGLE_COOLDOWN then
		return false
	end
	lastToggleAt = now
	return true
end

local function toggle()
	if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true and not open then
		return
	end
	if InventoryState.isOpen() and not open then
		return
	end
	if not canToggle() then
		return
	end
	applyOpen(not open)
end

local function closeOnly()
	lastToggleAt = os.clock()
	if open then
		applyOpen(false)
	end
end

local function openFromDPadUp()
	if open then
		if not canToggle() then
			return
		end
		applyOpen(false)
		return
	end
	if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
		return
	end
	if InventoryState.isOpen() then
		return
	end
	if not canToggle() then
		return
	end
	applyOpen(true)
end

local function bindCart(btn: GuiObject)
	cartBtn = btn
	local hit = ensureHitOverlay(btn)
	if hit:GetAttribute("_OceanTD_CartToggleBound") ~= true then
		hit:SetAttribute("_OceanTD_CartToggleBound", true)
		hit.Activated:Connect(toggle)
	end
end

task.spawn(function()
	local left = playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		warn("[ReefReport] PlayerGui.MobileLeftUI missing")
		return
	end
	LeftHudLayout.hardenScreenGui(left)
	if left:IsA("ScreenGui") then
		leftGui = left
		leftOrderBase = left.DisplayOrder
	else
		leftGui = left:FindFirstAncestorOfClass("ScreenGui")
		if leftGui then
			leftOrderBase = leftGui.DisplayOrder
		end
	end
	local dPad = left:WaitForChild("dPad", 30)
	if not dPad then
		warn("[ReefReport] MobileLeftUI.dPad missing")
		return
	end
	local cart = findCartButton(dPad)
	if not cart then
		warn("[ReefReport] Cart button missing under MobileLeftUI.dPad (Cart / CartBTN / Report)")
		return
	end
	bindCart(cart)
	applyOpen(false)
	print("[ReefReport] Bound", cart:GetFullName())

	LeftHudLayout.watchMobileLeftUi(playerGui, function(leftNow: Instance)
		local dPadNow = leftNow:FindFirstChild("dPad")
		if not dPadNow then
			return
		end
		local newCart = findCartButton(dPadNow)
		if newCart then
			bindCart(newCart)
			if open then
				ensureCloseChrome()
			end
		end
	end)
end)

playerGui:GetAttributeChangedSignal(FORCE_CLOSE_ATTR):Connect(function()
	closeOnly()
end)

playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(function()
	if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
		closeOnly()
	end
end)

UserInputService.LastInputTypeChanged:Connect(function()
	if open then
		syncCloseLabel()
		if helpCloseBtn and helpOpen then
			helpCloseBtn.Text = if isGamepadMode() then "B" else "CLOSE"
		end
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if input.KeyCode == Enum.KeyCode.DPadUp then
		if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
			return
		end
		if helpOpen then
			hideHelpPopup()
			return
		end
		openFromDPadUp()
		return
	end
	if not open then
		return
	end
	if helpOpen then
		if input.KeyCode == Enum.KeyCode.X
			or input.KeyCode == Enum.KeyCode.ButtonB
			or input.KeyCode == Enum.KeyCode.Escape
		then
			hideHelpPopup()
		end
		return
	end
	if input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.ButtonB then
		closeOnly()
		return
	end
	-- Keyboard / gamepad open help from the ? control.
	if not gameProcessed and (input.KeyCode == Enum.KeyCode.Slash or input.KeyCode == Enum.KeyCode.ButtonY) then
		showHelpPopup()
	end
end)

playerGui:SetAttribute(REPORT_OPEN_ATTR, false)
