--!strict
--[[
	Join-intro finger tutorial pipeline:
	roll → await → backpack → equip → plot → upgrade → hue → hueReroll → closeBackpack → waves
	(reselectCoral if inspect closes mid-upgrade / mid-hue) → …
	→ (after wave summary Finish) skills → plotSize → plotSizeUpgrade → closePlotSize → closeSkills
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local SeedWheelRevealApi = require(script.Parent:WaitForChild("SeedWheelRevealApi"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local WaveSlotSummary = require(script.Parent:WaitForChild("WaveSlotSummary"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))
local CoralInspectPanel = require(script.Parent:WaitForChild("CoralInspectPanel"))
local RelocatePickHover = require(script.Parent:WaitForChild("RelocatePickHover"))

local HINT_ATTR = "OceanTD_RollFingerHint"
local HUE_PLACE_ATTR = "OceanTD_TutorialHuePlaceId"
local GUI_NAME = "OceanTD_RollFingerHint"
local FINGER_PATH = "Plots.IntroElements.Finger"

local SKILLS_OPEN_ATTR = "OceanTD_SkillsBubblesOpen"
local POWERUP_OPEN_ATTR = "OceanTD_SkillPowerUpOpen"
local REPORT_OPEN_ATTR = "OceanTD_ReefReportOpen"
local HIDE_UI_ACTIVE_ATTR = "OceanTD_HideUiActive"

local FINGER_PX = 110
local RISE_SEC = 0.7
local PRESS_SEC = 0.17
local HOLD_SEC = 0.1
local RETREAT_SEC = 0.7
-- Backpack / upgrade / close targets travel 50% slower.
local SLOW_TRAVEL_MULT = 1.5
local PRESS_SCALE = 0.7
local PRESS_ROT_DEG = -10
local UPGRADE_BASE_ROT_DEG = 60
local BACKPACK_REST_TOWARD_CENTER = 1 -- retreat all the way to screen center
local EQUIP_REST_TOWARD_CENTER = 1
local WAVE_REST_TOWARD_CENTER = 1
local PLOT_REST_DOWN_PX = 140
local BELOW_PAD_PX = 130
local BOTTOM_REST_Y_FRAC = 0.88 -- bottom-center rest for mid-screen targets
local UPGRADE_AIM_UP_PX = 36 -- tip sits higher on the upgrade button (not below screen)
local ARC_X_PX = 42
local ARC_Y_PX = 18
local TIP_ANCHOR = Vector2.new(0.32, 0.12)

export type HintMode =
	"roll"
	| "backpack"
	| "equip"
	| "plot"
	| "upgrade"
	| "hue"
	| "hueReroll"
	| "reselectCoral"
	| "closeBackpack"
	| "waves"
	| "skills"
	| "plotSize"
	| "plotSizeUpgrade"
	| "closePlotSize"
	| "closeSkills"

local MODE_SET: { [string]: boolean } = {
	roll = true,
	backpack = true,
	equip = true,
	plot = true,
	upgrade = true,
	hue = true,
	hueReroll = true,
	reselectCoral = true,
	closeBackpack = true,
	waves = true,
	skills = true,
	plotSize = true,
	plotSizeUpgrade = true,
	closePlotSize = true,
	closeSkills = true,
}

local SLOW_TRAVEL_MODES: { [string]: boolean } = {
	backpack = true,
	upgrade = true,
	hue = true,
	hueReroll = true,
	closeBackpack = true,
	closePlotSize = true,
	closeSkills = true,
}

local gen = 0
local gui: ScreenGui? = nil
local finger: ImageLabel? = nil
local scaleObj: UIScale? = nil
local conn: RBXScriptConnection? = nil
local waitingWaveEnd = false
local wavesFingerConsumed = false
local wavesFingerDelayGen = 0

local function uiHidesChrome(): boolean
	return playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true
		or playerGui:GetAttribute(POWERUP_OPEN_ATTR) == true
		or playerGui:GetAttribute(REPORT_OPEN_ATTR) == true
		or playerGui:GetAttribute(HIDE_UI_ACTIVE_ATTR) == true
end

local function findByPath(root: Instance, path: string): Instance?
	local cur: Instance? = root
	for name in string.gmatch(path, "[^%.]+") do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(name)
	end
	return cur
end

local function resolveFingerImage(src: Instance): string?
	if src:IsA("ImageLabel") or src:IsA("ImageButton") then
		local id = src.Image
		if id ~= "" then
			return id
		end
	elseif src:IsA("Decal") or src:IsA("Texture") then
		local id = src.Texture
		if id ~= "" then
			return id
		end
	end
	local img = src:FindFirstChildWhichIsA("ImageLabel", true)
		or src:FindFirstChildWhichIsA("ImageButton", true)
	if img and (img:IsA("ImageLabel") or img:IsA("ImageButton")) and img.Image ~= "" then
		return img.Image
	end
	local decal = src:FindFirstChildWhichIsA("Decal", true) or src:FindFirstChildWhichIsA("Texture", true)
	if decal and (decal:IsA("Decal") or decal:IsA("Texture")) and decal.Texture ~= "" then
		return decal.Texture
	end
	return nil
end

local function findRollAnchor(): GuiObject?
	local left = playerGui:FindFirstChild("MobileLeftUI")
	local stop = left and left:FindFirstChild("StopAutoRoll", true)
	if stop and stop:IsA("GuiObject") then
		return stop
	end
	return nil
end

local function findBackpackSlot(): GuiObject?
	local hud = UiViewportTags.pickMainHud(playerGui)
	if hud then
		local qb = hud:FindFirstChild("Quickbar")
		local slot4 = qb and qb:FindFirstChild("Slot4")
		if slot4 and slot4:IsA("GuiObject") then
			return slot4
		end
	end
	for _, child in ipairs(playerGui:GetChildren()) do
		if child:IsA("ScreenGui") then
			local quickbar = child:FindFirstChild("Quickbar", true)
			local slot4 = quickbar and quickbar:FindFirstChild("Slot4")
			if slot4 and slot4:IsA("GuiObject") then
				return slot4
			end
		end
	end
	return nil
end

local function findWaveSlot(): GuiObject?
	local hud = UiViewportTags.pickMainHud(playerGui)
	if not hud then
		return nil
	end
	local qb = hud:FindFirstChild("Quickbar")
	local slot5 = qb and qb:FindFirstChild("Slot5")
	if slot5 and slot5:IsA("GuiObject") then
		return slot5
	end
	return nil
end

local function findSkillsButton(): GuiObject?
	local left = playerGui:FindFirstChild("MobileLeftUI")
	local dPad = left and left:FindFirstChild("dPad")
	local skills = dPad and dPad:FindFirstChild("Skills")
	if not (skills and skills:IsA("GuiObject")) then
		return nil
	end
	local hit = skills:FindFirstChild("_OceanTD_SkillsHit")
	if hit and hit:IsA("GuiObject") then
		return hit
	end
	return skills
end

local function findUpgradeButton(): GuiObject?
	local hud = UiViewportTags.pickMainHud(playerGui)
	if not hud then
		return nil
	end
	local up = hud:FindFirstChild("UPGRADE", true)
	if not (up and up:IsA("GuiObject") and up.Visible) then
		return nil
	end
	-- Parent CoralInspect may be hidden while the button's own Visible stays true.
	local p: Instance? = up.Parent
	while p and p ~= hud do
		if p:IsA("GuiObject") and not p.Visible then
			return nil
		end
		p = p.Parent
	end
	if up.AbsoluteSize.X < 2 then
		return nil
	end
	return up
end

local function findPlotSizeButton(): GuiObject?
	local skillsGui = playerGui:FindFirstChild("MobileSkillsA")
	if not skillsGui then
		return nil
	end
	local layer = skillsGui:FindFirstChild("_OceanTD_BubbleLayer")
	local btn = (layer and layer:FindFirstChild("PlotSizeBTN")) or skillsGui:FindFirstChild("PlotSizeBTN", true)
	if btn and btn:IsA("GuiObject") and btn.Visible then
		return btn
	end
	return nil
end

local function findPlotSizeUnlockButton(): GuiObject?
	-- Always use the live PowerUpTemplate UNLOCKbtn (not a bubble-tree duplicate like AutoRoll).
	if SkillPowerUpUI.getActiveSkillId() ~= "PlotSize" then
		return nil
	end
	return SkillPowerUpUI.getUnlockButton()
end

local function findPlotSizeCloseButton(): GuiObject?
	return SkillPowerUpUI.getCloseButton()
end

local function guiCenterInsetInclusive(anchor: GuiObject): Vector2
	local inset = GuiService:GetGuiInset()
	local c = anchor.AbsolutePosition + anchor.AbsoluteSize * 0.5
	return Vector2.new(c.X + inset.X, c.Y + inset.Y)
end

local function absoluteCenterToInsetInclusive(c: Vector2): Vector2
	local inset = GuiService:GetGuiInset()
	return Vector2.new(c.X + inset.X, c.Y + inset.Y)
end

local function plotScreenCenter(): Vector2?
	local plot = ClientPlot.get()
	local cam = Workspace.CurrentCamera
	if not (plot and cam) then
		return nil
	end
	local up = plot.cframe.UpVector
	local world = plot.cframe.Position - up * (plot.size.Y * 0.5) + up * 1.25
	local sp, onScreen = cam:WorldToViewportPoint(world)
	if not onScreen or sp.Z <= 0 then
		return nil
	end
	return Vector2.new(sp.X, sp.Y)
end

local function tutorialHueCoralScreenCenter(): Vector2?
	local pid = playerGui:GetAttribute(HUE_PLACE_ATTR)
	if typeof(pid) ~= "string" or pid == "" then
		return nil
	end
	local part = RelocatePickHover.findByPlaceId(pid)
	local cam = Workspace.CurrentCamera
	if not (part and cam) then
		return nil
	end
	local sp, onScreen = cam:WorldToViewportPoint(part.Position)
	if not onScreen or sp.Z <= 0 then
		return nil
	end
	return Vector2.new(sp.X, sp.Y)
end

local function viewportCenter(): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return Vector2.new(vp.X * 0.5, vp.Y * 0.5)
end

local function viewportBottomCenter(): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return Vector2.new(vp.X * 0.5, vp.Y * BOTTOM_REST_Y_FRAC)
end

local function baseRotDeg(mode: HintMode): number
	if mode == "upgrade" then
		return UPGRADE_BASE_ROT_DEG
	end
	return 0
end

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function easeOutCubic(t: number): number
	t = math.clamp(t, 0, 1)
	local u = 1 - t
	return 1 - u * u * u
end

local function easeInCubic(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * t
end

local function quadBezier(a: Vector2, ctrl: Vector2, b: Vector2, t: number): Vector2
	local u = 1 - t
	return a * (u * u) + ctrl * (2 * u * t) + b * (t * t)
end

local function destroyGui()
	if conn then
		conn:Disconnect()
		conn = nil
	end
	finger = nil
	scaleObj = nil
	if gui and gui.Parent then
		gui:Destroy()
	end
	gui = nil
end

local function stopHint()
	gen += 1
	destroyGui()
end

local function ensureGui(imageId: string): ImageLabel?
	if gui and finger and finger.Parent then
		finger.Image = imageId
		return finger
	end
	destroyGui()

	local sg = Instance.new("ScreenGui")
	sg.Name = GUI_NAME
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 8500
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	pcall(function()
		(sg :: any).ClipToDeviceSafeArea = false
		(sg :: any).SafeAreaCompatibility = Enum.SafeAreaCompatibility.None
	end)
	sg.Parent = playerGui
	gui = sg

	local img = Instance.new("ImageLabel")
	img.Name = "Finger"
	img.BackgroundTransparency = 1
	img.AnchorPoint = TIP_ANCHOR
	img.Size = UDim2.fromOffset(FINGER_PX, FINGER_PX)
	img.Image = imageId
	img.ScaleType = Enum.ScaleType.Fit
	img.ZIndex = 10
	img.Active = false
	-- Must not steal clicks or placement rays aim under the finger graphic.
	pcall(function()
		(img :: any).Interactable = false
	end)
	img.Visible = false
	img.Parent = sg

	local us = Instance.new("UIScale")
	us.Scale = 1
	us.Parent = img

	finger = img
	scaleObj = us
	return img
end

local function waitFingerSource(timeoutSec: number): Instance?
	local deadline = os.clock() + timeoutSec
	local found = findByPath(Workspace, FINGER_PATH)
	if found then
		return found
	end
	local plots = Workspace:FindFirstChild("Plots") or Workspace:WaitForChild("Plots", timeoutSec)
	if not plots then
		return nil
	end
	local remain = math.max(0.05, deadline - os.clock())
	local folder = plots:FindFirstChild("IntroElements") or plots:WaitForChild("IntroElements", remain)
	if not folder then
		return nil
	end
	remain = math.max(0.05, deadline - os.clock())
	return folder:FindFirstChild("Finger") or folder:WaitForChild("Finger", remain)
end

local function parseMode(raw: any): HintMode?
	if raw == true then
		return "roll"
	end
	if typeof(raw) == "string" and MODE_SET[raw] then
		return raw :: HintMode
	end
	return nil
end

local function resolveTarget(mode: HintMode): Vector2?
	if mode == "roll" then
		local a = findRollAnchor()
		return if a and a.Visible and a.AbsoluteSize.X >= 2 then guiCenterInsetInclusive(a) else nil
	elseif mode == "backpack" or mode == "closeBackpack" then
		local a = findBackpackSlot()
		return if a and a.Visible and a.AbsoluteSize.X >= 2 then guiCenterInsetInclusive(a) else nil
	elseif mode == "equip" then
		local id = SeedWheelRevealApi.lastAwardedItemId
		if typeof(id) ~= "string" or id == "" then
			return nil
		end
		local c = InventoryState.getItemSlotScreenCenter(id)
		return if c then absoluteCenterToInsetInclusive(c) else nil
	elseif mode == "plot" then
		return plotScreenCenter()
	elseif mode == "reselectCoral" then
		return tutorialHueCoralScreenCenter() or plotScreenCenter()
	elseif mode == "upgrade" then
		local a = findUpgradeButton()
		if not a then
			return nil
		end
		local c = guiCenterInsetInclusive(a)
		-- Aim slightly above center so the finger tip lands on the button, not below it.
		return Vector2.new(c.X, c.Y - UPGRADE_AIM_UP_PX)
	elseif mode == "hue" or mode == "hueReroll" then
		local a = CoralInspectPanel.getTutorialHueSwatch()
		return if a then guiCenterInsetInclusive(a) else nil
	elseif mode == "waves" then
		local a = findWaveSlot()
		return if a and a.Visible and a.AbsoluteSize.X >= 2 then guiCenterInsetInclusive(a) else nil
	elseif mode == "skills" or mode == "closeSkills" then
		local a = findSkillsButton()
		return if a and a.Visible and a.AbsoluteSize.X >= 2 then guiCenterInsetInclusive(a) else nil
	elseif mode == "plotSize" then
		local a = findPlotSizeButton()
		return if a then guiCenterInsetInclusive(a) else nil
	elseif mode == "plotSizeUpgrade" then
		local a = findPlotSizeUnlockButton()
		return if a then guiCenterInsetInclusive(a) else nil
	elseif mode == "closePlotSize" then
		local a = findPlotSizeCloseButton()
		return if a then guiCenterInsetInclusive(a) else nil
	end
	return nil
end

local function travelSec(mode: HintMode, base: number): number
	if SLOW_TRAVEL_MODES[mode] then
		return base * SLOW_TRAVEL_MULT
	end
	return base
end

local function restOf(mode: HintMode, btn: Vector2): Vector2
	-- Mid-screen skill targets: retreat to bottom-center so the finger clears the button.
	if mode == "plotSize" or mode == "plotSizeUpgrade" or mode == "hue" or mode == "hueReroll" then
		return viewportBottomCenter()
	end
	if mode == "upgrade" then
		return btn:Lerp(viewportCenter(), EQUIP_REST_TOWARD_CENTER)
	end
	if mode == "backpack" or mode == "closeBackpack" or mode == "equip"
		or mode == "closePlotSize" or mode == "waves"
	then
		local alpha = if mode == "waves" then WAVE_REST_TOWARD_CENTER
			elseif mode == "backpack" or mode == "closeBackpack" then BACKPACK_REST_TOWARD_CENTER
			else EQUIP_REST_TOWARD_CENTER
		return btn:Lerp(viewportCenter(), alpha)
	elseif mode == "plot" or mode == "reselectCoral" then
		return Vector2.new(btn.X, btn.Y + PLOT_REST_DOWN_PX)
	elseif mode == "skills" or mode == "closeSkills" or mode == "roll" then
		return btn:Lerp(viewportCenter(), WAVE_REST_TOWARD_CENTER)
	end
	return Vector2.new(btn.X, btn.Y + BELOW_PAD_PX)
end

local function startHint(mode: HintMode)
	gen += 1
	local myGen = gen

	if mode == "equip" then
		local id = SeedWheelRevealApi.lastAwardedItemId
		if typeof(id) == "string" then
			InventoryState.revealItemInBackpack(id)
		end
	elseif mode == "waves" then
		waitingWaveEnd = true
		wavesFingerConsumed = false
	elseif mode == "skills" then
		-- Left HUD must be visible for the Skills button.
		if playerGui:GetAttribute("OceanTD_TutorialGateLeftHud") == true then
			playerGui:SetAttribute("OceanTD_TutorialGateLeftHud", false)
		end
	end
	-- closeSkills: wait for Skills open in the heartbeat (don't clear the hint early).

	local riseDur = travelSec(mode, RISE_SEC)
	local retreatDur = travelSec(mode, RETREAT_SEC)

	task.spawn(function()
		local src = waitFingerSource(8)
		if myGen ~= gen or not src then
			return
		end
		local imageId = resolveFingerImage(src)
		if not imageId then
			warn("[RollFingerHint] IntroElements.Finger has no Image/Decal")
			return
		end
		local img = ensureGui(imageId)
		if not img or myGen ~= gen then
			return
		end

		local phase = "rise"
		local t0 = os.clock()
		local fromPos = Vector2.zero
		local toPos = Vector2.zero
		local ctrlPos = Vector2.zero
		local laidOut = false
		local arcSign = -1

		local function setArc(from: Vector2, to: Vector2, sign: number)
			local mid = from:Lerp(to, 0.5)
			local delta = to - from
			local len = delta.Magnitude
			local perp = if len > 1e-3
				then Vector2.new(-delta.Y, delta.X).Unit
				else Vector2.new(1, 0)
			ctrlPos = mid + perp * (ARC_X_PX * sign) + Vector2.new(0, -ARC_Y_PX * sign * 0.35)
		end

		local function beginRise(btn: Vector2, from: Vector2?)
			fromPos = from or restOf(mode, btn)
			toPos = btn
			arcSign = -1
			setArc(fromPos, toPos, arcSign)
			phase = "rise"
			t0 = os.clock()
		end

		local function beginRetreat(btn: Vector2)
			fromPos = btn
			toPos = restOf(mode, btn)
			arcSign = 1
			setArc(fromPos, toPos, arcSign)
			phase = "retreat"
			t0 = os.clock()
		end

		conn = RunService.Heartbeat:Connect(function()
			if myGen ~= gen then
				return
			end
			local f = finger
			local sc = scaleObj
			if not (f and f.Parent and sc) then
				return
			end

			-- Auto-advance / gate visibility by mode.
			if mode == "equip" and not InventoryState.isOpen() then
				f.Visible = false
				laidOut = false
				return
			end
			if mode == "waves" then
				if WaveSim.isRunning() then
					wavesFingerConsumed = true
					f.Visible = false
					laidOut = false
					return
				end
				-- After a wave session (or while summary is up), don't point at Slot5 behind it.
				if wavesFingerConsumed or WaveSlotSummary.isOpen() then
					f.Visible = false
					laidOut = false
					return
				end
			end
			if mode == "skills" and playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
				playerGui:SetAttribute(HINT_ATTR, "plotSize")
				return
			elseif mode == "plotSize" and playerGui:GetAttribute(POWERUP_OPEN_ATTR) == true then
				if SkillPowerUpUI.isOpen() and SkillPowerUpUI.getActiveSkillId() == "PlotSize" then
					playerGui:SetAttribute(HINT_ATTR, "plotSizeUpgrade")
					return
				end
			elseif mode == "plotSizeUpgrade" then
				if SkillPowerUpUI.getActiveSkillId() == "PlotSize" then
					-- Stay on unlock until unlock succeeds (closePlotSize) or panel closes.
				elseif playerGui:GetAttribute(POWERUP_OPEN_ATTR) ~= true then
					playerGui:SetAttribute(HINT_ATTR, "plotSize")
					return
				end
			elseif mode == "closePlotSize" and playerGui:GetAttribute(POWERUP_OPEN_ATTR) ~= true then
				-- Power-up already closed (or never open) — advance to skills close.
				if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
					playerGui:SetAttribute(HINT_ATTR, "closeSkills")
					return
				end
			elseif mode == "closeSkills" and playerGui:GetAttribute(SKILLS_OPEN_ATTR) ~= true then
				-- Wait for skills chrome; clear only once skills are gone after a real close.
				f.Visible = false
				laidOut = false
				return
			end

			local hideChrome = uiHidesChrome()
			-- Skills/powerup open is expected for later tutorial steps.
			if mode == "plotSize" or mode == "plotSizeUpgrade" or mode == "closePlotSize" or mode == "closeSkills" or mode == "upgrade" or mode == "hue" or mode == "hueReroll" then
				hideChrome = playerGui:GetAttribute(REPORT_OPEN_ATTR) == true
					or playerGui:GetAttribute(HIDE_UI_ACTIVE_ATTR) == true
			elseif mode == "plot" or mode == "reselectCoral" then
				hideChrome = hideChrome
			elseif mode == "skills" then
				hideChrome = playerGui:GetAttribute(REPORT_OPEN_ATTR) == true
					or playerGui:GetAttribute(HIDE_UI_ACTIVE_ATTR) == true
					or playerGui:GetAttribute(POWERUP_OPEN_ATTR) == true
			end

			f.Visible = not hideChrome
			if hideChrome then
				laidOut = false
				return
			end

			local btn = resolveTarget(mode)
			if not btn then
				f.Visible = false
				laidOut = false
				return
			end
			f.Visible = true

			if not laidOut then
				beginRise(btn, nil)
				laidOut = true
				f.Position = UDim2.fromOffset(fromPos.X, fromPos.Y)
				f.Rotation = baseRotDeg(mode)
				sc.Scale = 1
			end

			local now = os.clock()
			local elapsed = now - t0
			local baseRot = baseRotDeg(mode)

			if phase == "rise" then
				toPos = btn
				setArc(fromPos, toPos, arcSign)
				local u = easeOutCubic(elapsed / riseDur)
				local p = quadBezier(fromPos, ctrlPos, toPos, u)
				f.Position = UDim2.fromOffset(p.X, p.Y)
				f.Rotation = baseRot
				sc.Scale = 1
				if elapsed >= riseDur then
					phase = "pressIn"
					t0 = now
					f.Position = UDim2.fromOffset(btn.X, btn.Y)
				end
			elseif phase == "pressIn" then
				local u = smoothstep(math.clamp(elapsed / PRESS_SEC, 0, 1))
				sc.Scale = 1 + (PRESS_SCALE - 1) * u
				f.Rotation = baseRot + PRESS_ROT_DEG * u
				f.Position = UDim2.fromOffset(btn.X, btn.Y)
				if elapsed >= PRESS_SEC then
					phase = "pressOut"
					t0 = now
					sc.Scale = PRESS_SCALE
					f.Rotation = baseRot + PRESS_ROT_DEG
				end
			elseif phase == "pressOut" then
				local u = smoothstep(math.clamp(elapsed / PRESS_SEC, 0, 1))
				sc.Scale = PRESS_SCALE + (1 - PRESS_SCALE) * u
				f.Rotation = baseRot + PRESS_ROT_DEG * (1 - u)
				f.Position = UDim2.fromOffset(btn.X, btn.Y)
				if elapsed >= PRESS_SEC then
					phase = "hold"
					t0 = now
					sc.Scale = 1
					f.Rotation = baseRot
				end
			elseif phase == "hold" then
				f.Position = UDim2.fromOffset(btn.X, btn.Y)
				f.Rotation = baseRot
				sc.Scale = 1
				if elapsed >= HOLD_SEC then
					beginRetreat(btn)
					sc.Scale = 1
					f.Rotation = baseRot
				end
			elseif phase == "retreat" then
				toPos = restOf(mode, btn)
				setArc(fromPos, toPos, arcSign)
				local u = easeInCubic(elapsed / retreatDur)
				local p = quadBezier(fromPos, ctrlPos, toPos, u)
				f.Position = UDim2.fromOffset(p.X, p.Y)
				f.Rotation = baseRot
				sc.Scale = 1
				if elapsed >= retreatDur then
					beginRise(btn, p)
				end
			end
		end)
	end)
end

local function applyAttr(raw: any)
	if raw == "await" then
		stopHint()
		return
	end
	local mode = parseMode(raw)
	if mode then
		startHint(mode)
	else
		waitingWaveEnd = false
		stopHint()
	end
end

playerGui:GetAttributeChangedSignal(HINT_ATTR):Connect(function()
	applyAttr(playerGui:GetAttribute(HINT_ATTR))
end)

SeedWheelRevealApi.connectCycleFinished(function()
	if playerGui:GetAttribute(HINT_ATTR) == "await" then
		playerGui:SetAttribute(HINT_ATTR, "backpack")
	end
end)

InventoryState.onOpenChanged(function(isOpen: boolean)
	local v = playerGui:GetAttribute(HINT_ATTR)
	if isOpen then
		if v == "backpack" or v == "await" then
			playerGui:SetAttribute(HINT_ATTR, "equip")
		end
		return
	end
	if v == "equip" then
		playerGui:SetAttribute(HINT_ATTR, "backpack")
	elseif v == "closeBackpack" then
		-- Closed backpack after hue tutorial → wait for Slot5 pop, then point at Start Waves.
		wavesFingerDelayGen += 1
		local my = wavesFingerDelayGen
		playerGui:SetAttribute(HINT_ATTR, false)
		task.spawn(function()
			local deadline = os.clock() + 6
			while playerGui:GetAttribute("OceanTD_TutorialWavesSlotReady") ~= true do
				if my ~= wavesFingerDelayGen then
					return
				end
				if os.clock() > deadline then
					break
				end
				task.wait(0.05)
			end
			if my ~= wavesFingerDelayGen then
				return
			end
			if InventoryState.isOpen() then
				return
			end
			local cur = playerGui:GetAttribute(HINT_ATTR)
			if cur == false or cur == nil or cur == "await" then
				playerGui:SetAttribute(HINT_ATTR, "waves")
			end
		end)
	end
end)

InventoryState.onSelectionChanged(function(itemId: string?)
	if playerGui:GetAttribute(HINT_ATTR) ~= "equip" then
		return
	end
	local want = SeedWheelRevealApi.lastAwardedItemId
	if typeof(itemId) == "string" and itemId ~= "" and itemId == want then
		playerGui:SetAttribute(HINT_ATTR, "plot")
	end
end)

playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(function()
	local v = playerGui:GetAttribute(HINT_ATTR)
	local open = playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true
	if open and v == "skills" then
		playerGui:SetAttribute(HINT_ATTR, "plotSize")
	elseif not open then
		if v == "closeSkills" then
			playerGui:SetAttribute(HINT_ATTR, false)
		elseif v == "plotSize" or v == "plotSizeUpgrade" or v == "closePlotSize" then
			-- Closed skills without finishing the plot-size tutorial — back to Skills finger.
			playerGui:SetAttribute(HINT_ATTR, "skills")
		end
	end
end)

playerGui:GetAttributeChangedSignal(POWERUP_OPEN_ATTR):Connect(function()
	local v = playerGui:GetAttribute(HINT_ATTR)
	local open = playerGui:GetAttribute(POWERUP_OPEN_ATTR) == true
	if open and v == "plotSize" and SkillPowerUpUI.getActiveSkillId() == "PlotSize" then
		playerGui:SetAttribute(HINT_ATTR, "plotSizeUpgrade")
	elseif not open and v == "plotSizeUpgrade" then
		-- Closed plot-size power-up without unlocking — point at Plot Size bubble again.
		if playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
			playerGui:SetAttribute(HINT_ATTR, "plotSize")
		else
			playerGui:SetAttribute(HINT_ATTR, "skills")
		end
	end
end)

local function tryStartSkillsFingerFromTutorial()
	if not waitingWaveEnd then
		return
	end
	waitingWaveEnd = false
	playerGui:SetAttribute("OceanTD_TutorialGateLeftHud", false)
	playerGui:SetAttribute(HINT_ATTR, "skills")
end

playerGui:GetAttributeChangedSignal("OceanTD_TutorialSummaryFinished"):Connect(function()
	if playerGui:GetAttribute("OceanTD_TutorialSummaryFinished") ~= nil then
		tryStartSkillsFingerFromTutorial()
	end
end)

local LEFT_HUD_LOCK_BTN: { [string]: boolean } = {
	Skills = true,
	-- Settings / audio stays usable during the tutorial gate.
	HideUI = true,
	CartIcon = true,
	Cart = true,
	CartBTN = true,
	CartBtn = true,
	Report = true,
	ReefReport = true,
}

local LEFT_LOCK_OVERLAY = "_OceanTD_TutorialLeftLock"
local LEFT_LOCK_ICON = "_OceanTD_TutorialLeftLockIcon"
local LEFT_LOCK_IMAGE = "rbxassetid://105420423737825"
local LEFT_LOCK_RED = Color3.fromRGB(220, 40, 45)

local function clearTutorialLockOn(host: GuiObject)
	local ov = host:FindFirstChild(LEFT_LOCK_OVERLAY)
	if ov then
		ov:Destroy()
	end
	local ic = host:FindFirstChild(LEFT_LOCK_ICON)
	if ic then
		ic:Destroy()
	end
	local function restoreBtn(btn: GuiButton)
		local wasActive = btn:GetAttribute("_OceanTD_TutorialLockActive")
		local wasSel = btn:GetAttribute("_OceanTD_TutorialLockSelectable")
		if typeof(wasActive) == "boolean" then
			btn.Active = wasActive
			btn:SetAttribute("_OceanTD_TutorialLockActive", nil)
		end
		if typeof(wasSel) == "boolean" then
			btn.Selectable = wasSel
			btn:SetAttribute("_OceanTD_TutorialLockSelectable", nil)
		end
		pcall(function()
			(btn :: any).Interactable = btn.Active
		end)
	end
	if host:IsA("GuiButton") then
		restoreBtn(host)
	end
	for _, d in ipairs(host:GetDescendants()) do
		if d:IsA("GuiButton") then
			restoreBtn(d)
		end
	end
end

local function ensureTutorialLockOn(host: GuiObject)
	local function disarmBtn(btn: GuiButton)
		if btn:GetAttribute("_OceanTD_TutorialLockActive") == nil then
			btn:SetAttribute("_OceanTD_TutorialLockActive", btn.Active)
			btn:SetAttribute("_OceanTD_TutorialLockSelectable", btn.Selectable)
		end
		btn.Active = false
		btn.Selectable = false
		pcall(function()
			(btn :: any).Interactable = false
		end)
	end
	if host:IsA("GuiButton") then
		disarmBtn(host)
	end
	for _, d in ipairs(host:GetDescendants()) do
		if d:IsA("GuiButton") then
			disarmBtn(d)
		end
	end

	local overlay = host:FindFirstChild(LEFT_LOCK_OVERLAY)
	if not (overlay and overlay:IsA("GuiButton")) then
		if overlay then
			overlay:Destroy()
		end
		local f = Instance.new("TextButton")
		f.Name = LEFT_LOCK_OVERLAY
		f.Text = ""
		f.AutoButtonColor = false
		f.BackgroundColor3 = LEFT_LOCK_RED
		f.BackgroundTransparency = 0.45
		f.BorderSizePixel = 0
		f.Size = UDim2.fromScale(1, 1)
		f.Position = UDim2.fromScale(0, 0)
		f.Active = true -- swallow clicks
		f.Selectable = false
		f.ZIndex = host.ZIndex + 80
		f.Parent = host
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = f
		-- No-op Activated so the button still consumes input.
		f.Activated:Connect(function() end)
		overlay = f
	else
		overlay.Visible = true
		overlay.Active = true
		;(overlay :: GuiButton).ZIndex = host.ZIndex + 80
	end
	local icon = host:FindFirstChild(LEFT_LOCK_ICON)
	if not (icon and icon:IsA("ImageLabel")) then
		local img = Instance.new("ImageLabel")
		img.Name = LEFT_LOCK_ICON
		img.BackgroundTransparency = 1
		img.Image = LEFT_LOCK_IMAGE
		img.Size = UDim2.fromScale(0.55, 0.55)
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.Active = false
		img.ZIndex = host.ZIndex + 82
		img.ScaleType = Enum.ScaleType.Fit
		img.Parent = host
	else
		icon.Visible = true
		;(icon :: ImageLabel).ZIndex = host.ZIndex + 82
	end
end

local function applyLeftHudGate()
	local gate = playerGui:GetAttribute("OceanTD_TutorialGateLeftHud") == true
	local skillsOpen = playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true
	local left = playerGui:FindFirstChild("MobileLeftUI")
	if not (left and left:IsA("ScreenGui")) then
		return
	end
	-- Keep ScreenGui on — roll button lives under MobileLeftUI.
	left.Enabled = true
	-- Clear any legacy hide-flag from older gate behavior.
	for _, ch in ipairs(left:GetChildren()) do
		if ch:IsA("GuiObject") and ch:GetAttribute("_OceanTD_TutorialLeftHudHidden") == true then
			ch:SetAttribute("_OceanTD_TutorialLeftHudHidden", nil)
			ch.Visible = true
		end
	end
	local dPad = left:FindFirstChild("dPad")
	if not (dPad and dPad:IsA("GuiObject")) then
		return
	end
	dPad.Visible = true
	for _, ch in ipairs(dPad:GetChildren()) do
		if not (ch:IsA("GuiObject") and LEFT_HUD_LOCK_BTN[ch.Name]) then
			continue
		end
		-- Skills close must stay usable while bubbles are open (WaveSpeed/Skip ForceOpen).
		if gate and not (skillsOpen and ch.Name == "Skills") then
			ensureTutorialLockOn(ch)
		else
			clearTutorialLockOn(ch)
		end
	end
end

playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateLeftHud"):Connect(applyLeftHudGate)
playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(applyLeftHudGate)
playerGui.ChildAdded:Connect(function(ch)
	if ch.Name == "MobileLeftUI" then
		task.defer(applyLeftHudGate)
		ch.ChildAdded:Connect(function()
			if playerGui:GetAttribute("OceanTD_TutorialGateLeftHud") == true
				or playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true
			then
				task.defer(applyLeftHudGate)
			end
		end)
	end
end)
do
	local existing = playerGui:FindFirstChild("MobileLeftUI")
	if existing then
		existing.ChildAdded:Connect(function()
			if playerGui:GetAttribute("OceanTD_TutorialGateLeftHud") == true
				or playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true
			then
				task.defer(applyLeftHudGate)
			end
		end)
	end
end
task.defer(applyLeftHudGate)

applyAttr(playerGui:GetAttribute(HINT_ATTR))
