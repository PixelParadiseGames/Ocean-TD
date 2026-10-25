--!strict
--[[
	Shared wave clock for visitor sync.
	Host and visitors build the same spawn list from one seed, then place
	swim fish and sharks with a closed-form distance. Ground critters still
	pause on coral, so their distance is corrected from the host blob.
	Two channels so a player can run their own wave and watch someone else.
]]

local C = require(script.Parent:WaitForChild("WaveSimConsts"))
local WaveCrab = require(script.Parent:WaitForChild("WaveCrab"))
local WaveUrchin = require(script.Parent:WaitForChild("WaveUrchin"))
local WaveShark = require(script.Parent:WaitForChild("WaveShark"))

local WaveVisitPlan = {}

export type Spec = {
	slot: number,
	kind: string,
	route: number,
	spawnAt: number,
	lateral: number,
	vert: number,
	bobAmp: number,
	bobFreq: number,
	bobPhase: number,
	wanderAmp: number,
	wanderFreq: number,
	wanderPhase: number,
	speedPhase: number,
	speedFreq: number,
}

type Channel = {
	seed: number,
	t0: number,
	specs: { Spec },
	cursor: number,
	crabN: number,
	urchinN: number,
	a2n: number,
	armed: Spec?,
}

local function blank(): Channel
	return {
		seed = 0,
		t0 = 0,
		specs = {},
		cursor = 1,
		crabN = 0,
		urchinN = 0,
		a2n = 0,
		armed = nil,
	}
end

local channels: { [string]: Channel } = {
	host = blank(),
	ghost = blank(),
}

local function channel(name: string): Channel
	return channels[name] or channels.host
end

local function fishCount(wave: number): number
	local full = C.WAVE1_COUNT + (wave - 1) * C.WAVE_COUNT_STEP
	return math.max(1, math.floor(full * 0.5 + 0.5))
end

local function spawnGap(wave: number): number
	local w = math.max(1, math.floor(wave))
	local gap = C.STAGGER_SEC * (C.STAGGER_PER_WAVE_MULT ^ (w - 1))
	return math.max(C.STAGGER_MIN_SEC, gap)
end

local function tangMotion(rng: Random): Spec
	return {
		slot = 0,
		kind = "tang",
		route = 1,
		spawnAt = 0,
		lateral = rng:NextNumber(-C.LATERAL_SPREAD, C.LATERAL_SPREAD),
		vert = rng:NextNumber(-C.VERT_SPREAD, C.VERT_SPREAD),
		bobAmp = rng:NextNumber(C.BOB_AMP_MIN, C.BOB_AMP_MAX),
		bobFreq = rng:NextNumber(0.012, 0.032),
		bobPhase = rng:NextNumber(0, math.pi * 2),
		wanderAmp = rng:NextNumber(C.WANDER_AMP_MIN, C.WANDER_AMP_MAX),
		wanderFreq = rng:NextNumber(0.014, 0.038),
		wanderPhase = rng:NextNumber(0, math.pi * 2),
		speedPhase = rng:NextNumber(0, math.pi * 2),
		speedFreq = rng:NextNumber(0.22, 0.55),
	}
end

local function groundMotion(rng: Random, kind: string): Spec
	local spec = {
		slot = 0,
		kind = kind,
		route = 4,
		spawnAt = 0,
		lateral = rng:NextNumber(-C.CRAB_LATERAL_SPREAD, C.CRAB_LATERAL_SPREAD),
		vert = 0,
		bobAmp = 0,
		bobFreq = 1,
		bobPhase = 0,
		wanderAmp = rng:NextNumber(C.CRAB_WANDER_AMP_MIN, C.CRAB_WANDER_AMP_MAX),
		wanderFreq = rng:NextNumber(0.08, 0.18),
		wanderPhase = rng:NextNumber(0, math.pi * 2),
		speedPhase = if kind == "urchin" then WaveUrchin.rollSpeedMult(rng) else 0,
		speedFreq = 1,
	}
	return spec
end

local function rollGroundRoute(rng: Random, hasA: boolean, hasB: boolean): number
	if hasA and hasB then
		return if rng:NextNumber() < 0.5 then 4 else 5
	end
	return if hasB and not hasA then 5 else 4
