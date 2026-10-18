--!strict
--[[
	End-of-path VFX for WaveSim: reef heart loss + happy fish exit emoji.
	Extracted so WaveSim stays under Luau's 200-local register limit.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))
local AudioSettings = require(oceanRoot:WaitForChild("Shared"):WaitForChild("AudioSettings"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local WaveEndVfx = {}

-- While true, stage/plot sync must not snap the reef heart (Plot Size cinematic owns it).
local routeHeartDriveLocked = false
-- Join intro / pre-ink: keep reef heart invisible until the path tip scale-up.
local heartIntroHoldHidden = false
-- True while the ink tip scale-up is running — block ClientPlot heart teardown.
local heartPopBusy = false
-- Skip Intro finished heart settle — never re-apply ink shrink / teardown races.
local heartSkipSettled = false

local REEF_TICK_SOUND_ID = "rbxassetid://128707491647978"
local REEF_TICK_PITCH_START = 1.2
local REEF_TICK_PITCH_STEP = 0.09
local REEF_TICK_PITCH_MIN = 0.45
local REEF_TICK_GAP = 0.07
local HEART_LOSS_MAX_STUDS = 100 * 1.4 -- happy exit base size
local HEART_LOSS_END_SCALE = 3 -- broken heart grows to 3× this max
local HEART_FALL_STUDS = 360
local HEART_FALL_SEC = 2.55
local HEART_SPRAY_STUDS = 95 -- lateral fan so multi-heart losses don't stack straight down
local HEART_LIGHT_RANGE = 50
local HEART_LIGHT_BRIGHTNESS = 0.9
local HEART_GUI_ORDER = 2600 -- above happy-exit billboards
local HAPPY_EXIT_SEC = 1.4
local HAPPY_EXIT_START_SCALE = 0.06 -- tiny at the heart; grows to 1× at the player
local HAPPY_EXIT_FAN_STUDS = 18 -- lateral spread at arrival
local HAPPY_EXIT_SOUND_ID = "rbxassetid://138571475125488"
local HAPPY_EXIT_PITCH_MIN = 0.82
local HAPPY_EXIT_PITCH_MAX = 1.28
local HEART_INK_REVEAL_SOUND_ID = "rbxassetid://95604943882087"
local HEART_INK_SCALE_EPS = 0.02
-- Finish firework (endpoint burst)
local FIREWORK_SIZE_MIN = 15
local FIREWORK_SIZE_MAX = 33
local FIREWORK_START_SCALE = 0.08
local FIREWORK_SPEED_MIN = 28
local FIREWORK_SPEED_MAX = 62
local FIREWORK_GRAV_MIN = 38
local FIREWORK_GRAV_MAX = 72
local FIREWORK_LIFE_MIN = 1.05
local FIREWORK_LIFE_MAX = 1.75
local END_HEART_RED = Color3.fromRGB(255, 40, 55)
local END_HEART_BLACK = Color3.new(0, 0, 0)
local UNDERFED_HIDE_SEC = 0.25

local reefTickSound = Instance.new("Sound")
reefTickSound.Name = "OceanTD_ReefTick"
reefTickSound.SoundId = REEF_TICK_SOUND_ID
reefTickSound.Volume = 0.95
AudioSettings.markNoSoundGroup(reefTickSound)
reefTickSound.Parent = SoundService

local happyExitSound = Instance.new("Sound")
happyExitSound.Name = "OceanTD_HappyExit"
happyExitSound.SoundId = HAPPY_EXIT_SOUND_ID
happyExitSound.Volume = 0.9
AudioSettings.markNoSoundGroup(happyExitSound)
happyExitSound.Parent = SoundService

local heartInkRevealSound = Instance.new("Sound")
heartInkRevealSound.Name = "OceanTD_HeartInkReveal"
heartInkRevealSound.SoundId = HEART_INK_REVEAL_SOUND_ID
heartInkRevealSound.Volume = 1.5
AudioSettings.markNoSoundGroup(heartInkRevealSound)
heartInkRevealSound.Parent = SoundService

task.defer(function()
	pcall(function()
		ContentProvider:PreloadAsync({ reefTickSound, happyExitSound, heartInkRevealSound })
	end)
end)

-- One-shot that cannot be SFX-ducked. Load → Play → destroy after real duration (never early).
local function playUnduckedOneShot(soundId: string, volume: number, pitch: number?, name: string?): Sound
	local spd = if typeof(pitch) == "number" then pitch :: number else 1
	local snd = Instance.new("Sound")
	snd.Name = name or "OceanTD_UnduckedSfx"
	snd.SoundId = soundId
	snd.Volume = volume
	snd.PlaybackSpeed = spd
	AudioSettings.markNoSoundGroup(snd)
	snd.Parent = SoundService
	task.defer(function()
		if snd.Parent then
			AudioSettings.markNoSoundGroup(snd)
		end
	end)
	task.spawn(function()
		if not snd.Parent then
			return
		end
		if not snd.IsLoaded then
			pcall(function()
				ContentProvider:PreloadAsync({ snd })
			end)
		end
		local loadDeadline = os.clock() + 4
		while snd.Parent and not snd.IsLoaded and os.clock() < loadDeadline do
			task.wait()
		end
		if not snd.Parent then
			return
		end
		AudioSettings.markNoSoundGroup(snd)
		snd:Play()
		pcall(function()
			SoundService:PlayLocalSound(snd)
		end)
		local len = snd.TimeLength
		local ttl = if typeof(len) == "number" and len > 0.05
			then (len / math.max(0.2, spd)) + 0.35
			else 2.5
		task.wait(ttl)
		if snd.Parent then
			snd:Destroy()
		end
	end)
	return snd
end

local getFolder: (() -> Folder)? = nil
local endHeartPart: BasePart? = nil
local endHeartPlotId: string? = nil
local endHeartAnimToken = 0
local heartHideToken = 0
local heartHideUntil = 0
local heartInkScaleToken = 0
local heartNativeScaleByPlot: { [string]: number } = {}
-- Survives destroyRouteHeartClone — Skip must not forget full size after a mid-ink teardown.
local heartFullNativeByPlot: { [string]: number } = {}
local heartScaleMulByPlot: { [string]: number } = {}
local heartRestSizeByPlot: { [string]: Vector3 } = {}
local reefTickStreak = 0
local rng = Random.new()
local happyExitVisible = true
local activeHappyExits: { Instance } = {}

local function unregisterHappyExit(anchor: Instance)
	local i = table.find(activeHappyExits, anchor)
	if i then
		table.remove(activeHappyExits, i)
	end
end

local function registerHappyExit(anchor: Instance)
	table.insert(activeHappyExits, anchor)
	anchor.Destroying:Connect(function()
		unregisterHappyExit(anchor)
	end)
end

local function clearActiveHappyExits()
	for i = #activeHappyExits, 1, -1 do
		local anchor = activeHappyExits[i]
		if anchor.Parent then
			anchor:Destroy()
		end
	end
	table.clear(activeHappyExits)
end

function WaveEndVfx.setHappyExitVisible(visible: boolean)
	if happyExitVisible == visible then
		return
	end
	happyExitVisible = visible
	if not visible then
		clearActiveHappyExits()
	end
end

function WaveEndVfx.areHappyExitVisible(): boolean
	return happyExitVisible
end

-- Authored EndPoint sits at W8; plot-size routes end earlier — show a local heart at route end.
local routeEndPosByPlot: { [string]: Vector3 } = {}
local routeHeartCloneByPlot: { [string]: Instance } = {} -- EndPoint clone (or heart part)
local hiddenSourceRootByPlot: { [string]: Instance } = {}

function WaveEndVfx.bind(folderFn: () -> Folder)
	getFolder = folderFn
end

function WaveEndVfx.resetStreak()
	reefTickStreak = 0
	heartHideToken += 1
	heartHideUntil = 0
	local heart = endHeartPart
	if heart and heart.Parent then
		heart.LocalTransparencyModifier = 0
		heart.Color = END_HEART_RED
	end
end

local function resolveFolder(): Folder
	if getFolder then
		return getFolder()
	end
	local existing = Workspace:FindFirstChild("OceanTD_LocalWaves")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "OceanTD_LocalWaves"
	f.Parent = Workspace
	return f
end

local function findAuthoredEndPoint(): Instance?
	local route = Workspace:FindFirstChild("WaveRoute")
	local a = route and route:FindFirstChild("A")
	return a and a:FindFirstChild("EndPoint")
end

-- Preferred authored package: ReplicatedStorage.OceanTD.ReefHeart (heart + Sphere + light).
-- Avoids fragile EndPoint sibling / proximity orb discovery on the live WaveRoute.
local function getReefHeartTemplate(): Instance?
	local tmpl = oceanRoot:FindFirstChild("ReefHeart")
	if not tmpl then
		return nil
	end
	local heart = tmpl:FindFirstChild("heart", true)
	if not (heart and heart:IsA("BasePart")) then
		return nil
	end
	return tmpl
end

local function nameLooksLikeHeart(name: string): boolean
	local n = string.lower(name)
	return n == "heart" or string.find(n, "heart", 1, true) ~= nil
end

local function nameLooksLikeOrb(name: string): boolean
	local n = string.lower(name)
	return n == "orb"
		or string.find(n, "orb", 1, true) ~= nil
		or string.find(n, "glow", 1, true) ~= nil
		or string.find(n, "sphere", 1, true) ~= nil
		or string.find(n, "bubble", 1, true) ~= nil
		or string.find(n, "glass", 1, true) ~= nil
end

-- Glass sphere may not be named "orb" — detect by material / see-through size too.
local function isGlassOrbPart(p: BasePart): boolean
	if nameLooksLikeHeart(p.Name) then
		return false
	end
	if nameLooksLikeOrb(p.Name) then
		return true
	end
	local mat = p.Material
	if mat == Enum.Material.Glass or mat == Enum.Material.ForceField then
		return true
	end
	if p.Transparency > 0.05 and p.Transparency < 0.98 and p.Size.Magnitude >= 3 then
		return true
	end
	return false
end

local function findHeartIn(root: Instance?): BasePart?
	if not root then
		return nil
	end
	local heart = root:FindFirstChild("heart", true)
	if heart and heart:IsA("BasePart") then
		return heart
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and nameLooksLikeHeart(d.Name) then
			return d
		end
	end
	-- Fallback: any BasePart under EndPoint
	if root:IsA("BasePart") then
		return root
	end
	return root:FindFirstChildWhichIsA("BasePart", true)
end

local function packageHasOrb(root: Instance): boolean
	if root:IsA("BasePart") and isGlassOrbPart(root) then
		return true
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and isGlassOrbPart(d) then
			return true
		end
	end
	return false
end

-- Companion visuals sitting next to EndPoint (glass sphere, glow, etc.).
-- Use proximity — name/material checks alone were missing the authored orb.
local function collectOrbSiblings(endPoint: Instance): { Instance }
	local out: { Instance } = {}
	local parent = endPoint.Parent
	if not parent or parent == Workspace then
		return out
	end
	local heart = findHeartIn(endPoint)
	local origin: Vector3? = nil
	if heart then
		origin = heart.Position
	elseif endPoint:IsA("BasePart") then
		origin = endPoint.Position
	else
		local p = endPoint:FindFirstChildWhichIsA("BasePart", true)
		origin = if p then p.Position else nil
	end

	local function alreadyListed(inst: Instance): boolean
		return table.find(out, inst) ~= nil
	end

	for _, ch in ipairs(parent:GetChildren()) do
		if ch == endPoint or alreadyListed(ch) then
			continue
		end
		-- Classic name/material match.
		if ch:IsA("BasePart") and isGlassOrbPart(ch) then
			table.insert(out, ch)
			continue
		end
		if (ch:IsA("Model") or ch:IsA("Folder")) and packageHasOrb(ch) then
			table.insert(out, ch)
			continue
		end
		-- Proximity fallback: nearby ball / see-through / glass (not opaque path bricks).
		if origin then
			local sample: BasePart? = if ch:IsA("BasePart") then ch else ch:FindFirstChildWhichIsA("BasePart", true)
			if sample and not nameLooksLikeHeart(ch.Name) and not nameLooksLikeHeart(sample.Name) then
				local near = (sample.Position - origin).Magnitude <= 30
				local ball = sample:IsA("Part") and (sample :: Part).Shape == Enum.PartType.Ball
				local seeThrough = sample.Transparency > 0.1
				local glassMat = sample.Material == Enum.Material.Glass
					or sample.Material == Enum.Material.ForceField
					or sample.Material == Enum.Material.Ice
				if near and (ball or seeThrough or glassMat or nameLooksLikeOrb(sample.Name)) then
					table.insert(out, ch)
				end
			end
		end
	end
	return out
end

local FULL_NATIVE_ATTR = "OceanTD_FullNativeScale"
-- Stamped after Plot1→local-plot rigid remap (RS ReefHeart is authored in Plot1 space).
local PLOT_REMAP_ATTR = "OceanTD_HeartPlotRemapped"

local function rememberFullNative(plotId: string, scale: number)
	if scale < 0.85 then
		return
	end
	heartFullNativeByPlot[plotId] = scale
	heartNativeScaleByPlot[plotId] = scale
	local clone = routeHeartCloneByPlot[plotId]
	if clone then
		clone:SetAttribute(FULL_NATIVE_ATTR, scale)
	end
end

local function getFullNative(plotId: string): number
	-- Prefer scale stamped on the live package (survives table clears).
	local clone = routeHeartCloneByPlot[plotId]
	if clone then
		local attr = clone:GetAttribute(FULL_NATIVE_ATTR)
		if typeof(attr) == "number" and attr >= 0.85 then
			return attr
		end
	end
	local durable = heartFullNativeByPlot[plotId]
	if typeof(durable) == "number" and durable >= 0.85 then
		return durable
	end
	local native = heartNativeScaleByPlot[plotId]
	if typeof(native) == "number" and native >= 0.85 then
		return native
	end
	return 1
end

local ensureOrbInPackage: (Instance?, Instance?) -> boolean
local finishInkHeartVisible: (string) -> ()

local AUTHORED_T_ATTR = "OceanTD_AuthoredT"
local AUTHORED_MAT_ATTR = "OceanTD_AuthoredMat"
local AUTHORED_REF_ATTR = "OceanTD_AuthoredRef"

type PartAppearance = {
	transparency: number,
	material: Enum.Material,
	reflectance: number,
	materialVariant: string,
}

local function readPartAppearance(p: BasePart): PartAppearance
	return {
		transparency = p.Transparency,
		material = p.Material,
		reflectance = p.Reflectance,
		materialVariant = p.MaterialVariant,
	}
end

local function applyPartAppearance(p: BasePart, app: PartAppearance)
	p.Transparency = app.transparency
	p.Material = app.material
	p.Reflectance = app.reflectance
	p.MaterialVariant = app.materialVariant
end

local function capturePartAppearanceAttrs(p: BasePart)
	-- Always refresh from current values at clone time (source glass / ForceField).
	p:SetAttribute(AUTHORED_T_ATTR, p.Transparency)
	p:SetAttribute(AUTHORED_MAT_ATTR, p.Material.Name)
	p:SetAttribute(AUTHORED_REF_ATTR, p.Reflectance)
end

local function restoreAuthoredAppearance(p: BasePart)
	local t = p:GetAttribute(AUTHORED_T_ATTR)
	if typeof(t) == "number" then
		p.Transparency = t
	end
	local matName = p:GetAttribute(AUTHORED_MAT_ATTR)
	if typeof(matName) == "string" then
		local mat = (Enum.Material :: any)[matName]
		if typeof(mat) == "EnumItem" then
			p.Material = mat
		end
	end
	local ref = p:GetAttribute(AUTHORED_REF_ATTR)
	if typeof(ref) == "number" then
		p.Reflectance = ref
	end
end

-- Keep welds so heart + orb stay one rigid assembly. Only neutralize physics.
-- Must be defined before cloneHeartOrbPackage (Luau locals are not hoisted).
local function prepareLocalHeartClone(inst: Instance)
	local function prepPart(p: BasePart)
		capturePartAppearanceAttrs(p)
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.LocalTransparencyModifier = 0
		p.AssemblyLinearVelocity = Vector3.zero
		p.AssemblyAngularVelocity = Vector3.zero
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			prepPart(d)
		end
	end
	if inst:IsA("BasePart") then
		prepPart(inst)
	end
end

-- If the route package lost its glass sphere, clone it back from authored source.
-- Companions are rebased to the clone heart (source is at W8; clone may already sit at route end).
ensureOrbInPackage = function(clone: Instance?, sourceRoot: Instance?): boolean
	if not clone or not clone.Parent then
		return false
	end
	if packageHasOrb(clone) then
		return true
	end
	if not sourceRoot or not sourceRoot.Parent then
		return false
	end
	local cloneHeart = findHeartIn(clone)
	local srcHeart = findHeartIn(sourceRoot) or (sourceRoot:IsA("BasePart") and sourceRoot or nil)
	if not cloneHeart or not srcHeart or not srcHeart:IsA("BasePart") then
		return false
	end

	local function rebaseToCloneHeart(inst: Instance)
		local function rebasePart(p: BasePart)
			local offset = srcHeart.CFrame:ToObjectSpace(p.CFrame)
			p.CFrame = cloneHeart.CFrame * offset
		end
		if inst:IsA("BasePart") then
			rebasePart(inst)
		end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				rebasePart(d)
			end
		end
	end

	local added = false
	for _, sib in ipairs(collectOrbSiblings(sourceRoot)) do
		local c = sib:Clone()
		c.Parent = clone
		prepareLocalHeartClone(c)
		rebaseToCloneHeart(c)
		added = true
	end
	for _, d in ipairs(sourceRoot:GetDescendants()) do
		if d:IsA("BasePart") and isGlassOrbPart(d) then
			local existing = clone:FindFirstChild(d.Name, true)
			if not existing then
				local c = d:Clone()
				c.Parent = clone
				capturePartAppearanceAttrs(c)
				c.Anchored = true
				c.CanCollide = false
				c.CanQuery = false
				c.CanTouch = false
				c.CastShadow = false
				c.LocalTransparencyModifier = 0
				rebaseToCloneHeart(c)
				added = true
			end
		end
	end
	return packageHasOrb(clone) or added
end

local function collectAppearanceByName(root: Instance, into: { [string]: PartAppearance })
	local function consider(p: BasePart)
		if nameLooksLikeHeart(p.Name) then
			return
		end
		into[string.lower(p.Name)] = readPartAppearance(p)
	end
	if root:IsA("BasePart") then
		consider(root)
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			consider(d)
		end
	end
end

-- Re-apply glass/sphere look from authored source (Skip / force-visible must not leave opaque Plastic).
local function syncNonHeartAppearanceFromSource(cloneRoot: Instance?, sourceRoot: Instance?)
	if not cloneRoot or not cloneRoot.Parent or not sourceRoot or not sourceRoot.Parent then
		return
	end
	local byName: { [string]: PartAppearance } = {}
	collectAppearanceByName(sourceRoot, byName)
	for _, sib in ipairs(collectOrbSiblings(sourceRoot)) do
		collectAppearanceByName(sib, byName)
	end
	local function applyTo(p: BasePart)
		if nameLooksLikeHeart(p.Name) then
			return
		end
		local app = byName[string.lower(p.Name)]
		if app then
			applyPartAppearance(p, app)
			capturePartAppearanceAttrs(p)
		else
			restoreAuthoredAppearance(p)
		end
		p.LocalTransparencyModifier = 0
	end
	if cloneRoot:IsA("BasePart") then
		applyTo(cloneRoot)
	end
	for _, d in ipairs(cloneRoot:GetDescendants()) do
		if d:IsA("BasePart") then
			applyTo(d)
		end
	end
end

-- Clone a complete template (RS ReefHeart or EndPoint+orb) into one Model for ScaleTo/PivotTo.
local function cloneHeartOrbPackage(sourceRoot: Instance, sourceHeart: BasePart): Model
	local model = Instance.new("Model")
	model.Name = "OceanTD_RouteHeartPkg"

	-- RS ReefHeart / self-contained package: clone children flat (heart + Sphere + lights).
	local looksSelfContained = sourceRoot:FindFirstChild("heart", true) ~= nil
		and (sourceRoot:FindFirstChild("Sphere", true) ~= nil or packageHasOrb(sourceRoot))
	if looksSelfContained and (sourceRoot:IsA("Model") or sourceRoot:IsA("Folder")) then
		for _, ch in ipairs(sourceRoot:GetChildren()) do
			local c = ch:Clone()
			c.Parent = model
		end
	else
		-- Legacy: EndPoint + nearby orb siblings gathered by proximity.
		local companions = collectOrbSiblings(sourceRoot)
		local endClone = sourceRoot:Clone()
		endClone.Parent = model
		for _, sib in ipairs(companions) do
			local c = sib:Clone()
			c.Parent = model
		end
		if not findHeartIn(model) and sourceHeart.Parent ~= sourceRoot then
			local hc = sourceHeart:Clone()
			hc.Parent = model
		end
	end

	prepareLocalHeartClone(model)
	-- Clear hide left over from cloning a LocalTransparencyModifier=1 source.
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 0
			capturePartAppearanceAttrs(d)
		end
	end
	local heart = findHeartIn(model) or sourceHeart
	if heart and heart:IsA("BasePart") then
		model.PrimaryPart = if heart:IsDescendantOf(model) then heart else findHeartIn(model)
	end
	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
	end
	return model
end

-- Server replicates EndPoint to Workspace.OceanTD_PlotHearts.PlotN (N>=2).
-- Plot1 uses authored WaveRoute.A.EndPoint.
local function findPlotEndHeartRoot(plotId: string): Instance?
	if plotId == "Plot1" then
		return findAuthoredEndPoint()
	end
	local folder = Workspace:FindFirstChild("OceanTD_PlotHearts")
	if not folder then
		return nil
	end
	return folder:FindFirstChild(plotId)
end

-- Template used for clone + orb repair. Prefer RS ReefHeart over live EndPoint.
local function getHeartCloneSource(plotId: string): (Instance?, BasePart?)
	local tmpl = getReefHeartTemplate()
	if tmpl then
		local heart = findHeartIn(tmpl)
		if heart then
			return tmpl, heart
		end
	end
	local root = findPlotEndHeartRoot(plotId)
	local heart = findHeartIn(root)
	if heart then
		return root, heart
	end
	return root, nil
end

local heartByPlotId: { [string]: BasePart } = {}

local function setTreeLocalHidden(root: Instance, hidden: boolean)
	local mod = if hidden then 1 else 0
	if root:IsA("BasePart") then
		root.LocalTransparencyModifier = mod
	end
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = mod
		elseif d:IsA("Decal") or d:IsA("Texture") then
			-- LTM doesn't apply; leave authored transparency when showing.
			if hidden then
				d:SetAttribute("OceanTD_PrevDecalT", d.Transparency)
				d.Transparency = 1
			else
				local prev = d:GetAttribute("OceanTD_PrevDecalT")
				d.Transparency = if typeof(prev) == "number" then prev else 0
				d:SetAttribute("OceanTD_PrevDecalT", nil)
			end
		elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") or d:IsA("Fire") or d:IsA("PointLight") then
			if hidden then
				d:SetAttribute("OceanTD_PrevFxOn", (d :: any).Enabled == true)
				;(d :: any).Enabled = false
			else
				local prev = d:GetAttribute("OceanTD_PrevFxOn")
				;(d :: any).Enabled = prev ~= false
				d:SetAttribute("OceanTD_PrevFxOn", nil)
			end
		end
	end
end

local function clearHeartScaleCache(plotId: string)
	heartNativeScaleByPlot[plotId] = nil
	heartRestSizeByPlot[plotId] = nil
	-- Keep heartFullNativeByPlot — Skip settle needs the pre-ink full size after teardown.
	-- Keep mul so a recreated clone can stay shrunk during ink reveal.
end

local function destroyRouteHeartClone(plotId: string)
	local clone = routeHeartCloneByPlot[plotId]
	if clone then
		clone:Destroy()
		routeHeartCloneByPlot[plotId] = nil
	end
	local src = hiddenSourceRootByPlot[plotId]
	if src and src.Parent then
		setTreeLocalHidden(src, false)
		for _, sib in ipairs(collectOrbSiblings(src)) do
			setTreeLocalHidden(sib, false)
		end
	end
	hiddenSourceRootByPlot[plotId] = nil
	clearHeartScaleCache(plotId)
end

local function heartVisualRoot(plotId: string): Instance?
	local clone = routeHeartCloneByPlot[plotId]
	if clone and clone.Parent then
		return clone
	end
	return findPlotEndHeartRoot(plotId)
end

-- ScaleTo needs a Model. Wrap Folder/loose EndPoint packages so orb scales with heart.
local function ensureRouteHeartModel(inst: Instance): Model
	if inst:IsA("Model") then
		local heart = findHeartIn(inst)
		if heart then
			inst.PrimaryPart = heart
		end
		return inst
	end
	local model = Instance.new("Model")
	model.Name = inst.Name
	local heart: BasePart? = nil
	if inst:IsA("BasePart") then
		heart = inst
		inst.Parent = model
	else
		local children = inst:GetChildren()
		for _, ch in ipairs(children) do
			ch.Parent = model
		end
		heart = findHeartIn(model)
		if inst.Parent then
			inst:Destroy()
		end
	end
	if heart then
		model.PrimaryPart = heart
	end
	return model
end

local function pivotOf(inst: Instance): CFrame
	if inst:IsA("Model") then
		return inst:GetPivot()
	end
	if inst:IsA("BasePart") then
		return inst.CFrame
	end
	local p = inst:FindFirstChildWhichIsA("BasePart", true)
	return if p then p.CFrame else CFrame.new()
end

local function setPivot(inst: Instance, cf: CFrame)
	if inst:IsA("Model") then
		inst:PivotTo(cf)
	elseif inst:IsA("BasePart") then
		inst.CFrame = cf
	else
		local heart = findHeartIn(inst)
		if heart then
			local delta = cf * pivotOf(inst):Inverse()
			for _, d in ipairs(inst:GetDescendants()) do
				if d:IsA("BasePart") then
					d.CFrame = delta * d.CFrame
				end
			end
		end
	end
end

-- RS ReefHeart / Plot1 EndPoint are authored in Plot1 space — rigid remap onto the
-- local plot so yaw matches the player's pad (Plot2+ were facing Plot1 before).
local function remapHeartPackageToLocalPlot(inst: Instance)
	if inst:GetAttribute(PLOT_REMAP_ATTR) == true then
		return
	end
	local function remapPart(p: BasePart)
		p.CFrame = ClientPlot.remapCFrameFromPlot1(p.CFrame)
	end
	if inst:IsA("BasePart") then
		remapPart(inst)
	end
	for _, d in ipairs(inst:GetDescendants()) do
		if d:IsA("BasePart") then
			remapPart(d)
		end
	end
	inst:SetAttribute(PLOT_REMAP_ATTR, true)
end

local function snapHeartRootToRouteEnd(plotId: string)
	local routeEnd = routeEndPosByPlot[plotId]
	local root = heartVisualRoot(plotId)
	if not routeEnd or not root or not root.Parent then
		return
	end
	local heart = findHeartIn(root) or (root:IsA("BasePart") and root or nil)
	if not heart or not heart:IsA("BasePart") then
		return
	end
	-- Keep plot-remapped rotation; only slide so the heart mesh sits on the waypoint.
	local delta = routeEnd - heart.Position
	if delta.Magnitude < 1e-4 then
		return
	end
	setPivot(root, CFrame.new(delta) * pivotOf(root))
end

local function heartPartForScale(plotId: string, root: Instance?): BasePart?
	if root then
		local h = findHeartIn(root)
		if h then
			return h
		end
		if root:IsA("BasePart") then
			return root
		end
	end
	local cached = heartByPlotId[plotId]
	if cached and cached.Parent then
		return cached
	end
	return nil
end

-- mul 0..1+ for ink pop. `forceVisible` unhides even while tiny (scale-up must be seen).
-- Always ScaleTo the Model package so heart + orb stay together (never Size-only on heart).
-- Do not call resolveEndHeartForPlot here — applyRouteHeart re-enters via reapplyHeartScaleMul.
local function applyHeartScaleMul(plotId: string, mul: number, forceVisible: boolean?)
	local root = heartVisualRoot(plotId)
	if not root or not root.Parent then
		return
	end
	local heart = heartPartForScale(plotId, root)
	local m = math.clamp(mul, 0, 2)
	heartScaleMulByPlot[plotId] = m
	local show = forceVisible == true or m >= HEART_INK_SCALE_EPS

	local model: Model? = if root:IsA("Model") then root else nil
	if not model and root.Parent then
		-- Legacy non-model clone: wrap in place so orb scales with heart.
		local parent = root.Parent
		local modelWrap = ensureRouteHeartModel(root)
		modelWrap.Parent = parent
		routeHeartCloneByPlot[plotId] = modelWrap
		model = modelWrap
		root = modelWrap
		heart = findHeartIn(modelWrap) or heart
	end

	if model then
		local native = heartNativeScaleByPlot[plotId] or heartFullNativeByPlot[plotId]
		if native == nil or native < 0.85 then
			local cur = model:GetScale()
			-- Never cache a mid-ink shrunk scale as "native" (Skip used to leave a tiny heart).
			if cur >= 0.85 then
				native = cur
				rememberFullNative(plotId, cur)
			elseif m > 1e-3 and cur >= 0.05 then
				native = math.max(0.85, cur / m)
				rememberFullNative(plotId, native)
			else
				native = getFullNative(plotId)
			end
			heartNativeScaleByPlot[plotId] = native
		end
		pcall(function()
			model:ScaleTo(math.max(1e-3, native * math.max(m, 1e-3)))
		end)
		snapHeartRootToRouteEnd(plotId)
	elseif heart then
		-- Last resort (should be rare after ensureRouteHeartModel).
		local rest = heartRestSizeByPlot[plotId]
		if rest == nil then
			rest = heart.Size
			if rest.Magnitude < 0.05 then
				rest = Vector3.new(2, 2, 2)
			end
			heartRestSizeByPlot[plotId] = rest
		end
		heart.Size = rest * math.max(m, 1e-3)
		snapHeartRootToRouteEnd(plotId)
	end

	setTreeLocalHidden(root, not show)
	if show and heart then
		heart.LocalTransparencyModifier = 0
	end
end

-- Caller should resolveEndHeartForPlot first so a clone exists.
local function forceHeartFullyVisible(plotId: string)
	heartScaleMulByPlot[plotId] = nil
	local root = heartVisualRoot(plotId)
	local heart = heartPartForScale(plotId, root) or endHeartPart
	if root and root:IsA("Model") then
		local cur = root:GetScale()
		if cur >= 0.85 then
			-- Already full size — never ScaleTo(1) over a larger authored package.
			rememberFullNative(plotId, cur)
		else
			local native = getFullNative(plotId)
			heartNativeScaleByPlot[plotId] = native
			pcall(function()
				root:ScaleTo(native)
			end)
		end
	elseif heart then
		local rest = heartRestSizeByPlot[plotId]
		if rest then
			heart.Size = rest
		elseif heart.Size.Magnitude < 0.05 then
			heart.Size = Vector3.new(2, 2, 2)
		end
	end
	if root and root.Parent then
		setTreeLocalHidden(root, false)
	end
	-- Also clear any intro hide on the authored source (clone path keeps source dark).
	local src = findPlotEndHeartRoot(plotId)
	local clone = routeHeartCloneByPlot[plotId]
	if src and src.Parent and not (clone and clone.Parent) then
		setTreeLocalHidden(src, false)
		for _, sib in ipairs(collectOrbSiblings(src)) do
			setTreeLocalHidden(sib, false)
		end
	end
	if heart and heart.Parent then
		heart.LocalTransparencyModifier = 0
		heart.Transparency = 0
		heart.Color = END_HEART_RED
	end
	local function unhideTree(inst: Instance?)
		if not inst then
			return
		end
		local function unhidePart(p: BasePart)
			p.LocalTransparencyModifier = 0
			if nameLooksLikeHeart(p.Name) then
				p.Transparency = 0
			else
				-- Orbs / spheres / shells: restore glass Material + Transparency (never force opaque).
				restoreAuthoredAppearance(p)
			end
		end
		if inst:IsA("BasePart") then
			unhidePart(inst)
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			local prev = inst:GetAttribute("OceanTD_PrevDecalT")
			inst.Transparency = if typeof(prev) == "number" then prev else inst.Transparency
		elseif inst:IsA("ParticleEmitter") or inst:IsA("Beam") or inst:IsA("Trail") then
			(inst :: any).Enabled = true
		end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				unhidePart(d)
			elseif d:IsA("Decal") or d:IsA("Texture") then
				local prev = d:GetAttribute("OceanTD_PrevDecalT")
				if typeof(prev) == "number" then
					d.Transparency = prev
				end
			elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") then
				(d :: any).Enabled = true
			end
		end
	end
	unhideTree(root)
	unhideTree(clone)
	snapHeartRootToRouteEnd(plotId)
end

local function reapplyHeartScaleMul(plotId: string)
	local mul = heartScaleMulByPlot[plotId]
	if mul == nil then
		return
	end
	-- During scale-up (hold released), keep the pop visible across clone rebuilds.
	local forceVis = (not heartIntroHoldHidden) and mul >= HEART_INK_SCALE_EPS
	applyHeartScaleMul(plotId, mul, forceVis)
end

local function waitForHeartRoot(plotId: string, timeoutSec: number): (Instance?, BasePart?)
	local deadline = os.clock() + math.max(0.2, timeoutSec)
	while os.clock() < deadline do
		if not routeHeartDriveLocked then
			-- Public sync builds/moves the route clone without needing locals defined below.
			WaveEndVfx.syncToPlotSizeStage(nil, plotId)
		end
		local root = heartVisualRoot(plotId)
		local heart = heartPartForScale(plotId, root) or endHeartPart or WaveEndVfx.getEndHeartPart()
		if root and root.Parent and heart and heart.Parent then
			return root, heart
		end
		task.wait(0.05)
	end
	return heartVisualRoot(plotId), endHeartPart
end

local function waitOneHeartInkBeat(snd: Sound): number
	-- Returns approximate seconds waited for this beat.
	local t0 = os.clock()
	while snd.Parent and os.clock() - t0 < 2.5 do
		if snd.IsPlaying and snd.TimeLength > 0.05 then
			local waitSec = math.clamp(snd.TimeLength / math.max(0.2, snd.PlaybackSpeed), 0.12, 2.5)
			task.wait(waitSec)
			return math.max(0.12, os.clock() - t0)
		end
		task.wait(0.05)
	end
	if os.clock() - t0 < 0.2 then
		task.wait(0.35)
		return 0.35
	end
	return math.max(0.12, os.clock() - t0)
end

local function playHeartInkSoundTwiceAndWait()
	-- Quick zoom to the heart on the first beat; hold; ease back as the second beat ends.
	local IntroCamPunch = require(script.Parent:WaitForChild("IntroCamPunch"))
	local heartPos = WaveEndVfx.getEndHeartWorldPos()
	-- Stronger pull from PlotCam overview so the heart zoom reads clearly.
	local punch = IntroCamPunch.beginHold(heartPos, 0.42, 0.42, { freezeFocus = true })

	local snd1 = playUnduckedOneShot(HEART_INK_REVEAL_SOUND_ID, 1.6, nil, "OceanTD_HeartInkRevealPlay")
	local beat1Len = waitOneHeartInkBeat(snd1)

	local snd2 = playUnduckedOneShot(HEART_INK_REVEAL_SOUND_ID, 1.6, nil, "OceanTD_HeartInkRevealPlay")
	-- Ease back over most of beat 2 so we land as it finishes (use beat1 length as estimate).
	if punch then
		punch.release(math.max(0.22, beat1Len * 0.9))
	end
	waitOneHeartInkBeat(snd2)
end

local function playHeartInkSoundTwice()
	task.spawn(playHeartInkSoundTwiceAndWait)
end

local function resolveSourceHeart(plotId: string): (Instance?, BasePart?)
	-- Live plot EndPoint (for hide-in-place). Clone visuals prefer RS ReefHeart.
	local root = findPlotEndHeartRoot(plotId)
	local heart = findHeartIn(root)
	if heart then
		heartByPlotId[plotId] = heart
	else
		heartByPlotId[plotId] = nil
	end
	return root, heart
end

local function applyRouteHeartForPlot(plotId: string): BasePart?
	local routeEnd = routeEndPosByPlot[plotId]
	local authoredRoot, authoredHeart = resolveSourceHeart(plotId)
	local cloneSrc, cloneHeartSrc = getHeartCloneSource(plotId)
	if not cloneHeartSrc then
		destroyRouteHeartClone(plotId)
		return nil
	end

	-- No override → show authored heart in place (or RS clone at authored pose).
	if not routeEnd then
		destroyRouteHeartClone(plotId)
		if authoredHeart then
			endHeartPart = authoredHeart
			endHeartPlotId = plotId
			if heartIntroHoldHidden then
				if authoredRoot then
					setTreeLocalHidden(authoredRoot, true)
				else
					authoredHeart.LocalTransparencyModifier = 1
				end
			end
			return authoredHeart
		end
		return nil
	end

	-- Hide authored EndPoint (+ orb siblings) locally; show RS/cloned package at fish stop.
	if authoredRoot then
		setTreeLocalHidden(authoredRoot, true)
		for _, sib in ipairs(collectOrbSiblings(authoredRoot)) do
			setTreeLocalHidden(sib, true)
		end
		hiddenSourceRootByPlot[plotId] = authoredRoot
	end

	local clone = routeHeartCloneByPlot[plotId]
	-- Stale packages (missing Sphere/heart, or never plot-remapped): rebuild from RS ReefHeart.
	if clone and clone.Parent then
		local hasHeart = findHeartIn(clone) ~= nil
		local hasOrb = packageHasOrb(clone)
		local needsRs = getReefHeartTemplate() ~= nil
		local unmapped = clone:GetAttribute(PLOT_REMAP_ATTR) ~= true
		if not hasHeart or (needsRs and (not hasOrb or unmapped)) then
			destroyRouteHeartClone(plotId)
			clone = nil
		end
	end
	if not clone or not clone.Parent then
		local template = cloneSrc or cloneHeartSrc
		local model = cloneHeartOrbPackage(template, cloneHeartSrc)
		model.Name = "OceanTD_RouteHeart_" .. plotId
		-- Orient into this player's plot before parenting/snapping (Plot2+ yaw).
		remapHeartPackageToLocalPlot(model)
		model.Parent = resolveFolder()
		clone = model
		routeHeartCloneByPlot[plotId] = clone
		-- Capture native scale once at full size (before any ink shrink).
		local captured = model:GetScale()
		if captured < 0.85 then
			rememberFullNative(plotId, 1)
			pcall(function()
				model:ScaleTo(1)
			end)
		else
			rememberFullNative(plotId, captured)
		end
		ensureOrbInPackage(clone, cloneSrc)
	else
		-- Repair missing Sphere pieces from the RS template without full rebuild.
		ensureOrbInPackage(clone, cloneSrc)
	end

	local cloneHeart = findHeartIn(clone) or (clone:IsA("BasePart") and clone or nil)
	if not cloneHeart or not cloneHeart:IsA("BasePart") then
		destroyRouteHeartClone(plotId)
		endHeartPart = authoredHeart
		endHeartPlotId = plotId
		if heartIntroHoldHidden and authoredHeart then
			authoredHeart.LocalTransparencyModifier = 1
		end
		return authoredHeart
	end

	-- Slide package so the heart mesh sits on the route end (keep plot yaw).
	local delta = routeEnd - cloneHeart.Position
	setPivot(clone, CFrame.new(delta) * pivotOf(clone))

	cloneHeart.Color = END_HEART_RED
	cloneHeart.LocalTransparencyModifier = 0
	endHeartPart = cloneHeart
	endHeartPlotId = plotId
	heartByPlotId[plotId] = cloneHeart
	reapplyHeartScaleMul(plotId)
	if heartIntroHoldHidden and not heartSkipSettled then
		applyHeartScaleMul(plotId, 0, false)
	end
	return cloneHeart
end

local function resolveEndHeartForPlot(plotId: string): BasePart?
	local cached = heartByPlotId[plotId]
	if cached and cached.Parent and routeEndPosByPlot[plotId] then
		-- Prefer live route clone when we have a route end.
		local clone = routeHeartCloneByPlot[plotId]
		if clone and clone.Parent then
			local h = findHeartIn(clone)
			if h then
				endHeartPart = h
				endHeartPlotId = plotId
				return h
			end
		end
	end
	return applyRouteHeartForPlot(plotId)
end

local function waypointWorldForStage(stage: number, plotId: string): Vector3?
	local s = SkillStages.clampStage(stage)
	local finalWp = SkillStages.plotSizeFinalWaypoint(s)
	local route = Workspace:FindFirstChild("WaveRoute")
	local a = route and route:FindFirstChild("A")
	local wpFolder = a and a:FindFirstChild("Waypoints")
	if not wpFolder then
		return nil
	end
	local w: Instance? = wpFolder:FindFirstChild("W" .. tostring(finalWp))
	if not (w and w:IsA("BasePart")) then
		for _, ch in ipairs(wpFolder:GetDescendants()) do
			if ch:IsA("BasePart") and ch.Name == "W" .. tostring(finalWp) then
				w = ch
				break
			end
		end
	end
	if not (w and w:IsA("BasePart")) then
		return nil
	end
	local plot = ClientPlot.get()
	if plotId == "Plot1" or (plot and plot.plotId == plotId) then
		return ClientPlot.remapFromPlot1((w :: BasePart).Position)
	end
	return nil
end

-- Place the visible reef heart at the wave path end (plot-size waypoint).
function WaveEndVfx.setRouteHeartDriveLocked(locked: boolean)
	routeHeartDriveLocked = locked == true
end

function WaveEndVfx.isRouteHeartDriveLocked(): boolean
	return routeHeartDriveLocked
end

function WaveEndVfx.setRouteEndWorldPos(worldPos: Vector3?, plotId: string?)
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else "Plot1")
	if worldPos then
		routeEndPosByPlot[id] = worldPos
	else
		routeEndPosByPlot[id] = nil
	end
	applyRouteHeartForPlot(id)
end

function WaveEndVfx.getRouteEndWorldPosForStage(stage: number, plotId: string?): Vector3?
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else nil)
	if not id then
		return nil
	end
	return waypointWorldForStage(stage, id)
end

function WaveEndVfx.clearRouteEnd(plotId: string?)
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else nil)
	if not id then
		return
	end
	routeEndPosByPlot[id] = nil
	destroyRouteHeartClone(id)
	applyRouteHeartForPlot(id)
end

-- Place heart at W# for this Plot Size stage (works even when waves aren't running).
function WaveEndVfx.syncToPlotSizeStage(stage: number?, plotId: string?)
	if routeHeartDriveLocked then
		return
	end
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else nil)
	if not id then
		return
	end
	local s = if stage ~= nil then SkillStages.clampStage(stage) else nil
	if s == nil then
		local ok, SkillPowerUpUI = pcall(function()
			return require(script.Parent:WaitForChild("SkillPowerUpUI"))
		end)
		if ok and SkillPowerUpUI and typeof(SkillPowerUpUI.getStage) == "function" then
			s = SkillPowerUpUI.getStage("PlotSize")
		else
			s = 1
		end
	end
	local worldPos = waypointWorldForStage(s :: number, id)
	if not worldPos then
		return
	end
	WaveEndVfx.setRouteEndWorldPos(worldPos, id)
