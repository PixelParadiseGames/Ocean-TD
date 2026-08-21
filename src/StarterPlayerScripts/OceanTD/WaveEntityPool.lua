--!strict
--[[
	Typed acquire/release pools for wave visuals (client-local).

	Hungry fish ("Tang" kind): one random MeshPart from ReplicatedStorage.HungryFish,
	pooled for reuse; size jitter ±2 studs on longest axis at each acquire.
	Crabs: ReplicatedStorage.Fish.CrabTemplate. Same acquireFish/releaseFish API.

	Also pools food orbs, green-arrow sets, ammo balls, and short SFX clones.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local WaveEntityPool = {}

WaveEntityPool.FISH_TANG = "Tang"
WaveEntityPool.FISH_CRAB = "CrabTemplate"

local MAX_FISH_PER_KIND = 48
local MAX_FOOD = 64
local MAX_ARROW = 40
local MAX_AMMO = 64
local MAX_SOUND_PER_KEY = 12
local HUNGRY_SIZE_JITTER = 2 -- ± studs on longest axis

local ATTR_KIND = "OceanTD_PoolFishKind"
local ATTR_BASE_SIZE = "OceanTD_FishBaseSize"

local fishPools: { [string]: { Instance } } = {}
-- Prevents double-release / double-acquire (shared WaveSim + WaveGhostSim pool).
local fishInUse: { [Instance]: boolean } = {}
local foodPool: { BasePart } = {}
local arrowPool: { Instance } = {}
local ammoPool: { BasePart } = {}
local soundPools: { [string]: { Sound } } = {}
local liveSounds: { [string]: Sound } = {}
-- Invalid generation so a delayed recycle can't Stop/Destroy a reused or replacement Sound.
local soundGen: { [Sound]: number } = {}

local fishTemplateCache: { [string]: Instance? } = {}
local hungryMeshTemplates: { BasePart }? = nil
local arrowTemplateCache: Instance? = nil

local function findPrimary(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		if inst.PrimaryPart then
			return inst.PrimaryPart
		end
		return inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function prepareLocalFxInstance(inst: Instance)
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
		end
	end
	if inst:IsA("BasePart") then
		inst.Anchored = true
		inst.CanCollide = false
		inst.CanTouch = false
		inst.CanQuery = false
		inst.CastShadow = false
	end
end

-- Root stays anchored so Pivot/CFrame drives the assembly; welded legs stay
-- unanchored so C0 walk-cycle offsets actually move them.
local function prepareCrabInstance(inst: Instance)
	local root = findPrimary(inst)
	if inst:IsA("Model") then
		local named = inst:FindFirstChild("RootPart")
		if named and named:IsA("BasePart") then
			root = named
			inst.PrimaryPart = named
		elseif root and not inst.PrimaryPart then
			inst.PrimaryPart = root
		end
	end
	local toDestroy: { Instance } = {}
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
			if d == root then
				d.Anchored = true
			else
				d.Anchored = false
				d.Massless = true
			end
		elseif d:IsA("Script") or d:IsA("LocalScript") then
			d.Disabled = true
		elseif d:IsA("Seat") or d:IsA("VehicleSeat") or d:IsA("Humanoid") then
			table.insert(toDestroy, d)
		end
	end
	for _, d in ipairs(toDestroy) do
		d:Destroy()
	end
	if inst:IsA("BasePart") then
		inst.Anchored = true
		inst.CanCollide = false
		inst.CanTouch = false
		inst.CanQuery = false
		inst.CastShadow = false
	end
end

local function stripHungerUi(root: BasePart)
	for _, ch in ipairs(root:GetChildren()) do
		if ch:IsA("BillboardGui") and ch.Name == "HungerBar" then
			ch:Destroy()
		end
	end
end

local function getHungryMeshTemplates(): { BasePart }
	if hungryMeshTemplates then
		return hungryMeshTemplates
	end
	local list: { BasePart } = {}
	local folder = ReplicatedStorage:FindFirstChild("HungryFish")
	if not folder then
		warn("[WAVEPOOL] ReplicatedStorage.HungryFish missing")
		hungryMeshTemplates = list
		return list
	end
	for _, ch in ipairs(folder:GetChildren()) do
		if ch:IsA("BasePart") then
			table.insert(list, ch)
		end
	end
	if #list == 0 then
		warn("[WAVEPOOL] ReplicatedStorage.HungryFish has no MeshParts")
	end
	hungryMeshTemplates = list
	return list
end

local function applyHungrySizeJitter(root: BasePart)
	local baseAttr = root:GetAttribute(ATTR_BASE_SIZE)
	local base: Vector3
	if typeof(baseAttr) == "Vector3" then
		base = baseAttr
	else
		base = root.Size
		root:SetAttribute(ATTR_BASE_SIZE, base)
	end
	local longest = math.max(base.X, base.Y, base.Z)
	if longest < 1e-4 then
		return
	end
	-- Old max (longest + jitter) is the new floor; same 4-stud span above it.
	local minTarget = longest + HUNGRY_SIZE_JITTER
	local target = minTarget + math.random() * (2 * HUNGRY_SIZE_JITTER)
	root.Size = base * (target / longest)
end

local function getFishTemplate(kind: string): Instance?
	if kind == WaveEntityPool.FISH_TANG then
		local meshes = getHungryMeshTemplates()
		return if #meshes > 0 then meshes[1] else nil
	end
	local cached = fishTemplateCache[kind]
	if cached and cached.Parent then
		return cached
	end
	local fishFolder = ReplicatedStorage:FindFirstChild("Fish")
	if not fishFolder then
		warn("[WAVEPOOL] ReplicatedStorage.Fish missing")
		return nil
	end
	local tmpl = fishFolder:FindFirstChild(kind)
	if not tmpl then
		warn("[WAVEPOOL] ReplicatedStorage.Fish." .. kind .. " missing")
		return nil
	end
	fishTemplateCache[kind] = tmpl
	return tmpl
end

local function getArrowTemplate(): Instance?
	if arrowTemplateCache and arrowTemplateCache.Parent then
		return arrowTemplateCache
	end
	local arrows = ReplicatedStorage:FindFirstChild("GreenArrows")
	if not arrows then
		return nil
	end
	arrowTemplateCache = arrows
	return arrows
end

local function newFishFromTemplate(kind: string): (Instance?, BasePart?)
	if kind == WaveEntityPool.FISH_TANG then
		local meshes = getHungryMeshTemplates()
		if #meshes == 0 then
			return nil, nil
		end
		-- Clone only the chosen variant — never the whole HungryFish folder.
		local tmpl = meshes[math.random(1, #meshes)]
		local clone = tmpl:Clone()
		prepareLocalFxInstance(clone)
		if clone:IsA("BasePart") then
			clone:SetAttribute(ATTR_BASE_SIZE, clone.Size)
		end
		clone:SetAttribute(ATTR_KIND, kind)
		local root = findPrimary(clone)
		if not root then
			clone:Destroy()
			return nil, nil
		end
		return clone, root
	end
	local tmpl = getFishTemplate(kind)
	if not tmpl then
		return nil, nil
	end
	local clone = tmpl:Clone()
	if kind == WaveEntityPool.FISH_CRAB then
		prepareCrabInstance(clone)
	else
		prepareLocalFxInstance(clone)
	end
	local root = findPrimary(clone)
	if not root then
		clone:Destroy()
		return nil, nil
	end
	if clone:IsA("Model") and not clone.PrimaryPart then
		clone.PrimaryPart = root
	end
	clone:SetAttribute(ATTR_KIND, kind)
	return clone, root
end

function WaveEntityPool.findPrimary(inst: Instance): BasePart?
	return findPrimary(inst)
end

function WaveEntityPool.prepareLocalFx(inst: Instance)
	prepareLocalFxInstance(inst)
end

function WaveEntityPool.hasFishKind(kind: string): boolean
	return getFishTemplate(kind) ~= nil
end

-- Returns model + root part. Parent is set by caller after acquire.
function WaveEntityPool.acquireFish(kind: string, name: string): (Instance?, BasePart?)
	local pool = fishPools[kind]
	if not pool then
		pool = {}
		fishPools[kind] = pool
	end
	local function finish(inst: Instance, root: BasePart): (Instance, BasePart)
		stripHungerUi(root)
		inst.Name = name
		if inst:IsA("Model") and not inst.PrimaryPart then
			inst.PrimaryPart = root
		end
		if kind == WaveEntityPool.FISH_TANG then
			applyHungrySizeJitter(root)
		end
		fishInUse[inst] = true
		return inst, root
	end
	while #pool > 0 do
		local inst = table.remove(pool) :: Instance
		if inst and not fishInUse[inst] then
			local root = findPrimary(inst)
			if root then
				return finish(inst, root)
			end
			inst:Destroy()
		end
	end
	local clone, root = newFishFromTemplate(kind)
	if not clone or not root then
		return nil, nil
	end
	return finish(clone, root)
end

function WaveEntityPool.releaseFish(kind: string, model: Instance)
	if not model then
		return
	end
	-- Idempotent: hardCleanup used to re-release finished fish and corrupt the pool
	-- (same Tang handed to two live agents → one "steals" the other and it vanishes).
	if not fishInUse[model] then
		return
	end
	fishInUse[model] = nil
	local root = findPrimary(model)
	if root then
		stripHungerUi(root)
	end
	model.Parent = nil
	local pool = fishPools[kind]
	if not pool then
		pool = {}
		fishPools[kind] = pool
	end
	if #pool < MAX_FISH_PER_KIND then
		table.insert(pool, model)
	else
		model:Destroy()
	end
end

function WaveEntityPool.acquireFood(parent: Instance, radius: number): BasePart
	local p = table.remove(foodPool)
	if p then
		p.Transparency = 0
		p.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
		p.Parent = parent
		return p
	end
	local n = Instance.new("Part")
	n.Name = "OceanTD_FoodOrb"
	n.Shape = Enum.PartType.Ball
	n.Material = Enum.Material.Neon
	n.Anchored = true
	n.CanCollide = false
	n.CanQuery = false
	n.CanTouch = false
	n.CastShadow = false
	n.Size = Vector3.new(radius * 2, radius * 2, radius * 2)
	n.Parent = parent
	return n
end

function WaveEntityPool.releaseFood(p: BasePart)
	p.Transparency = 1
	p.CFrame = CFrame.new(0, -1000, 0)
	p.Parent = nil
	if #foodPool < MAX_FOOD then
		table.insert(foodPool, p)
	else
		p:Destroy()
	end
end

function WaveEntityPool.acquireAmmo(parent: Instance, color: Color3, diameter: number): BasePart
	local p = table.remove(ammoPool)
	if p then
		p.Color = color
		p.Size = Vector3.new(diameter, diameter, diameter)
		p.Transparency = 0
		p.Parent = parent
		return p
	end
	local n = Instance.new("Part")
	n.Name = "OceanTD_CoralAmmo"
	n.Shape = Enum.PartType.Ball
	n.Material = Enum.Material.Neon
	n.Color = color
	n.Anchored = true
	n.CanCollide = false
	n.CanQuery = false
	n.CanTouch = false
	n.CastShadow = false
	n.Size = Vector3.new(diameter, diameter, diameter)
	n.Parent = parent
	return n
end

function WaveEntityPool.releaseAmmo(p: BasePart)
	p.Transparency = 1
	p.Parent = nil
	if #ammoPool < MAX_AMMO then
		table.insert(ammoPool, p)
	else
		p:Destroy()
	end
end

local function newArrowFromTemplate(name: string): Instance?
	local tmpl = getArrowTemplate()
	if not tmpl then
		return nil
	end
	local clone = tmpl:Clone()
	clone.Name = name
	if clone:IsA("Folder") then
		local model = Instance.new("Model")
		model.Name = name
		for _, ch in ipairs(clone:GetChildren()) do
			ch.Parent = model
		end
		clone:Destroy()
		clone = model
	end
	prepareLocalFxInstance(clone)
	if clone:IsA("Model") then
		local root = findPrimary(clone)
		if root and not clone.PrimaryPart then
			clone.PrimaryPart = root
		end
	end
	return clone
end

function WaveEntityPool.acquireArrows(name: string, parent: Instance): Instance?
	while #arrowPool > 0 do
		local inst = table.remove(arrowPool) :: Instance
		if inst then
			inst.Name = name
			inst.Parent = parent
			return inst
		end
	end
	local clone = newArrowFromTemplate(name)
	if not clone then
		return nil
	end
	clone.Parent = parent
	return clone
end

function WaveEntityPool.releaseArrows(model: Instance)
	model.Parent = nil
	if #arrowPool < MAX_ARROW then
		table.insert(arrowPool, model)
	else
		model:Destroy()
	end
end

-- Play a short SFX from a template Sound; clones are pooled after playback.
-- cutPrevious: stop any live instance of this key before starting (wave start / skip spam).
function WaveEntityPool.playSound(
	key: string,
	template: Sound,
	playbackSpeed: number?,
	volume: number?,
	cutPrevious: boolean?
)
	local pool = soundPools[key]
	if not pool then
		pool = {}
		soundPools[key] = pool
	end

	if cutPrevious == true then
		local prev = liveSounds[key]
		liveSounds[key] = nil
		if prev then
			-- Invalidate any pending recycle delay so it can't Stop/Destroy the next play.
			soundGen[prev] = -1
			pcall(function()
				prev:Stop()
				prev:Destroy()
			end)
		end
		-- Always fresh clone — reparenting a just-stopped Sound can lock Parent.
		local snd = template:Clone()
		snd.PlaybackSpeed = playbackSpeed or 1
		snd.Volume = volume or template.Volume
		snd.Parent = SoundService
		liveSounds[key] = snd
		local gen = 1
		soundGen[snd] = gen
		snd:Play()
		local pitch = math.max(0.2, snd.PlaybackSpeed)
		local ttl = math.max(0.8, (snd.TimeLength > 0 and snd.TimeLength or 0.5) / pitch + 0.35)
		task.delay(ttl, function()
			if soundGen[snd] ~= gen then
				return
			end
			soundGen[snd] = nil
			if liveSounds[key] == snd then
				liveSounds[key] = nil
			end
			pcall(function()
				snd:Stop()
				snd:Destroy()
			end)
		end)
		return
	end

	local snd = table.remove(pool)
	if not snd or not snd:IsA("Sound") then
		snd = template:Clone()
	end
	local gen = (soundGen[snd] or 0) + 1
	soundGen[snd] = gen
	snd.PlaybackSpeed = playbackSpeed or 1
	snd.Volume = volume or template.Volume
	local parentOk = pcall(function()
		snd.Parent = SoundService
	end)
	if not parentOk then
		soundGen[snd] = nil
		pcall(function()
			snd:Destroy()
		end)
		snd = template:Clone()
		gen = 1
		soundGen[snd] = gen
		snd.PlaybackSpeed = playbackSpeed or 1
		snd.Volume = volume or template.Volume
		snd.Parent = SoundService
	end
	snd:Play()
	local pitch = math.max(0.2, snd.PlaybackSpeed)
	local ttl = math.max(0.8, (snd.TimeLength > 0 and snd.TimeLength or 0.5) / pitch + 0.35)
	task.delay(ttl, function()
		if soundGen[snd] ~= gen then
			return
		end
		soundGen[snd] = nil
		snd:Stop()
		local unparentOk = pcall(function()
			snd.Parent = nil
		end)
		if not unparentOk then
			pcall(function()
				snd:Destroy()
			end)
			return
		end
		local bucket = soundPools[key]
		if bucket and #bucket < MAX_SOUND_PER_KEY then
			table.insert(bucket, snd)
		else
			snd:Destroy()
		end
	end)
end

function WaveEntityPool.debugCounts(): { [string]: number }
	local out: { [string]: number } = {
		food = #foodPool,
		arrow = #arrowPool,
		ammo = #ammoPool,
	}
	for kind, pool in pairs(fishPools) do
		out["fish:" .. kind] = #pool
	end
	return out
end

return WaveEntityPool
