-- Plot layout restore helpers: plot-local coords portable across plot slots;
-- reframeLayout preserves world positions when Plot Size stage changes bounds CFrame.

local GridMath = require(script.Parent.GridMath)
local PlotTypes = require(script.Parent.PlotTypes)

type LayoutObject = PlotTypes.LayoutObject

local LayoutRestore = {}

-- Plot-local VisualPos for the current bounds CFrame (portable across Plot1..Plot6).
function LayoutRestore.resolveVisualLocal(obj: LayoutObject, _boundsCFrame: CFrame): Vector3
	return Vector3.new(obj.lx, obj.ly, obj.lz)
end

-- Keep world positions when plot bounds CFrame changes (Plot Size stage, same plot slot).
function LayoutRestore.reframeLayout(layout: { LayoutObject }, oldCf: CFrame, newCf: CFrame): { LayoutObject }
	if oldCf == newCf then
		return layout
	end
	local out: { LayoutObject } = {}
	for _, obj in ipairs(layout) do
		local world = GridMath.plotLocalToWorld(Vector3.new(obj.lx, obj.ly, obj.lz), oldCf)
		local localPos = GridMath.worldToPlotLocal(world, newCf)
		local gx, gy, gz = GridMath.worldToGrid(localPos, Vector3.zero)
		table.insert(out, {
			id = obj.id,
			lx = localPos.X,
			ly = localPos.Y,
			lz = localPos.Z,
			gx = gx,
			gy = gy,
			gz = gz,
			diameter = obj.diameter,
			sizeTier = obj.sizeTier,
			sizeClass = obj.sizeClass,
			colorIndex = obj.colorIndex,
			colorR = obj.colorR,
			colorG = obj.colorG,
			colorB = obj.colorB,
			variantIndex = obj.variantIndex,
			scaleMult = obj.scaleMult,
			scaleWidth = obj.scaleWidth,
			scaleHeight = obj.scaleHeight,
			facingYaw = obj.facingYaw,
			webColorR = obj.webColorR,
			webColorG = obj.webColorG,
			webColorB = obj.webColorB,
			placeId = obj.placeId,
			parentPlaceId = obj.parentPlaceId,
		})
	end
	return out
end

return LayoutRestore
