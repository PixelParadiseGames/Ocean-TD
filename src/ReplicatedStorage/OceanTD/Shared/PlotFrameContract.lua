--!strict
--[[
	Plot-frame contract (stability).

	Runtime PlotN CFrames MUST be a pure function of MasterTerrainBox + RingMath
	(+ ExpansionOffset). Do NOT:
	  - Sample Terrain voxels to nudge slot.cframe (TerrainPlotAlign)
	  - Read PreviewBox_* as live pose (stamp helpers only)
	  - Persist absolute world positions for layout

	Layout locals (lx,ly,lz) are ObjectSpace against this frame. Changing the frame
	under saved locals slides every coral + remapped wave path (radial on a ring).

	If stamp ≠ ring: fix in Studio (Show → Stamp → Hide), not at runtime.
]]

local RingMath = require(script.Parent:WaitForChild("RingMath"))

local PlotFrameContract = {}

PlotFrameContract.MAX_POSE_DRIFT_STUDS = 0.05

-- Expected logical pose for plotIndex (1..plotCount).
function PlotFrameContract.expectedCFrame(
	plotIndex: number,
	plotCount: number,
	masterCf: CFrame,
	masterSize: Vector3,
	expansionOffset: number?
): CFrame
	return RingMath.plotCFrame(plotIndex, plotCount, masterCf, masterSize, expansionOffset)
end

-- Returns drift magnitude, or 0 if within tolerance.
function PlotFrameContract.poseDrift(actual: CFrame, expected: CFrame): number
	return (actual.Position - expected.Position).Magnitude
end

function PlotFrameContract.passes(actual: CFrame, expected: CFrame): boolean
	return PlotFrameContract.poseDrift(actual, expected) <= PlotFrameContract.MAX_POSE_DRIFT_STUDS
end

return PlotFrameContract
