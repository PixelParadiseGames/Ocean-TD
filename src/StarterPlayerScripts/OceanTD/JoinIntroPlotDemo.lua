--!strict
--[[
	Join-intro sample plot beat (replaces old example drop after bleach):
	1) Shrink footprint MAX → stage 1 (PLOT title ~2s before shrink ends)
	2) Open fake backpack (non-clickable), scroll list bottom → top
	3) Fire 1 of each species (orb from slot); grow plot when PS1 spots fill
	4) Short beat, then ADD MAX press → autoplant fill (stretched)
	5) Avatar sped-up dash/dig chase from first orb fire
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SkillStages = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("SkillStages"))
local UiViewportTags = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("UiViewportTags"))

local PlotSizeCinematic = require(script.Parent:WaitForChild("PlotSizeCinematic"))
local JoinIntroExampleCorals = require(script.Parent:WaitForChild("JoinIntroExampleCorals"))
local JoinIntroBackpackDemo = require(script.Parent:WaitForChild("JoinIntroBackpackDemo"))
local JoinIntroAvatarBuild = require(script.Parent:WaitForChild("JoinIntroAvatarBuild"))

local JoinIntroPlotDemo = {}

local ATTR_SHOW_BACKPACK = "OceanTD_JoinIntroShowBackpack"
local DEMO_GROW_TO_STAGE = 4
local SHRINK_TO_ONE_SEC = 2.2
-- PLOT title pops this many seconds before shrink reaches stage 1.
local PLOT_TITLE_EARLY_SEC = 1.0 -- show 0.5s later than prior 1.5
local GROW_DURATION_SEC = 5.5
-- Spread 1-of-each fires ~1s longer; ADD_MAX_DELAY shrinks by the same so ADD MAX stays put.
local PLANT_STAGGER_SEC = 0.30
local FIRST_ORB_DELAY_SEC = 1.5 -- beat after backpack open before first species orb (+1s later)
local FILL_COUNT = 180
local FILL_STAGGER = 0.072 -- ~1s longer firing window than 0.045
local ADD_MAX_DELAY_SEC = 1.0 -- was 2.0; gap after last species (individuals took the extra second)
local ADD_MAX_WAIT_SEC = 1.5
local PLANT_RETRY_SEC = 0.12

local function smoothstep(t: number): number
	local u = math.clamp(t, 0, 1)
	return u * u * (3 - 2 * u)
end

local function enableRightHudForDemo(playerGui: PlayerGui, hiddenScreens: { [ScreenGui]: boolean }?)
	local is720 = UiViewportTags.is720p(UiViewportTags.readViewport())
	local names = { UiViewportTags.MOBILE_RIGHT_HUD, UiViewportTags.P720_RIGHT_HUD }
	for _, name in ipairs(names) do
		local sg = playerGui:FindFirstChild(name)
		if sg and sg:IsA("ScreenGui") then
			local want = if name == UiViewportTags.P720_RIGHT_HUD then is720 else not is720
			if hiddenScreens and hiddenScreens[sg] ~= nil then
				hiddenScreens[sg] = nil
			end
			sg.Enabled = want
		end
	end
end

export type RunOpts = {
	cancelled: () -> boolean,
	hiddenScreens: { [ScreenGui]: boolean }?,
	-- Called when backpack opens — JoinIntro starts CamEnd → PlotCam lift.
	onBackpackOpen: (() -> ())?,
	-- Fired ~2s before footprint finishes shrinking to plot-size 1 (PLOT title beat).
	onPlotSizeOne: (() -> ())?,
}

