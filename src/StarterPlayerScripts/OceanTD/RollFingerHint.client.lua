--!strict
--[[
	Join-intro finger tutorial pipeline:
	roll → await → backpack → equip → plot → upgrade → hue (finger stays on swatch, cycles colors until user taps)
	→ closeBackpack → waves
	(reselectCoral if inspect closes mid-upgrade / mid-hue) → …
	→ (after first wave-session Finish) if defeat: roll again → skills; if win: skills
	→ plotSize → plotSizeUpgrade → closePlotSize → closeSkills → cam

	After join intro ends (intro SKIP gone): bottom-left SKIP clears all finger steps + tutorial gates.
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
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))

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
local PLANT_FIRST_CORAL_SOUND_ID = "rbxassetid://139678980175457"
local HOW_MANY_WAVES_SOUND_ID = "rbxassetid://135876579370482"
local WAVE_EXPLAINER_SOUND_ID = "rbxassetid://72069463774995"
local FINGER_CAM_SOUND_ID = "rbxassetid://80359058869110"
local FINGER_SKILLS_SOUND_ID = "rbxassetid://125491130885745"
local TRY_WAVES_AGAIN_SOUND_ID = "rbxassetid://107210999893937"
local TRY_WAVES_AGAIN_DELAY_SEC = 3
local TutorialVo = require(script.Parent:WaitForChild("TutorialVo"))
local WaveArrowPreview = require(script.Parent:WaitForChild("WaveArrowPreview"))

local SKILLS_OPEN_ATTR = "OceanTD_SkillsBubblesOpen"
local POWERUP_OPEN_ATTR = "OceanTD_SkillPowerUpOpen"
local REPORT_OPEN_ATTR = "OceanTD_ReefReportOpen"
local HIDE_UI_ACTIVE_ATTR = "OceanTD_HideUiActive"

local FINGER_PX = 110
local RISE_SEC = 0.7
local PRESS_SEC = 0.17
local HOLD_SEC = 0.1
local RETREAT_SEC = 0.7
-- Hue demo: stay on the swatch after each fake tap so the color change is visible.
local HUE_DEMO_HOLD_SEC = 1.0
-- Backpack / upgrade / close targets travel 50% slower.
local SLOW_TRAVEL_MULT = 1.5
-- Plot place finger travels backpack↔plot at half speed (2× duration).
local PLOT_TRAVEL_MULT = 2
local PRESS_SCALE = 0.7
local PRESS_ROT_DEG = -10
local TAP_BURST_COUNT = 6
local TAP_BURST_COLOR = Color3.new(1, 1, 1)
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
	| "cam"

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
	cam = true,
}

local SLOW_TRAVEL_MODES: { [string]: boolean } = {
	backpack = true,
	upgrade = true,
	hue = true,
	hueReroll = true,
	closeBackpack = true,
	closePlotSize = true,
	closeSkills = true,
	cam = true,
}

local gen = 0
local gui: ScreenGui? = nil
local burstLayer: Frame? = nil
local finger: ImageLabel? = nil
local scaleObj: UIScale? = nil
local conn: RBXScriptConnection? = nil
local waitingWaveEnd = false
local wavesFingerConsumed = false
local wavesFingerDelayGen = 0
local tapBurstRng = Random.new()
local fingerTutorialSkipped = false
local skipTutorialGui: ScreenGui? = nil
local skipTutorialBtn: TextButton? = nil
local plantFirstCoralSoundPlayed = false
local howManyWavesSoundPlayed = false
local waveExplainerSoundPlayed = false
local fingerCamSoundPlayed = false
local fingerSkillsSoundPlayed = false
local tryWavesAgainSoundPlayed = false
local tryWavesAgainGen = 0
local camVoFinished = false
local camButtonClicked = false
local wavesHudWasRunning = false
local JOIN_INTRO_BUSY_ATTR = "OceanTD_JoinIntroBusy"
local SKIP_TUTORIAL_GUI = "OceanTD_FingerTutorialSkip"
local SKIP_GREEN = Color3.fromRGB(55, 200, 90)
local SKIP_STROKE_BRIGHT = Color3.fromRGB(90, 255, 110)
local SKIP_BTN_SIZE = Vector2.new(70, 26) -- half of prior 140×52

local function playPlantFirstCoralSoundOnce()
	if plantFirstCoralSoundPlayed or fingerTutorialSkipped then
		return
	end
	plantFirstCoralSoundPlayed = true
	TutorialVo.play(PLANT_FIRST_CORAL_SOUND_ID, "OceanTD_PlantFirstCoral")
