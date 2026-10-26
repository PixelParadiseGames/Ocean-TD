--!strict
--[[
	Join-intro finger tutorial pipeline (two chapters):

	Auto Plant chapter (first):
	  roll → await (+ Auto Plant HUD intro center→dock) → seed spin → auto-plant
	  → waves
	  → (after first wave-session Finish) if defeat: roll again → skills; if win: skills
	  → plotSize → plotSizeUpgrade → closePlotSize → otherSkillsExplainer → closeSkills

	Manual Plant chapter (after closeSkills):
	  roll → await → backpack → selectCoral → relocateDrag → relocateConfirm
	  → equip → plot → upgrade → hue → plant → closeBackpack → cam
	  (reselectCoral if inspect closes mid-upgrade / mid-hue)

	After join intro ends (Skip Intro gone): bottom-left Skip Training clears all finger steps + tutorial gates.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local UiViewportTags = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiViewportTags"))
local UiPopupScale = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiPopupScale"))
local UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme"))
local LeftHudLayout = require(oceanRoot:WaitForChild("Shared"):WaitForChild("LeftHudLayout"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local SeedWheelRevealApi = require(script.Parent:WaitForChild("SeedWheelRevealApi"))
local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
local WaveSlotSummary = require(script.Parent:WaitForChild("WaveSlotSummary"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))
local SkillsBubbleSim = require(script.Parent:WaitForChild("SkillsBubbleSim"))
local CoralInspectPanel = require(script.Parent:WaitForChild("CoralInspectPanel"))
local PlacementController = require(script.Parent:WaitForChild("PlacementController"))
local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
local RelocatePickHover = require(script.Parent:WaitForChild("RelocatePickHover"))
local PlacedCoralIndex = require(script.Parent:WaitForChild("PlacedCoralIndex"))

local HINT_ATTR = "OceanTD_RollFingerHint"
local CHAPTER_ATTR = "OceanTD_TutorialChapter" -- "autoPlant" | "manualPlant"
local AUTO_PLANT_DONE_ATTR = "OceanTD_TutorialAutoPlantDone"
local HUE_PLACE_ATTR = "OceanTD_TutorialHuePlaceId"
local OTHER_SKILLS_EXPLAINER_ATTR = "OceanTD_OtherSkillsExplainerBusy"
local GUI_NAME = "OceanTD_RollFingerHint"
local FINGER_PATH = "Plots.IntroElements.Finger"
local PLANT_FIRST_CORAL_SOUND_ID = "rbxassetid://139678980175457"
local HOW_MANY_WAVES_SOUND_ID = "rbxassetid://135876579370482"
local WAVE_EXPLAINER_SOUND_ID = "rbxassetid://72069463774995"
local FINGER_CAM_SOUND_ID = "rbxassetid://80359058869110" -- legacy; wave-3 / free-cam use dedicated clips
local FISH_CAM_VO_ID = "rbxassetid://116779253231128"
local FREE_CAM_VO_ID = "rbxassetid://100197872909244"
local FINGER_SKILLS_SOUND_ID = "rbxassetid://125491130885745"
local TRY_WAVES_AGAIN_SOUND_ID = "rbxassetid://107210999893937"
local UPGRADE_EXPLAINER_VO_ID = "rbxassetid://83510865258719"
local HUE_EXPLAINER_VO_ID = "rbxassetid://107456758453409"
local AUTO_PLANT_EXPLAINER_VO_ID = "rbxassetid://108713452088272"
local MORE_UPGRADES_EXPLAINER_VO_ID = "rbxassetid://135424394390803"
local ROLL_AGAIN_MANUAL_PLANT_VO_ID = "rbxassetid://136401393424131"
local MOVE_CORAL_EXPLAINER_VO_ID = "rbxassetid://114674116035117"
local SMARTER_THAN_GUPPY_VO_ID = "rbxassetid://87436646085490"
local TRY_WAVES_AGAIN_DELAY_SEC = 3
local TutorialVo = require(script.Parent:WaitForChild("TutorialVo"))
local WaveArrowPreview = require(script.Parent:WaitForChild("WaveArrowPreview"))

local SKILLS_OPEN_ATTR = "OceanTD_SkillsBubblesOpen"
local POWERUP_OPEN_ATTR = "OceanTD_SkillPowerUpOpen"
local REPORT_OPEN_ATTR = "OceanTD_ReefReportOpen"
local HIDE_UI_ACTIVE_ATTR = "OceanTD_HideUiActive"
-- PlotSizeCinematic sets these while ForceClose tears down skills for the grow/dial shot.
local PLOT_SIZE_CINE_BUSY_ATTR = "OceanTD_PlotSizeCinematicBusy"
local PLOT_SIZE_CINE_SUPPRESS_ATTR = "OceanTD_PlotSizeCineSuppressTutorial"

local function plotSizeCineBlocksTutorialAdvance(): boolean
	return playerGui:GetAttribute(PLOT_SIZE_CINE_BUSY_ATTR) == true
		or playerGui:GetAttribute(PLOT_SIZE_CINE_SUPPRESS_ATTR) == true
end

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
local TOP_REST_Y_FRAC = 0.12 -- top-center rest (plant finger retreat)
-- First coral upgrade: approach from bottom-right → UNLOCK; retreat to bottom-left.
local UPGRADE_REST_Y_FRAC = 0.94
local UPGRADE_APPROACH_X_FRAC = 0.94 -- rise from BR
local UPGRADE_RETREAT_X_FRAC = 0.06 -- leave toward BL
local UPGRADE_AIM_UP_PX = 36 -- tip sits higher on the unlock button (not below screen)
-- Above OceanTD_CoralSizeConfirm (25000) so the finger isn't buried under the popup.
local FINGER_DISPLAY_ORDER = 26000
local ARC_X_PX = 42
local ARC_Y_PX = 18
local TIP_ANCHOR = Vector2.new(0.32, 0.12)

export type HintMode =
	"roll"
	| "backpack"
	| "selectCoral"
	| "relocateDrag"
	| "relocateConfirm"
	| "equip"
	| "plot"
	| "upgrade"
	| "hue"
	| "hueReroll"
	| "reselectCoral"
	| "plant"
	| "closeBackpack"
	| "autoPlantWait"
	| "waves"
	| "skills"
	| "plotSize"
	| "plotSizeUpgrade"
	| "closePlotSize"
	| "otherSkillsExplainer"
	| "closeSkills"
	| "cam"

local MODE_SET: { [string]: boolean } = {
	roll = true,
	backpack = true,
	selectCoral = true,
	relocateDrag = true,
	relocateConfirm = true,
	equip = true,
	plot = true,
	upgrade = true,
	hue = true,
	hueReroll = true,
	reselectCoral = true,
	plant = true,
	closeBackpack = true,
	autoPlantWait = true,
	waves = true,
	skills = true,
	plotSize = true,
	plotSizeUpgrade = true,
	closePlotSize = true,
	otherSkillsExplainer = true,
	closeSkills = true,
	cam = true,
}

-- Manual-plant relocate teach: shrink to 75%, slide ±10% viewport width, rest 1s.
local RELOCATE_DRAG_SCALE = 0.75
local RELOCATE_SLIDE_FRAC = 0.10
local RELOCATE_SLIDE_SEC = 0.4
local RELOCATE_APPROACH_SEC = 0.55
local RELOCATE_RECOVER_SEC = 0.35
local RELOCATE_REST_SEC = 1
local RELOCATE_BELOW_PX = 140
local selectCoralPlaceId: string? = nil
local relocateTeachMoved = false

local SLOW_TRAVEL_MODES: { [string]: boolean } = {
	backpack = true,
	selectCoral = true,
	relocateConfirm = true,
	upgrade = true,
	hue = true,
	hueReroll = true,
	plant = true,
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
local skillsFingerAfterVoGen = 0
local autoPlantWavesArmed = false
local tapBurstRng = Random.new()
local fingerTutorialSkipped = false
local skipTutorialGui: ScreenGui? = nil
local skipTutorialBtn: TextButton? = nil
local plantFirstCoralSoundPlayed = false
local howManyWavesSoundPlayed = false
local waveExplainerSoundPlayed = false
local upgradeExplainerVoPlayed = false
local hueExplainerVoPlayed = false
local autoPlantExplainerVoPlayed = false
local moreUpgradesExplainerVoPlayed = false
local rollAgainManualPlantVoPlayed = false
local moveCoralExplainerVoPlayed = false
local smarterThanGuppyVoPlayed = false
local fingerCamSoundPlayed = false -- legacy shared; wave-3 / free-cam use flags below
local fishCamVoPlayed = false
local freeCamVoPlayed = false
local fingerSkillsSoundPlayed = false
local tryWavesAgainSoundPlayed = false
local tryWavesAgainGen = 0
local camVoFinished = false
-- Manual-plant Free Cam teach: point at Start Waves only after that VO finishes.
local pendingStartWavesFinger = false
local camButtonClicked = false
local wavesHudWasRunning = false
local lastHintAttr: any = nil
local JOIN_INTRO_BUSY_ATTR = "OceanTD_JoinIntroBusy"
local SKIP_TUTORIAL_GUI = "OceanTD_FingerTutorialSkip"
local SKIP_BLUE = Color3.fromRGB(55, 160, 230) -- gradient top
local SKIP_BLUE_DARK = Color3.fromRGB(16, 48, 96) -- gradient bottom
local SKIP_STROKE_BRIGHT = Color3.fromRGB(110, 200, 255)
local SKIP_BTN_SIZE = Vector2.new(132, 28)

local function playPlantFirstCoralSoundOnce()
	if plantFirstCoralSoundPlayed or fingerTutorialSkipped then
		return
	end
	plantFirstCoralSoundPlayed = true
	-- After coral move in manual plant; queue if Move Coral explainer is still speaking.
	TutorialVo.playWhenIdle(PLANT_FIRST_CORAL_SOUND_ID, "OceanTD_PlantFirstCoral")
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
		-- Never cut a priority line (out of reef health) or other active VO.
		-- Finger to Start Waves waits until this clip (and anything queued ahead of it) ends.
		TutorialVo.playWhenIdle(TRY_WAVES_AGAIN_SOUND_ID, "OceanTD_TryWavesAgain", {
			volume = 4,
			onEnded = function()
				if not pendingStartWavesFinger or fingerTutorialSkipped then
					return
				end
				pendingStartWavesFinger = false
				local running = false
				pcall(function()
					running = require(script.Parent:WaitForChild("WaveSim")).isRunning()
				end)
				if running then
					return
				end
				wavesFingerConsumed = false
				playerGui:SetAttribute("OceanTD_TutorialLockStartWaves", false)
				playerGui:SetAttribute(HINT_ATTR, "waves")
			end,
		})
	end)
end

local function playFingerCamSoundOnce()
	if fingerTutorialSkipped then
		camVoFinished = true
		return
	end
	-- Wave 3: Fish Cam teach (during waves).
	if playerGui:GetAttribute("OceanTD_Wave3FishCamHint") == true then
		if fishCamVoPlayed then
			camVoFinished = true
			return
		end
		fishCamVoPlayed = true
		fingerCamSoundPlayed = true
		camVoFinished = false
		TutorialVo.play(FISH_CAM_VO_ID, "OceanTD_FishCam", {
			volume = 4,
			onEnded = function()
				camVoFinished = true
			end,
		})
		return
	end
	-- Manual plant: Free Cam teach after backpack close — wait for guppy VO.
	if freeCamVoPlayed then
		camVoFinished = true
		tryScheduleTryWavesAgain()
		return
	end
	freeCamVoPlayed = true
	fingerCamSoundPlayed = true
	camVoFinished = false
	TutorialVo.playWhenIdle(FREE_CAM_VO_ID, "OceanTD_FreeCam", {
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
	-- Skills button click: speak now. Override so a leftover clip can't swallow it.
	TutorialVo.playOverride(FINGER_SKILLS_SOUND_ID, "OceanTD_FingerSkills", { volume = 4 })
end

-- True while the skills-finger teach step is active (or just advanced by heartbeat).
local function skillsTeachStepActive(): boolean
	local v = playerGui:GetAttribute(HINT_ATTR)
	return v == "skills" or (v == "plotSize" and not fingerSkillsSoundPlayed)
end

local function onSkillsOpenedForTutorial()
	if fingerTutorialSkipped or fingerSkillsSoundPlayed then
		return
	end
	local v = playerGui:GetAttribute(HINT_ATTR)
	-- Accept "skills", or "plotSize" if heartbeat advanced before VO could fire.
	if v ~= "skills" and v ~= "plotSize" then
		return
	end
	playFingerSkillsSoundOnce()
	if playerGui:GetAttribute(HINT_ATTR) == "skills" then
		playerGui:SetAttribute(HINT_ATTR, "plotSize")
	end
end

local function playUpgradeExplainerOnce()
	if upgradeExplainerVoPlayed or fingerTutorialSkipped then
		return
	end
	upgradeExplainerVoPlayed = true
	-- After first plant → upgrade finger; wait if another VO is still speaking.
	TutorialVo.playWhenIdle(UPGRADE_EXPLAINER_VO_ID, "OceanTD_UpgradeExplainer")
end

local function playHueExplainerOnce()
	if hueExplainerVoPlayed or fingerTutorialSkipped then
		return
	end
	hueExplainerVoPlayed = true
	-- After first upgrade → hue finger; waits until upgrade explainer finishes.
	TutorialVo.playWhenIdle(HUE_EXPLAINER_VO_ID, "OceanTD_HueExplainer")
end

local function playAutoPlantExplainerOnce()
	if autoPlantExplainerVoPlayed or fingerTutorialSkipped then
		return
	end
	autoPlantExplainerVoPlayed = true
	TutorialVo.playWhenIdle(AUTO_PLANT_EXPLAINER_VO_ID, "OceanTD_AutoPlantExplainer")
end

local function playMoreUpgradesExplainerOnce()
	if moreUpgradesExplainerVoPlayed or fingerTutorialSkipped then
		return
	end
	moreUpgradesExplainerVoPlayed = true
	TutorialVo.playWhenIdle(MORE_UPGRADES_EXPLAINER_VO_ID, "OceanTD_MoreUpgradesExplainer")
end

local function playRollAgainManualPlantOnce()
	if rollAgainManualPlantVoPlayed or fingerTutorialSkipped then
		return
	end
	rollAgainManualPlantVoPlayed = true
	TutorialVo.playWhenIdle(ROLL_AGAIN_MANUAL_PLANT_VO_ID, "OceanTD_RollAgainManualPlant")
end

local function playMoveCoralExplainerOnce()
	if moveCoralExplainerVoPlayed or fingerTutorialSkipped then
		return
	end
	moveCoralExplainerVoPlayed = true
	TutorialVo.playWhenIdle(MOVE_CORAL_EXPLAINER_VO_ID, "OceanTD_MoveCoralExplainer")
end

local function playSmarterThanGuppyOnce()
	if smarterThanGuppyVoPlayed or fingerTutorialSkipped then
		return
	end
	smarterThanGuppyVoPlayed = true
	-- After hue change + hue explainer finishes.
	TutorialVo.playWhenIdle(SMARTER_THAN_GUPPY_VO_ID, "OceanTD_SmarterThanGuppy")
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

local function findUpgradeUnlockButton(): GuiObject?
	-- Prefer the size-confirm UNLOCK (tutorial opens that panel when needed).
	local unlock = CoralInspectPanel.getTutorialUnlockButton()
	if unlock then
		return unlock
	end
	local sg = playerGui:FindFirstChild("OceanTD_CoralSizeConfirm")
	if sg then
		local btn = sg:FindFirstChild("UNLOCK", true)
		if btn and btn:IsA("GuiObject") and btn.Visible and btn.AbsoluteSize.X >= 2 then
			return btn
		end
	end
	return nil
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

local function coralScreenCenterForPlaceId(placeId: string): Vector2?
	local part = RelocatePickHover.findByPlaceId(placeId)
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

local function ensureMidPlotCoralPlaceId(): string?
	if typeof(selectCoralPlaceId) == "string" and selectCoralPlaceId ~= "" then
		if RelocatePickHover.findByPlaceId(selectCoralPlaceId) then
			return selectCoralPlaceId
		end
	end
	local plot = ClientPlot.get()
	if not plot then
		return nil
	end
	local parts = PlacedCoralIndex.getParts(plot.plotId)
	local center = plot.cframe.Position
	local best: BasePart? = nil
	local bestD = math.huge
	for _, part in ipairs(parts) do
		local dx = part.Position.X - center.X
		local dz = part.Position.Z - center.Z
		local d = dx * dx + dz * dz
		if d < bestD then
			bestD = d
			best = part
		end
	end
	if not best then
		return nil
	end
	local pid = best:GetAttribute("OceanTD_PlaceId")
	if typeof(pid) ~= "string" or pid == "" then
		return nil
	end
	selectCoralPlaceId = pid
	return pid
end

-- Manual plant: pan Plot Cam so the teach coral (and finger) sit on-screen.
local function focusPlotCamOnSelectCoral()
	local pid = ensureMidPlotCoralPlaceId()
	if not pid then
		return
	end
	local part = RelocatePickHover.findByPlaceId(pid)
	if not part then
		return
	end
	local worldPos = part.Position
	task.spawn(function()
		if playerGui:GetAttribute("OceanTD_CamCycleMode") ~= "plotcam" then
			playerGui:SetAttribute("OceanTD_ForceCamMode", "plotcam")
			playerGui:SetAttribute("OceanTD_ForceCamStamp", os.clock())
		end
		playerGui:SetAttribute("OceanTD_EnsurePlotCam", os.clock())
		local deadline = os.clock() + 1.5
		while os.clock() < deadline do
			local ok, PlotCam2 = pcall(function()
				return require(script.Parent:WaitForChild("PlotCam2"))
			end)
			if ok and typeof(PlotCam2) == "table" and PlotCam2.isActive and PlotCam2.isActive() then
				if PlotCam2.focusWorldPoint then
					PlotCam2.focusWorldPoint(worldPos)
				end
				-- Snap the Scriptable lens to the new focus this frame.
				playerGui:SetAttribute("OceanTD_EnsurePlotCam", os.clock())
				return
			end
			task.wait()
		end
	end)
end

local function midPlotCoralScreenCenter(): Vector2?
	local pid = ensureMidPlotCoralPlaceId()
	if not pid then
		return nil
	end
	return coralScreenCenterForPlaceId(pid)
end

local function relocateMoveDiscScreenCenter(): Vector2?
	-- guiPosFromWorld / WorldToViewport — same space as selectCoral (not Billboard AbsolutePosition).
	local c = RelocateController.getMoveHandleScreenCenter()
	if not c or (c.X < 12 and c.Y < 12) then
		return nil
	end
	return clampFingerToViewport(c)
end

local function relocateConfirmScreenCenter(): Vector2?
	local c = RelocateController.getConfirmScreenCenter()
	if not c or (c.X < 12 and c.Y < 12) then
		return nil
	end
	return clampFingerToViewport(c)
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

local function viewportTopCenter(): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return Vector2.new(vp.X * 0.5, vp.Y * TOP_REST_Y_FRAC)
end

local function viewportBottomRight(): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return Vector2.new(vp.X * UPGRADE_APPROACH_X_FRAC, vp.Y * UPGRADE_REST_Y_FRAC)
end

local function viewportBottomLeft(): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	return Vector2.new(vp.X * UPGRADE_RETREAT_X_FRAC, vp.Y * UPGRADE_REST_Y_FRAC)
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
	if playerGui:GetAttribute("OceanTD_TutorialGateFreeCam") == true then
		return true
	end
	if playerGui:GetAttribute("OceanTD_TutorialGateShop") == true then
		return true
	end
	return false
end

local function destroySkipTutorialBtn()
	if skipTutorialBtn and GuiService.SelectedObject == skipTutorialBtn then
		GuiService.SelectedObject = nil
	end
	skipTutorialBtn = nil
	game:GetService("ContextActionService"):UnbindAction("OceanTD_SkipTrainingR1")
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
	autoPlantWavesArmed = false
	TutorialVo.stop()
	stopHint()
	playerGui:SetAttribute("OceanTD_FingerTutorialSkipped", true)
	playerGui:SetAttribute(HINT_ATTR, false)
	playerGui:SetAttribute(HUE_PLACE_ATTR, nil)
	playerGui:SetAttribute("OceanTD_TutorialHueResume", nil)
	playerGui:SetAttribute("OceanTD_TutorialGateBackpack", false)
	playerGui:SetAttribute("OceanTD_TutorialGateWaves", false)
	playerGui:SetAttribute("OceanTD_TutorialLockStartWaves", false)
	playerGui:SetAttribute("OceanTD_TutorialGateLeftHud", false)
	playerGui:SetAttribute("OceanTD_TutorialGateCam", false)
	playerGui:SetAttribute("OceanTD_TutorialGateFreeCam", false)
	playerGui:SetAttribute("OceanTD_TutorialGateShop", false)
	playerGui:SetAttribute("OceanTD_TutorialWavesSlotReady", true)
	playerGui:SetAttribute("OceanTD_TutorialSummaryFinished", nil)
	playerGui:SetAttribute("OceanTD_TutorialRollThenSkills", nil)
	playerGui:SetAttribute("OceanTD_FingerTutorialLock", false)
	playerGui:SetAttribute(OTHER_SKILLS_EXPLAINER_ATTR, false)
	playerGui:SetAttribute(CHAPTER_ATTR, nil)
	playerGui:SetAttribute(AUTO_PLANT_DONE_ATTR, nil)
	selectCoralPlaceId = nil
	relocateTeachMoved = false
	skillsFingerAfterVoGen += 1
	pcall(function()
		SkillsBubbleSim.cancelOtherSkillsExplainer()
	end)
	if playerGui:GetAttribute("OceanTD_Wave3FishCamHint") == true then
		playerGui:SetAttribute("OceanTD_Wave3FishCamHint", nil)
	end
	if playerGui:GetAttribute("OceanTD_Wave3CamHoldPause") == true then
		playerGui:SetAttribute("OceanTD_Wave3CamHoldPause", nil)
		pcall(function()
			require(script.Parent:WaitForChild("WaveSim")).setCinematicPaused(false)
		end)
	end
	pcall(function()
		require(script.Parent:WaitForChild("AutoPlantHudSlot")).setForcedHidden(false)
	end)
	-- Gates clear while the player is often still on the plot edge — suppress outline tip briefly.
	playerGui:SetAttribute("OceanTD_SuppressPlotOutlineHintUntil", os.clock() + 6)
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
	btn.Name = "SkipTraining"
	btn.AnchorPoint = Vector2.new(0, 1)
	btn.Position = UDim2.new(0, 28, 1, -28)
	btn.Size = UDim2.fromOffset(SKIP_BTN_SIZE.X, SKIP_BTN_SIZE.Y)
	-- White base so UIGradient blues read true (top bright → bottom dark).
	btn.BackgroundColor3 = Color3.new(1, 1, 1)
	btn.BorderSizePixel = 0
	btn.Text = ""
	btn.AutoButtonColor = true
	btn.Selectable = true
	btn.Active = true
	btn.ZIndex = 3
	btn.ClipsDescendants = false
	btn.Parent = sg
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = btn
	local grad = Instance.new("UIGradient")
	grad.Name = "_OceanTD_SkipGrad"
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, SKIP_BLUE),
		ColorSequenceKeypoint.new(1, SKIP_BLUE_DARK),
	})
	grad.Rotation = 90
	grad.Parent = btn
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
	local lbl = Instance.new("TextLabel")
	lbl.Name = "Label"
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = UiTheme.Font
	lbl.Text = "Skip Training"
	lbl.TextColor3 = Color3.new(1, 1, 1)
	lbl.TextScaled = true
	lbl.ZIndex = 4
	lbl.Active = false
	lbl.Parent = btn
	UiPopupScale.attachHud(btn)

	-- 720p+: sit between the lifted $D count and the reef bar. Phone stays on the corner.
	local function layoutSkipTraining()
		local cam = Workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		if UiViewportTags.is720p(vp) then
			local scale = UiPopupScale.getHud()
			local reefTop = 10 + 26 * scale
			local bottom = math.floor(reefTop + 16 + 0.5)
			btn.Position = UDim2.new(0, 28, 1, -bottom)
		else
			btn.Position = UDim2.new(0, 28, 1, -28)
		end
	end
	layoutSkipTraining()
	local skipLayoutConn: RBXScriptConnection? = nil
	local function bindSkipLayout(cam: Camera)
		if skipLayoutConn then
			skipLayoutConn:Disconnect()
		end
		skipLayoutConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(layoutSkipTraining)
	end
	local liveCam = Workspace.CurrentCamera
	if liveCam then
		bindSkipLayout(liveCam)
	end
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		layoutSkipTraining()
		local nextCam = Workspace.CurrentCamera
		if nextCam then
			bindSkipLayout(nextCam)
		end
	end)

	local r1Tip = Instance.new("TextLabel")
	r1Tip.Name = "_OceanTD_SkipR1Glyph"
	r1Tip.AnchorPoint = Vector2.new(0, 1)
	r1Tip.Position = UDim2.new(1, 8, 0, -4)
	r1Tip.Size = UDim2.fromOffset(36, 26)
	r1Tip.BackgroundColor3 = Color3.fromRGB(200, 45, 50)
	r1Tip.BorderSizePixel = 0
	r1Tip.Font = Enum.Font.GothamBold
	r1Tip.Text = "R1"
	r1Tip.TextColor3 = Color3.new(1, 1, 1)
	r1Tip.TextScaled = true
	r1Tip.ZIndex = btn.ZIndex + 6
	r1Tip.Active = false
	r1Tip.Visible = false
	r1Tip.Parent = btn
	local r1Corner = Instance.new("UICorner")
	r1Corner.CornerRadius = UDim.new(1, 0)
	r1Corner.Parent = r1Tip
	local r1Pad = Instance.new("UIPadding")
	r1Pad.PaddingTop = UDim.new(0.12, 0)
	r1Pad.PaddingBottom = UDim.new(0.12, 0)
	r1Pad.PaddingLeft = UDim.new(0.08, 0)
	r1Pad.PaddingRight = UDim.new(0.08, 0)
	r1Pad.Parent = r1Tip

	local function skipTrainingR1Ready(): boolean
		if not btn.Parent or not btn.Visible then
			return false
		end
		if WaveSim.isRunning() or InventoryState.isOpen() then
			return false
		end
		if PlacementController.isActive() or RelocateController.isActive() then
			return false
		end
		if InventoryState.isSettingsOpen() then
			return false
		end
		return true
	end

	local glyphConn: RBXScriptConnection
	glyphConn = RunService.Heartbeat:Connect(function()
		if not btn.Parent then
			glyphConn:Disconnect()
			return
		end
		local t = UserInputService:GetLastInputType()
		local pad = t == Enum.UserInputType.Gamepad1
			or t == Enum.UserInputType.Gamepad2
			or t == Enum.UserInputType.Gamepad3
			or t == Enum.UserInputType.Gamepad4
		r1Tip.Visible = pad and skipTrainingR1Ready()
	end)

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
	game:GetService("ContextActionService"):BindActionAtPriority("OceanTD_SkipTrainingR1", function(_name, state)
		if state ~= Enum.UserInputState.Begin or not skipTrainingR1Ready() then
			return Enum.ContextActionResult.Pass
		end
		flashThenSkip()
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 5, Enum.KeyCode.ButtonR1)

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
	local fingerPx = math.max(1, math.floor(FINGER_PX * UiPopupScale.getHud() + 0.5))
	if gui and finger and finger.Parent then
		gui.DisplayOrder = FINGER_DISPLAY_ORDER
		finger.Image = imageId
		finger.Size = UDim2.fromOffset(fingerPx, fingerPx)
		return finger
	end
	destroyGui()

	local sg = Instance.new("ScreenGui")
	sg.Name = GUI_NAME
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = FINGER_DISPLAY_ORDER
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
	img.Size = UDim2.fromOffset(fingerPx, fingerPx)
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
	elseif mode == "selectCoral" then
		return midPlotCoralScreenCenter() or plotScreenCenter()
	elseif mode == "relocateDrag" then
		-- Always the taught/selected coral — never fall back to a different mid-plot pick.
		local disc = relocateMoveDiscScreenCenter()
		if disc then
			return disc
		end
		if typeof(selectCoralPlaceId) == "string" and selectCoralPlaceId ~= "" then
			return coralScreenCenterForPlaceId(selectCoralPlaceId)
		end
		return nil
	elseif mode == "relocateConfirm" then
		return relocateConfirmScreenCenter()
	elseif mode == "plot" then
		return plotTapScreenPos()
	elseif mode == "reselectCoral" then
		return tutorialHueCoralScreenCenter() or plotScreenCenter()
	elseif mode == "upgrade" then
		-- Prefer UNLOCK only after the player opened the confirm; otherwise aim at UPGRADE.
		-- Re-open inspect on the planted tutorial coral if place→relocate raced.
		CoralInspectPanel.ensureTutorialUpgradeTarget()
		local a = findUpgradeUnlockButton() or CoralInspectPanel.getTutorialUpgradeButton()
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
	elseif mode == "plant" then
		-- Billboard AbsolutePosition X is unreliable — use world project + chrome offset.
		local c = PlacementController.getPlantConfirmScreenCenter()
		return if c then clampFingerToViewport(c) else nil
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
	if mode == "plant" then
		return viewportTopCenter()
	end
	if mode == "plotSize" or mode == "plotSizeUpgrade" or mode == "hue" or mode == "hueReroll" then
		return viewportBottomCenter()
	end
	if mode == "upgrade" then
		-- Retreat / idle park: bottom-left (rise still starts from bottom-right).
		return viewportBottomLeft()
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
	elseif mode == "selectCoral" or mode == "reselectCoral" then
		return Vector2.new(btn.X, btn.Y + PLOT_REST_DOWN_PX)
	elseif mode == "relocateConfirm" then
		return Vector2.new(btn.X, btn.Y + BELOW_PAD_PX)
	elseif mode == "skills" or mode == "closeSkills" or mode == "cam" or mode == "roll" then
		return btn:Lerp(viewportCenter(), WAVE_REST_TOWARD_CENTER)
	end
	return Vector2.new(btn.X, btn.Y + BELOW_PAD_PX)
end

local function beginWavesAfterCloseBackpack()
	-- After Auto Plant chapter (or legacy close-backpack) → Slot5 / waves finger.
	if autoPlantWavesArmed and playerGui:GetAttribute(CHAPTER_ATTR) == "autoPlant" then
		return
	end
	if playerGui:GetAttribute(CHAPTER_ATTR) == "autoPlant" then
		autoPlantWavesArmed = true
	end
	playHowManyWavesSoundOnce()
	if playerGui:GetAttribute("OceanTD_TutorialGateWaves") == true then
		playerGui:SetAttribute("OceanTD_TutorialGateWaves", false)
	end
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
		if cur == false or cur == nil or cur == "await" or cur == "autoPlantWait" then
			playerGui:SetAttribute(HINT_ATTR, "waves")
		end
	end)
end

local function beginManualPlantChapter()
	autoPlantWavesArmed = false
	selectCoralPlaceId = nil
	relocateTeachMoved = false
	playerGui:SetAttribute(CHAPTER_ATTR, "manualPlant")
	playerGui:SetAttribute(AUTO_PLANT_DONE_ATTR, nil)
	pcall(function()
		local AutoPlantUI = require(script.Parent:WaitForChild("AutoPlantUI"))
		AutoPlantUI.requestTutorialPrep(false)
	end)
	pcall(function()
		require(script.Parent:WaitForChild("AutoPlantHudSlot")).setForcedHidden(false)
	end)
	-- Plot-size cinematic ForceClose'd FreeCam — reclaim Plot Cam before manual plant zoom.
	-- Defer until SkillsAvatarCam restore finishes so Player Cam can't win the race.
	playerGui:SetAttribute("OceanTD_EnsurePlotCam", os.clock())
	task.spawn(function()
		local deadline = os.clock() + 2
		while os.clock() < deadline do
			if playerGui:GetAttribute("OceanTD_SkillsAvatarCamBusy") ~= true
				and playerGui:GetAttribute("OceanTD_PlotSizeCinematicBusy") ~= true
				and playerGui:GetAttribute("OceanTD_PlotSizeCineSuppressTutorial") ~= true
			then
				break
			end
			task.wait()
		end
		playerGui:SetAttribute("OceanTD_EnsurePlotCam", os.clock())
	end)
	-- Teach BUILD again from a fresh roll.
	playerGui:SetAttribute("OceanTD_TutorialGateBackpack", true)
	playRollAgainManualPlantOnce()
	playerGui:SetAttribute(HINT_ATTR, "roll")
end

local function beginCamAfterManualPlant()
	if playerGui:GetAttribute("OceanTD_TutorialGateCam") == true then
		playerGui:SetAttribute("OceanTD_TutorialGateCam", false)
	end
	-- Free Cam stays locked through manual plant; unlock only after backpack closes.
	playerGui:SetAttribute("OceanTD_TutorialGateFreeCam", false)
	-- Hint "cam" first so requestSetEnabled gates allow ON during manualPlant chapter.
	playerGui:SetAttribute(HINT_ATTR, "cam")
	if playerGui:GetAttribute("OceanTD_ManualPlantTrainingReported") ~= true then
		playerGui:SetAttribute("OceanTD_ManualPlantTrainingReported", true)
		task.defer(function()
			pcall(function()
				local Remotes = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Remotes"))
				Remotes.get("ReportManualPlantTraining"):FireServer()
			end)
		end)
	end
	-- Manual plant turned Auto Plant off; restore ON after they finish and close backpack.
	pcall(function()
		local AutoPlantUI = require(script.Parent:WaitForChild("AutoPlantUI"))
		AutoPlantUI.requestTutorialPrep(true)
	end)
end

local function playAutoPlantChapterIntro()
	task.spawn(function()
		pcall(function()
			local AutoPlantUI = require(script.Parent:WaitForChild("AutoPlantUI"))
			AutoPlantUI.requestTutorialPrep(true)
		end)
		pcall(function()
			local AutoPlantHudSlot = require(script.Parent:WaitForChild("AutoPlantHudSlot"))
			AutoPlantHudSlot.playTutorialIntro()
		end)
	end)
end

local function startRelocateDragHint(myGen: number)
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
		if conn then
			conn:Disconnect()
			conn = nil
		end

		local phase = "approach"
		local t0 = os.clock()
		local fromPos = Vector2.zero
		local toPos = Vector2.zero
		local discCenter = Vector2.zero
		local slideAmp = 0
		local laidOut = false

		local function refreshDisc(): Vector2?
			local sel = RelocateController.getSelectedPart()
			if not sel then
				return nil
			end
			local selId = sel:GetAttribute("OceanTD_PlaceId")
			-- Keep the demo glued to the coral the finger told them to pick.
			if typeof(selectCoralPlaceId) == "string" and selectCoralPlaceId ~= "" then
				if typeof(selId) ~= "string" or selId ~= selectCoralPlaceId then
					return nil
				end
			elseif typeof(selId) == "string" and selId ~= "" then
				selectCoralPlaceId = selId
			end
			local c = relocateMoveDiscScreenCenter()
			if not c and typeof(selectCoralPlaceId) == "string" then
				c = coralScreenCenterForPlaceId(selectCoralPlaceId)
			end
			if not c then
				return nil
			end
			discCenter = c
			local cam = Workspace.CurrentCamera
			local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
			slideAmp = vp.X * RELOCATE_SLIDE_FRAC
			return c
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

			if not InventoryState.isOpen() then
				f.Visible = false
				laidOut = false
				return
			end
			if playerGui:GetAttribute(REPORT_OPEN_ATTR) == true
				or playerGui:GetAttribute(HIDE_UI_ACTIVE_ATTR) == true
			then
				f.Visible = false
				laidOut = false
				return
			end

			if not RelocateController.isActive() then
				playerGui:SetAttribute(HINT_ATTR, "selectCoral")
				return
			end

			-- Wrong coral selected vs teach target — send them back to select.
			do
				local sel = RelocateController.getSelectedPart()
				local selId = if sel then sel:GetAttribute("OceanTD_PlaceId") else nil
				if typeof(selectCoralPlaceId) == "string"
					and selectCoralPlaceId ~= ""
					and typeof(selId) == "string"
					and selId ~= selectCoralPlaceId
				then
					playerGui:SetAttribute(HINT_ATTR, "selectCoral")
					return
				end
			end

			-- Hide demo for the whole press/drag; only advance to Confirm after release.
			local playerDragging = RelocateController.isDragging()
				or RelocateController.isCoralMovePointerDown()
			if RelocateController.hasMovedSelection() then
				relocateTeachMoved = true
			end
			if playerDragging then
				f.Visible = false
				laidOut = false
				return
			end
			if relocateTeachMoved then
				playerGui:SetAttribute(HINT_ATTR, "relocateConfirm")
				return
			end

			local disc = refreshDisc()
			if not disc then
				f.Visible = false
				laidOut = false
				return
			end

			f.Visible = true
			local now = os.clock()
			local elapsed = now - t0

			if not laidOut then
				phase = "approach"
				fromPos = Vector2.new(disc.X, disc.Y + RELOCATE_BELOW_PX)
				toPos = disc
				t0 = now
				laidOut = true
				f.Position = UDim2.fromOffset(fromPos.X, fromPos.Y)
				f.Rotation = 0
				sc.Scale = 1
			end

			if phase == "approach" then
				local u = easeOutCubic(math.clamp(elapsed / RELOCATE_APPROACH_SEC, 0, 1))
				local p = fromPos:Lerp(toPos, u)
				f.Position = UDim2.fromOffset(p.X, p.Y)
				f.Rotation = PRESS_ROT_DEG * u
				sc.Scale = 1 + (RELOCATE_DRAG_SCALE - 1) * u
				if elapsed >= RELOCATE_APPROACH_SEC then
					f.Position = UDim2.fromOffset(discCenter.X, discCenter.Y)
					sc.Scale = RELOCATE_DRAG_SCALE
					spawnTapBurst(discCenter)
					phase = "slideLeft"
					t0 = now
					fromPos = discCenter
					toPos = Vector2.new(discCenter.X - slideAmp, discCenter.Y)
				end
			elseif phase == "slideLeft" then
				local u = smoothstep(math.clamp(elapsed / RELOCATE_SLIDE_SEC, 0, 1))
				local p = fromPos:Lerp(toPos, u)
				f.Position = UDim2.fromOffset(p.X, p.Y)
				f.Rotation = PRESS_ROT_DEG
				sc.Scale = RELOCATE_DRAG_SCALE
				if elapsed >= RELOCATE_SLIDE_SEC then
					phase = "slideRight"
					t0 = now
					fromPos = toPos
					toPos = Vector2.new(discCenter.X + slideAmp, discCenter.Y)
				end
			elseif phase == "slideRight" then
				local u = smoothstep(math.clamp(elapsed / (RELOCATE_SLIDE_SEC * 2), 0, 1))
				local p = fromPos:Lerp(toPos, u)
				f.Position = UDim2.fromOffset(p.X, p.Y)
				f.Rotation = PRESS_ROT_DEG
				sc.Scale = RELOCATE_DRAG_SCALE
				if elapsed >= RELOCATE_SLIDE_SEC * 2 then
					phase = "recover"
					t0 = now
					fromPos = Vector2.new(f.Position.X.Offset, f.Position.Y.Offset)
					toPos = discCenter
				end
			elseif phase == "recover" then
				local u = smoothstep(math.clamp(elapsed / RELOCATE_RECOVER_SEC, 0, 1))
				local p = fromPos:Lerp(toPos, u)
				f.Position = UDim2.fromOffset(p.X, p.Y)
				f.Rotation = PRESS_ROT_DEG * (1 - u)
				sc.Scale = RELOCATE_DRAG_SCALE + (1 - RELOCATE_DRAG_SCALE) * u
				if elapsed >= RELOCATE_RECOVER_SEC then
					f.Position = UDim2.fromOffset(discCenter.X, discCenter.Y)
					sc.Scale = 1
					f.Rotation = 0
					phase = "rest"
					t0 = now
				end
			elseif phase == "rest" then
				f.Position = UDim2.fromOffset(discCenter.X, discCenter.Y)
				sc.Scale = 1
				f.Rotation = 0
				if elapsed >= RELOCATE_REST_SEC then
					-- Next cycle: tap-hold at center (no approach from below).
					phase = "pressIn"
					t0 = now
				end
			elseif phase == "pressIn" then
				local u = smoothstep(math.clamp(elapsed / PRESS_SEC, 0, 1))
				f.Position = UDim2.fromOffset(discCenter.X, discCenter.Y)
				f.Rotation = PRESS_ROT_DEG * u
				sc.Scale = 1 + (RELOCATE_DRAG_SCALE - 1) * u
				if elapsed >= PRESS_SEC then
					spawnTapBurst(discCenter)
					phase = "slideLeft"
					t0 = now
					fromPos = discCenter
					toPos = Vector2.new(discCenter.X - slideAmp, discCenter.Y)
					sc.Scale = RELOCATE_DRAG_SCALE
				end
			end
		end)
	end)