end

function WaveVisitPlan.begin(name: string, opts: {
	seed: number?,
	wave: number,
	t0: number,
	hasA2: boolean,
	hasGroundA: boolean,
	hasGroundB: boolean,
	hasShark: boolean,
}): number
	local ch = channel(name)
	local wave = math.max(1, math.floor(opts.wave))
	local seed = opts.seed
	if typeof(seed) ~= "number" or seed < 1 then
		seed = math.random(1, 2147483646)
	end
	seed = math.floor(seed)
	local rng = Random.new(seed)
	local hasGround = opts.hasGroundA or opts.hasGroundB
	local crabN = 0
	if hasGround and WaveCrab.shouldSpawn(wave) then
		local lo, hi = C.crabCountRangeForWave(wave)
		if hi > 0 then
			crabN = rng:NextInteger(lo, hi)
		end
	end
	local urchinN = 0
	if hasGround and WaveUrchin.shouldSpawn(wave) then
		local lo, hi = C.urchinCountRangeForWave(wave)
		if hi > 0 then
			urchinN = rng:NextInteger(lo, hi)
		end
	end
	local nFish = fishCount(wave)
	local a2n = 0
	if opts.hasA2 and wave > C.FISH_A2_AFTER_WAVE then
		local frac = rng:NextNumber(C.FISH_A2_FRAC_MIN, C.FISH_A2_FRAC_MAX)
		a2n = math.clamp(math.floor(nFish * frac + 0.5), 0, nFish)
	end
	local a2Left = a2n
	local specs: { Spec } = {}
	local t0 = opts.t0
	if opts.hasShark and WaveShark.shouldSpawn(wave) then
		local shark: Spec = {
			slot = 0,
			kind = "shark",
			route = 3,
			spawnAt = t0,
			lateral = 0,
			vert = 0,
			bobAmp = 0,
			bobFreq = 1,
			bobPhase = rng:NextNumber(0, math.pi * 2),
			wanderAmp = 0,
			wanderFreq = 1,
			wanderPhase = 0,
			speedPhase = 0,
			speedFreq = 1,
		}
		table.insert(specs, shark)
	end
	local urchinT = t0
	if urchinN > 0 then
		urchinT += if wave == 1 then C.WAVE1_SPAWN_LEAD_SEC else WaveUrchin.rollFirstDelay(rng)
	end
	for i = 1, urchinN do
		local spec = groundMotion(rng, "urchin")
		spec.route = rollGroundRoute(rng, opts.hasGroundA, opts.hasGroundB)
		spec.spawnAt = urchinT
		table.insert(specs, spec)
		if i < urchinN then
			urchinT += WaveUrchin.rollSpawnGap(rng)
		end
	end
	local lead = if wave == 1 then C.WAVE1_SPAWN_LEAD_SEC else C.ARROW_LEAD_SEC
	local fishT = t0 + lead
	local firstFishT = fishT
	local gap = spawnGap(wave)
	for i = 1, nFish do
		local spec = tangMotion(rng)
		local remain = nFish - i + 1
		if a2Left > 0 and remain > 0 and rng:NextNumber() < (a2Left / remain) then
			a2Left -= 1
			spec.route = 2
		end
		spec.spawnAt = fishT
		table.insert(specs, spec)
		if i < nFish then
			fishT += gap * rng:NextNumber(0.7, 1.35)
		end
	end
	local crabT = firstFishT
	if crabN > 0 then
		crabT += rng:NextNumber(C.CRAB_FIRST_DELAY_MIN, C.CRAB_FIRST_DELAY_MAX)
	end
	for i = 1, crabN do
		local spec = groundMotion(rng, "crab")
		spec.route = rollGroundRoute(rng, opts.hasGroundA, opts.hasGroundB)
		spec.spawnAt = crabT
		table.insert(specs, spec)
		if i < crabN then
			crabT += rng:NextNumber(C.CRAB_STAGGER_MIN, C.CRAB_STAGGER_MAX)
		end
	end
	table.sort(specs, function(a: Spec, b: Spec): boolean
		if a.spawnAt ~= b.spawnAt then
			return a.spawnAt < b.spawnAt
		end
		return a.kind < b.kind
	end)
	for i, spec in ipairs(specs) do
		spec.slot = i
	end
	ch.seed = seed
	ch.t0 = t0
	ch.specs = specs
	ch.cursor = 1
	ch.crabN = crabN
	ch.urchinN = urchinN
	ch.a2n = a2n
	ch.armed = nil
	return seed
