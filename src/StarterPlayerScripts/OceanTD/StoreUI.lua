--!strict
--[[
	Fullscreen store (empty for now). Opened from dPad cart while NOT in build mode.
	While open: CartIcon becomes pulsing red close (X / B), same pattern as Skills / Reef Report.
	Cart click / DPadUp are routed by ReefReportUI; X / ButtonB / Escape also close.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oceanRoot = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD")
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))

local StoreUI = {}

local STORE_OPEN_ATTR = "OceanTD_StoreOpen"
local FORCE_CLOSE_ATTR = "OceanTD_ForceCloseStore"
local SKILLS_OPEN_ATTR = "OceanTD_SkillsBubblesOpen"
local REPORT_OPEN_ATTR = "OceanTD_ReefReportOpen"
local STORE_GUI_NAME = "OceanTD_Store"
local STORE_DISPLAY_ORDER = 9200

local CART_NAMES: { [string]: boolean } = {
	CartIcon = true,
	Cart = true,
	CartBTN = true,
	CartBtn = true,
	Report = true,
	ReefReport = true,
	ShoppingCart = true,
}

local open = false
local storeGui: ScreenGui? = nil
local cartBtn: GuiObject? = nil
local leftGui: ScreenGui? = nil
local leftOrderBase = 0
local closeChrome: GuiObject? = nil
local closeLabel: TextLabel? = nil
local closeScale: UIScale? = nil
local pulseToken = 0
local hiddenCartKids: { GuiObject } = {}
local hiddenLeft: { { gui: GuiObject, wasVisible: boolean } } = {}
local lastToggleAt = 0
local TOGGLE_COOLDOWN = 0.2
local inited = false

local function isGamepadMode(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function findCartButton(dPad: Instance): GuiObject?
	local preferred = { "CartIcon", "CartBTN", "CartBtn", "Cart", "cart", "Report", "ReefReport", "ShoppingCart" }
	for _, name in ipairs(preferred) do
		local ch = dPad:FindFirstChild(name)
		if ch and ch:IsA("GuiObject") then
			return ch
		end
	end
	for _, ch in ipairs(dPad:GetChildren()) do
		if ch:IsA("GuiObject") and CART_NAMES[ch.Name] then
			return ch
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
	hit.BorderSizePixel = 0
	hit.Size = UDim2.fromScale(1, 1)
	hit.ZIndex = btn.ZIndex + 5
	hit.AutoButtonColor = false
	hit.Parent = btn
	return hit
end

local function stopClosePulse()
	pulseToken += 1
end

local function syncCloseLabel()
	if closeLabel then
		closeLabel.Text = if isGamepadMode() then "B" else "X"
	end
end

local function startClosePulse()
	stopClosePulse()
	local my = pulseToken
	if closeScale then
		closeScale.Scale = 1
	end
	task.spawn(function()
		while my == pulseToken and open and closeScale and closeChrome and closeChrome.Parent do
			local twIn = TweenService:Create(
				closeScale,
				TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Scale = 1.12 }
			)
			twIn:Play()
			twIn.Completed:Wait()
			if my ~= pulseToken then
				return
			end
			local twOut = TweenService:Create(
				closeScale,
				TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ Scale = 1 }
			)
			twOut:Play()
			twOut.Completed:Wait()
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
			if ch:IsA("GuiObject")
				and ch.Name ~= "_OceanTD_CartHit"
				and ch.Name ~= "_OceanTD_StoreClose"
				and ch.Name ~= "_OceanTD_ReefReportClose"
				and ch.Name ~= "_OceanTD_CartInfoChrome"
			then
				if ch.Name == "_OceanTD_TutorialLeftLock" or ch.Name == "_OceanTD_TutorialLeftLockIcon" then
					ch:Destroy()
					continue
				end
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
			if ch.Parent
				and ch.Name ~= "_OceanTD_CartInfoChrome"
				and ch.Name ~= "_OceanTD_TutorialLeftLock"
				and ch.Name ~= "_OceanTD_TutorialLeftLockIcon"
			then
				ch.Visible = true
			end
		end
		table.clear(hiddenCartKids)
		-- Build mode owns the info “i” chrome — don’t force the shop glyph back over it.
		if cartBtn:FindFirstChild("_OceanTD_CartInfoChrome") then
			return
		end
		if cartBtn:IsA("ImageButton") or cartBtn:IsA("ImageLabel") then
			(cartBtn :: ImageButton).ImageTransparency = 0
		end
	end