end

local function playHowManyWavesSoundOnce()
	if howManyWavesSoundPlayed or fingerTutorialSkipped then
		return
	end
	howManyWavesSoundPlayed = true
	TutorialVo.play(HOW_MANY_WAVES_SOUND_ID, "OceanTD_HowManyWaves")
end

local function playWaveExplainerSoundOnce()
	if waveExplainerSoundPlayed or fingerTutorialSkipped then
		return
	end
	waveExplainerSoundPlayed = true
	-- Never cut off "how many waves" — queue until that clip finishes.
	TutorialVo.playWhenIdle(WAVE_EXPLAINER_SOUND_ID, "OceanTD_WaveExplainer", {
		onStart = function()
			-- Wave 1 arrow sting under the VO.
			WaveArrowPreview.fadeOutStartSound(0.45)
		end,
	})
end

-- After cam button click AND cam VO ends: wait 3s, then "try waves again".
local function tryScheduleTryWavesAgain()
	if tryWavesAgainSoundPlayed or fingerTutorialSkipped then
		return
	end
	if not (camButtonClicked and camVoFinished) then
		return
	end
	tryWavesAgainGen += 1
	local my = tryWavesAgainGen
	task.spawn(function()
		task.wait(TRY_WAVES_AGAIN_DELAY_SEC)
		if my ~= tryWavesAgainGen or fingerTutorialSkipped or tryWavesAgainSoundPlayed then
			return
		end
		tryWavesAgainSoundPlayed = true
		TutorialVo.play(TRY_WAVES_AGAIN_SOUND_ID, "OceanTD_TryWavesAgain", { volume = 4 })
	end)
end

local function playFingerCamSoundOnce()
	if fingerCamSoundPlayed or fingerTutorialSkipped then
		-- Already played earlier this session — don't block "try waves again".
		camVoFinished = true
		tryScheduleTryWavesAgain()
		return
	end
	fingerCamSoundPlayed = true
	camVoFinished = false
	TutorialVo.play(FINGER_CAM_SOUND_ID, "OceanTD_FingerCam", {
		volume = 4,
		onEnded = function()
			camVoFinished = true
			tryScheduleTryWavesAgain()
		end,
	})
end

local function playFingerSkillsSoundOnce()
	if fingerSkillsSoundPlayed or fingerTutorialSkipped then
		return
	end
	fingerSkillsSoundPlayed = true
	TutorialVo.play(FINGER_SKILLS_SOUND_ID, "OceanTD_FingerSkills", { volume = 4 })
end

local function onCamButtonClickedForTryWaves()
	camButtonClicked = true
	tryScheduleTryWavesAgain()
end

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

local function findCamButton(): GuiObject?
	local left = playerGui:FindFirstChild("MobileLeftUI")
	local dPad = left and left:FindFirstChild("dPad")
	if not dPad then
		return nil
	end
	-- Prefer the active mode icon; fall back to PlotCam (main RTS seat).
	local mode = playerGui:GetAttribute("OceanTD_CamCycleMode")
	local preferName = if mode == "fishcam"
		then "FishCam"
		elseif mode == "dronecam" then "FreeCam"
		elseif mode == "off" then "OffCam"
		else "PlotCam"
	local prefer = dPad:FindFirstChild(preferName)
	if prefer and prefer:IsA("GuiObject") and prefer.Visible and prefer.AbsoluteSize.X >= 2 then
		return prefer
	end
	for _, name in ipairs({ "PlotCam", "FishCam", "FreeCam", "OffCam" }) do
		local g = dPad:FindFirstChild(name)
		if g and g:IsA("GuiObject") and g.Visible and g.AbsoluteSize.X >= 2 then
			return g
		end
	end
	return nil
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

local function clampFingerToViewport(p: Vector2): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local margin = 48
	return Vector2.new(math.clamp(p.X, margin, vp.X - margin), math.clamp(p.Y, margin, vp.Y - margin))
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

-- First-place plot finger: each tap lands on a slightly different spot near the floor middle.
-- Angled cam makes geometric center read as the near edge — bias away from camera + slight
-- screen lift so the tip sits mid-pad.
local plotTapRng = Random.new()
local plotTapOffsetX = 0
local plotTapOffsetZ = 0
local PLOT_TAP_AIM_UP_PX = 22