end

-- Join intro: suppress reef heart until ink tip scale-up (survives plot/heart sync).
function WaveEndVfx.setHeartIntroHoldHidden(held: boolean)
	heartIntroHoldHidden = held == true
	local plot = ClientPlot.get()
	local id = if plot then plot.plotId else "Plot1"
	if heartIntroHoldHidden then
		heartScaleMulByPlot[id] = nil
		resolveEndHeartForPlot(id)
		applyHeartScaleMul(id, 0, false)
		local root = heartVisualRoot(id)
		if root then
			setTreeLocalHidden(root, true)
		end
		local src = hiddenSourceRootByPlot[id] or findPlotEndHeartRoot(id)
		if src then
			setTreeLocalHidden(src, true)
		end
	end
end

function WaveEndVfx.isHeartIntroHoldHidden(): boolean
	return heartIntroHoldHidden
end

-- Hard guarantee used after ink / planning — retries until a heart exists and is unhidden.
function WaveEndVfx.ensureHeartVisibleAfterInk(plotId: string?)
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else "Plot1")
	heartIntroHoldHidden = false
	heartPopBusy = false
	heartScaleMulByPlot[id] = nil
	task.spawn(function()
		for _ = 1, 50 do
			if heartIntroHoldHidden then
				return
			end
			waitForHeartRoot(id, 0.15)
			forceHeartFullyVisible(id)
			local root = heartVisualRoot(id)
			local heart = heartPartForScale(id, root) or endHeartPart
			local visible = false
			if root and root.Parent and heart and heart.Parent then
				local ltmOk = heart.LocalTransparencyModifier < 0.5
				local scaleOk = (not root:IsA("Model")) or root:GetScale() >= 0.85
				local orbOk = packageHasOrb(root)
				visible = ltmOk and scaleOk and orbOk
				-- Non-model / no-orb packages: still accept a visible heart.
				if not visible and ltmOk and scaleOk then
					visible = true
				end
			end
			if visible then
				return
			end
			task.wait(0.08)
		end
		if heartIntroHoldHidden then
			return
		end
		resolveEndHeartForPlot(id)
		forceHeartFullyVisible(id)
	end)
