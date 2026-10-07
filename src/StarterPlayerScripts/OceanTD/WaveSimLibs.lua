--!strict
--[[
	Shared requires for WaveSim — keeps WaveSim.lua under Luau's 200 top-level locals.
	Hot paths (Path, WaveCrab, WaveEntityPool, C, …) stay as locals in WaveSim.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local parent = script.Parent

return {
	ContentProvider = ContentProvider,
	ReplicatedStorage = ReplicatedStorage,
	RunService = RunService,
	SoundService = SoundService,

	Remotes = require(oceanRoot:WaitForChild("Remotes")),
	ItemCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("ItemCatalog")),
	SpeciesCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SpeciesCatalog")),
	UiTheme = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiTheme")),
	CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual")),
	CoralSize = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralSize")),
	BrainStack = require(oceanRoot:WaitForChild("Shared"):WaitForChild("BrainStack")),
	UiHaptics = require(oceanRoot:WaitForChild("Shared"):WaitForChild("UiHaptics")),
	SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages")),

	PlacedCoralIndex = require(parent:WaitForChild("PlacedCoralIndex")),
	WaveArrowPreview = require(parent:WaitForChild("WaveArrowPreview")),
	SharkCam = require(parent:WaitForChild("SharkCam")),
	UrchinCam = require(parent:WaitForChild("UrchinCam")),
	TangCam = require(parent:WaitForChild("TangCam")),
	ReefDefeatCam = require(parent:WaitForChild("ReefDefeatCam")),
	WaveEndVfx = require(parent:WaitForChild("WaveEndVfx")),
	WaveStartVfx = require(parent:WaitForChild("WaveStartVfx")),
	Wave1LeadArrow = require(parent:WaitForChild("Wave1LeadArrow")),
	WaveFeedPayout = require(parent:WaitForChild("WaveFeedPayout")),
	SkillPowerUpUI = require(parent:WaitForChild("SkillPowerUpUI")),
	UrchinStingEffects = require(parent:WaitForChild("UrchinStingEffects")),
	TutorialVo = require(parent:WaitForChild("TutorialVo")),

	-- First-time / defeat tutorial VO asset ids.
	VO_REEF_EMPTY = "rbxassetid://80635392364728",
	VO_FIRST_URCHIN = "rbxassetid://73895188345477",
	VO_FIRST_CRAB = "rbxassetid://73529365912447",
	VO_FIRST_SHARK = "rbxassetid://81763997714855",
}
