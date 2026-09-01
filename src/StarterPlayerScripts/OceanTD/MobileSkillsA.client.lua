--!strict
--[[
	Toggle MobileSkillsA from the left dPad Skills button.
	While open: soft bubble physics; Skills button becomes pulsing red close (X / B).
	Gamepad: DPad Right opens skills; B closes (power-up first, then bubbles).
	Left stick moves bubble focus while open; A activates.
	Power-up open: bubbles + left Skills close hidden; power-up CloseBTN stays; stick selects UNLOCK ↔ Close.
]]

local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local SkillsBubbleSim = require(script.Parent:WaitForChild("SkillsBubbleSim"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))

local oceanRoot = game:GetService("ReplicatedStorage"):WaitForChild("OceanTD")
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))

local CLOSE_NAMES = {
	Close = true,
	close = true,
	CloseBTN = true,
	CloseBtn = true,
	X = true,
	Exit = true,
	Hide = true,
	Back = true,
	Dismiss = true,
}

local STICK_DEAD = 0.55
local STICK_COOLDOWN = 0.22
local TOGGLE_COOLDOWN = 1.0
local MOVE_SINK_ACTION = "_OceanTD_SkillsMoveSink"
local LEFT_UI_SINK_ACTION = "_OceanTD_SkillsLeftUiDPadSink"
local movementFrozen = false
local savedAutoSelectGui: boolean? = nil
local leftUiSelectableRestore: { [GuiObject]: boolean } = {}
local cachedControls: any = nil
local hiddenHudGuis: { { gui: GuiObject, wasVisible: boolean, scale: UIScale?, wasScale: number? } } = {}

local SKILLS_OPEN_ATTR = "OceanTD_SkillsBubblesOpen"
local SKILLS_DISMISS_KEY_ATTR = "OceanTD_SkillsDismissKey"
local skillsScaleConn: RBXScriptConnection? = nil

local function applySkillsViewportScale(panel: Instance)
	local sg: ScreenGui? = if panel:IsA("ScreenGui") then panel else panel:FindFirstAncestorOfClass("ScreenGui")
	if not sg then
		return
	end
	for _, ch in sg:GetChildren() do
		if ch:IsA("GuiObject") and ch.Name ~= "_OceanTD_BubbleLayer" then
			UiPopupScale.attachHud(ch)
		end
	end
end

local function bindSkillsViewportScale(panel: Instance)
	if skillsScaleConn then
		skillsScaleConn:Disconnect()
		skillsScaleConn = nil
	end
	local cam = Workspace.CurrentCamera
	if not cam then
		applySkillsViewportScale(panel)
		return
	end
	skillsScaleConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		applySkillsViewportScale(panel)
	end)
	applySkillsViewportScale(panel)
end

local function ancestorScreenGui(inst: Instance): ScreenGui?
	if inst:IsA("ScreenGui") then
		return inst
	end
	return inst:FindFirstAncestorOfClass("ScreenGui")
end