end

-- Ink reveal: keep the reef heart invisible/shrunk until the path tip arrives.
function WaveEndVfx.prepareHeartShrunkForInkReveal(stage: number?, plotId: string?)
	-- Cancel any in-flight pop; finalize that gen as hidden for the new ink draw.
	heartInkScaleToken += 1
	heartSkipSettled = false
	-- Hold ClientPlot.onChanged from tearing down the clone for the whole ink draw.
	heartPopBusy = true
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else "Plot1")
	heartIntroHoldHidden = true
	heartScaleMulByPlot[id] = nil
	if not routeHeartDriveLocked then
		WaveEndVfx.syncToPlotSizeStage(stage, id)
	end
	-- Retry resolve — PlotHearts / EndPoint can stream in late after plot shrink.
	local root, heart = waitForHeartRoot(id, 2.5)
	if root and root:IsA("Model") then
		local cur = root:GetScale()
		-- Always prefer a full-size native; never cache a shrunk ink scale as "native".
		if cur >= 0.85 then
			rememberFullNative(id, cur)
		else
			local full = getFullNative(id)
			rememberFullNative(id, full)
			pcall(function()
				root:ScaleTo(full)
			end)
			snapHeartRootToRouteEnd(id)
		end
		local orbSrc = getHeartCloneSource(id)
		ensureOrbInPackage(root, orbSrc)
	end
	if heart then
		local sz = heart.Size
		heartRestSizeByPlot[id] = if sz.Magnitude >= 0.05 then sz else (heartRestSizeByPlot[id] or Vector3.new(2, 2, 2))
	end
	applyHeartScaleMul(id, 0, false)
	heartIntroHoldHidden = true
	heartPopBusy = true
