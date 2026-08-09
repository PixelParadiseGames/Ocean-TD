--!strict
--[[
	DEPRECATED — FORBIDDEN for runtime plot poses / décor / wave remap.

	See Shared/PlotFrameContract.lua. Calling xzOffset to mutate slot.cframe
	breaks leave/rejoin VisualPos restore (coral + path slide radially).

	If PreviewBox / stamp disagree with RingMath, fix in Studio:
	Show Previews → Stamp Terrain → Hide (keep ExpansionOffset in sync).
]]

local TerrainPlotAlign = {}

function TerrainPlotAlign.xzOffset(_plotCf: CFrame, _size: Vector3): Vector3
	warn("[PLOT] TerrainPlotAlign.xzOffset is deprecated — returning zero (PlotFrameContract)")
	return Vector3.zero
end

function TerrainPlotAlign.shiftParts(_root: Instance, _worldOffset: Vector3)
	warn("[PLOT] TerrainPlotAlign.shiftParts is deprecated — no-op (PlotFrameContract)")
end

return TerrainPlotAlign