local function rerollPlotTapOffset()
	local plot = ClientPlot.get()
	if not plot then
		plotTapOffsetX = 0
		plotTapOffsetZ = 0
		return
	end
	-- Tight central scatter (~±12% of pad width/depth).
	local hx = math.max(0.6, plot.size.X * 0.12)
	local hz = math.max(0.6, plot.size.Z * 0.12)
	plotTapOffsetX = plotTapRng:NextNumber(-hx, hx)
	plotTapOffsetZ = plotTapRng:NextNumber(-hz, hz)
end

local function plotTapFloorWorld(): Vector3?
	local plot = ClientPlot.get()
	local cam = Workspace.CurrentCamera
	if not (plot and cam) then
		return nil
	end
	local cf = plot.cframe
	local floorY = -plot.size.Y * 0.5 + 1.0
	local floorCenter = (cf * CFrame.new(0, floorY, 0)).Position

	-- Push aim slightly away from the camera on the ground plane so the projection
	-- sits in the visual middle of the pad (not the near/bottom edge).
	local toCam = Vector3.new(cam.CFrame.Position.X - floorCenter.X, 0, cam.CFrame.Position.Z - floorCenter.Z)
	local awayWorld = if toCam.Magnitude > 1e-3 then -toCam.Unit else cf.LookVector
	local awayLocal = cf:VectorToObjectSpace(awayWorld)
	local awayFlat = Vector3.new(awayLocal.X, 0, awayLocal.Z)
	if awayFlat.Magnitude > 1e-3 then
		awayFlat = awayFlat.Unit
	else
		awayFlat = Vector3.new(0, 0, 0)
	end
	local bias = math.min(plot.size.X, plot.size.Z) * 0.14
	local localPos = Vector3.new(plotTapOffsetX, floorY, plotTapOffsetZ) + awayFlat * bias

	local maxX = plot.size.X * 0.22
	local maxZ = plot.size.Z * 0.22
	localPos = Vector3.new(
		math.clamp(localPos.X, -maxX, maxX),
		floorY,
		math.clamp(localPos.Z, -maxZ, maxZ)
	)
	return (cf * CFrame.new(localPos)).Position
end

local function plotTapScreenPos(): Vector2?
	local cam = Workspace.CurrentCamera
	local world = plotTapFloorWorld()
	if not (cam and world) then
		return plotScreenCenter()
	end
	local sp, onScreen = cam:WorldToViewportPoint(world)
	if not onScreen or sp.Z <= 0 then
		return plotScreenCenter()
	end
	-- Tip sits slightly above the projected floor point so contact reads mid-pad.
	return Vector2.new(sp.X, sp.Y - PLOT_TAP_AIM_UP_PX)
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

-- First-place plot finger: rise/retreat from the selected backpack coral circle.
local function plotCoralSlotRest(fallback: Vector2): Vector2
	local id = InventoryState.getSelectedId()
	if typeof(id) ~= "string" or id == "" then
		local awarded = SeedWheelRevealApi.lastAwardedItemId
		if typeof(awarded) == "string" and awarded ~= "" then
			id = awarded
		end
	end
	if typeof(id) == "string" and id ~= "" then
		local c = InventoryState.getItemSlotScreenCenter(id)
		if c then
			return absoluteCenterToInsetInclusive(c)
		end
	end
	-- Fallback if backpack cell isn't laid out yet.
	return Vector2.new(fallback.X, fallback.Y + PLOT_REST_DOWN_PX)
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
	burstLayer = nil
	if gui and gui.Parent then
		gui:Destroy()
	end
	gui = nil
end

local function ensureBurstLayer(sg: ScreenGui): Frame
	local existing = burstLayer
	if existing and existing.Parent == sg then
		return existing
	end
	local layer = sg:FindFirstChild("TapBurstLayer")
	if layer and layer:IsA("Frame") then
		burstLayer = layer
		return layer
	end
	if layer then
		layer:Destroy()
	end
	local f = Instance.new("Frame")
	f.Name = "TapBurstLayer"
	f.BackgroundTransparency = 1
	f.Size = UDim2.fromScale(1, 1)
	f.Active = false
	f.ZIndex = 5
	pcall(function()
		(f :: any).Interactable = false
	end)
	f.Parent = sg
	burstLayer = f
	return f
end