end

local function runHeartScaleInFromInk(durationSec: number?, plotId: string?, waitForBeats: boolean): boolean
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else "Plot1")
	local dur = if typeof(durationSec) == "number" and durationSec > 0 then durationSec else 0.48
	heartInkScaleToken += 1
	local my = heartInkScaleToken
	heartIntroHoldHidden = false
	heartPopBusy = true

	local function finalizeVisible()
		finishInkHeartVisible(id)
	end

	local root = waitForHeartRoot(id, 2.5)
	if my ~= heartInkScaleToken then
		heartPopBusy = false
		if not heartIntroHoldHidden then
			finalizeVisible()
		end
		return false
	end

	local beatsDone = not waitForBeats
	if waitForBeats then
		task.spawn(function()
			playHeartInkSoundTwiceAndWait()
			beatsDone = true
		end)
	else
		playHeartInkSoundTwice()
		beatsDone = true
	end

	if not root then
		if waitForBeats then
			while not beatsDone and my == heartInkScaleToken do
				task.wait(0.05)
			end
		end
		finalizeVisible()
		return my == heartInkScaleToken
	end
	applyHeartScaleMul(id, 0.02, true)

	local t0 = os.clock()
	while my == heartInkScaleToken do
		local u = (os.clock() - t0) / dur
		if u >= 1 then
			break
		end
		local t = u - 1
		local e = 1 + t * t * (2.70158 * t + 1.70158)
		applyHeartScaleMul(id, math.clamp(e, 0.02, 1.12), true)
		RunService.RenderStepped:Wait()
	end

	if waitForBeats then
		while not beatsDone and my == heartInkScaleToken do
			task.wait(0.05)
		end
	end

	if my ~= heartInkScaleToken then
		heartPopBusy = false
		if not heartIntroHoldHidden then
			finalizeVisible()
		end
		return false
	end
	finalizeVisible()
	task.delay(0.35, function()
		if heartIntroHoldHidden then
			return
		end
		WaveEndVfx.syncToPlotSizeStage(nil, id)
		forceHeartFullyVisible(id)
	end)
	return true
