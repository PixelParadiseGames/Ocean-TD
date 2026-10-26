--!strict
--[[
	Roblox badge grants. AwardBadge is safe to retry; UserHasBadgeAsync skips repeats.
]]

local BadgeService = game:GetService("BadgeService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Remotes"))

local BadgeAwards = {}

local AUTO_ROLL_USES = 3296414762108303
local WAVE_10 = 4447323609882120
local PLANT_5 = 2812747434854351
local MANUAL_PLANT_TRAINING = 3935785856036918

local AUTO_ROLL_USES_NEEDED = 3
local WAVE_NEEDED = 10
local PLANTS_NEEDED = 5

local pending: { [string]: boolean } = {}

local function Persistence()
	return require(script.Parent:WaitForChild("PersistenceService"))
end

local function plotCoralCount(player: Player): number
	local PlotService = require(script.Parent:WaitForChild("PlotService"))
	local GridService = require(script.Parent:WaitForChild("GridService"))
	local plotId = PlotService.getOwnerPlotId(player)
	if not plotId then
		return 0
	end
	return GridService.getPlotCount(plotId)
end

function BadgeAwards.award(player: Player, badgeId: number)
	if not player or not player.Parent then
		return
	end
	local key = tostring(player.UserId) .. ":" .. tostring(badgeId)
	if pending[key] then
		return
	end
	pending[key] = true
	task.spawn(function()
		local function finish()
			pending[key] = nil
		end
		if not player.Parent then
			finish()
			return
		end
		local hasOk, has = pcall(function()
			return BadgeService:UserHasBadgeAsync(player.UserId, badgeId)
		end)
		if hasOk and has == true then
			return
		end
		pcall(function()
			BadgeService:AwardBadge(player.UserId, badgeId)
		end)
		finish()
	end)
end

function BadgeAwards.noteAutoRollEnabled(player: Player)
	local count = Persistence().addAutoRollUse(player)
	player:SetAttribute("OceanTD_AutoRollUseCount", count)
	if count >= AUTO_ROLL_USES_NEEDED then
		BadgeAwards.award(player, AUTO_ROLL_USES)
	end
end

function BadgeAwards.noteWave(player: Player, wave: number)
	if math.floor(tonumber(wave) or 0) >= WAVE_NEEDED then
		BadgeAwards.award(player, WAVE_10)
	end
end

function BadgeAwards.noteCoralPlanted(player: Player)
	if plotCoralCount(player) >= PLANTS_NEEDED then
		BadgeAwards.award(player, PLANT_5)
	end
end

function BadgeAwards.noteManualPlantTraining(player: Player)
	if plotCoralCount(player) < 1 then
		return
	end
	BadgeAwards.award(player, MANUAL_PLANT_TRAINING)
end

function BadgeAwards.grantStored(player: Player)
	local profile = Persistence().getProfile(player)
	if not profile then
		return
	end
	local uses = math.max(0, math.floor(tonumber(profile.autoRollUseCount) or 0))
	player:SetAttribute("OceanTD_AutoRollUseCount", uses)
	if uses >= AUTO_ROLL_USES_NEEDED then
		BadgeAwards.award(player, AUTO_ROLL_USES)
	end
	if (profile.highestWave or 0) >= WAVE_NEEDED then
		BadgeAwards.award(player, WAVE_10)
	end
	if plotCoralCount(player) >= PLANTS_NEEDED then
		BadgeAwards.award(player, PLANT_5)
	end
end

function BadgeAwards.start()
	if BadgeAwards._started then
		return
	end
	BadgeAwards._started = true
	Remotes.get("ReportManualPlantTraining").OnServerEvent:Connect(function(player: Player)
		BadgeAwards.noteManualPlantTraining(player)
	end)
end

return BadgeAwards