-- Same feel as roll-button dice fountain: pop out, arc up, gravity, fade.
local function spawnTapCircle(layer: Frame, origin: Vector2)
	local sizePx = tapBurstRng:NextInteger(7, 12)
	local circle = Instance.new("Frame")
	circle.Name = "TapBurst"
	circle.BorderSizePixel = 0
	circle.BackgroundColor3 = TAP_BURST_COLOR
	circle.BackgroundTransparency = 0
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromOffset(origin.X, origin.Y)
	circle.Size = UDim2.fromOffset(sizePx, sizePx)
	circle.ZIndex = 5
	circle.Active = false
	pcall(function()
		(circle :: any).Interactable = false
	end)
	circle.Parent = layer
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = circle
	local scale = Instance.new("UIScale")
	scale.Scale = 0.15
	scale.Parent = circle

	local angle = tapBurstRng:NextNumber(-math.pi * 0.85, -math.pi * 0.15)
	local speed = tapBurstRng:NextNumber(180, 420)
	local vx = math.cos(angle) * speed
	local vy = math.sin(angle) * speed
	local grav = tapBurstRng:NextNumber(850, 1200)
	local life = tapBurstRng:NextNumber(0.45, 0.75)
	local popAt = tapBurstRng:NextNumber(0.05, 0.12)
	local peak = tapBurstRng:NextNumber(1.0, 1.35)
	local x = origin.X
	local y = origin.Y
	task.spawn(function()
		local t0 = os.clock()
		while circle.Parent do
			local dt = RunService.RenderStepped:Wait()
			local age = os.clock() - t0
			if age >= life then
				break
			end
			vy += grav * dt
			x += vx * dt
			y += vy * dt
			vx *= (1 - 0.4 * dt)
			circle.Position = UDim2.fromOffset(x, y)
			if age < popAt then
				scale.Scale = 0.15 + (peak - 0.15) * (age / popAt)
			else
				local u = math.clamp((age - popAt) / math.max(0.05, life - popAt), 0, 1)
				scale.Scale = peak * (1 - 0.55 * u)
			end
			circle.BackgroundTransparency = math.clamp((age - life * 0.45) / (life * 0.55), 0, 1)
		end
		if circle.Parent then
			circle:Destroy()
		end
	end)
end

local function spawnTapBurst(origin: Vector2)
	local sg = gui
	if not sg or not sg.Parent then
		return
	end
	local layer = ensureBurstLayer(sg)
	for _ = 1, TAP_BURST_COUNT do
		spawnTapCircle(layer, origin)
	end
end

local function stopHint()
	gen += 1
	destroyGui()
end

local function isFingerTutorialActive(): boolean
	if fingerTutorialSkipped then
		return false
	end
	local hint = playerGui:GetAttribute(HINT_ATTR)
	if hint == "await" then
		return true
	end
	if typeof(hint) == "string" and MODE_SET[hint] then
		return true
	end
	if waitingWaveEnd then
		return true
	end
	if playerGui:GetAttribute("OceanTD_TutorialGateBackpack") == true then
		return true
	end
	if playerGui:GetAttribute("OceanTD_TutorialGateWaves") == true then
		return true
	end
	if playerGui:GetAttribute("OceanTD_TutorialGateLeftHud") == true then
		return true
	end
	if playerGui:GetAttribute("OceanTD_TutorialGateCam") == true then
		return true
	end
	return false
end

local function destroySkipTutorialBtn()
	if skipTutorialBtn and GuiService.SelectedObject == skipTutorialBtn then
		GuiService.SelectedObject = nil
	end
	skipTutorialBtn = nil
	if skipTutorialGui and skipTutorialGui.Parent then
		skipTutorialGui:Destroy()
	end
	skipTutorialGui = nil
	local existing = playerGui:FindFirstChild(SKIP_TUTORIAL_GUI)
	if existing then
		existing:Destroy()
	end
end

local syncSkipTutorialBtn: () -> ()