end

function WaveEndVfx.playHeartScaleInFromInk(durationSec: number?, plotId: string?)
	task.spawn(function()
		runHeartScaleInFromInk(durationSec, plotId, false)
	end)
end

-- Blocking: scale-up + both heartbeat sounds finish before returning (line → heart → fish order).
function WaveEndVfx.playHeartScaleInFromInkAndWait(durationSec: number?, plotId: string?): boolean
	return runHeartScaleInFromInk(durationSec, plotId, true)
end

-- Shared by normal ink pop end + Skip Intro. Never destroys the live package.
finishInkHeartVisible = function(plotId: string)
	heartIntroHoldHidden = false
	heartScaleMulByPlot[plotId] = nil
	heartPopBusy = true

	local clone = routeHeartCloneByPlot[plotId]
	if not clone or not clone.Parent then
		if not routeHeartDriveLocked then
			WaveEndVfx.syncToPlotSizeStage(nil, plotId)
		end
		resolveEndHeartForPlot(plotId)
		clone = routeHeartCloneByPlot[plotId]
	end
	if not clone or not clone.Parent then
		heartPopBusy = false
		return
	end

	-- Pull glass orb + authored materials onto the package (Skip used to leave heart-only).
	local src = getHeartCloneSource(plotId)
	ensureOrbInPackage(clone, src)
	syncNonHeartAppearanceFromSource(clone, src)

	local native = getFullNative(plotId)
	heartNativeScaleByPlot[plotId] = native
	clone:SetAttribute(FULL_NATIVE_ATTR, native)
	if clone:IsA("Model") then
		pcall(function()
			clone:ScaleTo(native)
		end)
	end

	setTreeLocalHidden(clone, false)
	local heartPart: BasePart? = nil
	for _, d in ipairs(clone:GetDescendants()) do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = 0
			if nameLooksLikeHeart(d.Name) then
				d.Transparency = 0
				d.Color = END_HEART_RED
				heartPart = d
			else
				restoreAuthoredAppearance(d)
			end
		end
	end
	if clone:IsA("BasePart") then
		clone.LocalTransparencyModifier = 0
		if nameLooksLikeHeart(clone.Name) then
			clone.Transparency = 0
			clone.Color = END_HEART_RED
			heartPart = clone
		else
			restoreAuthoredAppearance(clone)
		end
	end
	if clone:IsA("Model") and clone.PrimaryPart then
		local pp = clone.PrimaryPart
		pp.LocalTransparencyModifier = 0
		if nameLooksLikeHeart(pp.Name) then
			pp.Transparency = 0
			pp.Color = END_HEART_RED
			heartPart = pp
		end
	end
	if not heartPart then
		heartPart = findHeartIn(clone)
	end
	if heartPart then
		heartPart.LocalTransparencyModifier = 0
		heartPart.Transparency = 0
		heartPart.Color = END_HEART_RED
		endHeartPart = heartPart
		heartByPlotId[plotId] = heartPart
	end

	-- Authored source stays hidden (clone is what you see at the route end).
	if src and src.Parent then
		setTreeLocalHidden(src, true)
		for _, sib in ipairs(collectOrbSiblings(src)) do
			setTreeLocalHidden(sib, true)
		end
		hiddenSourceRootByPlot[plotId] = src
	end

	snapHeartRootToRouteEnd(plotId)
	heartPopBusy = false