end

local function startHint(mode: HintMode)
	gen += 1
	local myGen = gen
	if conn then
		conn:Disconnect()
		conn = nil
	end

	if mode == "selectCoral" then
		relocateTeachMoved = false
		selectCoralPlaceId = nil
		ensureMidPlotCoralPlaceId()
		focusPlotCamOnSelectCoral()
		playMoveCoralExplainerOnce()
	elseif mode == "relocateDrag" then
		startRelocateDragHint(myGen)
		return
	elseif mode == "equip" then
		local id = SeedWheelRevealApi.lastAwardedItemId
		if typeof(id) == "string" then
			InventoryState.revealItemInBackpack(id)
			-- Open tween / list layout can finish after the first reveal attempt.
			task.delay(0.35, function()
				if playerGui:GetAttribute(HINT_ATTR) == "equip" then
					InventoryState.revealItemInBackpack(id)
				end
			end)
		end
	elseif mode == "plot" then
		rerollPlotTapOffset()
		local id = InventoryState.getSelectedId() or SeedWheelRevealApi.lastAwardedItemId
		if typeof(id) == "string" and id ~= "" then
			InventoryState.revealItemInBackpack(id)
			task.delay(0.35, function()
				if playerGui:GetAttribute(HINT_ATTR) == "plot" then
					InventoryState.revealItemInBackpack(id)
				end
			end)
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
		-- Skills VO waits until they click Skills (see SKILLS_OPEN handler).
	elseif mode == "cam" then
		playFingerCamSoundOnce()
		-- Wave-3 fish-cam teach replaces the Slot5 finger; keep End Waves → roll/skills armed.
		if wavesFingerConsumed then
			waitingWaveEnd = true
		end
	elseif mode == "closeBackpack" then
		-- Soft-plant PLANT may leave backpack already closed — don't stall the pipeline.
		if not InventoryState.isOpen() then
			task.defer(function()
				if playerGui:GetAttribute(HINT_ATTR) == "closeBackpack" and not InventoryState.isOpen() then
					if playerGui:GetAttribute(CHAPTER_ATTR) == "manualPlant" then
						beginCamAfterManualPlant()
					else
						beginWavesAfterCloseBackpack()
					end
				end
			end)
		end
	elseif mode == "otherSkillsExplainer" then
		-- No finger — pulse skill bubbles, then hand off to closeSkills.
		destroyGui()
		playerGui:SetAttribute(OTHER_SKILLS_EXPLAINER_ATTR, true)
		playMoreUpgradesExplainerOnce()
		SkillsBubbleSim.playOtherSkillsExplainer(function()
			if myGen ~= gen or fingerTutorialSkipped then
				playerGui:SetAttribute(OTHER_SKILLS_EXPLAINER_ATTR, false)
				return
			end
			if playerGui:GetAttribute(HINT_ATTR) ~= "otherSkillsExplainer" then
				playerGui:SetAttribute(OTHER_SKILLS_EXPLAINER_ATTR, false)
				return
			end
			playerGui:SetAttribute(OTHER_SKILLS_EXPLAINER_ATTR, false)
			playerGui:SetAttribute(HINT_ATTR, "closeSkills")
		end)
		syncSkipTutorialBtn()
		return
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
			-- Upgrade: first approach from bottom-right; later cycles continue from retreat (BL).
			if from ~= nil then
				fromPos = from
			elseif mode == "upgrade" then
				fromPos = viewportBottomRight()
			else
				fromPos = restOf(mode, btn)
			end
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
			if (mode == "selectCoral" or mode == "relocateConfirm") and not InventoryState.isOpen() then
				f.Visible = false
				laidOut = false
				return
			end
			if mode == "selectCoral" then
				local sel = RelocateController.getSelectedPart()
				if sel then
					local want = ensureMidPlotCoralPlaceId()
					local selId = sel:GetAttribute("OceanTD_PlaceId")
					local wantAlive = typeof(want) == "string"
						and want ~= ""
						and RelocatePickHover.findByPlaceId(want) ~= nil
					local matched = typeof(selId) == "string" and typeof(want) == "string" and selId == want
					-- Mid-plot coral, or any coral if the target despawned.
					if matched or not wantAlive then
						-- Lock drag demo to whatever they actually selected.
						if typeof(selId) == "string" and selId ~= "" then
							selectCoralPlaceId = selId
						end
						playerGui:SetAttribute(HINT_ATTR, "relocateDrag")
						return
					end
				end
			elseif mode == "relocateConfirm" then
				if RelocateController.hasMovedSelection() then
					relocateTeachMoved = true
				end
				if not RelocateController.isActive() then
					if relocateTeachMoved then
						playerGui:SetAttribute(HINT_ATTR, "equip")
					else
						playerGui:SetAttribute(HINT_ATTR, "selectCoral")
					end
					return
				end
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
				-- Don't advance past skills without the teach VO (AttributeChanged can miss).
				playFingerSkillsSoundOnce()
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
				-- Grow/dial cinematic ForceClose is not a real close — stay on CloseBTN.
				if plotSizeCineBlocksTutorialAdvance() then
					-- wait
				elseif playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true then
					-- Power-up closed — spotlight the other skills, then close finger.
					playerGui:SetAttribute(HINT_ATTR, "otherSkillsExplainer")
					return
				end
			elseif mode == "otherSkillsExplainer" then
				-- Finger hidden; SkillsBubbleSim drives the pulse, then sets closeSkills.
			elseif mode == "closeSkills" and playerGui:GetAttribute(SKILLS_OPEN_ATTR) ~= true then
				-- Same: cinematic teardown must not skip into Manual Plant early.
				if not plotSizeCineBlocksTutorialAdvance() then
					-- Skills closed after plot-size → Manual Plant chapter (roll again).
					beginManualPlantChapter()
					return
				end
			elseif mode == "cam" then
				-- Cleared when the player changes cam mode (see CamCycleMode listener).
			end

			local hideChrome = uiHidesChrome()
			-- Skills/powerup open is expected for later tutorial steps.
			if mode == "plotSize" or mode == "plotSizeUpgrade" or mode == "closePlotSize" or mode == "otherSkillsExplainer" or mode == "closeSkills" or mode == "upgrade" or mode == "hue" or mode == "hueReroll" or mode == "plant" or mode == "cam" or mode == "selectCoral" or mode == "relocateConfirm" then
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
	local prevHint = lastHintAttr
	lastHintAttr = raw
	-- After hue: wait for PLANT/CONFIRM press (plant → closeBackpack), then guppy VO.
	if raw == "closeBackpack" and prevHint == "plant" then
		playSmarterThanGuppyOnce()
	end
	if raw == "await" then
		stopHint()
		-- Auto Plant chapter: show the HUD button as they start the roll spin.
		if playerGui:GetAttribute(CHAPTER_ATTR) == "autoPlant" and not fingerTutorialSkipped then
			playAutoPlantChapterIntro()
		end
		syncSkipTutorialBtn()
		return
	end
	if raw == "autoPlantWait" then
		-- Finger hidden while auto-plant orb/dig finishes.
		stopHint()
		syncSkipTutorialBtn()
		return
	end
	-- Intro owns the screen until JoinIntroBusy clears (roll finger = training start).
	if playerGui:GetAttribute(JOIN_INTRO_BUSY_ATTR) == true then
		stopHint()
		syncSkipTutorialBtn()
		return
	end
	local mode = parseMode(raw)
	if mode then
		if mode == "backpack" then
			-- Unlock BUILD when the finger points at it (after roll finishes).
			playerGui:SetAttribute("OceanTD_TutorialGateBackpack", false)
			-- "Plant first coral" VO waits until they move a coral (relocateConfirm).
		elseif mode == "relocateConfirm" then
			-- Manual plant: after they drag the coral, then plant-first-coral VO.
			if playerGui:GetAttribute(CHAPTER_ATTR) == "manualPlant" then
				playPlantFirstCoralSoundOnce()
			end
		elseif mode == "upgrade" then
			-- First coral planted → upgrade finger + upgrade explainer VO.
			playUpgradeExplainerOnce()
		elseif mode == "hue" then
			-- First upgrade done → hue finger; hue VO waits for upgrade explainer.
			playHueExplainerOnce()
		end
		startHint(mode)
	else
		-- Do not clear waitingWaveEnd here. Wave-3 cam teach + hardCleanup set the hint
		-- false while the run is still active; End Waves must still hand off to roll/skills.
		stopHint()
	end
	syncSkipTutorialBtn()