end

local function destroyCloseChrome()
	stopClosePulse()
	if closeChrome then
		closeChrome:Destroy()
		closeChrome = nil
	end
	closeLabel = nil
	closeScale = nil
	hideCartBtnContent(false)
end

local function ensureCloseChrome()
	if not cartBtn then
		return
	end
	destroyCloseChrome()
	hideCartBtnContent(true)

	local chrome = Instance.new("Frame")
	chrome.Name = "_OceanTD_StoreClose"
	chrome.BackgroundColor3 = Color3.fromRGB(220, 40, 50)
	chrome.BorderSizePixel = 0
	chrome.AnchorPoint = Vector2.new(0.5, 0.5)
	chrome.Position = UDim2.fromScale(0.5, 0.5)
	chrome.Size = UDim2.fromScale(1, 1)
	chrome.ZIndex = cartBtn.ZIndex + 50
	chrome.Active = false
	chrome.Parent = cartBtn
	local hitBtn = ensureHitOverlay(cartBtn)
	hitBtn.Visible = true
	hitBtn.Active = true
	hitBtn.ZIndex = chrome.ZIndex + 5

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
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.TextYAlignment = Enum.TextYAlignment.Center
	lbl.ZIndex = chrome.ZIndex + 1
	lbl.Active = false
	lbl.Parent = chrome
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.18, 0)
	pad.PaddingBottom = UDim.new(0.18, 0)
	pad.PaddingLeft = UDim.new(0.18, 0)
	pad.PaddingRight = UDim.new(0.18, 0)
	pad.Parent = lbl

	closeChrome = chrome
	closeLabel = lbl
	closeScale = scale
	syncCloseLabel()
	startClosePulse()
end

local function hideLeftUiExceptCart()
	table.clear(hiddenLeft)
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if not left then
		return
	end
	local dPad = left:FindFirstChild("dPad")
	if dPad then
		for _, ch in ipairs(dPad:GetChildren()) do
			if ch:IsA("GuiObject") and ch ~= cartBtn and not CART_NAMES[ch.Name] and ch.Name ~= "dPadIcon" then
				if not LeftHudLayout.isSandDollarChrome(ch) then
					table.insert(hiddenLeft, { gui = ch, wasVisible = ch.Visible })
					ch.Visible = false
				end
			end
		end
	end
end

local function restoreLeftUi()
	for _, entry in ipairs(hiddenLeft) do
		if entry.gui.Parent then
			entry.gui.Visible = entry.wasVisible
		end
	end
	table.clear(hiddenLeft)
end

local function ensureStoreGui(): ScreenGui
	local existing = playerGui:FindFirstChild(STORE_GUI_NAME)
	if existing and existing:IsA("ScreenGui") then
		storeGui = existing
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = STORE_GUI_NAME
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = STORE_DISPLAY_ORDER
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Enabled = false
	pcall(function()
		(sg :: any).ClipToDeviceSafeArea = false
		(sg :: any).SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	end)
	sg.Parent = playerGui

	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.BackgroundColor3 = Color3.fromRGB(6, 10, 16)
	dim.BackgroundTransparency = 0.15
	dim.BorderSizePixel = 0
	dim.Size = UDim2.fromScale(1, 1)
	dim.ZIndex = 1
	dim.Active = true
	dim.Parent = sg

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromScale(0.72, 0.78)
	panel.BackgroundColor3 = Color3.fromRGB(14, 22, 32)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.ZIndex = 2
	panel.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 18)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(70, 110, 140)
	stroke.Transparency = 0.35
	stroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.AnchorPoint = Vector2.new(0.5, 0)
	title.Position = UDim2.new(0.5, 0, 0, 28)
	title.Size = UDim2.new(1, -48, 0, 44)
	title.Font = UiTheme.Font
	title.Text = "Store"
	title.TextSize = 36
	title.TextColor3 = Color3.fromRGB(230, 245, 255)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 3
	title.Parent = panel

	local empty = Instance.new("TextLabel")
	empty.Name = "EmptyHint"
	empty.BackgroundTransparency = 1
	empty.AnchorPoint = Vector2.new(0.5, 0.5)
	empty.Position = UDim2.fromScale(0.5, 0.52)
	empty.Size = UDim2.new(0.8, 0, 0, 40)
	empty.Font = UiTheme.Font
	empty.Text = "" -- intentionally empty for now
	empty.TextSize = 22
	empty.TextColor3 = Color3.fromRGB(160, 180, 195)
	empty.TextTransparency = 0.25
	empty.ZIndex = 3
	empty.Parent = panel

	storeGui = sg
	return sg
