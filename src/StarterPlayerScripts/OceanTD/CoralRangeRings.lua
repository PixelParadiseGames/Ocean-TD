--!strict
--[[
	Coral feed / shoot range preview (placement ghost + inspect).

	Range Preview A — orbiting green dashes (original).
	Range Preview B — tall vertical disc that rotates about Y (sphere slice).
	Preview B size lerps to the current range so upgrades tween instead of vanishing.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local CoralSize = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralSize"))

local CoralRangeRings = {}

-- "A" = spinning dashes, "B" = tall disc
local PREVIEW_STYLE: "A" | "B" = "B"

local ACTIVE_GREEN = Color3.fromRGB(40, 255, 90)

-- ── Preview A (dashes) ──────────────────────────────────────────────────────
local RANGE_SPIN = { 0.55, -0.7, 0.4, -0.5, 0.62, -0.38 }
local RANGE_PHASE = { 0, 1.05, 2.1, 3.15, 4.2, 5.25 }
local RANGE_RING_N = 6
local RANGE_DASH_N = 14
local RANGE_NORMALS = {
	Vector3.new(1, 1, 0),
	Vector3.new(1, -1, 0),
	Vector3.new(1, 0, 1),
	Vector3.new(1, 0, -1),
	Vector3.new(0, 1, 1),
	Vector3.new(0, 1, -1),
}

-- ── Preview B (tall disc) ───────────────────────────────────────────────────
local DISC_THICK = 0.22
local GROW_SEC_A = 2
-- Prior ~0.7975; +30% more transparent (of remaining opacity).
local TALL_TRANSPARENCY = 0.7975 + (1 - 0.7975) * 0.3 -- ≈0.858
local BREATHE_AMP = 0.04
local BREATHE_HZ = 0.55
local TALL_SPIN_RAD_PER_SEC = 0.55
-- Smooth size changes (intro + upgrades). Higher = snappier.
local RANGE_LERP_RATE = 6.5
-- Coral mesh swap on upgrade briefly nils the part — keep disc alive.
local PART_MISSING_GRACE_SEC = 0.45

local rangeFolder: Folder? = nil
local rangeFollow: RBXScriptConnection? = nil
local getPartFn: (() -> BasePart?)? = nil
local getRangeFn: (() -> number)? = nil
local activeStyle: string? = nil

-- Preview B displayed radius (studs); lerps toward target each frame.
local displayRange = 0
local lastTallCenter: Vector3? = nil
local missingPartT = 0
local spinA = 0
local timeB = 0
local yawB = 0
local growT_A = 0

local function defaultRange(part: BasePart): number
	local _d, cls = CoralSize.readFromPart(part)
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	local sid = if typeof(speciesId) == "string" then speciesId else nil
	return CoralSize.statsFor(cls, sid).range
end

local function makeDisc(name: string, transparency: number): BasePart
	local disc = Instance.new("Part")
	disc.Name = name
	disc.Shape = Enum.PartType.Cylinder
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.CastShadow = false
	disc.Material = Enum.Material.Neon
	disc.Color = ACTIVE_GREEN
	disc.Transparency = transparency
	disc.Size = Vector3.new(DISC_THICK, 1, 1)
	return disc
end

-- ── Preview A ───────────────────────────────────────────────────────────────

local function ringBasis(ri: number, spin: number): CFrame
	local n = RANGE_NORMALS[ri] or Vector3.yAxis
	n = n.Unit
	local spinA0 = spin * (RANGE_SPIN[ri] or 0.5) + (RANGE_PHASE[ri] or 0)
	local tumble = CFrame.Angles(spin * 0.11, spin * 0.17, spin * 0.07)
	local up = if math.abs(n.Y) > 0.92 then Vector3.xAxis else Vector3.yAxis
	return tumble * CFrame.lookAt(Vector3.zero, n, up) * CFrame.Angles(0, 0, spinA0)
end

local function poseRangeRingsA(part: BasePart, folder: Folder, range: number, spin: number, grow: number)
	local pos = CoralSize.visualCenter(part)
	local s = math.clamp(grow, 0, 1)
	s = 1 - (1 - s) * (1 - s)
	local r = range * s
	local thick = 0.55 * math.max(s, 0.15)
	local arcLen = math.max(2.2, (2 * math.pi * range / RANGE_DASH_N) * 0.5) * s
	for _, dash in ipairs(folder:GetChildren()) do
		if not dash:IsA("BasePart") then
			continue
		end
		local ri = dash:GetAttribute("Ring")
		local di = dash:GetAttribute("Dash")
		if typeof(ri) ~= "number" or typeof(di) ~= "number" then
			continue
		end
		local ang = ((di - 1) / RANGE_DASH_N) * math.pi * 2 + spin * (RANGE_SPIN[ri] or 1)
		dash.Size = Vector3.new(math.max(0.05, arcLen), thick, thick)
		dash.CFrame = CFrame.new(pos)
			* ringBasis(ri, spin)
			* CFrame.Angles(0, 0, ang)
			* CFrame.new(r, 0, 0)
			* CFrame.Angles(0, 0, math.pi * 0.5)
	end
end

local function buildPreviewA(folder: Folder)
	for ri = 1, RANGE_RING_N do
		for di = 1, RANGE_DASH_N do
			local dash = Instance.new("Part")
			dash.Name = "Dash"
			dash.Anchored = true
			dash.CanCollide = false
			dash.CanQuery = false
			dash.CanTouch = false
			dash.CastShadow = false
			dash.Material = Enum.Material.Neon
			dash.Color = ACTIVE_GREEN
			dash.Transparency = 0.05
			dash:SetAttribute("Ring", ri)
			dash:SetAttribute("Dash", di)
			dash.Parent = folder
		end
	end
end

-- ── Preview B ───────────────────────────────────────────────────────────────

local function poseTallDisc(disc: BasePart, center: Vector3, diameter: number, yaw: number, transparency: number)
	local d = math.max(0.05, diameter)
	disc.Size = Vector3.new(DISC_THICK, d, d)
	disc.Transparency = transparency
	disc.CFrame = CFrame.new(center) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, math.pi * 0.5, 0)
end

local function poseRangePreviewB(folder: Folder, center: Vector3, rangeRadius: number, t: number, yaw: number)
	local diameter = math.max(0.05, rangeRadius * 2)
	local breath = 1 + math.sin(t * math.pi * 2 * BREATHE_HZ) * BREATHE_AMP
	local tallT = math.clamp(TALL_TRANSPARENCY * breath, 0.55, 0.98)
	local tall = folder:FindFirstChild("Tall")
	if tall and tall:IsA("BasePart") then
		poseTallDisc(tall, center, diameter, yaw, tallT)
	end
end

local function buildPreviewB(folder: Folder)
	local tall = makeDisc("Tall", TALL_TRANSPARENCY)
	tall.Parent = folder
end

local function lerpRange(current: number, target: number, dt: number): number
	local u = 1 - math.exp(-RANGE_LERP_RATE * dt)
	return current + (target - current) * u
end

-- ── Public API ──────────────────────────────────────────────────────────────

function CoralRangeRings.hide()
	if rangeFollow then
		rangeFollow:Disconnect()
		rangeFollow = nil
	end
	if rangeFolder then
		rangeFolder:Destroy()
		rangeFolder = nil
	end
	getPartFn = nil
	getRangeFn = nil
	activeStyle = nil
	displayRange = 0
	lastTallCenter = nil
	missingPartT = 0
	spinA = 0
	timeB = 0
	yawB = 0
	growT_A = 0
end

function CoralRangeRings.isShowing(): boolean
	return rangeFolder ~= nil and rangeFolder.Parent ~= nil
end

function CoralRangeRings.getStyle(): string
	return PREVIEW_STYLE
end

function CoralRangeRings.setStyle(style: string)
	if style == "A" or style == "B" then
		PREVIEW_STYLE = style :: any
	end
end

local function ensureHeartbeat()
	if rangeFollow then
		return
	end
	rangeFollow = RunService.Heartbeat:Connect(function(dt)
		local f = rangeFolder
		if not f or not f.Parent then
			CoralRangeRings.hide()
			return
		end
		local p = if getPartFn then getPartFn() else nil
		if PREVIEW_STYLE == "A" then
			if not p or not p.Parent then
				CoralRangeRings.hide()
				return
			end
			growT_A += dt
			spinA += dt
			local range = if getRangeFn then getRangeFn() else defaultRange(p)
			poseRangeRingsA(p, f, range, spinA, growT_A / GROW_SEC_A)
			return
		end

		-- Preview B: grace through mesh swap; lerp size to new range.
		timeB += dt
		yawB += dt * TALL_SPIN_RAD_PER_SEC
		local targetRange = displayRange
		local center = lastTallCenter
		if p and p.Parent then
			missingPartT = 0
			center = CoralSize.visualCenter(p)
			lastTallCenter = center
			targetRange = if getRangeFn then getRangeFn() else defaultRange(p)
		else
			missingPartT += dt
			if missingPartT > PART_MISSING_GRACE_SEC or not center then
				CoralRangeRings.hide()
				return
			end
		end
		displayRange = lerpRange(displayRange, targetRange, dt)
		poseRangePreviewB(f, center :: Vector3, displayRange, timeB, yawB)
	end)
end

-- Follow `getPart` each frame (or a fixed part). Optional `getRange` overrides size stats.
function CoralRangeRings.show(part: BasePart, getPart: (() -> BasePart?)?, getRange: (() -> number)?)
	getPartFn = getPart or function()
		return part
	end
	getRangeFn = getRange
	local target = if getRange then getRange() else defaultRange(part)
	lastTallCenter = CoralSize.visualCenter(part)

	if rangeFolder and rangeFolder.Parent and activeStyle == PREVIEW_STYLE then
		-- Keep existing disc; only retarget size (upgrade path).
		if PREVIEW_STYLE == "B" and displayRange < 0.05 then
			displayRange = 0
		end
		ensureHeartbeat()
		return
	end

	-- Fresh folder. Preserve displayRange if we already had a size (rebuild mid-tween).
	local keepSize = displayRange
	if rangeFolder then
		if rangeFollow then
			rangeFollow:Disconnect()
			rangeFollow = nil
		end
		rangeFolder:Destroy()
		rangeFolder = nil
	end

	local folder = Instance.new("Folder")
	folder.Name = if PREVIEW_STYLE == "A" then "OceanTD_RangePreviewA" else "OceanTD_RangePreviewB"
	folder.Parent = workspace
	if PREVIEW_STYLE == "A" then
		buildPreviewA(folder)
		growT_A = 0
		spinA = 0
		poseRangeRingsA(part, folder, target, 0, 0)
	else
		buildPreviewB(folder)
		-- Intro: grow from 0. Upgrade rebuild: continue from keepSize.
		displayRange = if keepSize > 0.05 then keepSize else 0
		missingPartT = 0
		poseRangePreviewB(folder, lastTallCenter :: Vector3, displayRange, timeB, yawB)
	end
	rangeFolder = folder
	activeStyle = PREVIEW_STYLE
	ensureHeartbeat()
end

return CoralRangeRings