local function skipEntireFingerTutorial()
	if fingerTutorialSkipped then
		return
	end
	fingerTutorialSkipped = true
	waitingWaveEnd = false
	wavesFingerDelayGen += 1
	tryWavesAgainGen += 1
	wavesFingerConsumed = true
	TutorialVo.stop()
	stopHint()
	playerGui:SetAttribute(HINT_ATTR, false)
	playerGui:SetAttribute(HUE_PLACE_ATTR, nil)
	playerGui:SetAttribute("OceanTD_TutorialHueResume", nil)
	playerGui:SetAttribute("OceanTD_TutorialGateBackpack", false)
	playerGui:SetAttribute("OceanTD_TutorialGateWaves", false)
	playerGui:SetAttribute("OceanTD_TutorialGateLeftHud", false)
	playerGui:SetAttribute("OceanTD_TutorialGateCam", false)
	playerGui:SetAttribute("OceanTD_TutorialWavesSlotReady", true)
	playerGui:SetAttribute("OceanTD_TutorialSummaryFinished", nil)
	playerGui:SetAttribute("OceanTD_TutorialRollThenSkills", nil)
	playerGui:SetAttribute("OceanTD_FingerTutorialLock", false)
	destroySkipTutorialBtn()
	-- Drop any leftover tutorial lock overlays on the cart, then refresh info/cart chrome.
	-- (Lock helpers are defined later; destroy by name here so skip works immediately.)
	task.defer(function()
		local left = playerGui:FindFirstChild("MobileLeftUI")
		local dPad = left and left:FindFirstChild("dPad")
		if dPad then
			for _, name in ipairs({ "CartIcon", "Cart", "CartBTN", "CartBtn", "Report", "ReefReport" }) do
				local cart = dPad:FindFirstChild(name)
				if cart then
					local ov = cart:FindFirstChild("_OceanTD_TutorialLeftLock")
					if ov then
						ov:Destroy()
					end
					local ic = cart:FindFirstChild("_OceanTD_TutorialLeftLockIcon")
					if ic then
						ic:Destroy()
					end
					-- Always force the cart click proxy live (never restore a saved Active=false).
					local function forceLive(btn: GuiButton)
						btn:SetAttribute("_OceanTD_TutorialLockActive", nil)
						btn:SetAttribute("_OceanTD_TutorialLockSelectable", nil)
						btn.Active = true
						pcall(function()
							(btn :: any).Interactable = true
						end)
					end
					if cart:IsA("GuiButton") then
						forceLive(cart)
					end
					for _, d in ipairs(cart:GetDescendants()) do
						if d:IsA("GuiButton") then
							forceLive(d)
						end
					end
				end
			end
		end
		playerGui:SetAttribute("OceanTD_SyncCartChrome", os.clock())
		-- Second pulse after backpack/left-HUD settle.
		task.delay(0.1, function()
			playerGui:SetAttribute("OceanTD_SyncCartChrome", os.clock())
		end)
	end)
end

local function ensureSkipTutorialBtn()
	if skipTutorialGui and skipTutorialGui.Parent and skipTutorialBtn and skipTutorialBtn.Parent then
		skipTutorialGui.Enabled = true
		skipTutorialBtn.Visible = true
		return
	end
	destroySkipTutorialBtn()

	local sg = Instance.new("ScreenGui")
	sg.Name = SKIP_TUTORIAL_GUI
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 8600
	sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	sg.Parent = playerGui

	local btn = Instance.new("TextButton")
	btn.Name = "Skip"
	btn.AnchorPoint = Vector2.new(0, 1)
	btn.Position = UDim2.new(0, 28, 1, -28)
	btn.Size = UDim2.fromOffset(SKIP_BTN_SIZE.X, SKIP_BTN_SIZE.Y)
	btn.BackgroundColor3 = SKIP_GREEN
	btn.Font = UiTheme.Font
	btn.Text = "SKIP"
	btn.TextColor3 = Color3.new(1, 1, 1)
	btn.TextScaled = true
	btn.AutoButtonColor = true
	btn.Selectable = true
	btn.Active = true
	btn.ZIndex = 3
	btn.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn
	local stroke = Instance.new("UIStroke")
	stroke.Name = "_OceanTD_SkipStroke"
	stroke.Color = SKIP_STROKE_BRIGHT
	stroke.Thickness = 2.5
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = btn
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.08, 0)
	pad.PaddingBottom = UDim.new(0.08, 0)
	pad.PaddingLeft = UDim.new(0.1, 0)
	pad.PaddingRight = UDim.new(0.1, 0)
	pad.Parent = btn

	local skipping = false
	local function flashThenSkip()
		if skipping then
			return
		end
		skipping = true
		btn.BackgroundColor3 = SKIP_STROKE_BRIGHT
		stroke.Color = Color3.new(1, 1, 1)
		task.delay(0.1, skipEntireFingerTutorial)
	end

	btn.Activated:Connect(flashThenSkip)
	btn.MouseButton1Click:Connect(flashThenSkip)

	skipTutorialGui = sg
	skipTutorialBtn = btn
end