end

-- When intro ends, apply any pending roll-finger hint that was blocked while busy.
playerGui:GetAttributeChangedSignal(JOIN_INTRO_BUSY_ATTR):Connect(function()
	if playerGui:GetAttribute(JOIN_INTRO_BUSY_ATTR) == true then
		return
	end
	applyAttr(playerGui:GetAttribute(HINT_ATTR))
end)

playerGui:GetAttributeChangedSignal(HINT_ATTR):Connect(function()
	applyAttr(playerGui:GetAttribute(HINT_ATTR))
end)

SeedWheelRevealApi.connectCycleFinished(function()
	local hint = playerGui:GetAttribute(HINT_ATTR)
	if hint ~= "await" and hint ~= "autoPlantWait" then
		return
	end
	if playerGui:GetAttribute(CHAPTER_ATTR) == "autoPlant" then
		-- Claim already fired auto-plant; wait for dig/orb done (fallback timeout below).
		playerGui:SetAttribute(HINT_ATTR, "autoPlantWait")
		local doneAt = playerGui:GetAttribute(AUTO_PLANT_DONE_ATTR)
		if typeof(doneAt) == "number" then
			beginWavesAfterCloseBackpack()
			return
		end
		task.delay(10, function()
			if fingerTutorialSkipped then
				return
			end
			if playerGui:GetAttribute(CHAPTER_ATTR) ~= "autoPlant" then
				return
			end
			local cur = playerGui:GetAttribute(HINT_ATTR)
			if cur == "autoPlantWait" or cur == "await" or cur == false or cur == nil then
				beginWavesAfterCloseBackpack()
			end
		end)
		return
	end
	-- Manual Plant chapter (or no chapter): unlock BUILD + finger on it.
	playerGui:SetAttribute("OceanTD_TutorialGateBackpack", false)
	playerGui:SetAttribute(HINT_ATTR, "backpack")
end)

