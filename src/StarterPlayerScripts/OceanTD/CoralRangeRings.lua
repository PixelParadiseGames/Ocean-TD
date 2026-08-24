--!strict
-- Green orbiting range dashes around a coral / place-ghost.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local CoralSize = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralSize"))

local CoralRangeRings = {}

local ACTIVE_GREEN = Color3.fromRGB(40, 255, 90)
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

local rangeFolder: Folder? = nil
local rangeFollow: RBXScriptConnection? = nil
local getPartFn: (() -> BasePart?)? = nil
local getRangeFn: (() -> number)? = nil

local function ringBasis(ri: number, spin: number): CFrame
	local n = RANGE_NORMALS[ri] or Vector3.yAxis
	n = n.Unit
	local spinA = spin * (RANGE_SPIN[ri] or 0.5) + (RANGE_PHASE[ri] or 0)
	local tumble = CFrame.Angles(spin * 0.11, spin * 0.17, spin * 0.07)
	local up = if math.abs(n.Y) > 0.92 then Vector3.xAxis else Vector3.yAxis
	return tumble * CFrame.lookAt(Vector3.zero, n, up) * CFrame.Angles(0, 0, spinA)
end

local function poseRangeRings(part: BasePart, folder: Folder, range: number, spin: number, grow: number)
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

local function defaultRange(part: BasePart): number
	local _d, cls = CoralSize.readFromPart(part)
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	local sid = if typeof(speciesId) == "string" then speciesId else nil
	return CoralSize.statsFor(cls, sid).range
end

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
end

function CoralRangeRings.isShowing(): boolean
	return rangeFolder ~= nil and rangeFolder.Parent ~= nil
end

-- Follow `getPart` each frame (or a fixed part). Optional `getRange` overrides size stats.
function CoralRangeRings.show(part: BasePart, getPart: (() -> BasePart?)?, getRange: (() -> number)?)
	if rangeFolder and rangeFolder.Parent and getPartFn == getPart then
		getRangeFn = getRange
		return
	end
	CoralRangeRings.hide()
	local folder = Instance.new("Folder")
	folder.Name = "OceanTD_RangeRing"
	folder.Parent = workspace
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
	rangeFolder = folder
	getPartFn = getPart or function()
		return part
	end
	getRangeFn = getRange
	local spin = 0
	local growT = 0
	local range0 = if getRange then getRange() else defaultRange(part)
	poseRangeRings(part, folder, range0, spin, 0)
	rangeFollow = RunService.Heartbeat:Connect(function(dt)
		local p = if getPartFn then getPartFn() else nil
		local f = rangeFolder
		if not p or not p.Parent or not f or not f.Parent then
			CoralRangeRings.hide()
			return
		end
		spin += dt
		growT += dt
		local range = if getRangeFn then getRangeFn() else defaultRange(p)
		poseRangeRings(p, f, range, spin, growT / 2)
	end)
end

return CoralRangeRings