local function isGamepadMode(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

-- Never WaitForChild here — that blocked skills open/close by up to 5s.
local function getPlayerControls(): any
	if cachedControls then
		return cachedControls
	end
	local ps = player:FindFirstChild("PlayerScripts")
	local pm = ps and ps:FindFirstChild("PlayerModule")
	if not pm then
		return nil
	end
	local ok, controls = pcall(function()
		return require(pm):GetControls()
	end)
	if ok and controls then
		cachedControls = controls
		return controls
	end
	return nil
end

task.spawn(function()
	local ps = player:WaitForChild("PlayerScripts", 30)
	if not ps then
		return
	end
	local pm = ps:WaitForChild("PlayerModule", 30)
	if not pm then
		return
	end
	pcall(function()
		cachedControls = require(pm):GetControls()
	end)
end)

local function clearGuiSelection()
	GuiService.SelectedObject = nil
end

local function setBubbleModeGuiNav(enabled: boolean)
	-- Bubbles use custom focus — GuiService selection steals the stick and leaves a highlight.
	if enabled then
		if savedAutoSelectGui == nil then
			savedAutoSelectGui = GuiService.AutoSelectGuiEnabled
		end
		GuiService.AutoSelectGuiEnabled = false
		clearGuiSelection()
	else
		clearGuiSelection()
		if savedAutoSelectGui ~= nil then
			GuiService.AutoSelectGuiEnabled = savedAutoSelectGui
			savedAutoSelectGui = nil
		end
	end
end

local function bindMoveSink(on: boolean)
	ContextActionService:UnbindAction(MOVE_SINK_ACTION)
	if not on then
		return
	end
	-- Sink locomotion so left stick only drives bubble/UI focus while skills are open.
	ContextActionService:BindActionAtPriority(
		MOVE_SINK_ACTION,
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Thumbstick1,
		Enum.KeyCode.W,
		Enum.KeyCode.A,
		Enum.KeyCode.S,
		Enum.KeyCode.D,
		Enum.KeyCode.Space
	)
end

-- While skills are open, d-pad must not drive MobileLeftUI / FreeCam — only bubble/power-up UI.
local function bindLeftUiDPadSink(on: boolean)
	ContextActionService:UnbindAction(LEFT_UI_SINK_ACTION)
	if not on then
		return
	end
	ContextActionService:BindActionAtPriority(
		LEFT_UI_SINK_ACTION,
		function()
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value + 10,
		Enum.KeyCode.DPadLeft,
		Enum.KeyCode.DPadRight,
		Enum.KeyCode.DPadUp,
		Enum.KeyCode.DPadDown
	)
end

local leftUiSelectableRestore: { [GuiObject]: boolean } = {}

local function lockForeignSelectables(lock: boolean)
	if lock then
		for obj, _ in pairs(leftUiSelectableRestore) do
			if obj.Parent then
				obj.Selectable = true
			end
		end
		table.clear(leftUiSelectableRestore)
		for _, layer in ipairs(playerGui:GetChildren()) do
			if not layer:IsA("LayerCollector") then
				continue
			end
			local function consider(obj: Instance)
				if obj:IsA("GuiObject") and obj.Selectable then
					leftUiSelectableRestore[obj] = true
					obj.Selectable = false
				end
			end
			consider(layer)
			for _, d in ipairs(layer:GetDescendants()) do
				consider(d)
			end
		end
	else
		for obj, _ in pairs(leftUiSelectableRestore) do
			if obj.Parent then
				obj.Selectable = true
			end
		end
		table.clear(leftUiSelectableRestore)
	end
end

local function setMovementEnabled(on: boolean)
	bindMoveSink(not on and isGamepadMode())
	local controls = getPlayerControls()
	pcall(function()
		if controls then
			if on then
				controls:Enable()
			else
				controls:Disable()
			end
		end
	end)
	movementFrozen = not on
end

local QUICKBAR_HIDE_SLOTS = {
	Slot4 = true, -- backpack
	Slot5 = true, -- waves start/stop
	Slot6 = true, -- skip wave
	Slot7 = true, -- wave speed
}

local WAVE_HUD_NAMES = {
	OceanTD_WaveHud = true,
	OceanTD_WatchHud = true,
}

local function rememberHide(gui: GuiObject)
	for _, entry in ipairs(hiddenHudGuis) do
		if entry.gui == gui then
			return
		end
	end
	table.insert(hiddenHudGuis, {
		gui = gui,
		wasVisible = gui.Visible,
		scale = nil,
		wasScale = nil,
	})
	gui.Visible = false
end

local function restoreHiddenHud()
	for _, entry in ipairs(hiddenHudGuis) do
		local gui = entry.gui
		if gui.Parent then
			gui.Visible = entry.wasVisible
		end
	end
	table.clear(hiddenHudGuis)
end

local function hideLeftUiExceptSkillsClose()
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if not left then
		return
	end
	local dPad = left:FindFirstChild("dPad")
	if dPad then
		for _, ch in ipairs(dPad:GetChildren()) do
			-- dPadIcon is owned by FreeCam via OceanTD_SkillsBubblesOpen attribute.
			if ch:IsA("GuiObject") and ch.Name ~= "Skills" and ch.Name ~= "dPadIcon" and not LeftHudLayout.isSandDollarChrome(ch) then
				rememberHide(ch)
			end
		end
	end
	for _, ch in ipairs(left:GetChildren()) do
		if ch:IsA("GuiObject") and ch.Name ~= "dPad" and not LeftHudLayout.isSandDollarChrome(ch) then
			rememberHide(ch)
		end
	end
end

local function hideQuickbarSlotsOnHud(hud: Instance)
	local quickbar = hud:FindFirstChild("Quickbar")
	if quickbar then
		for _, ch in ipairs(quickbar:GetChildren()) do
			if ch:IsA("GuiObject") and QUICKBAR_HIDE_SLOTS[ch.Name] then
				rememberHide(ch)
			end
		end
	end
	local help = hud:FindFirstChild("QuickbarHelp")
	if help and help:IsA("GuiObject") then
		-- Hide the whole help strip (wave/backpack shortcut circles), not only named slots.
		rememberHide(help)
	elseif help then
		for _, ch in ipairs(help:GetChildren()) do
			if ch:IsA("GuiObject") and QUICKBAR_HIDE_SLOTS[ch.Name] then
				rememberHide(ch)
			end
		end
	end
	for _, d in ipairs(hud:GetDescendants()) do
		if d:IsA("GuiObject") and WAVE_HUD_NAMES[d.Name] then
			rememberHide(d)
		end
	end
end

local function hideBackpackAndWaveUi()
	local mobile = playerGui:FindFirstChild(UiViewportTags.MOBILE_RIGHT_HUD)
	local p720 = playerGui:FindFirstChild(UiViewportTags.P720_RIGHT_HUD)
	if mobile then
		hideQuickbarSlotsOnHud(mobile)
	end
	if p720 then
		hideQuickbarSlotsOnHud(p720)
	end
	-- Watch HUD can sit under either right HUD parent.
	for _, ch in ipairs(playerGui:GetChildren()) do
		if ch:IsA("GuiObject") and WAVE_HUD_NAMES[ch.Name] then
			rememberHide(ch)
		end
	end
end

local function setSkillsOpenHud(hide: boolean)
	if hide then
		local already = playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true
		if already and #hiddenHudGuis > 0 then
			return
		end
		-- Flag first so FreeCam cancels pending carousel collapse before we hide dPad icons.
		-- FreeCam must not set FreeCam/FishCam/OffCam.Visible here (rememberHide needs wasVisible).
		playerGui:SetAttribute(SKILLS_OPEN_ATTR, true)
		restoreHiddenHud()
		hideLeftUiExceptSkillsClose()
		hideBackpackAndWaveUi()
	else
		-- Always restore — never early-out; cinematic / ForceClose can desync the flag.
		restoreHiddenHud()
		playerGui:SetAttribute(SKILLS_OPEN_ATTR, false)
	end
end

local function syncMovementFreeze(skillsOpen: boolean)
	if skillsOpen then
		lockForeignSelectables(true)
		bindLeftUiDPadSink(true)
		setSkillsOpenHud(true)
		clearGuiSelection()
		if isGamepadMode() then
			setMovementEnabled(false)
			setBubbleModeGuiNav(true)
		else
			bindMoveSink(false)
			setMovementEnabled(true)
			setBubbleModeGuiNav(false)
		end
	else
		bindLeftUiDPadSink(false)
		lockForeignSelectables(false)
		setSkillsOpenHud(false)
		bindMoveSink(false)
		clearGuiSelection()
		setBubbleModeGuiNav(false)
		setMovementEnabled(true)
		task.defer(function()
			setMovementEnabled(true)
		end)
	end
end

local function ensureHitOverlay(host: GuiObject): GuiButton
	local existing = host:FindFirstChild("_OceanTD_SkillsHit")
	if existing and existing:IsA("GuiButton") then
		existing:Destroy()
	end
	local made = Instance.new("TextButton")
	made.Name = "_OceanTD_SkillsHit"
	made.Text = ""
	made.BackgroundTransparency = 1
	made.BorderSizePixel = 0
	made.Size = UDim2.fromScale(1, 1)
	made.Position = UDim2.fromScale(0, 0)
	made.ZIndex = host.ZIndex + 20
	made.Active = true
	made.Selectable = false
	made.AutoButtonColor = false
	made.Parent = host
	return made
end

task.spawn(function()
	local left = playerGui:WaitForChild("MobileLeftUI", 60)
	if not left then
		warn("[Skills] PlayerGui.MobileLeftUI missing")
		return
	end
	local dPad = left:WaitForChild("dPad", 30)
	if not dPad then
		warn("[Skills] MobileLeftUI.dPad missing")
		return
	end
	if dPad:IsA("GuiObject") then
		-- Active=false only — Interactable=false would disable all child buttons.
		dPad.Active = false
	end
	local skillsBtn = dPad:WaitForChild("Skills", 30)
	if not skillsBtn or not skillsBtn:IsA("GuiObject") then
		warn("[Skills] MobileLeftUI.dPad.Skills missing")
		return
	end

	-- Optional: dPad.Right also toggles skills (blocked while backpack is open).
	local rightBtn = dPad:FindFirstChild("Right")
		or dPad:FindFirstChild("right")
		or dPad:FindFirstChild("dPadRight")
		or dPad:FindFirstChild("DPadRight")
		or dPad:FindFirstChild("RightBTN")
		or dPad:FindFirstChild("RightBtn")
	if not rightBtn then
		for _, ch in ipairs(dPad:GetChildren()) do
			local n = string.lower(ch.Name)
			if n == "right" or n == "dpadright" or string.find(n, "right", 1, true) then
				rightBtn = ch
				break
			end
		end
	end

	local panel = playerGui:WaitForChild("MobileSkillsA", 60)
	if not panel or not (panel:IsA("ScreenGui") or panel:IsA("GuiObject")) then
		warn("[Skills] PlayerGui.MobileSkillsA missing")
		return
	end
	bindSkillsViewportScale(panel)

	SkillPowerUpUI.bind(panel)
	SkillsBubbleSim.setOnBubbleActivated(function(buttonName: string)
		SkillsBubbleSim.clearGamepadFocus()
		SkillPowerUpUI.openFromButtonName(buttonName)
	end)
	SkillPowerUpUI.setOnClosed(function()
		clearGuiSelection()
		-- Only return to bubble focus while skills stay open. Never re-hide HUD here —
		-- PlotSize unlock calls close() before ForceClose finishes and that raced restore.
		if open and isGamepadMode() then
			lockForeignSelectables(true)
			setBubbleModeGuiNav(true)
			if SkillsBubbleSim.isRunning() then
				SkillsBubbleSim.setGamepadFocus(1)
			end
		end
	end)

	local leftGui = ancestorScreenGui(left)
	local panelGui: ScreenGui? = if panel:IsA("ScreenGui") then panel else ancestorScreenGui(panel)
	local leftOrderBase = if leftGui then leftGui.DisplayOrder else 0

	local open = false
	local lastToggleAt = 0
	local openToken = 0

	local closeChrome: Frame? = nil
	local closeLabel: TextLabel? = nil
	local closeScale: UIScale? = nil
	local pulseToken = 0
	local stickCooldownUntil = 0
	local stickWasOut = false
	local hiddenSkillKids: { GuiObject } = {}

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

	local function hideSkillsBtnContent(hide: boolean)
		if hide then
			table.clear(hiddenSkillKids)
			for _, ch in ipairs(skillsBtn:GetChildren()) do
				if ch:IsA("GuiObject") and ch.Name ~= "_OceanTD_SkillsHit" and ch.Name ~= "_OceanTD_SkillsCloseChrome" then
					if ch.Visible then
						table.insert(hiddenSkillKids, ch)
						ch.Visible = false
					end
				end
			end
			if skillsBtn:IsA("ImageButton") or skillsBtn:IsA("ImageLabel") then
				(skillsBtn :: ImageButton).ImageTransparency = 1
			end
			if skillsBtn:IsA("GuiButton") or skillsBtn:IsA("Frame") then
				-- Keep hit target; chrome covers art.
			end
		else
			for _, ch in ipairs(hiddenSkillKids) do
				if ch.Parent then
					ch.Visible = true
				end
			end
			table.clear(hiddenSkillKids)
			if skillsBtn:IsA("ImageButton") or skillsBtn:IsA("ImageLabel") then
				(skillsBtn :: ImageButton).ImageTransparency = 0
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
		hideSkillsBtnContent(false)
	end

	local function ensureCloseChrome()
		destroyCloseChrome()
		hideSkillsBtnContent(true)

		local chrome = Instance.new("Frame")
		chrome.Name = "_OceanTD_SkillsCloseChrome"
		chrome.BackgroundColor3 = Color3.fromRGB(220, 40, 50)
		chrome.BorderSizePixel = 0
		chrome.Size = UDim2.fromScale(1, 1)
		chrome.Position = UDim2.fromScale(0, 0)
		chrome.ZIndex = skillsBtn.ZIndex + 15
		chrome.Active = false
		chrome.Parent = skillsBtn
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

	local function applyOpen(want: boolean)
		open = want
		openToken += 1
		local myToken = openToken

		if leftGui and panelGui then
			if want then
				panelGui.DisplayOrder = math.max(panelGui.DisplayOrder, 50)
				leftGui.DisplayOrder = math.max(leftOrderBase, panelGui.DisplayOrder + 10)
			else
				leftGui.DisplayOrder = leftOrderBase
			end
		end

		if want then
			-- Bubbles first — never block on PlayerModule / freeze setup.
			-- Backpack may have hidden Skills; force it visible for close chrome.
			if skillsBtn then
				skillsBtn.Visible = true
			end
			applySkillsViewportScale(panel)
			ensureCloseChrome()
			SkillsBubbleSim.preHide(panel)
			if panel:IsA("ScreenGui") then
				(panel :: ScreenGui).Enabled = true
			else
				(panel :: GuiObject).Visible = true
			end
			SkillsBubbleSim.start(panel)
			if isGamepadMode() and SkillsBubbleSim.isRunning() then
				SkillsBubbleSim.setGamepadFocus(1)
			end
			syncMovementFreeze(true)
		else
			SkillsBubbleSim.clearGamepadFocus()
			SkillPowerUpUI.close()
			clearGuiSelection()
			destroyCloseChrome()
			if skillsBtn then
				skillsBtn.Visible = true
			end
			SkillsBubbleSim.stop(function()
				if myToken ~= openToken then
					return
				end
				if panel:IsA("ScreenGui") then
					(panel :: ScreenGui).Enabled = false
				else
					(panel :: GuiObject).Visible = false
				end
			end)
			syncMovementFreeze(false)
			-- Belt-and-suspenders: cinematic ForceClose can race HUD restore.
			if skillsBtn then
				skillsBtn.Visible = true
			end
			hideSkillsBtnContent(false)
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
		if not canToggle() then
			return
		end
		applyOpen(not open)
	end

	local function closeOnly()
		-- Always run full teardown (even if open flag desynced after PlotSize cinematic).
		lastToggleAt = os.clock()
		applyOpen(false)
	end

	local function openFromDPadRight()
		if InventoryState.isOpen() then
			return
		end
		-- DPad Right opens only; B closes.
		if open then
			return
		end
		if not canToggle() then
			return
		end
		applyOpen(true)
	end

	applyOpen(false)

	playerGui:GetAttributeChangedSignal("OceanTD_ForceCloseSkills"):Connect(function()
		closeOnly()
	end)

	playerGui:GetAttributeChangedSignal("OceanTD_SkillPowerUpOpen"):Connect(function()
		if playerGui:GetAttribute("OceanTD_SkillPowerUpOpen") == true then
			-- Hide left Skills chrome (don't restore the Skills icon).
			destroyCloseChrome()
			if skillsBtn then
				skillsBtn.Visible = false
			end
		elseif open then
			if skillsBtn then
				skillsBtn.Visible = true
			end
			ensureCloseChrome()
			syncCloseLabel()
		end
	end)

	playerGui:GetAttributeChangedSignal("OceanTD_ForceOpenSkills"):Connect(function()
		local skillId = playerGui:GetAttribute("OceanTD_ForceOpenSkillId")
		lastToggleAt = os.clock()
		if not open then
			applyOpen(true)
		end
		if typeof(skillId) == "string" and skillId ~= "" then
			task.defer(function()
				SkillPowerUpUI.open(skillId :: string)
			end)
		end
	end)

	playerGui:GetAttributeChangedSignal("OceanTD_SkillsUiRestore"):Connect(function()
		closeOnly()
		if skillsBtn then
			skillsBtn.Visible = true
		end
		hideSkillsBtnContent(false)
		playerGui:SetAttribute(SKILLS_OPEN_ATTR, false)
	end)

	local hit = ensureHitOverlay(skillsBtn)
	if hit:GetAttribute("_OceanTD_SkillsToggleBound") ~= true then
		hit:SetAttribute("_OceanTD_SkillsToggleBound", true)
		hit.Activated:Connect(toggle)
	end

	local function rebindSkillsChrome()
		local leftNow = playerGui:FindFirstChild("MobileLeftUI")
		if not leftNow then
			return
		end
		LeftHudLayout.hardenScreenGui(leftNow)
		local dPadNow = leftNow:FindFirstChild("dPad")
		if not dPadNow then
			return
		end
		if dPadNow:IsA("GuiObject") then
			dPadNow.Active = false
		end
		local newSkills = dPadNow:FindFirstChild("Skills")
		if not newSkills or not newSkills:IsA("GuiObject") then
			return
		end
		local existingHit = newSkills:FindFirstChild("_OceanTD_SkillsHit")
		if newSkills == skillsBtn and existingHit and existingHit:GetAttribute("_OceanTD_SkillsToggleBound") == true then
			return
		end
		skillsBtn = newSkills
		local newHit = ensureHitOverlay(skillsBtn)
		if newHit:GetAttribute("_OceanTD_SkillsToggleBound") ~= true then
			newHit:SetAttribute("_OceanTD_SkillsToggleBound", true)
			newHit.Activated:Connect(toggle)
		end
		-- Right d-pad optional
		local newRight = dPadNow:FindFirstChild("Right")
			or dPadNow:FindFirstChild("right")
			or dPadNow:FindFirstChild("dPadRight")
		if newRight and newRight:IsA("GuiObject") then
			local rightHit = ensureHitOverlay(newRight)
			rightHit.Name = "_OceanTD_SkillsRightHit"
			if rightHit:GetAttribute("_OceanTD_SkillsToggleBound") ~= true then
				rightHit:SetAttribute("_OceanTD_SkillsToggleBound", true)
				rightHit.Activated:Connect(openFromDPadRight)
			end
		end
		print("[Skills] Re-bound Skills button after left HUD reset")
	end

	LeftHudLayout.hardenScreenGui(left)
	LeftHudLayout.hardenScreenGui(panel)
	LeftHudLayout.watchMobileLeftUi(playerGui, function()
		rebindSkillsChrome()
	end)
	task.spawn(function()
		while true do
			task.wait(2)
			local hitOk = skillsBtn
				and skillsBtn.Parent
				and skillsBtn:FindFirstChild("_OceanTD_SkillsHit")
			if not hitOk then
				rebindSkillsChrome()
			end
		end
	end)

	if rightBtn and rightBtn:IsA("GuiObject") then
		local rightHit = ensureHitOverlay(rightBtn)
		rightHit.Name = "_OceanTD_SkillsRightHit"
		if rightHit:GetAttribute("_OceanTD_SkillsToggleBound") ~= true then
			rightHit:SetAttribute("_OceanTD_SkillsToggleBound", true)
			rightHit.Activated:Connect(openFromDPadRight)
		end
	end
	-- No warn if missing: Skills button + gamepad DPadRight still work.

	local function wireClose(btn: GuiButton)
		if btn:GetAttribute("_OceanTD_SkillsCloseBound") == true then
			return
		end
		btn:SetAttribute("_OceanTD_SkillsCloseBound", true)
		btn.Active = true
		btn.Activated:Connect(function()
			if SkillPowerUpUI.isConfirmOpen() then
				SkillPowerUpUI.cancelConfirm()
				return
			end
			if SkillPowerUpUI.isOpen() then
				SkillPowerUpUI.close()
				return
			end
			closeOnly()
		end)
	end

	for _, desc in ipairs(panel:GetDescendants()) do
		if desc:IsA("GuiButton") and CLOSE_NAMES[desc.Name] then
			wireClose(desc)
		end
	end
	panel.DescendantAdded:Connect(function(desc)
		if desc:IsA("GuiButton") and CLOSE_NAMES[desc.Name] then
			wireClose(desc)
		end
	end)

	UserInputService.LastInputTypeChanged:Connect(function()
		if open then
			syncCloseLabel()
			SkillPowerUpUI.syncCloseGlyph()
			syncMovementFreeze(true)
			if isGamepadMode() and SkillsBubbleSim.isRunning() and SkillsBubbleSim.getGamepadFocus() < 1 then
				SkillsBubbleSim.setGamepadFocus(1)
			elseif not isGamepadMode() then
				SkillsBubbleSim.clearGamepadFocus()
			end
		end
	end)

	local function dismissSkillsFromKeyboard()
		playerGui:SetAttribute(SKILLS_DISMISS_KEY_ATTR, os.clock())
		if SkillPowerUpUI.isConfirmOpen() then
			SkillPowerUpUI.cancelConfirm()
			return
		end
		if SkillPowerUpUI.isOpen() then
			SkillPowerUpUI.close()
			return
		end
		closeOnly()
	end

	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.KeyCode == Enum.KeyCode.DPadRight then
			-- Opens skills only (B closes). Blocked while backpack is open.
			openFromDPadRight()
			return
		end
		if not open then
			return
		end
		-- Keyboard X / Q / gamepad B: close power-up first, then skills bubbles.
		if input.KeyCode == Enum.KeyCode.X
			or input.KeyCode == Enum.KeyCode.Q
			or input.KeyCode == Enum.KeyCode.ButtonB
		then
			dismissSkillsFromKeyboard()
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonA then
			if SkillPowerUpUI.isConfirmOpen() or SkillPowerUpUI.isOpen() then
				-- GuiService.SelectedObject handles UNLOCK / Close / Cancel.
				return
			end
			if SkillsBubbleSim.isRunning() then
				SkillsBubbleSim.activateGamepadFocus()
			end
		elseif SkillPowerUpUI.isConfirmOpen() or SkillPowerUpUI.isOpen() then
			-- Stick / DPad navigate GuiService selection only.
			return
		elseif input.KeyCode == Enum.KeyCode.DPadLeft then
			SkillsBubbleSim.moveGamepadFocus(-1, 0)
		elseif input.KeyCode == Enum.KeyCode.DPadUp then
			SkillsBubbleSim.moveGamepadFocus(0, -1)
		elseif input.KeyCode == Enum.KeyCode.DPadDown then
			SkillsBubbleSim.moveGamepadFocus(0, 1)
		end
	end)

	RunService.Heartbeat:Connect(function()
		if not open or not isGamepadMode() or not SkillsBubbleSim.isRunning() then
			stickWasOut = false
			return
		end
		if SkillPowerUpUI.isConfirmOpen() or SkillPowerUpUI.isOpen() then
			-- Modal owns stick via GuiService.SelectedObject.
			stickWasOut = false
			return
		end
		local ok, states = pcall(function()
			return UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
		end)
		if not ok or typeof(states) ~= "table" then
			return
		end
		local stick: Vector2? = nil
		for _, obj in ipairs(states) do
			if obj.KeyCode == Enum.KeyCode.Thumbstick1 then
				stick = Vector2.new(obj.Position.X, -obj.Position.Y) -- UI Y down
				break
			end
		end
		if not stick then
			return
		end
		local mag = stick.Magnitude
		if mag < STICK_DEAD then
			stickWasOut = false
			return
		end
		local now = os.clock()
		if stickWasOut and now < stickCooldownUntil then
			return
		end
		stickWasOut = true
		stickCooldownUntil = now + STICK_COOLDOWN
		if SkillsBubbleSim.getGamepadFocus() < 1 then
			SkillsBubbleSim.setGamepadFocus(1)
			return
		end
		SkillsBubbleSim.moveGamepadFocus(stick.X, stick.Y)
	end)

	print("[Skills] Ready — close chrome + gamepad bubble focus")
end)

playerGui:SetAttribute(SKILLS_OPEN_ATTR, false)