playerGui:GetAttributeChangedSignal(AUTO_PLANT_DONE_ATTR):Connect(function()
	if fingerTutorialSkipped then
		return
	end
	if playerGui:GetAttribute(CHAPTER_ATTR) ~= "autoPlant" then
		return
	end
	if typeof(playerGui:GetAttribute(AUTO_PLANT_DONE_ATTR)) ~= "number" then
		return
	end
	local cur = playerGui:GetAttribute(HINT_ATTR)
	if cur == "autoPlantWait" or cur == "await" or cur == false or cur == nil then
		beginWavesAfterCloseBackpack()
	end
end)

-- First tutorial auto-plant orb launch → Auto Plant explainer VO.
playerGui:GetAttributeChangedSignal("OceanTD_TutorialAutoPlantOrbFired"):Connect(function()
	if typeof(playerGui:GetAttribute("OceanTD_TutorialAutoPlantOrbFired")) ~= "number" then
		return
	end
	if playerGui:GetAttribute(CHAPTER_ATTR) ~= "autoPlant" then
		return
	end
	playAutoPlantExplainerOnce()
end)

InventoryState.onOpenChanged(function(isOpen: boolean)
	local v = playerGui:GetAttribute(HINT_ATTR)
	if isOpen then
		-- Manual plant BUILD: seat Plot Cam if they opened from Fish/Player/Drone.
		if playerGui:GetAttribute(CHAPTER_ATTR) == "manualPlant" then
			if playerGui:GetAttribute("OceanTD_CamCycleMode") ~= "plotcam" then
				playerGui:SetAttribute("OceanTD_ForceCamMode", "plotcam")
				playerGui:SetAttribute("OceanTD_ForceCamStamp", os.clock())
			end
			-- Opening BUILD for move-coral teach: center Plot Cam on the target coral.
			if v == "backpack" or v == "await" or v == "selectCoral" then
				focusPlotCamOnSelectCoral()
			end
		end
		if v == "backpack" or v == "await" then
			if playerGui:GetAttribute(CHAPTER_ATTR) == "manualPlant" then
				playerGui:SetAttribute(HINT_ATTR, "selectCoral")
			else
				playerGui:SetAttribute(HINT_ATTR, "equip")
			end
		end
		return
	end
	if v == "equip" then
		playerGui:SetAttribute(HINT_ATTR, "backpack")
	elseif v == "selectCoral" or v == "relocateDrag" or v == "relocateConfirm" then
		playerGui:SetAttribute(HINT_ATTR, "backpack")
	elseif v == "closeBackpack" then
		if playerGui:GetAttribute(CHAPTER_ATTR) == "manualPlant" then
			beginCamAfterManualPlant()
		else
			beginWavesAfterCloseBackpack()
		end
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
	if open and skillsTeachStepActive() then
		onSkillsOpenedForTutorial()
	elseif not open then
		-- Plot size grow/dial shot force-closes skills; ignore until chrome is restored.
		if plotSizeCineBlocksTutorialAdvance() then
			return
		end
		if v == "closeSkills" then
			-- After plot-size upgrade + closing skills → Manual Plant chapter.
			beginManualPlantChapter()
		elseif v == "otherSkillsExplainer" then
			-- Explainer blocked close; if skills still closed, resume from Skills finger.
			playerGui:SetAttribute(OTHER_SKILLS_EXPLAINER_ATTR, false)
			SkillsBubbleSim.cancelOtherSkillsExplainer()
			playerGui:SetAttribute(HINT_ATTR, "skills")
		elseif v == "plotSize" or v == "plotSizeUpgrade" or v == "closePlotSize" then
			-- Closed skills without finishing the plot-size tutorial — back to Skills finger.
			playerGui:SetAttribute(HINT_ATTR, "skills")
		end
	end
end)

