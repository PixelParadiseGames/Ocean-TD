--!strict
--[[
	Typed acquire/release pools for wave visuals (client-local).

	Hungry fish ("Tang" kind): one random MeshPart from ReplicatedStorage.HungryFish,
	pooled for reuse; size jitter on longest axis (min 25% below prior floor, same max).
	Crabs: ReplicatedStorage.Fish.CrabTemplate. Same acquireFish/releaseFish API.
	Urchins: ReplicatedStorage.Fish.Urchin.UrchinMesh (RootPart + ShellHitbox under UrchinMesh).

	Also pools food orbs, green/red arrow sets, ammo balls, and short SFX clones.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local WaveEntityPool = {}

WaveEntityPool.FISH_TANG = "Tang"
WaveEntityPool.FISH_CRAB = "CrabTemplate"
WaveEntityPool.FISH_URCHIN = "Urchin"

local MAX_FISH_PER_KIND = 48
local MAX_FOOD = 64
local MAX_ARROW = 40
local MAX_AMMO = 64
local MAX_SOUND_PER_KEY = 12
-- Longest-axis studs: floor = (longest + JITTER) * MIN_SCALE, max = longest + 3*JITTER.
local HUNGRY_SIZE_JITTER = 2 * 1.2
local HUNGRY_SIZE_MIN_SCALE = 0.75 -- smallest fish 25% below prior floor

local ATTR_KIND = "OceanTD_PoolFishKind"
local ATTR_BASE_SIZE = "OceanTD_FishBaseSize"
local ATTR_ARROW_TINT = "OceanTD_ArrowTint"
local ATTR_URCHIN_BASE_SX = "OceanTD_UrchinBaseSX"
local ATTR_URCHIN_BASE_SY = "OceanTD_UrchinBaseSY"
local ATTR_URCHIN_BASE_SZ = "OceanTD_UrchinBaseSZ"
local ATTR_URCHIN_BASE_OX = "OceanTD_UrchinBaseOX"
local ATTR_URCHIN_BASE_OY = "OceanTD_UrchinBaseOY"
local ATTR_URCHIN_BASE_OZ = "OceanTD_UrchinBaseOZ"
local ATTR_URCHIN_SCALE = "OceanTD_UrchinScale"
-- Current authored size = 1×; random up to 2× (100% larger).
local URCHIN_SCALE_MIN = 1
local URCHIN_SCALE_MAX = 2

local fishPools: { [string]: { Instance } } = {}
-- Prevents double-release / double-acquire (shared WaveSim + WaveGhostSim pool).
local fishInUse: { [Instance]: boolean } = {}
local foodPool: { BasePart } = {}
local arrowPool: { Instance } = {}
local redArrowPool: { Instance } = {}
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

-- RootPart when present (crab/urchin rigs); else PrimaryPart / first BasePart.
local function resolveMovementRoot(inst: Instance): BasePart?
	if inst:IsA("Model") then
		local named = inst:FindFirstChild("RootPart", true)
		if named and named:IsA("BasePart") then
			if not inst.PrimaryPart then
				inst.PrimaryPart = named
			end
			return named
		end
	end
	local named = inst:FindFirstChild("RootPart", true)
	if named and named:IsA("BasePart") then
		return named
	end
	return findPrimary(inst)
end

-- Utility parts that must stay invisible (authored hitboxes / movement roots).
local function isUtilityHitbox(p: BasePart): boolean
	local n = p.Name
	return n == "ShellHitbox" or n == "RootPart" or string.find(n, "Hitbox", 1, true) ~= nil
end

-- GhostSim fade tweens Transparency; restore mesh opacity but keep hitboxes invisible.
local function resetPartVisibility(inst: Instance)
	local function fix(p: BasePart)
		p.LocalTransparencyModifier = 0
		p.Transparency = if isUtilityHitbox(p) then 1 else 0
	end
	if inst:IsA("BasePart") then
		fix(inst)
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			fix(d)
		end
	end
end

-- Root stays anchored so Pivot/CFrame drives the assembly; welded legs stay
-- unanchored so C0 walk-cycle offsets actually move them.
local function prepareCrabInstance(inst: Instance): BasePart?
	local root = resolveMovementRoot(inst)
	local toDestroy: { Instance } = {}
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
			if isUtilityHitbox(d) then
				d.Transparency = 1
			end
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
		inst.CanCollide = false
		inst.CanTouch = false
		inst.CanQuery = false
		inst.CastShadow = false
		if isUtilityHitbox(inst) then
			inst.Transparency = 1
		end
		if inst == root then
			inst.Anchored = true
		else
			inst.Anchored = false
			inst.Massless = true
		end
	end
	return root
end

-- Urchins are CFrame-snapped every frame. Keep parts Anchored; hitboxes stay invisible.
local function prepareUrchinInstance(inst: Instance): BasePart?
	local root = resolveMovementRoot(inst)
	local toDestroy: { Instance } = {}
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			d.CastShadow = false
			d.Massless = true
			d.LocalTransparencyModifier = 0
			d.Transparency = if isUtilityHitbox(d) then 1 else 0
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
		inst.Massless = true
		inst.LocalTransparencyModifier = 0
		-- UrchinMesh container is the visible shell mesh, not a utility hitbox.
		inst.Transparency = if isUtilityHitbox(inst) then 1 else 0
	end
	return root
end

local function collectBaseParts(inst: Instance): { BasePart }
	local parts: { BasePart } = {}
	if inst:IsA("BasePart") then
		table.insert(parts, inst)
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

local function ensureUrchinBaseSnapshot(inst: Instance, root: BasePart)
	for _, p in ipairs(collectBaseParts(inst)) do
		if typeof(p:GetAttribute(ATTR_URCHIN_BASE_SX)) ~= "number" then
			p:SetAttribute(ATTR_URCHIN_BASE_SX, p.Size.X)
			p:SetAttribute(ATTR_URCHIN_BASE_SY, p.Size.Y)
			p:SetAttribute(ATTR_URCHIN_BASE_SZ, p.Size.Z)
			if p ~= root then
				local o = root.CFrame:ToObjectSpace(p.CFrame)
				p:SetAttribute(ATTR_URCHIN_BASE_OX, o.X)
				p:SetAttribute(ATTR_URCHIN_BASE_OY, o.Y)
				p:SetAttribute(ATTR_URCHIN_BASE_OZ, o.Z)
			end
		end
	end
end

local function applyUrchinScale(inst: Instance, root: BasePart, scale: number)
	local s = math.clamp(scale, URCHIN_SCALE_MIN, URCHIN_SCALE_MAX)
	ensureUrchinBaseSnapshot(inst, root)
	for _, p in ipairs(collectBaseParts(inst)) do
		local bx = p:GetAttribute(ATTR_URCHIN_BASE_SX)
		local by = p:GetAttribute(ATTR_URCHIN_BASE_SY)
		local bz = p:GetAttribute(ATTR_URCHIN_BASE_SZ)
		if typeof(bx) == "number" and typeof(by) == "number" and typeof(bz) == "number" then
			p.Size = Vector3.new(bx * s, by * s, bz * s)
		end
		if p ~= root then
			local ox = p:GetAttribute(ATTR_URCHIN_BASE_OX)
			local oy = p:GetAttribute(ATTR_URCHIN_BASE_OY)
			local oz = p:GetAttribute(ATTR_URCHIN_BASE_OZ)
			if typeof(ox) == "number" and typeof(oy) == "number" and typeof(oz) == "number" then
				local rel = root.CFrame:ToObjectSpace(p.CFrame)
				local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = rel:GetComponents()
				local rot = CFrame.new(0, 0, 0, r00, r01, r02, r10, r11, r12, r20, r21, r22)
				p.CFrame = root.CFrame * CFrame.new(ox * s, oy * s, oz * s) * rot
			end
		end
	end
	inst:SetAttribute(ATTR_URCHIN_SCALE, s)
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
	-- Floor 25% below prior minimum; same max as before (longest + 3*JITTER).
	local floorBase = longest + HUNGRY_SIZE_JITTER
	local minTarget = floorBase * HUNGRY_SIZE_MIN_SCALE
	local maxTarget = floorBase + 2 * HUNGRY_SIZE_JITTER
	local target = minTarget + math.random() * (maxTarget - minTarget)
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
	if kind == WaveEntityPool.FISH_URCHIN then
		local fishFolder = ReplicatedStorage:FindFirstChild("Fish")
		local tmpl: Instance? = nil
		if fishFolder then
			local urchinFolder = fishFolder:FindFirstChild("Urchin")
			if urchinFolder then
				tmpl = urchinFolder:FindFirstChild("UrchinMesh") or urchinFolder
			end
			if not tmpl then
				tmpl = fishFolder:FindFirstChild("UrchinTemplate")
			end
		end
		if not tmpl then
			local legacy = ReplicatedStorage:FindFirstChild("Urchin")
			if legacy then
				tmpl = legacy:FindFirstChild("UrchinMesh")
					or legacy:FindFirstChild("UrchinTemplate")
					or legacy:FindFirstChild("Urchin")
			end
		end
		if not tmpl then
			warn("[WAVEPOOL] Urchin missing (Fish.Urchin.UrchinMesh)")
			return nil
		end
		fishTemplateCache[kind] = tmpl
		return tmpl
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

local redArrowTemplateCache: Instance? = nil

local function getRedArrowTemplate(): Instance?
	if redArrowTemplateCache and redArrowTemplateCache.Parent then
		return redArrowTemplateCache
	end
	local arrows = ReplicatedStorage:FindFirstChild("RedArrows")
	if arrows then
		redArrowTemplateCache = arrows
		return arrows
	end
	return nil
end

local function paintArrowModel(model: Instance, color: Color3)
	local function paint(p: BasePart)
		p.Color = color
		if p:IsA("MeshPart") then
			-- Solid tint so green mesh textures don't fight the crab path color.
			p.TextureID = ""
		end
	end
	if model:IsA("BasePart") then
		paint(model)
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			paint(d)
		end
	end
	model:SetAttribute(ATTR_ARROW_TINT, "red")
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
	local root: BasePart?
	if kind == WaveEntityPool.FISH_URCHIN then
		root = prepareUrchinInstance(clone)
	elseif kind == WaveEntityPool.FISH_CRAB then
		root = prepareCrabInstance(clone)
	else
		prepareLocalFxInstance(clone)
		root = findPrimary(clone)
	end
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
		resetPartVisibility(inst)
		inst.Name = name
		if inst:IsA("Model") and not inst.PrimaryPart then
			inst.PrimaryPart = root
		end
		if kind == WaveEntityPool.FISH_TANG then
			applyHungrySizeJitter(root)
		elseif kind == WaveEntityPool.FISH_URCHIN then
			-- Re-assert anchors (pooled urchins may have been crab-prepared historically).
			prepareUrchinInstance(inst)
			applyUrchinScale(inst, root, URCHIN_SCALE_MIN + math.random() * (URCHIN_SCALE_MAX - URCHIN_SCALE_MIN))
		end
		fishInUse[inst] = true
		return inst, root
	end
	while #pool > 0 do
		local inst = table.remove(pool) :: Instance
		if inst and not fishInUse[inst] then
			local root = if kind == WaveEntityPool.FISH_CRAB or kind == WaveEntityPool.FISH_URCHIN
				then resolveMovementRoot(inst)
				else findPrimary(inst)
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
	local root = if kind == WaveEntityPool.FISH_URCHIN
		then resolveMovementRoot(model)
		else findPrimary(model)
	if root then
		stripHungerUi(root)
	end
	resetPartVisibility(model)
	if kind == WaveEntityPool.FISH_URCHIN and root then
		applyUrchinScale(model, root, 1)
	end
	-- Skip pooling if Destroy already ran (Parent locked); pcall avoids the throw.
	local ok = pcall(function()
		model.Parent = nil
	end)
	if not ok then
		return
	end
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

local function newArrowFromTemplate(name: string, preferRed: boolean): Instance?
	local tmpl = if preferRed then (getRedArrowTemplate() or getArrowTemplate()) else getArrowTemplate()
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
	if preferRed and not getRedArrowTemplate() then
		paintArrowModel(clone, Color3.fromRGB(230, 45, 55))
	elseif preferRed then
		clone:SetAttribute(ATTR_ARROW_TINT, "red")
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
	local clone = newArrowFromTemplate(name, false)
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

function WaveEntityPool.acquireRedArrows(name: string, parent: Instance, tint: Color3?): Instance?
	while #redArrowPool > 0 do
		local inst = table.remove(redArrowPool) :: Instance
		if inst then
			inst.Name = name
			inst.Parent = parent
			return inst
		end
	end
	local clone = newArrowFromTemplate(name, true)
	if not clone then
		return nil
	end
	-- Prefer Studio RedArrows; otherwise tint a GreenArrows clone.
	if not getRedArrowTemplate() then
		paintArrowModel(clone, tint or Color3.fromRGB(230, 45, 55))
	end
	clone.Parent = parent
	return clone
end

function WaveEntityPool.releaseRedArrows(model: Instance)
	model.Parent = nil
	if #redArrowPool < MAX_ARROW then
		table.insert(redArrowPool, model)
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
		redArrow = #redArrowPool,
		ammo = #ammoPool,
	}
	for kind, pool in pairs(fishPools) do
		out["fish:" .. kind] = #pool
	end
	return out
end

return WaveEntityPool