end

function WaveVisitPlan.clear(name: string)
	channels[name] = blank()
end

function WaveVisitPlan.active(name: string): boolean
	return #channel(name).specs > 0
end

function WaveVisitPlan.seed(name: string): number
	return channel(name).seed
end

function WaveVisitPlan.t0(name: string): number
	return channel(name).t0
end

function WaveVisitPlan.count(name: string): number
	return #channel(name).specs
end

function WaveVisitPlan.remaining(name: string): number
	local ch = channel(name)
	if #ch.specs < 1 then
		return 0
	end
	return math.max(0, #ch.specs - ch.cursor + 1)
end

function WaveVisitPlan.unspawnedByKind(name: string): (number, number, number, number)
	local ch = channel(name)
	local fish, crab, urchin, shark = 0, 0, 0, 0
	for i = ch.cursor, #ch.specs do
		local kind = ch.specs[i].kind
		if kind == "crab" then
			crab += 1
		elseif kind == "urchin" then
			urchin += 1
		elseif kind == "shark" then
			shark += 1
		else
			fish += 1
		end
	end
	return fish, crab, urchin, shark
end

function WaveVisitPlan.crabCount(name: string): number
	return channel(name).crabN
end

function WaveVisitPlan.urchinCount(name: string): number
	return channel(name).urchinN
end

function WaveVisitPlan.a2Remaining(name: string): number
	return channel(name).a2n
end

function WaveVisitPlan.arm(name: string, spec: Spec)
	channel(name).armed = spec
end

function WaveVisitPlan.consumeArmed(name: string): Spec?
	local ch = channel(name)
	local spec = ch.armed
	ch.armed = nil
	return spec
end

function WaveVisitPlan.isDue(name: string, slot: number, now: number): boolean
	local spec = channel(name).specs[slot]
	return spec ~= nil and spec.spawnAt <= now + 1e-3
end

function WaveVisitPlan.drain(name: string, now: number, spawn: (Spec) -> ())
	local ch = channel(name)
	local specs = ch.specs
	while ch.cursor <= #specs do
		local spec = specs[ch.cursor]
		if spec.spawnAt > now + 1e-3 then
			break
		end
		ch.cursor += 1
		spawn(spec)
	end
end

function WaveVisitPlan.swimDist(spawnAt: number, freq: number, phase: number, now: number): number
	local elapsed = math.max(0, now - spawnAt)
	local w = freq
	if w < 1e-4 then
		return C.FISH_SPEED * elapsed
	end
	local amp = C.FISH_SPEED_VAR
	local integral = elapsed + (amp / w) * (math.cos(w * spawnAt + phase) - math.cos(w * now + phase))
	return C.FISH_SPEED * integral
end

function WaveVisitPlan.closedDist(agent: any, now: number): number
	local t0 = agent.spawnClock
	if typeof(t0) ~= "number" then
		return agent.dist or 0
	end
	if agent.isShark then
		return WaveShark.speed() * math.max(0, now - t0)
	end
	if agent.isUrchin then
		return WaveUrchin.speedNow() * (agent.speedPhase or 1) * math.max(0, now - t0)
	end
	if agent.isCrab then
		return WaveCrab.baseSpeed() * math.max(0, now - t0)
	end
	return WaveVisitPlan.swimDist(t0, agent.speedFreq or 0.3, agent.speedPhase or 0, now)
end

-- Hunger byte + distance in quarter-studs.
-- 0 = not spawned yet, 1-252 = partial, 254 = gone, 255 = full.
function WaveVisitPlan.readSlot(blob: string, slot: number): (number?, number?)
	if slot < 1 then
		return nil, nil
	end
	local i = (slot - 1) * 3 + 1
	local hunger, lo, hi = string.byte(blob, i, i + 2)
	if hunger == nil or lo == nil or hi == nil then
		return nil, nil
	end
	return hunger, (lo + hi * 256) / 4
end

return WaveVisitPlan