syncSkipTutorialBtn = function()
	if fingerTutorialSkipped then
		playerGui:SetAttribute("OceanTD_FingerTutorialLock", false)
		destroySkipTutorialBtn()
		return
	end
	-- Only after join intro finishes (intro skip is gone).
	if playerGui:GetAttribute(JOIN_INTRO_BUSY_ATTR) == true then
		destroySkipTutorialBtn()
		-- Intro still busy: no finger tutorial yet — keep save unlocked.
		playerGui:SetAttribute("OceanTD_FingerTutorialLock", false)
		return
	end
	local active = isFingerTutorialActive()
	playerGui:SetAttribute("OceanTD_FingerTutorialLock", active)
	if active then
		ensureSkipTutorialBtn()
	else
		destroySkipTutorialBtn()
	end
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
	ensureBurstLayer(sg)

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
		return plotTapScreenPos()
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
		if not a then
			return nil
		end
		-- Belt-and-suspenders: never aim the tutorial finger off-screen.
		return clampFingerToViewport(guiCenterInsetInclusive(a))
	elseif mode == "waves" then
		local a = findWaveSlot()
		return if a and a.Visible and a.AbsoluteSize.X >= 2 then guiCenterInsetInclusive(a) else nil
	elseif mode == "skills" or mode == "closeSkills" then
		local a = findSkillsButton()
		return if a and a.Visible and a.AbsoluteSize.X >= 2 then guiCenterInsetInclusive(a) else nil
	elseif mode == "cam" then
		local a = findCamButton()
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
	if mode == "plot" then
		return base * PLOT_TRAVEL_MULT
	end
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
	elseif mode == "plot" then
		return plotCoralSlotRest(btn)
	elseif mode == "reselectCoral" then
		return Vector2.new(btn.X, btn.Y + PLOT_REST_DOWN_PX)
	elseif mode == "skills" or mode == "closeSkills" or mode == "cam" or mode == "roll" then
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
	elseif mode == "plot" then
		rerollPlotTapOffset()
		local id = InventoryState.getSelectedId() or SeedWheelRevealApi.lastAwardedItemId
		if typeof(id) == "string" and id ~= "" then
			InventoryState.revealItemInBackpack(id)
		end
	elseif mode == "waves" then
		waitingWaveEnd = true
		wavesFingerConsumed = false
		-- Safety: cam unlocks once they leave build mode for waves (if closeBackpack was skipped).
		if playerGui:GetAttribute("OceanTD_TutorialGateCam") == true then
			playerGui:SetAttribute("OceanTD_TutorialGateCam", false)
		end
	elseif mode == "skills" then
		-- Left HUD must be visible for the Skills button.
		if playerGui:GetAttribute("OceanTD_TutorialGateLeftHud") == true then
			playerGui:SetAttribute("OceanTD_TutorialGateLeftHud", false)
		end
		if playerGui:GetAttribute("OceanTD_TutorialGateCam") == true then
			playerGui:SetAttribute("OceanTD_TutorialGateCam", false)
		end
		playFingerSkillsSoundOnce()
	elseif mode == "cam" then
		playFingerCamSoundOnce()
	end
	-- closeSkills: wait for Skills open in the heartbeat (don't clear the hint early).

	local riseDur = travelSec(mode, RISE_SEC)
	local retreatDur = travelSec(mode, RETREAT_SEC)
	local holdDur = if mode == "hue" or mode == "hueReroll" then HUE_DEMO_HOLD_SEC else HOLD_SEC
	local isHueDemo = mode == "hue" or mode == "hueReroll"

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
			if mode == "plot" then
				-- New ground spot each approach (skip first rise — already rolled in startHint).
				if from ~= nil then
					rerollPlotTapOffset()
				end
				btn = resolveTarget(mode) or btn
			end
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

		-- Hue demo: stay on the swatch and keep painting until the player taps once.
		local lastHueAim: Vector2? = nil

		local function beginHuePress(btn: Vector2)
			local f = finger
			local sc = scaleObj
			if not (f and sc) then
				return
			end
			f.Position = UDim2.fromOffset(btn.X, btn.Y)
			phase = "pressIn"
			t0 = os.clock()
			sc.Scale = 1
			f.Rotation = baseRotDeg(mode)
		end

		local function onHueFakeTap()
			task.defer(function()
				if myGen ~= gen then
					return
				end
				CoralInspectPanel.tutorialDemoApplyHue()
			end)
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
				-- Skills fully closed after plot-size tutorial → point at camera cycle.
				playerGui:SetAttribute(HINT_ATTR, "cam")
				return
			elseif mode == "cam" then
				-- Cleared when the player changes cam mode (see CamCycleMode listener).
			end

			local hideChrome = uiHidesChrome()
			-- Skills/powerup open is expected for later tutorial steps.
			if mode == "plotSize" or mode == "plotSizeUpgrade" or mode == "closePlotSize" or mode == "closeSkills" or mode == "upgrade" or mode == "hue" or mode == "hueReroll" or mode == "cam" then
				hideChrome = playerGui:GetAttribute(REPORT_OPEN_ATTR) == true
					or playerGui:GetAttribute(HIDE_UI_ACTIVE_ATTR) == true
			elseif mode == "plot" or mode == "reselectCoral" then
				hideChrome = hideChrome
			elseif mode == "skills" then
				hideChrome = playerGui:GetAttribute(REPORT_OPEN_ATTR) == true
					or playerGui:GetAttribute(HIDE_UI_ACTIVE_ATTR) == true
					or playerGui:GetAttribute(POWERUP_OPEN_ATTR) == true
			end
			-- Plot grow shot: hide tutorial finger so the footprint is visible.
			if playerGui:GetAttribute("OceanTD_PlotSizeCinematicBusy") == true then
				hideChrome = true
			end

			if hideChrome then
				f.Visible = false
				-- Hue demo: don't abandon the cycle if chrome briefly hides.
				if not isHueDemo then
					laidOut = false
				end
				return
			end

			local resolved = resolveTarget(mode)
			local btn: Vector2
			if resolved then
				btn = resolved
				if isHueDemo then
					lastHueAim = resolved
				end
			elseif isHueDemo and laidOut and lastHueAim then
				-- Swatch can briefly vanish during paint refresh — keep last aim.
				btn = lastHueAim
			else
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
					spawnTapBurst(btn)
					if mode == "hue" or mode == "hueReroll" then
						onHueFakeTap()
					end
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
				if elapsed >= holdDur then
					if isHueDemo then
						-- Stay on the swatch: press again (keeps cycling colors until user taps).
						beginHuePress(btn)
					else
						beginRetreat(btn)
					end
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
		syncSkipTutorialBtn()
		return
	end
	local mode = parseMode(raw)
	if mode then
		if mode == "backpack" then
			-- First coral rolled → finger on BUILD: VO once.
			playPlantFirstCoralSoundOnce()
		end
		startHint(mode)
	else
		waitingWaveEnd = false
		stopHint()
	end
	syncSkipTutorialBtn()
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
		-- Closed backpack after hue tutorial → unlock cam cycle, wait for Slot5 pop, then point at Start Waves.
		playHowManyWavesSoundOnce()
		if playerGui:GetAttribute("OceanTD_TutorialGateCam") == true then
			playerGui:SetAttribute("OceanTD_TutorialGateCam", false)
		end
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
			-- After plot-size upgrade + closing skills, teach the cam cycle button.
			if playerGui:GetAttribute("OceanTD_TutorialGateCam") == true then
				playerGui:SetAttribute("OceanTD_TutorialGateCam", false)
			end
			playerGui:SetAttribute(HINT_ATTR, "cam")
		elseif v == "plotSize" or v == "plotSizeUpgrade" or v == "closePlotSize" then
			-- Closed skills without finishing the plot-size tutorial — back to Skills finger.
			playerGui:SetAttribute(HINT_ATTR, "skills")
		end
	end
end)