end

-- If ink is cancelled mid-draw, snap the heart back to full size.
function WaveEndVfx.restoreHeartAfterInkCancel(plotId: string?)
	heartInkScaleToken += 1
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else "Plot1")
	heartSkipSettled = true
	finishInkHeartVisible(id)
	task.delay(0.35, function()
		heartSkipSettled = false
	end)
end

--[[
	Skip Intro: one light refresh to full heart + glass orb (same as ink pop end).
	At most two delayed retries if PlotHearts/route end aren't ready yet — no hot loops.
]]
function WaveEndVfx.settleHeartAfterIntroSkip(plotId: string?): boolean
	heartInkScaleToken += 1
	local plot = ClientPlot.get()
	local id = plotId or (if plot then plot.plotId else "Plot1")
	heartSkipSettled = true
	heartIntroHoldHidden = false
	heartScaleMulByPlot[id] = nil
	heartPopBusy = false

	local function packageOk(): boolean
		local clone = routeHeartCloneByPlot[id]
		if not clone or not clone.Parent then
			return false
		end
		local heart = findHeartIn(clone)
		if not heart or not heart.Parent then
			return false
		end
		local scaleOk = (not clone:IsA("Model")) or clone:GetScale() >= 0.85
		return scaleOk and heart.LocalTransparencyModifier < 0.5 and packageHasOrb(clone)
	end

	local function refreshOnce(forceRebuild: boolean)
		if heartIntroHoldHidden then
			return false
		end
		local clone = routeHeartCloneByPlot[id]
		local broken = forceRebuild
			or not clone
			or not clone.Parent
			or not findHeartIn(clone)
			or (clone:IsA("Model") and clone:GetScale() < 0.2)
		if broken then
			destroyRouteHeartClone(id)
			heartByPlotId[id] = nil
			if endHeartPlotId == id then
				endHeartPart = nil
				endHeartPlotId = nil
			end
		end
		if not routeHeartDriveLocked then
			WaveEndVfx.syncToPlotSizeStage(nil, id)
		end
		finishInkHeartVisible(id)
		forceHeartFullyVisible(id)
		return packageOk()
	end

	local ok = refreshOnce(false)
	if not ok then
		-- One rebuild pass, then a single late retry (route/PlotHearts can stream in).
		task.delay(0.4, function()
			if heartIntroHoldHidden then
				return
			end
			refreshOnce(true)
		end)
	end
	task.delay(1.0, function()
		heartSkipSettled = false
		if heartIntroHoldHidden then
			return
		end
		if not packageOk() then
			refreshOnce(true)
		end
	end)
	return ok
