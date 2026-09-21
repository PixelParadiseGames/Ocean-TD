--!strict
--[[
	Resolve SkyCam + SkyCamFocus for the local plot.
	Plot1: MasterPlotDecor; PlotN: StaticPlot_N (décor clone).
	Falls back to remapping MasterPlotDecor when the local clone is missing/late.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("Constants"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))

local SkyCamParts = {}

local SKY_CAM_NAME = "SkyCam"
local SKY_FOCUS_NAME = "SkyCamFocus"

export type SkyPose = {
	skyCFrame: CFrame,
	skySize: Vector3,
	focusPos: Vector3,
	-- Live parts when present on this plot (nil when using remapped master fallback).
	skyPart: BasePart?,
	focusPart: BasePart?,
}

local function decorRootForPlot(plotId: string): Instance?
	if plotId == "Plot1" then
		return Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	end
	local n = tonumber(string.match(plotId, "%d+"))
	if n and n >= 2 then
		return Workspace:FindFirstChild(Constants.STATIC_PLOT_PREFIX .. tostring(n))
	end
	return nil
end

local function findSkyFocusInRoot(root: Instance): (BasePart?, BasePart?)
	local sky: Instance? = root:FindFirstChild(SKY_CAM_NAME)
	if not sky then
		sky = root:FindFirstChild(SKY_CAM_NAME, true)
	end
	if not (sky and sky:IsA("BasePart")) then
		return nil, nil
	end
	local focus: Instance? = sky:FindFirstChild(SKY_FOCUS_NAME)
	if not (focus and focus:IsA("BasePart")) then
		focus = root:FindFirstChild(SKY_FOCUS_NAME, true)
	end
	if not (focus and focus:IsA("BasePart")) then
		return sky, nil
	end
	return sky, focus :: BasePart
end

function SkyCamParts.findLocalParts(): (BasePart?, BasePart?)
	local plot = ClientPlot.get()
	local plotId = if plot then plot.plotId else nil
	local root: Instance? = if plotId then decorRootForPlot(plotId) else nil
	if root then
		local sky, focus = findSkyFocusInRoot(root)
		if sky and focus then
			return sky, focus
		end
	end
	-- Plot1 / unassigned: master folder.
	local master = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	if master and (not plotId or plotId == "Plot1") then
		return findSkyFocusInRoot(master)
	end
	return nil, nil
end

-- World pose for plotcam (local parts, or Plot1-authored master remapped onto this plot).
function SkyCamParts.resolvePose(): SkyPose?
	local sky, focus = SkyCamParts.findLocalParts()
	if sky and focus then
		return {
			skyCFrame = sky.CFrame,
			skySize = sky.Size,
			focusPos = focus.Position,
			skyPart = sky,
			focusPart = focus,
		}
	end

	local master = Workspace:FindFirstChild(Constants.MASTER_DECOR_NAME)
	if not master then
		return nil
	end
	local mSky, mFocus = findSkyFocusInRoot(master)
	if not mSky or not mFocus then
		return nil
	end

	local plot = ClientPlot.get()
	if not plot or plot.plotId == "Plot1" then
		return {
			skyCFrame = mSky.CFrame,
			skySize = mSky.Size,
			focusPos = mFocus.Position,
			skyPart = mSky,
			focusPart = mFocus,
		}
	end

	return {
		skyCFrame = ClientPlot.remapCFrameFromPlot1(mSky.CFrame),
		skySize = mSky.Size,
		focusPos = ClientPlot.remapFromPlot1(mFocus.Position),
		skyPart = nil,
		focusPart = nil,
	}
end

function SkyCamParts.waitForPose(timeoutSec: number): SkyPose?
	local deadline = os.clock() + math.max(0, timeoutSec)
	while os.clock() < deadline do
		local pose = SkyCamParts.resolvePose()
		if pose then
			return pose
		end
		task.wait(0.05)
	end
	return SkyCamParts.resolvePose()
end

function SkyCamParts.topMiddle(pose: SkyPose): Vector3
	return (pose.skyCFrame * CFrame.new(0, pose.skySize.Y * 0.5, 0)).Position
end

function SkyCamParts.bottomMiddle(pose: SkyPose): Vector3
	return (pose.skyCFrame * CFrame.new(0, -pose.skySize.Y * 0.5, 0)).Position
end

function SkyCamParts.clampToPose(pos: Vector3, pose: SkyPose, margin: number?): Vector3
	local m = if typeof(margin) == "number" then margin else 0.5
	local localPos = pose.skyCFrame:PointToObjectSpace(pos)
	local half = pose.skySize * 0.5
	local hx = math.max(half.X - m, 0.05)
	local hy = math.max(half.Y - m, 0.05)
	local hz = math.max(half.Z - m, 0.05)
	local clamped = Vector3.new(
		math.clamp(localPos.X, -hx, hx),
		math.clamp(localPos.Y, -hy, hy),
		math.clamp(localPos.Z, -hz, hz)
	)
	return pose.skyCFrame:PointToWorldSpace(clamped)
end

return SkyCamParts
