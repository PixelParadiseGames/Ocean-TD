-- Shared coral / placeable visuals. Optimized for many instances (simple Part, no shadow, no collide).

local SpeciesCatalog = require(script.Parent.SpeciesCatalog)

local CoralVisual = {}

export type VisualOptions = {
	ghost: boolean?,
	valid: boolean?, -- ghost only: species color vs red when blocked
	color: Color3?,
}

local function applyPartFlags(part: BasePart, castShadow: boolean, canCollide: boolean)
	part.Anchored = true
	part.Massless = true
	part.CanCollide = canCollide
	part.CanTouch = false
	part.CanQuery = true
	part.CastShadow = castShadow
end

function CoralVisual.create(speciesId: string, worldPos: Vector3, opts: VisualOptions?): BasePart?
	local def = SpeciesCatalog.get(speciesId)
	if not def then
		return nil
	end
	opts = opts or {}

	local diameter = def.diameter
	local part = Instance.new("Part")
	part.Name = def.speciesId
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(diameter, diameter, diameter)
	-- Halfway in terrain: center on surface so only upper hemisphere shows.
	part.CFrame = CFrame.new(worldPos)

	local ghost = opts.ghost == true
	if ghost then
		local valid = opts.valid ~= false
		local baseColor = opts.color or SpeciesCatalog.randomColor(def)
		part.Color = if valid then baseColor else Color3.fromRGB(220, 70, 70)
		part.Transparency = 0.4
		part.Material = def.material
		applyPartFlags(part, false, false)
		part:SetAttribute("OceanTD_GhostBaseR", baseColor.R)
		part:SetAttribute("OceanTD_GhostBaseG", baseColor.G)
		part:SetAttribute("OceanTD_GhostBaseB", baseColor.B)
	else
		part.Color = opts.color or SpeciesCatalog.randomColor(def)
		part.Transparency = 0
		part.Material = def.material
		applyPartFlags(part, def.castShadow, def.canCollide)
	end

	part:SetAttribute("OceanTD_SpeciesId", def.speciesId)
	part:SetAttribute("OceanTD_ItemId", def.itemId)
	return part
end

return CoralVisual
