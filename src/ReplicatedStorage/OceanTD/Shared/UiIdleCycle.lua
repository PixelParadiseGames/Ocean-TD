--!strict
--[[
	Low-frequency UI idle cycles: task.wait (not Heartbeat), dirty apply, optional shared clock.
]]

local UiIdleCycle = {}

export type StopFn = () -> ()

type ToggleSub = {
	apply: (alt: boolean) -> (),
	shouldContinue: () -> boolean,
	invert: boolean,
	lastAlt: boolean?,
}

local sharedSubs: { ToggleSub } = {}
local sharedToken = 0
local sharedPeriod = 2
local sharedAlt = false
local sharedPumping = false

local function removeSub(sub: ToggleSub)
	local i = table.find(sharedSubs, sub)
	if i then
		table.remove(sharedSubs, i)
	end
end

local function effectiveAlt(sub: ToggleSub): boolean
	return if sub.invert then not sharedAlt else sharedAlt
end

local function pumpShared()
	if sharedPumping then
		return
	end
	sharedPumping = true
	local my = sharedToken
	task.spawn(function()
		while my == sharedToken do
			task.wait(sharedPeriod)
			if my ~= sharedToken then
				break
			end
			if #sharedSubs == 0 then
				break
			end
			sharedAlt = not sharedAlt
			local i = 1
			while i <= #sharedSubs do
				local s = sharedSubs[i]
				if not s.shouldContinue() then
					table.remove(sharedSubs, i)
				else
					local eff = effectiveAlt(s)
					if s.lastAlt ~= eff then
						s.lastAlt = eff
						s.apply(eff)
					end
					i += 1
				end
			end
			if #sharedSubs == 0 then
				break
			end
		end
		if my == sharedToken then
			sharedPumping = false
		end
	end)
end

--[[
	All subscribers share one flip clock (same period).
	apply(alt) runs on subscribe and only again when the shared phase changes.
	invertPhase: when true, shows the opposite frame of normal subscribers
	(e.g. text while others show graphic).
]]
function UiIdleCycle.subscribeSharedToggle(
	periodSec: number,
	apply: (alt: boolean) -> (),
	shouldContinue: () -> boolean,
	invertPhase: boolean?
): StopFn
	sharedPeriod = math.max(0.05, periodSec)
	local sub: ToggleSub = {
		apply = apply,
		shouldContinue = shouldContinue,
		invert = invertPhase == true,
		lastAlt = nil,
	}
	table.insert(sharedSubs, sub)
	if #sharedSubs == 1 then
		sharedAlt = false
		sharedToken += 1
		sharedPumping = false
	end
	local eff = effectiveAlt(sub)
	sub.lastAlt = eff
	apply(eff)
	if not sharedPumping then
		pumpShared()
	end
	return function()
		removeSub(sub)
		if #sharedSubs == 0 then
			sharedToken += 1
			sharedPumping = false
			sharedAlt = false
		end
	end
end

export type SequenceStep = {
	duration: number,
	apply: () -> (),
}

--[[
	Asymmetric sequence on a delay loop (e.g. 1s letter → 2s CLOSE).
	apply runs when entering each step only.
]]
function UiIdleCycle.startSequence(steps: { SequenceStep }, shouldContinue: () -> boolean): StopFn
	local box = { alive = true }
	task.spawn(function()
		while box.alive do
			if not shouldContinue() then
				break
			end
			for _, step in ipairs(steps) do
				if not box.alive or not shouldContinue() then
					return
				end
				step.apply()
				task.wait(math.max(0.05, step.duration))
			end
		end
	end)
	return function()
		box.alive = false
	end
end

return UiIdleCycle