playerGui:GetAttributeChangedSignal("OceanTD_CamCycleMode"):Connect(function()
	if playerGui:GetAttribute(HINT_ATTR) == "cam" then
		playerGui:SetAttribute(HINT_ATTR, false)
		onCamButtonClickedForTryWaves()
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
	if playerGui:GetAttribute("OceanTD_TutorialGateCam") == true then
		playerGui:SetAttribute("OceanTD_TutorialGateCam", false)
	end
	-- First loss: point at roll again so they grab more corals, then skills.
	-- First win (or non-defeat summary): go straight to skills.
	local wasDefeat = playerGui:GetAttribute("OceanTD_TutorialSummaryWasDefeat") == true
	playerGui:SetAttribute("OceanTD_TutorialSummaryWasDefeat", nil)
	if wasDefeat then
		playerGui:SetAttribute("OceanTD_TutorialRollThenSkills", true)
		-- Keep LeftHud gated so Skills stays locked until they start a roll.
		playerGui:SetAttribute(HINT_ATTR, "roll")
		return
	end
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
	-- Cart / info stays usable (build mode → reef report). Do not lock it.
}

-- Camera cycle icons — locked until build mode closes after the first coral hue.
-- dPadIcon (center decor) stays unlocked/visible; only the four mode buttons lock.
local LEFT_CAM_LOCK_BTN: { [string]: boolean } = {
	FreeCam = true,
	PlotCam = true,
	FishCam = true,
	OffCam = true,
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

local SAND_DOLLAR_HIDDEN_ATTR = "_OceanTD_HiddenForSkillsLock"

local function setSandDollarChromeVisible(left: Instance, visible: boolean)
	local targets: { GuiObject } = {}
	local dCount = LeftHudLayout.findDCount(left)
	local dLabel = LeftHudLayout.findDLabel(left)
	if dCount then
		table.insert(targets, dCount)
	end
	if dLabel then
		table.insert(targets, dLabel)
	end
	local row = left:FindFirstChild(LeftHudLayout.ROW_NAME)
	if row and row:IsA("GuiObject") then
		table.insert(targets, row)
	end
	for _, gui in ipairs(targets) do
		if not visible then
			if gui.Visible or gui:GetAttribute(SAND_DOLLAR_HIDDEN_ATTR) == true then
				gui:SetAttribute(SAND_DOLLAR_HIDDEN_ATTR, true)
				gui.Visible = false
			end
		elseif gui:GetAttribute(SAND_DOLLAR_HIDDEN_ATTR) == true then
			gui:SetAttribute(SAND_DOLLAR_HIDDEN_ATTR, nil)
			gui.Visible = true
		end
	end
end

local function applyLeftHudGate()
	local gate = playerGui:GetAttribute("OceanTD_TutorialGateLeftHud") == true
	local gateCam = playerGui:GetAttribute("OceanTD_TutorialGateCam") == true
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
	-- $D / $DCount stay hidden while Skills is tutorial-locked.
	local skillsLocked = gate and not skillsOpen
	setSandDollarChromeVisible(left, not skillsLocked)
	local dPad = left:FindFirstChild("dPad")
	if not (dPad and dPad:IsA("GuiObject")) then
		return
	end
	dPad.Visible = true
	-- Center dPadIcon is decor only — never show the tutorial lock over it.
	local mid = dPad:FindFirstChild("dPadIcon")
	if mid and mid:IsA("GuiObject") then
		clearTutorialLockOn(mid)
	end
	for _, ch in ipairs(dPad:GetChildren()) do
		if not ch:IsA("GuiObject") then
			continue
		end
		local lockHud = LEFT_HUD_LOCK_BTN[ch.Name] == true
		local lockCam = LEFT_CAM_LOCK_BTN[ch.Name] == true
		if not lockHud and not lockCam then
			continue
		end
		local shouldLock = false
		if lockHud then
			-- Skills close must stay usable while bubbles are open (WaveSpeed/Skip ForceOpen).
			shouldLock = gate and not (skillsOpen and ch.Name == "Skills")
		elseif lockCam then
			shouldLock = gateCam
		end
		if shouldLock then
			ensureTutorialLockOn(ch)
		else
			clearTutorialLockOn(ch)
		end
	end
end

playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateLeftHud"):Connect(applyLeftHudGate)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateCam"):Connect(applyLeftHudGate)
playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(applyLeftHudGate)
playerGui.ChildAdded:Connect(function(ch)
	if ch.Name == "MobileLeftUI" then
		task.defer(applyLeftHudGate)
		ch.ChildAdded:Connect(function()
			if playerGui:GetAttribute("OceanTD_TutorialGateLeftHud") == true
				or playerGui:GetAttribute("OceanTD_TutorialGateCam") == true
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
				or playerGui:GetAttribute("OceanTD_TutorialGateCam") == true
				or playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true
			then
				task.defer(applyLeftHudGate)
			end
		end)
	end
end
task.defer(applyLeftHudGate)

applyAttr(playerGui:GetAttribute(HINT_ATTR))

-- First real Start Waves: wave explainer VO (waits if "how many waves" is still playing).
WaveSim.onHud(function(snap)
	if WaveSim.isJoinIntroDemo() then
		return
	end
	if snap.running and not wavesHudWasRunning then
		wavesHudWasRunning = true
		if (snap.wave or 0) <= 1 then
			playWaveExplainerSoundOnce()
		end
	elseif not snap.running then
		wavesHudWasRunning = false
	end
end)

playerGui:GetAttributeChangedSignal(JOIN_INTRO_BUSY_ATTR):Connect(syncSkipTutorialBtn)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateBackpack"):Connect(syncSkipTutorialBtn)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateWaves"):Connect(syncSkipTutorialBtn)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateLeftHud"):Connect(syncSkipTutorialBtn)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateCam"):Connect(syncSkipTutorialBtn)
task.defer(syncSkipTutorialBtn)