function JoinIntroPlotDemo.runAfterBleach(opts: RunOpts): boolean
	local cancelled = opts.cancelled
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end

	-- PLOT title before shrink completes (shrink duration unchanged).
	if opts.onPlotSizeOne then
		task.spawn(function()
			local titleAt = os.clock() + math.max(0, SHRINK_TO_ONE_SEC - PLOT_TITLE_EARLY_SEC)
			while os.clock() < titleAt and not cancelled() do
				task.wait(0.05)
			end
			if cancelled() then
				return
			end
			pcall(opts.onPlotSizeOne)
		end)
	end

	PlotSizeCinematic.tweenStagesLocal(SkillStages.MAX_STAGE, 1, {
		duration = SHRINK_TO_ONE_SEC,
		cancelled = cancelled,
	})
	if cancelled() then
		return false
	end

	playerGui:SetAttribute(ATTR_SHOW_BACKPACK, true)
	enableRightHudForDemo(playerGui, opts.hiddenScreens)
	local bindDeadline = os.clock() + 3
	while not JoinIntroBackpackDemo.isBound() and os.clock() < bindDeadline do
		task.wait()
	end
	local scrollSec = GROW_DURATION_SEC
	local began = JoinIntroBackpackDemo.begin(scrollSec)
	if not began then
		warn("[JoinIntroPlotDemo] backpack demo begin failed")
	end
	pcall(function()
		local AutoPlantUI = require(script.Parent:WaitForChild("AutoPlantUI"))
		if AutoPlantUI.setJoinIntroDemo then
			AutoPlantUI.setJoinIntroDemo(true)
		end
	end)
	pcall(function()
		local AutoPlantHudSlot = require(script.Parent:WaitForChild("AutoPlantHudSlot"))
		if AutoPlantHudSlot.setVisible then
			AutoPlantHudSlot.setVisible(false)
		end
	end)
	if opts.onBackpackOpen then
		pcall(opts.onBackpackOpen)
	end
	task.wait(0.2)
	enableRightHudForDemo(playerGui, opts.hiddenScreens)
	local species = JoinIntroBackpackDemo.speciesBottomToTop()
	if #species == 0 then
		species = {
			"Sponge",
			"BrainCoral",
			"LeatherCoral",
			"SeaFan",
			"FireCoral",
			"Zoas",
			"SeaGrass",
			"TreeCoral",
		}
	end

	local plantCount = #species
	local growDone = false
	task.spawn(function()
		PlotSizeCinematic.tweenStagesLocal(1, DEMO_GROW_TO_STAGE, {
			duration = GROW_DURATION_SEC,
			cancelled = cancelled,
		})
		growDone = true
	end)

	local t0 = os.clock()
	local plantedIdx = 0
	local nextPlantAt = t0 + FIRST_ORB_DELAY_SEC
	local avatarStarted = false

	JoinIntroExampleCorals.setOnPlanted(function(worldPos, coralPart)
		if not avatarStarted then
			avatarStarted = true
			JoinIntroAvatarBuild.begin()
		end
		JoinIntroAvatarBuild.enqueue(worldPos, coralPart)
	end)

	-- Fire exactly one orb per species. Retry when PS1 is full until grow opens PS2+.
	while plantedIdx < plantCount and not cancelled() do
		local elapsed = os.clock() - t0
		local u = smoothstep(math.clamp(elapsed / scrollSec, 0, 1))
		JoinIntroBackpackDemo.setScrollProgress(u)

		if os.clock() >= nextPlantAt then
			local sid = species[plantedIdx + 1]
			local screen = JoinIntroBackpackDemo.slotScreenCenter(sid)
			local ok = false
			pcall(function()
				ok = JoinIntroExampleCorals.plantSpeciesDemo(sid, screen, 0.4) == true
			end)
			if ok then
				plantedIdx += 1
				nextPlantAt = os.clock() + PLANT_STAGGER_SEC
			else
				nextPlantAt = os.clock() + PLANT_RETRY_SEC
			end
		end
		RunService.RenderStepped:Wait()
	end
	JoinIntroBackpackDemo.setScrollProgress(1)
	enableRightHudForDemo(playerGui, opts.hiddenScreens)

	-- Beat after last species orb, then ADD MAX (2s later than prior "immediate" timing).
	if not cancelled() and plantedIdx >= plantCount and ADD_MAX_DELAY_SEC > 0 then
		local delayUntil = os.clock() + ADD_MAX_DELAY_SEC
		while os.clock() < delayUntil and not cancelled() do
			RunService.RenderStepped:Wait()
		end
	end

	local function onAddMaxOrbsFired()
		-- Remaining digs 2× faster; backpack shrinks into BUILD (top-right) immediately.
		JoinIntroAvatarBuild.rushRemaining()
		pcall(function()
			JoinIntroBackpackDemo.collapseAway()
		end)
		playerGui:SetAttribute(ATTR_SHOW_BACKPACK, false)
	end

	local fillDone = false
	if not cancelled() and plantedIdx >= plantCount then
		local btnDeadline = os.clock() + ADD_MAX_WAIT_SEC
		local btnCenter: Vector2? = nil
		while os.clock() < btnDeadline and not cancelled() do
			btnCenter = JoinIntroBackpackDemo.addMaxScreenCenter()
			if btnCenter then
				break
			end
			RunService.RenderStepped:Wait()
		end
		if btnCenter and not cancelled() then
			pcall(function()
				JoinIntroBackpackDemo.playAddMaxPress()
			end)
			btnCenter = JoinIntroBackpackDemo.addMaxScreenCenter() or btnCenter
			JoinIntroExampleCorals.fillRestDemo(FILL_COUNT, btnCenter, cancelled, FILL_STAGGER, onAddMaxOrbsFired)
			fillDone = true
		else
			local bpCenter = JoinIntroBackpackDemo.slotScreenCenter(species[1] or "BrainCoral")
			JoinIntroExampleCorals.fillRestDemo(FILL_COUNT, bpCenter, cancelled, FILL_STAGGER, onAddMaxOrbsFired)
			fillDone = true
		end
	end

	-- After ADD MAX orbs + plot VO: advance to path section (no multi-second hang).
	if fillDone and not cancelled() then
		local TutorialVo = require(script.Parent:WaitForChild("TutorialVo"))
		local voDeadline = os.clock() + 10
		while TutorialVo.isPlaying() and os.clock() < voDeadline and not cancelled() do
			task.wait()
		end
		task.wait(0.3) -- brief land pad for last orbs
		JoinIntroAvatarBuild.waitDrain(0.6)
	end

	JoinIntroExampleCorals.setOnPlanted(nil)
	JoinIntroAvatarBuild.finish()
	JoinIntroBackpackDemo.finish()
	pcall(function()
		local AutoPlantUI = require(script.Parent:WaitForChild("AutoPlantUI"))
		if AutoPlantUI.setJoinIntroDemo then
			AutoPlantUI.setJoinIntroDemo(false)
		end
	end)
	playerGui:SetAttribute(ATTR_SHOW_BACKPACK, false)
	return not cancelled()
end

function JoinIntroPlotDemo.shrinkToOneForPath(cancelled: (() -> boolean)?): boolean
	local cf1, size1 = PlotSizeCinematic.resolveStagePose(1)
	local fadeStarted = false
	task.spawn(function()
		if cf1 and size1 then
			fadeStarted = true
			JoinIntroExampleCorals.fadeOutsidePose(cf1, size1, 1.0, cancelled)
		end
	end)
	local ok = PlotSizeCinematic.tweenStagesLocal(DEMO_GROW_TO_STAGE, 1, {
		duration = 1.0,
		cancelled = cancelled,
	})
	if not fadeStarted and cf1 and size1 then
		JoinIntroExampleCorals.fadeOutsidePose(cf1, size1, 0.35, cancelled)
	end
	return ok
end

function JoinIntroPlotDemo.demoGrowStage(): number
	return DEMO_GROW_TO_STAGE
end

return JoinIntroPlotDemo