end

function WaveEndVfx.getEndHeartPart(): BasePart?
	local plot = ClientPlot.get()
	local plotId = if plot then plot.plotId else "Plot1"
	return resolveEndHeartForPlot(plotId)
end

function WaveEndVfx.getEndHeartPartForPlot(plotId: string): BasePart?
	return resolveEndHeartForPlot(plotId)
end

function WaveEndVfx.getEndHeartWorldPos(): Vector3?
	local plot = ClientPlot.get()
	local plotId = if plot then plot.plotId else "Plot1"
	local routed = routeEndPosByPlot[plotId]
	if routed then
		return routed
	end
	local heart = WaveEndVfx.getEndHeartPart()
	if heart then
		return heart.Position
	end
	-- Fallback remap if server hearts not ready yet
	local authored = findHeartIn(findAuthoredEndPoint())
	if authored then
		return ClientPlot.remapFromPlot1(authored.Position)
	end
	return nil
end

function WaveEndVfx.getEndHeartWorldPosForPlot(plotId: string): Vector3?
	local routed = routeEndPosByPlot[plotId]
	if routed then
		return routed
	end
	local heart = resolveEndHeartForPlot(plotId)
	if heart then
		return heart.Position
	end
	local authored = findHeartIn(findAuthoredEndPoint())
	if authored and plotId ~= "Plot1" then
		-- Soft fallback until OceanTD_PlotHearts replicates
		local plot = ClientPlot.get()
		if plot and plot.plotId == plotId then
			return ClientPlot.remapFromPlot1(authored.Position)
		end
	end
	return nil
end

function WaveEndVfx.refreshLocalEndHeart()
	table.clear(heartByPlotId)
	endHeartPart = nil
	endHeartPlotId = nil
	local plot = ClientPlot.get()
	if not plot then
		return
	end
	-- Keep route-end overrides; re-apply clone against the current source heart.
	if plot.plotId == "Plot1" then
		resolveEndHeartForPlot("Plot1")
		return
	end
	local heart = resolveEndHeartForPlot(plot.plotId)
	if heart then
		return
	end
	task.spawn(function()
		local folder = Workspace:WaitForChild("OceanTD_PlotHearts", 10)
		if folder then
			folder:WaitForChild(plot.plotId, 5)
		end
		heartByPlotId[plot.plotId] = nil
		endHeartPart = nil
		endHeartPlotId = nil
		resolveEndHeartForPlot(plot.plotId)
	end)
end

local function setEndHeartHidden(heart: BasePart, hidden: boolean)
	heart.LocalTransparencyModifier = if hidden then 1 else 0
end

-- Underfed fish hit the end: hide mesh 0.25s.
function WaveEndVfx.notifyUnderfedArrival()
	local heart = WaveEndVfx.getEndHeartPart()
	if not heart then
		return
	end
	heartHideToken += 1
	local myHide = heartHideToken
	heartHideUntil = os.clock() + UNDERFED_HIDE_SEC
	setEndHeartHidden(heart, true)
	task.delay(UNDERFED_HIDE_SEC, function()
		if myHide ~= heartHideToken or os.clock() < heartHideUntil then
			return
		end
		if heart.Parent then
			setEndHeartHidden(heart, false)
		end
	end)
end

local function pulseReefHeartLoss(at: Vector3, tintHeart: boolean?, sprayIndex: number?, sprayCount: number?)
	local folder = resolveFolder()
	local startPos = at + Vector3.new(0, 2, 0)
	-- Fan sideways as they fall (evenly spaced when several tick at once, plus a little jitter).
	local n = math.max(1, sprayCount or 1)
	local i = math.clamp(sprayIndex or 1, 1, n)
	local baseAngle = ((i - 1) / n) * math.pi * 2 + rng:NextNumber(-0.35, 0.35)
	local sprayReach = HEART_SPRAY_STUDS * rng:NextNumber(0.65, 1.15)
	local sprayDir = Vector3.new(math.cos(baseAngle), 0, math.sin(baseAngle))
	local anchor = Instance.new("Part")
	anchor.Name = "OceanTD_HeartLoss"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(startPos)
	anchor.Parent = folder

	-- ScreenGui so broken hearts draw above happy-exit world billboards.
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_HeartLossGui"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = HEART_GUI_ORDER
	sg.Parent = playerGui or folder

	local holder = Instance.new("Frame")
	holder.Name = "Heart"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(8, 8)
	holder.Parent = sg

	local scale = Instance.new("UIScale")
	scale.Scale = 1
	scale.Parent = holder

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.SourceSansBold
	lbl.Text = "💔"
	lbl.TextColor3 = Color3.fromRGB(255, 35, 55)
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.35
	lbl.TextStrokeColor3 = Color3.fromRGB(80, 0, 10)
	lbl.Parent = holder

	-- Local plot heart (Plot1 authored, or remapped clone on Plot2+).
	local worldHeart = if tintHeart ~= false then WaveEndVfx.getEndHeartPart() else nil
	endHeartAnimToken += 1
	local myHeartToken = endHeartAnimToken
	if worldHeart then
		worldHeart.Color = END_HEART_RED
	end

	local lightHost = worldHeart or anchor
	local light = Instance.new("PointLight")
	light.Name = "OceanTD_HeartLossLight"
	light.Color = END_HEART_RED
	light.Brightness = HEART_LIGHT_BRIGHTNESS
	light.Range = HEART_LIGHT_RANGE
	light.Shadows = false
	light.Parent = lightHost

	local function studsToPx(worldPos: Vector3, studs: number): number
		local cam = Workspace.CurrentCamera
		if not cam then
			return studs * 2
		end
		local dist = math.max(1, (cam.CFrame.Position - worldPos).Magnitude)
		local halfFov = math.rad(cam.FieldOfView) * 0.5
		local vp = cam.ViewportSize
		return studs / dist * (vp.Y * 0.5) / math.tan(halfFov)
	end

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local u = math.clamp((os.clock() - t0) / HEART_FALL_SEC, 0, 1)
		local ease = u * u
		-- Ease out sideways faster than the fall so they read as a spray, not a column.
		local sprayU = 1 - (1 - u) * (1 - u)
		local worldPos = startPos
			+ sprayDir * (sprayReach * sprayU)
			- Vector3.new(0, HEART_FALL_STUDS * ease, 0)
		anchor.CFrame = CFrame.new(worldPos)

		local cam = Workspace.CurrentCamera
		if cam then
			local sp, onScreen = cam:WorldToViewportPoint(worldPos)
			holder.Visible = onScreen and sp.Z > 0
			holder.Position = UDim2.fromOffset(sp.X, sp.Y)
			local px = studsToPx(worldPos, HEART_LOSS_MAX_STUDS)
			holder.Size = UDim2.fromOffset(math.max(8, px), math.max(8, px))
		end
		scale.Scale = 1 + (HEART_LOSS_END_SCALE - 1) * ease
		lbl.TextTransparency = u
		lbl.TextStrokeTransparency = 0.35 + 0.65 * u
		light.Brightness = HEART_LIGHT_BRIGHTNESS * (1 - u)
		if worldHeart and myHeartToken == endHeartAnimToken then
			worldHeart.Color = END_HEART_RED:Lerp(END_HEART_BLACK, u)
		end
		if u >= 1 then
			conn:Disconnect()
			if light.Parent then
				light:Destroy()
			end
			if sg.Parent then
				sg:Destroy()
			end
			if anchor.Parent then
				anchor:Destroy()
			end
			if worldHeart and worldHeart.Parent and myHeartToken == endHeartAnimToken then
				worldHeart.Color = END_HEART_RED
			end
		end
	end)
end

local function playHappyExitSound()
	local pitch = rng:NextNumber(HAPPY_EXIT_PITCH_MIN, HAPPY_EXIT_PITCH_MAX)
	playUnduckedOneShot(HAPPY_EXIT_SOUND_ID, 1.2, pitch, "OceanTD_HappyExitPlay")
end

-- Sound only (full fish → reef heart). Used by join-intro rating fireworks.
function WaveEndVfx.playHappyExitSoundOnce()
	playHappyExitSound()
end

-- Sound only (one reef heart lost). Pitch steps like playReefHealthTicks.
function WaveEndVfx.playReefTickSoundOnce()
	local pitch = math.max(REEF_TICK_PITCH_MIN, REEF_TICK_PITCH_START - reefTickStreak * REEF_TICK_PITCH_STEP)
	reefTickStreak += 1
	playUnduckedOneShot(REEF_TICK_SOUND_ID, 1.2, pitch, "OceanTD_ReefTickPlay")
end

local function characterAimPos(fallback: Vector3): Vector3
	local char = Players.LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position + Vector3.new(0, 1.5, 0)
	end
	return fallback
end

