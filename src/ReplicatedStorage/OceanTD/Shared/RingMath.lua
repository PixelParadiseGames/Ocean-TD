-- Ring math matching ArenaGeneratorPlugin (Spawn/Update Previews).
-- centerCFrame = master * CFrame.new(0, 0, -radius)
-- PreviewBox_i = center * Angles(0, angleStep*i, 0) * CFrame.new(0, 0, radius)

local RingMath = {}

function RingMath.pluginRadius(masterSize: Vector3, plotCount: number, expansionOffset: number?): number
	local expansion = expansionOffset or 0
	local apothem = (masterSize.X / 2) / math.tan(math.pi / plotCount)
	return apothem + (masterSize.Z / 2) + expansion
end

function RingMath.pluginCenterCFrame(masterCf: CFrame, masterSize: Vector3, plotCount: number, expansionOffset: number?): CFrame
	local radius = RingMath.pluginRadius(masterSize, plotCount, expansionOffset)
	return masterCf * CFrame.new(0, 0, -radius)
end

-- previewIndex is 1 .. plotCount-1 (PreviewBox_1 .. PreviewBox_(N-1))
function RingMath.pluginPreviewCFrame(
	previewIndex: number,
	plotCount: number,
	masterCf: CFrame,
	masterSize: Vector3,
	expansionOffset: number?
): CFrame
	local angleStep = (math.pi * 2) / plotCount
	local radius = RingMath.pluginRadius(masterSize, plotCount, expansionOffset)
	local centerCFrame = masterCf * CFrame.new(0, 0, -radius)
	local currentAngle = angleStep * previewIndex
	return centerCFrame * CFrame.Angles(0, currentAngle, 0) * CFrame.new(0, 0, radius)
end

-- Logical plotIndex 1 = master; 2..N = PreviewBox_(plotIndex-1)
function RingMath.plotCFrame(
	plotIndex: number,
	plotCount: number,
	masterCf: CFrame,
	masterSize: Vector3,
	expansionOffset: number?
): CFrame
	assert(plotIndex >= 1 and plotIndex <= plotCount, "plotIndex out of range")
	if plotIndex == 1 then
		return masterCf
	end
	return RingMath.pluginPreviewCFrame(plotIndex - 1, plotCount, masterCf, masterSize, expansionOffset)
end

function RingMath.remapFromMaster(worldCf: CFrame, masterPlotCf: CFrame, targetPlotCf: CFrame): CFrame
	local localCf = masterPlotCf:ToObjectSpace(worldCf)
	return targetPlotCf * localCf
end

function RingMath.remapOffsetFromMaster(worldPos: Vector3, masterPlotCf: CFrame, targetPlotCf: CFrame): Vector3
	local localPos = masterPlotCf:PointToObjectSpace(worldPos)
	return targetPlotCf:PointToWorldSpace(localPos)
end

return RingMath