-- Real Skills button press (not ForceOpen) — most reliable teach VO trigger.
playerGui:GetAttributeChangedSignal("OceanTD_SkillsPlayerOpened"):Connect(function()
	if typeof(playerGui:GetAttribute("OceanTD_SkillsPlayerOpened")) ~= "number" then
		return
	end
	onSkillsOpenedForTutorial()
end)

playerGui:GetAttributeChangedSignal("OceanTD_CamCycleMode"):Connect(function()
	if playerGui:GetAttribute(HINT_ATTR) ~= "cam" then
		return
	end
	local wave3FishPov = playerGui:GetAttribute("OceanTD_Wave3FishCamHint") == true
	local wasManualPlant = playerGui:GetAttribute(CHAPTER_ATTR) == "manualPlant"
	playerGui:SetAttribute(HINT_ATTR, false)
	playerGui:SetAttribute(CHAPTER_ATTR, nil)
	if wave3FishPov then
		playerGui:SetAttribute("OceanTD_Wave3FishCamHint", nil)
		playerGui:SetAttribute("OceanTD_Wave3CamHoldPause", nil)
		-- Force Fish Cam + POV (pad coaster), not just the next carousel step.
		pcall(function()
			require(script.Parent:WaitForChild("FishCamTune")).setPovOn(true, true)
		end)
		playerGui:SetAttribute("OceanTD_ForceCamMode", "fishcam")
		playerGui:SetAttribute("OceanTD_ForceCamStamp", os.clock())
		-- Release W3 hold-pause so fish start swimming.
		pcall(function()
			require(script.Parent:WaitForChild("WaveSim")).setCinematicPaused(false)
		end)
		-- Don't leave ForceCamMode stuck on fishcam — later cycle taps must work.
		task.defer(function()
			if playerGui:GetAttribute("OceanTD_ForceCamMode") == "fishcam" then
				playerGui:SetAttribute("OceanTD_ForceCamMode", "")
			end
			playerGui:SetAttribute("OceanTD_RefreshCamCycleHits", os.clock())
		end)
		return
	end
	-- Manual plant Free Cam teach: jump straight to Free Cam (not the next carousel step).
	if wasManualPlant then
		pendingStartWavesFinger = true
		playerGui:SetAttribute("OceanTD_TutorialLockStartWaves", false)
		playerGui:SetAttribute("OceanTD_ForceCamMode", "dronecam")
		playerGui:SetAttribute("OceanTD_ForceCamStamp", os.clock())
		task.defer(function()
			if playerGui:GetAttribute("OceanTD_ForceCamMode") == "dronecam" then
				playerGui:SetAttribute("OceanTD_ForceCamMode", "")
			end
			playerGui:SetAttribute("OceanTD_RefreshCamCycleHits", os.clock())
		end)
	end
	onCamButtonClickedForTryWaves()
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
	if fingerTutorialSkipped then
		return
	end
	-- Primary: waitingWaveEnd from the waves finger. Recover if mid-run hint clears
	-- (W3 cam / hardCleanup) wiped the flag while LeftHud is still tutorial-gated.
	if not waitingWaveEnd then
		local leftGated = playerGui:GetAttribute("OceanTD_TutorialGateLeftHud") == true
		if not (leftGated and wavesFingerConsumed) then
			return
		end
	end
	waitingWaveEnd = false
	-- After End Waves (win or loss): skills next. Roll-again is later (manual plant).
	playerGui:SetAttribute("OceanTD_TutorialSummaryWasDefeat", nil)
	playerGui:SetAttribute("OceanTD_TutorialRollThenSkills", nil)
	-- Keep Skills locked + no finger until out-of-reef-health (or any) VO finishes.
	skillsFingerAfterVoGen += 1
	local my = skillsFingerAfterVoGen
	task.spawn(function()
		local deadline = os.clock() + 45
		while TutorialVo.isPlaying() and os.clock() < deadline do
			if my ~= skillsFingerAfterVoGen or fingerTutorialSkipped then
				return
			end
			task.wait()
		end
		if my ~= skillsFingerAfterVoGen or fingerTutorialSkipped then
			return
		end
		if playerGui:GetAttribute("OceanTD_TutorialGateCam") == true then
			playerGui:SetAttribute("OceanTD_TutorialGateCam", false)
		end
		-- Block Start Waves until skills + manual plant training finish.
		playerGui:SetAttribute("OceanTD_TutorialLockStartWaves", true)
		playerGui:SetAttribute("OceanTD_TutorialGateLeftHud", false)
		playerGui:SetAttribute(HINT_ATTR, "skills")
	end)
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
}