function WaveEndVfx.pulseHappyExit(emoji: string, at: Vector3)
	if not happyExitVisible then
		return
	end
	playHappyExitSound()

	local folder = resolveFolder()
	local startPos = at + Vector3.new(0, 2, 0)
	-- Random lateral/vertical fan so simultaneous exits don't stack.
	local fanYaw = rng:NextNumber(0, math.pi * 2)
	local fanReach = rng:NextNumber(HAPPY_EXIT_FAN_STUDS * 0.45, HAPPY_EXIT_FAN_STUDS)
	local fanSide = Vector3.new(math.cos(fanYaw), 0, math.sin(fanYaw)) * fanReach
	local fanUp = Vector3.new(0, rng:NextNumber(-6, 10), 0)

	local anchor = Instance.new("Part")
	anchor.Name = "OceanTD_HappyExit"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(startPos)
	anchor.Parent = folder
	registerHappyExit(anchor)

	local bb = Instance.new("BillboardGui")
	bb.Name = "HappyFace"
	bb.Adornee = anchor
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 2000
	local startStuds = HEART_LOSS_MAX_STUDS * HAPPY_EXIT_START_SCALE
	bb.Size = UDim2.fromScale(startStuds, startStuds)
	bb.Parent = anchor

	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.Font = Enum.Font.SourceSansBold
	lbl.Text = emoji
	lbl.TextScaled = true
	lbl.TextStrokeTransparency = 0.4
	lbl.TextStrokeColor3 = Color3.fromRGB(20, 40, 10)
	lbl.Parent = bb

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if not happyExitVisible then
			conn:Disconnect()
			if anchor.Parent then
				anchor:Destroy()
			end
			return
		end
		local u = math.clamp((os.clock() - t0) / HAPPY_EXIT_SEC, 0, 1)
		local ease = 1 - (1 - u) * (1 - u)
		local goal = characterAimPos(startPos) + fanSide + fanUp
		local pos = startPos:Lerp(goal, ease)
		anchor.CFrame = CFrame.new(pos)
		-- Grow with remaining distance to the player (not just elapsed time).
		local startDist = (startPos - goal).Magnitude
		local dist = (pos - goal).Magnitude
		local approach = if startDist > 1 then 1 - math.clamp(dist / startDist, 0, 1) else ease
		local grow = approach * approach
		local studs = HEART_LOSS_MAX_STUDS * (HAPPY_EXIT_START_SCALE + (1 - HAPPY_EXIT_START_SCALE) * grow)
		bb.Size = UDim2.fromScale(studs, studs)
		lbl.TextTransparency = u
		lbl.TextStrokeTransparency = 0.4 + 0.6 * u
		if u >= 1 then
			conn:Disconnect()
			if anchor.Parent then
				anchor:Destroy()
			end
		end
	end)
end

-- Finish-button burst: tiny sparks that explode outward from the endpoint and arc down.
function WaveEndVfx.burstHappyFirework(emojis: { string }, at: Vector3)
	if #emojis == 0 or not happyExitVisible then
		return
	end
	playHappyExitSound()

	local folder = resolveFolder()
	local origin = at + Vector3.new(0, 2.5, 0)
	local count = math.clamp(#emojis * 2, 14, 36)

	for i = 1, count do
		local emoji = emojis[((i - 1) % #emojis) + 1]
		local delaySec = rng:NextNumber(0, 0.08)
		task.delay(delaySec, function()
			if not happyExitVisible then
				return
			end
			local anchor = Instance.new("Part")
			anchor.Name = "OceanTD_HappyFirework"
			anchor.Anchored = true
			anchor.CanCollide = false
			anchor.CanQuery = false
			anchor.CanTouch = false
			anchor.CastShadow = false
			anchor.Transparency = 1
			anchor.Size = Vector3.new(0.4, 0.4, 0.4)
			anchor.CFrame = CFrame.new(origin)
			anchor.Parent = folder
			registerHappyExit(anchor)

			local sizeStuds = rng:NextNumber(FIREWORK_SIZE_MIN, FIREWORK_SIZE_MAX)
			local bb = Instance.new("BillboardGui")
			bb.Name = "HappySpark"
			bb.Adornee = anchor
			bb.AlwaysOnTop = true
			bb.LightInfluence = 0
			bb.MaxDistance = 2000
			bb.Size = UDim2.fromScale(sizeStuds, sizeStuds)
			bb.Parent = anchor

			local scale = Instance.new("UIScale")
			scale.Scale = FIREWORK_START_SCALE
			scale.Parent = bb

			local lbl = Instance.new("TextLabel")
			lbl.BackgroundTransparency = 1
			lbl.Size = UDim2.fromScale(1, 1)
			lbl.Font = Enum.Font.SourceSansBold
			lbl.Text = emoji
			lbl.TextScaled = true
			lbl.TextStrokeTransparency = 0.45
			lbl.TextStrokeColor3 = Color3.fromRGB(20, 40, 10)
			lbl.Parent = bb

			-- Full sphere with a slight upward bias so arcs read as fireworks.
			local yaw = rng:NextNumber(0, math.pi * 2)
			local pitch = rng:NextNumber(-0.35, 1.15) -- more up than down at launch
			local dir = Vector3.new(
				math.cos(yaw) * math.cos(pitch),
				math.sin(pitch),
				math.sin(yaw) * math.cos(pitch)
			).Unit
			local speed = rng:NextNumber(FIREWORK_SPEED_MIN, FIREWORK_SPEED_MAX)
			local vel = dir * speed
			local grav = rng:NextNumber(FIREWORK_GRAV_MIN, FIREWORK_GRAV_MAX)
			local life = rng:NextNumber(FIREWORK_LIFE_MIN, FIREWORK_LIFE_MAX)
			local peakScale = rng:NextNumber(0.85, 1.45)
			local popAt = rng:NextNumber(0.1, 0.22)
			local pos = origin
			local t0 = os.clock()
			local conn: RBXScriptConnection
			conn = RunService.RenderStepped:Connect(function(dt)
				if not happyExitVisible then
					conn:Disconnect()
					if anchor.Parent then
						anchor:Destroy()
					end
					return
				end
				local age = os.clock() - t0
				if age >= life then
					conn:Disconnect()
					if anchor.Parent then
						anchor:Destroy()
					end
					return
				end
				vel += Vector3.new(0, -grav, 0) * dt
				-- Light air drag so they don't fly forever.
				vel *= (1 - 0.35 * dt)
				pos += vel * dt
				anchor.CFrame = CFrame.new(pos)

				if age < popAt then
					scale.Scale = FIREWORK_START_SCALE
						+ (peakScale - FIREWORK_START_SCALE) * (age / popAt)
				else
					local fadeU = math.clamp((age - popAt) / math.max(0.05, life - popAt), 0, 1)
					scale.Scale = peakScale * (1 - 0.35 * fadeU)
				end
				local fade = math.clamp((age - life * 0.55) / (life * 0.45), 0, 1)
				lbl.TextTransparency = fade
				lbl.TextStrokeTransparency = 0.45 + 0.55 * fade
			end)
		end)
	end
end

function WaveEndVfx.playReefHealthTicks(amount: number, endPos: Vector3?, tintHeart: boolean?)
	if amount <= 0 then
		return
	end
	local at = endPos
	if not at then
		at = WaveEndVfx.getEndHeartWorldPos()
	end
	for i = 1, amount do
		local pitch = math.max(REEF_TICK_PITCH_MIN, REEF_TICK_PITCH_START - reefTickStreak * REEF_TICK_PITCH_STEP)
		reefTickStreak += 1
		local delaySec = (i - 1) * REEF_TICK_GAP
		local sprayI = i
		task.delay(delaySec, function()
			playUnduckedOneShot(REEF_TICK_SOUND_ID, 1.2, pitch, "OceanTD_ReefTickPlay")
			if at then
				pulseReefHeartLoss(at, tintHeart, sprayI, amount)
			end
		end)
	end
end

ClientPlot.onChanged(function(plot)
	-- Plot Size grow / intro ink / Skip settle: never tear down the heart+orb package mid-sequence.
	-- Teardown was the main reason the orb vanished (clone rebuilt without welds / mid-ScaleTo).
	if routeHeartDriveLocked or heartPopBusy or heartIntroHoldHidden or heartSkipSettled then
		if plot and not routeHeartDriveLocked then
			local id = plot.plotId
			if routeEndPosByPlot[id] then
				snapHeartRootToRouteEnd(id)
			else
				WaveEndVfx.syncToPlotSizeStage(nil, id)
			end
			if heartIntroHoldHidden and not heartSkipSettled then
				applyHeartScaleMul(id, 0, false)
			end
		end
		return
	end
	table.clear(heartByPlotId)
	endHeartPart = nil
	endHeartPlotId = nil
	if plot then
		-- Drop stale clones; caller / sync will re-place at the plot-size end.
		for id in pairs(routeHeartCloneByPlot) do
			destroyRouteHeartClone(id)
		end
		WaveEndVfx.refreshLocalEndHeart()
		WaveEndVfx.syncToPlotSizeStage(nil, plot.plotId)
	end
end)

task.defer(function()
	if ClientPlot.get() then
		WaveEndVfx.refreshLocalEndHeart()
		WaveEndVfx.syncToPlotSizeStage()
	end
end)

return WaveEndVfx
