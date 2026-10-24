--!strict
-- Reports join_to_training steps in order. Skip Training freezes the rest
-- so later play is not filled in as if they finished training.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local FunnelCatalog = require(oceanRoot:WaitForChild("Shared"):WaitForChild("FunnelCatalog"))

local JoinFunnel = {}

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local nextIndex = 1
local frozen = false
local started = false
local remote: RemoteEvent? = nil

type Pending = { id: string, field: string?, index: number }
local pending: { Pending } = {}

local REACH: { [string]: number } = {
	reach_wave_3 = 3,
	reach_wave_5 = 5,
	reach_wave_8 = 8,
	reach_wave_10 = 10,
	reach_wave_11 = 11,
}

local function nextId(): string?
	return FunnelCatalog.JOIN_STEPS[nextIndex]
end

local function deviceField(): string
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		return "touch"
	end
	if string.sub(last.Name, 1, 7) == "Gamepad" then
		return "gamepad"
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled and not UserInputService.TouchEnabled then
		return "gamepad"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled and not UserInputService.GamepadEnabled then
		return "touch"
	end
	return "keyboard"
end

local function ackedIndex(): number
	local ack = player:GetAttribute("OceanTD_JoinFunnelAck")
	if typeof(ack) == "number" then
		return ack
	end
	return 0
end

local function flush()
	local ev = remote
	if not ev then
		return
	end
	local ack = ackedIndex()
	local froze = player:GetAttribute("OceanTD_JoinFunnelFrozen") == true
	for _, item in ipairs(pending) do
		if item.id == "freeze" then
			if not froze then
				ev:FireServer(item.id)
			end
		elseif item.index > ack then
			ev:FireServer(item.id, item.field)
		end
	end
end

local function send(stepId: string, field: string?)
	table.insert(pending, { id = stepId, field = field, index = nextIndex })
	nextIndex += 1
	flush()
end

local function accept(stepId: string, field: string?)
	if frozen or nextId() ~= stepId then
		return
	end
	send(stepId, field)
end

function JoinFunnel.mark(stepId: string, field: string?)
	if frozen then
		return
	end
	if stepId == "load_bar_shown" and (field == nil or field == "") then
		field = deviceField()
	end
	-- Skip Intro can happen before the reef pan. Keep the earlier steps in order.
	if stepId == "showcase_exit" and field == "skip" then
		local guard = 0
		while not frozen and (nextId() == "load_bar_filled" or nextId() == "showcase_started") do
			send(nextId() :: string, nil)
			guard += 1
			if guard > 4 then
				break
			end
		end
	end
	accept(stepId, field)
end

function JoinFunnel.abandon()
	if frozen then
		return
	end
	frozen = true
	table.insert(pending, { id = "freeze", field = nil, index = 1000 })
	flush()
end

local function tryReach(wave: number)
	local guard = 0
	while not frozen do
		local id = nextId()
		local need = if id then REACH[id] else nil
		if not need or wave < need then
			return
		end
		send(id :: string, nil)
		guard += 1
		if guard > 5 then
			return
		end
	end
end

function JoinFunnel.start()
	if started then
		return
	end
	started = true

	task.spawn(function()
		local Remotes = require(oceanRoot:WaitForChild("Remotes"))
		remote = Remotes.get("FunnelStep")
		flush()
	end)
	player:GetAttributeChangedSignal("OceanTD_JoinFunnelAck"):Connect(flush)
	player:GetAttributeChangedSignal("OceanTD_JoinFunnelFrozen"):Connect(flush)
	task.spawn(function()
		while player.Parent do
			task.wait(2)
			flush()
		end
	end)

	playerGui:GetAttributeChangedSignal("OceanTD_TutorialAutoPlantDone"):Connect(function()
		if typeof(playerGui:GetAttribute("OceanTD_TutorialAutoPlantDone")) == "number" then
			JoinFunnel.mark("first_roll")
		end
	end)

	playerGui:GetAttributeChangedSignal("OceanTD_SkillsPlayerOpened"):Connect(function()
		if typeof(playerGui:GetAttribute("OceanTD_SkillsPlayerOpened")) == "number" then
			JoinFunnel.mark("skills")
		end
	end)

	playerGui:GetAttributeChangedSignal("OceanTD_RollFingerHint"):Connect(function()
		local hint = playerGui:GetAttribute("OceanTD_RollFingerHint")
		if hint == "relocateConfirm" then
			JoinFunnel.mark("move_coral")
		elseif hint == "upgrade" then
			JoinFunnel.mark("place_new_coral")
		elseif hint == "hue" or hint == "hueReroll" then
			JoinFunnel.mark("upgrade_coral")
		elseif hint == "plant" or hint == "closeBackpack" then
			JoinFunnel.mark("hue_change")
		end
	end)

	playerGui:GetAttributeChangedSignal("OceanTD_ForceCamMode"):Connect(function()
		if playerGui:GetAttribute("OceanTD_ForceCamMode") == "dronecam" then
			JoinFunnel.mark("free_cam")
		end
	end)
	playerGui:GetAttributeChangedSignal("OceanTD_CamCycleMode"):Connect(function()
		if playerGui:GetAttribute("OceanTD_CamCycleMode") == "dronecam" then
			JoinFunnel.mark("free_cam")
		end
	end)

	playerGui:GetAttributeChangedSignal("OceanTD_FingerTutorialSkipped"):Connect(function()
		if playerGui:GetAttribute("OceanTD_FingerTutorialSkipped") == true then
			JoinFunnel.abandon()
		end
	end)

	local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
	InventoryState.onOpenChanged(function(open: boolean)
		if not open then
			JoinFunnel.mark("close_backpack")
		end
	end)

	local WaveSim = require(script.Parent:WaitForChild("WaveSim"))
	local wasRunning = false
	WaveSim.onHud(function(snap)
		if playerGui:GetAttribute("OceanTD_JoinIntroBusy") == true or WaveSim.isJoinIntroDemo() then
			return
		end
		if snap.running and not wasRunning then
			wasRunning = true
			JoinFunnel.mark("start_waves")
			JoinFunnel.mark("start_waves_again")
		elseif not snap.running then
			wasRunning = false
		end
		if snap.running and snap.wave == 1 and snap.feedComplete == true then
			JoinFunnel.mark("clear_wave_1")
		end
		if snap.running then
			tryReach(snap.wave)
		end
	end)
	WaveSim.onStopped(function(summary)
		wasRunning = false
		if typeof(summary) == "table" and summary.defeated == true then
			return
		end
		JoinFunnel.mark("end_waves")
	end)
end

task.defer(function()
	JoinFunnel.start()
end)

return JoinFunnel