-- Shop / cart locked until plot-size upgrade finger tutorial completes.
local LEFT_SHOP_LOCK_BTN: { [string]: boolean } = {
	CartIcon = true,
	Cart = true,
	CartBTN = true,
	CartBtn = true,
	Report = true,
	ReefReport = true,
	ShoppingCart = true,
}

-- Camera cycle icons — locked until build mode closes after the first coral hue.
-- dPadIcon (center decor) stays unlocked/visible; only the four mode buttons lock.
local LEFT_CAM_LOCK_BTN: { [string]: boolean } = {
	FreeCam = true,
	PlotCam = true,
	FishCam = true,
	OffCam = true,
}
-- Free Cam (DroneCam) stays locked until manual plant + backpack close.
local LEFT_FREECAM_LOCK_BTN: { [string]: boolean } = {
	FreeCam = true,
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
		btn:SetAttribute("_OceanTD_TutorialLockActive", nil)
		btn:SetAttribute("_OceanTD_TutorialLockSelectable", nil)
		-- Always re-enable on unlock. Restoring a saved Active=false left cam hits dead
		-- (wave 3 teach tap) until a later carousel pass — which often never came.
		btn.Active = true
		btn.Selectable = true
		pcall(function()
			(btn :: any).Interactable = true
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
	local gateFreeCam = playerGui:GetAttribute("OceanTD_TutorialGateFreeCam") == true
	local gateShop = playerGui:GetAttribute("OceanTD_TutorialGateShop") == true
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
	-- $D / $DCount stay hidden while Skills is tutorial-locked — except during
	-- live waves, where the balance must stay visible as fish pay out.
	local skillsLocked = gate and not skillsOpen
	local wavesLive = WaveSim.isRunning() == true and not WaveSim.isJoinIntroDemo()
	setSandDollarChromeVisible(left, (not skillsLocked) or wavesLive)
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
	local lockedShopHosts: { [GuiObject]: boolean } = {}
	for _, ch in ipairs(dPad:GetChildren()) do
		if not ch:IsA("GuiObject") then
			continue
		end
		local lockHud = LEFT_HUD_LOCK_BTN[ch.Name] == true
		local lockCam = LEFT_CAM_LOCK_BTN[ch.Name] == true
		local lockFreeCam = LEFT_FREECAM_LOCK_BTN[ch.Name] == true
		local lockShop = LEFT_SHOP_LOCK_BTN[ch.Name] == true
		if not lockHud and not lockCam and not lockShop and not lockFreeCam then
			continue
		end
		local shouldLock = false
		if lockShop then
			shouldLock = gateShop
			if shouldLock then
				lockedShopHosts[ch] = true
			end
		elseif lockHud then
			-- Skills close must stay usable while bubbles are open (WaveSpeed/Skip ForceOpen).
			shouldLock = gate and not (skillsOpen and ch.Name == "Skills")
		elseif lockCam or lockFreeCam then
			-- All cams while GateCam. Player Cam (OffCam) + Free Cam stay locked
			-- until Free Cam unlocks (manual plant + backpack close).
			if ch.Name == "OffCam" then
				shouldLock = gateCam or gateFreeCam
			else
				shouldLock = gateCam or (gateFreeCam and lockFreeCam)
			end
		end
		if shouldLock then
			ensureTutorialLockOn(ch)
		else
			clearTutorialLockOn(ch)
		end
	end
	-- Cart may be nested / aliased — match ReefReport preferred names so the red lock always lands.
	if gateShop then
		local preferred = { "CartIcon", "CartBTN", "CartBtn", "Cart", "cart", "Report", "ReefReport", "ShoppingCart" }
		for _, name in ipairs(preferred) do
			local gui = dPad:FindFirstChild(name, true)
			if gui and gui:IsA("GuiObject") and not lockedShopHosts[gui] then
				ensureTutorialLockOn(gui)
				lockedShopHosts[gui] = true
				break
			end
		end
	else
		for _, name in ipairs({ "CartIcon", "CartBTN", "CartBtn", "Cart", "cart", "Report", "ReefReport", "ShoppingCart" }) do
			local gui = dPad:FindFirstChild(name, true)
			if gui and gui:IsA("GuiObject") and LEFT_SHOP_LOCK_BTN[gui.Name] == true then
				clearTutorialLockOn(gui)
			end
		end
	end
end

playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateLeftHud"):Connect(applyLeftHudGate)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateCam"):Connect(applyLeftHudGate)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateFreeCam"):Connect(applyLeftHudGate)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateShop"):Connect(applyLeftHudGate)
playerGui:GetAttributeChangedSignal("OceanTD_RefreshLeftHudGate"):Connect(applyLeftHudGate)
playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(applyLeftHudGate)
playerGui.ChildAdded:Connect(function(ch)
	if ch.Name == "MobileLeftUI" then
		task.defer(applyLeftHudGate)
		ch.ChildAdded:Connect(function()
			if playerGui:GetAttribute("OceanTD_TutorialGateLeftHud") == true
				or playerGui:GetAttribute("OceanTD_TutorialGateCam") == true
				or playerGui:GetAttribute("OceanTD_TutorialGateFreeCam") == true
				or playerGui:GetAttribute("OceanTD_TutorialGateShop") == true
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
				or playerGui:GetAttribute("OceanTD_TutorialGateFreeCam") == true
				or playerGui:GetAttribute("OceanTD_TutorialGateShop") == true
				or playerGui:GetAttribute(SKILLS_OPEN_ATTR) == true
			then
				task.defer(applyLeftHudGate)
			end
		end)
	end
end
task.defer(applyLeftHudGate)

-- Joypad skills / camera teach: pulse the center D-pad graphic until they do it.
local dpadTeachConn: RBXScriptConnection? = nil

local function gamepadTeachInput(): boolean
	local t = UserInputService:GetLastInputType()
	return t == Enum.UserInputType.Gamepad1
		or t == Enum.UserInputType.Gamepad2
		or t == Enum.UserInputType.Gamepad3
		or t == Enum.UserInputType.Gamepad4
end

local function dpadTeachWanted(): boolean
	if not gamepadTeachInput() or InventoryState.isOpen() then
		return false
	end
	-- Skills pulses d-pad right. Free-cam and wave-3 fish cam pulse d-pad down.
	local hint = playerGui:GetAttribute(HINT_ATTR)
	if hint == "skills" then
		return playerGui:GetAttribute(SKILLS_OPEN_ATTR) ~= true
	end
	if hint ~= "cam" then
		return false
	end
	return true
end

local function stopDpadTeachPulse()
	if dpadTeachConn then
		dpadTeachConn:Disconnect()
		dpadTeachConn = nil
	end
	local left = playerGui:FindFirstChild("MobileLeftUI")
	local dPad = left and left:FindFirstChild("dPad")
	local mid = dPad and dPad:FindFirstChild("dPadIcon")
	if mid and mid:IsA("GuiObject") and mid.Visible then
		local sc = mid:FindFirstChild("_OceanTD_DPadTeachScale")
		if sc and sc:IsA("UIScale") then
			sc.Scale = 1
		end
		local teachSheet = mid:FindFirstChild("_OceanTD_DPadTeachSheet")
		if teachSheet and teachSheet:IsA("GuiObject") then
			teachSheet.Visible = false
		end
		if mid:IsA("ImageLabel") or mid:IsA("ImageButton") then
			local saved = mid:GetAttribute("_OceanTD_TeachImgT")
			if typeof(saved) == "number" then
				mid.ImageTransparency = saved
			end
		end
		mid.ZIndex = 80
	end
	local dPadReset = dPad
	if dPadReset then
		for _, ch in ipairs(dPadReset:GetChildren()) do
			if ch:IsA("GuiObject") then
				local extra = ch:FindFirstChild("_OceanTD_TeachBtnScale")
				if extra and extra:IsA("UIScale") then
					extra.Scale = 1
				end
			end
		end
	end
end

local function syncDpadTeachPulse()
	if not dpadTeachWanted() then
		stopDpadTeachPulse()
		return
	end
	if dpadTeachConn then
		return
	end
	local t0 = os.clock()
	dpadTeachConn = RunService.RenderStepped:Connect(function()
		if not dpadTeachWanted() then
			stopDpadTeachPulse()
			return
		end
		local left = playerGui:FindFirstChild("MobileLeftUI")
		local dPad = left and left:FindFirstChild("dPad")
		local mid = dPad and dPad:FindFirstChild("dPadIcon")
		if not (mid and mid:IsA("GuiObject")) then
			return
		end
		mid.Visible = true
		mid.Active = false
		if mid:IsA("ImageLabel") or mid:IsA("ImageButton") then
			if mid:GetAttribute("_OceanTD_TeachImgSaved") ~= true then
				mid:SetAttribute("_OceanTD_TeachImgSaved", true)
				mid:SetAttribute("_OceanTD_TeachImgT", mid.ImageTransparency)
			end
			mid.ImageTransparency = 1
		end
		pcall(function()
			(mid :: any).Interactable = false
		end)
		mid.ZIndex = 200
		for _, d in ipairs(mid:GetDescendants()) do
			if d:IsA("GuiObject") then
				d.Active = false
				d.ZIndex = math.max(d.ZIndex, 201)
			end
		end
		local sc = mid:FindFirstChild("_OceanTD_DPadTeachScale")
		if sc and sc:IsA("UIScale") then
			sc.Scale = 1
		end
		local wave = (math.sin((os.clock() - t0) * 5) + 1) * 0.5
		local pulse = 1 + 0.28 * wave
		local hintNow = playerGui:GetAttribute(HINT_ATTR)
		local lit = math.sin((os.clock() - t0) * 5) > 0
		local token = "DPad"
		if hintNow == "skills" then
			token = if lit then "DRight" else "DPad"
		elseif hintNow == "cam" then
			token = if lit then "DDown" else "DPad"
		end
		local teachWin = mid:FindFirstChild("_OceanTD_DPadTeachSheet")
		if not (teachWin and teachWin:IsA("Frame")) then
			if teachWin then
				teachWin:Destroy()
			end
			local made = Instance.new("Frame")
			made.Name = "_OceanTD_DPadTeachSheet"
			made.BackgroundTransparency = 1
			made.BorderSizePixel = 0
			made.AnchorPoint = Vector2.new(0.5, 0.5)
			made.Position = UDim2.fromScale(0.5, 0.5)
			made.Size = UDim2.fromScale(1, 1)
			made.ClipsDescendants = true
			made.Active = false
			made.ZIndex = mid.ZIndex + 3
			made.Parent = mid
			local sheet = Instance.new("ImageLabel")
			sheet.Name = "Sheet"
			sheet.BackgroundTransparency = 1
			sheet.BorderSizePixel = 0
			sheet.Active = false
			sheet.ZIndex = made.ZIndex
			sheet.Parent = made
			teachWin = made
		end
		if teachWin and teachWin:IsA("Frame") then
			teachWin.Visible = true
			local sheet = teachWin:FindFirstChild("Sheet")
			if sheet and sheet:IsA("ImageLabel") then
				local sheets = require(oceanRoot:WaitForChild("Shared"):WaitForChild("GamepadButtonGlyph"))
				sheets.placeCell(sheet, token)
			end
		end
		-- Also grow the button the finger is pointing at (Free Cam / Skills).
		local teachBtn: GuiObject? = nil
		if hintNow == "skills" then
			teachBtn = findSkillsButton()
		elseif hintNow == "cam" then
			teachBtn = findCamButton()
		end
		if dPad then
			for _, ch in ipairs(dPad:GetChildren()) do
				if ch:IsA("GuiObject") and ch ~= teachBtn then
					local extra = ch:FindFirstChild("_OceanTD_TeachBtnScale")
					if extra and extra:IsA("UIScale") then
						extra.Scale = 1
					end
				end
			end
		end
		if teachBtn then
			local extra = teachBtn:FindFirstChild("_OceanTD_TeachBtnScale")
			if not (extra and extra:IsA("UIScale")) then
				local made = Instance.new("UIScale")
				made.Name = "_OceanTD_TeachBtnScale"
				made.Parent = teachBtn
				extra = made
			end
			if extra and extra:IsA("UIScale") then
				extra.Scale = pulse
			end
		end
	end)
end

playerGui:GetAttributeChangedSignal(HINT_ATTR):Connect(syncDpadTeachPulse)
playerGui:GetAttributeChangedSignal("OceanTD_Wave3FishCamHint"):Connect(syncDpadTeachPulse)
playerGui:GetAttributeChangedSignal(SKILLS_OPEN_ATTR):Connect(syncDpadTeachPulse)
UserInputService.LastInputTypeChanged:Connect(syncDpadTeachPulse)
task.defer(syncDpadTeachPulse)

applyAttr(playerGui:GetAttribute(HINT_ATTR))

-- First real Start Waves: wave explainer VO (waits if "how many waves" is still playing).
WaveSim.onHud(function(snap)
	if WaveSim.isJoinIntroDemo() then
		return
	end
	if snap.running and not wavesHudWasRunning then
		wavesHudWasRunning = true
		task.defer(applyLeftHudGate)
		if (snap.wave or 0) <= 1 then
			playWaveExplainerSoundOnce()
		end
	elseif not snap.running then
		if wavesHudWasRunning then
			task.defer(applyLeftHudGate)
		end
		wavesHudWasRunning = false
	end
end)

playerGui:GetAttributeChangedSignal(JOIN_INTRO_BUSY_ATTR):Connect(syncSkipTutorialBtn)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateBackpack"):Connect(syncSkipTutorialBtn)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateWaves"):Connect(syncSkipTutorialBtn)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateLeftHud"):Connect(syncSkipTutorialBtn)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateCam"):Connect(syncSkipTutorialBtn)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateFreeCam"):Connect(syncSkipTutorialBtn)
playerGui:GetAttributeChangedSignal("OceanTD_TutorialGateShop"):Connect(syncSkipTutorialBtn)
task.defer(syncSkipTutorialBtn)
