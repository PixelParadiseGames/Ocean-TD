--!strict
--[[
	Typed acquire/release pools for wave visuals (client-local).

	Fish are keyed by species kind (first: "Tang"). Future critters = new kind +
	ReplicatedStorage.Fish.<Kind> template — same acquireFish/releaseFish API.

	Also pools food orbs, green-arrow sets, ammo balls, and short SFX clones.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local WaveEntityPool = {}

WaveEntityPool.FISH_TANG = "Tang"

local MAX_FISH_PER_KIND = 48
local MAX_FOOD = 64
local MAX_ARROW = 40
local MAX_AMMO = 64
local MAX_SOUND_PER_KEY = 12

local ATTR_KIND = "OceanTD_PoolFishKind"

local fishPools: { [string]: { Instance } } = {}
-- Prevents double-release / double-acquire (shared WaveSim + WaveGhostSim pool).
local fishInUse: { [Instance]: boolean } = {}
local foodPool: { BasePart } = {}
local arrowPool: { Instance } = {}
local ammoPool: { BasePart } = {}
local soundPools: { [string]: { Sound } } = {}

local fishTemplateCache: { [string]: Instance? } = {}
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

local function stripHungerUi(root: BasePart)
	for _, ch in ipairs(root:GetChildren()) do
		if ch:IsA("BillboardGui") and ch.Name == "HungerBar" then
			ch:Destroy()
		end
	end
end

local function getFishTemplate(kind: string): Instance?
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
	local tmpl = getFishTemplate(kind)
	if not tmpl then
		return nil, nil
	end
	local clone = tmpl:Clone()
	prepareLocalFxInstance(clone)
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
	while #pool > 0 do
		local inst = table.remove(pool) :: Instance
		if inst and not fishInUse[inst] then
			local root = findPrimary(inst)
			if root then
				stripHungerUi(root)
				inst.Name = name
				if inst:IsA("Model") and not inst.PrimaryPart then
					inst.PrimaryPart = root
				end
				fishInUse[inst] = true
				return inst, root
			end
			inst:Destroy()
		end
	end
	local clone, root = newFishFromTemplate(kind)
	if not clone or not root then
		return nil, nil
	end
	clone.Name = name
	fishInUse[clone] = true
	return clone, root
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
function WaveEntityPool.playSound(key: string, template: Sound, playbackSpeed: number?, volume: number?)
	local pool = soundPools[key]
	if not pool then
		pool = {}
		soundPools[key] = pool
	end
	local snd = table.remove(pool)
	if not snd or not snd:IsA("Sound") then
		snd = template:Clone()
	end
	snd.PlaybackSpeed = playbackSpeed or 1
	snd.Volume = volume or template.Volume
	snd.Parent = SoundService
	snd:Play()
	local pitch = math.max(0.2, snd.PlaybackSpeed)
	local ttl = math.max(0.8, (snd.TimeLength > 0 and snd.TimeLength or 0.5) / pitch + 0.35)
	task.delay(ttl, function()
		if not snd then
			return
		end
		snd:Stop()
		snd.Parent = nil
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