end

local function canToggle(): boolean
	local now = os.clock()
	if now - lastToggleAt < TOGGLE_COOLDOWN then
		return false
	end
	lastToggleAt = now
	return true
end

function StoreUI.isOpen(): boolean
	return open
end

function StoreUI.close()
	if not open then
		return
	end
	lastToggleAt = os.clock()
	open = false
	playerGui:SetAttribute(STORE_OPEN_ATTR, false)
	destroyCloseChrome()
	restoreLeftUi()
	if leftGui then
		leftGui.DisplayOrder = leftOrderBase
	end
	local sg = storeGui
	if sg then
		sg.Enabled = false
	end
end

function StoreUI.open()
	if open then
		return
	end
	if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
		return
	end
	playerGui:SetAttribute("OceanTD_ForceCloseReefReport", os.clock())
	playerGui:SetAttribute("OceanTD_ForceCloseSkills", os.clock())
	lastToggleAt = os.clock()
	open = true
	playerGui:SetAttribute(STORE_OPEN_ATTR, true)
	local sg = ensureStoreGui()
	sg.Enabled = true
	if leftGui then
		leftGui.DisplayOrder = STORE_DISPLAY_ORDER + 20
	end
	if cartBtn then
		cartBtn.Visible = true
	end
	hideLeftUiExceptCart()
	ensureCloseChrome()
	task.defer(function()
		if not open then
			return
		end
		if cartBtn then
			cartBtn.Visible = true
		end
		if not closeChrome or not closeChrome.Parent then
			ensureCloseChrome()
		end
	end)
end

function StoreUI.toggle()
	if not canToggle() then
		return
	end
	if open then
		StoreUI.close()
	else
		StoreUI.open()
	end
end

function StoreUI.bindCart(btn: GuiObject)
	cartBtn = btn
	ensureHitOverlay(btn)
end

function StoreUI.init()
	if inited then
		return
	end
	inited = true
	playerGui:SetAttribute(STORE_OPEN_ATTR, false)

	task.spawn(function()
		local left = playerGui:WaitForChild("MobileLeftUI", 60)
		if not left then
			warn("[StoreUI] PlayerGui.MobileLeftUI missing")
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
			warn("[StoreUI] MobileLeftUI.dPad missing")
			return
		end
		local cart = findCartButton(dPad)
		if cart then
			StoreUI.bindCart(cart)
		end
		LeftHudLayout.watchMobileLeftUi(playerGui, function(leftNow: Instance)
			local dPadNow = leftNow:FindFirstChild("dPad")
			if not dPadNow then
				return
			end
			local newCart = findCartButton(dPadNow)
			if newCart then
				StoreUI.bindCart(newCart)
				if open then
					ensureCloseChrome()
				end
			end
		end)
	end)

	playerGui:GetAttributeChangedSignal(FORCE_CLOSE_ATTR):Connect(function()
		StoreUI.close()
	end)
	playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(function()
		if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
			StoreUI.close()
		end
	end)
	playerGui:GetAttributeChangedSignal(REPORT_OPEN_ATTR):Connect(function()
		if playerGui:GetAttribute(REPORT_OPEN_ATTR) == true then
			StoreUI.close()
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(function()
		if open then
			syncCloseLabel()
		end
	end)

	-- DPadUp / cart are owned by ReefReportUI (routes store vs reef report).
	-- X / B / Escape still close while store is open.
	UserInputService.InputBegan:Connect(function(input, _gameProcessed)
		if not open then
			return
		end
		if input.KeyCode == Enum.KeyCode.X
			or input.KeyCode == Enum.KeyCode.ButtonB
			or input.KeyCode == Enum.KeyCode.Escape
		then
			StoreUI.close()
		end
	end)
end

return StoreUI
