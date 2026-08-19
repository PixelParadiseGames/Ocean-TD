-- Shared coral / placeable visuals. Optimized for many instances (simple Part, no shadow).

local SpeciesCatalog = require(script.Parent.SpeciesCatalog)

local CoralVisual = {}

export type VisualOptions = {
	ghost: boolean?,
	valid: boolean?, -- ghost only: species color vs red when blocked
	color: Color3?,
	diameter: number?, -- overrides species default (e.g. BrainCoral 2..5)
}

local BRAIN_DIAMETER_MIN = 1.5
local BRAIN_DIAMETER_MAX = 9

function CoralVisual.randomBrainDiameter(): number
	-- New placements are Small band (1.5–4).
	return 1.5 + math.random() * (4 - 1.5)
end

function CoralVisual.sanitizeBrainDiameter(raw: any): number
	local n = tonumber(raw)
	if typeof(n) ~= "number" or n ~= n then
		return CoralVisual.randomBrainDiameter()
	end
	return math.clamp(n, BRAIN_DIAMETER_MIN, BRAIN_DIAMETER_MAX)
end

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

	local diameter = opts.diameter or def.diameter
	if typeof(diameter) ~= "number" or diameter ~= diameter or diameter <= 0 then
		diameter = def.diameter
	end
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
		local color = opts.color or SpeciesCatalog.randomColor(def)
		part.Color = color
		part.Transparency = 0
		part.Material = def.material
		applyPartFlags(part, def.castShadow, def.canCollide)
		-- Rest look for hover/relocate restore (avoids stuck Neon after build selection).
		part:SetAttribute("OceanTD_RestR", color.R)
		part:SetAttribute("OceanTD_RestG", color.G)
		part:SetAttribute("OceanTD_RestB", color.B)
		part:SetAttribute("OceanTD_RestMaterial", def.material.Name)
	end

	part:SetAttribute("OceanTD_SpeciesId", def.speciesId)
	part:SetAttribute("OceanTD_ItemId", def.itemId)
	part:SetAttribute("OceanTD_Diameter", diameter)
	return part
end

--- Read stored rest look, or capture/write it if missing (and not mid-neon flash).
function CoralVisual.readRestLook(part: BasePart): (Enum.Material, Color3)
	local r = part:GetAttribute("OceanTD_RestR")
	local g = part:GetAttribute("OceanTD_RestG")
	local b = part:GetAttribute("OceanTD_RestB")
	local matName = part:GetAttribute("OceanTD_RestMaterial")
	if typeof(r) == "number" and typeof(g) == "number" and typeof(b) == "number" then
		local mat = Enum.Material.Pebble
		if typeof(matName) == "string" then
			local ok, resolved = pcall(function()
				return (Enum.Material :: any)[matName]
			end)
			if ok and typeof(resolved) == "EnumItem" then
				mat = resolved :: Enum.Material
			end
		end
		return mat, Color3.new(r, g, b)
	end

	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	local def = if typeof(speciesId) == "string" then SpeciesCatalog.get(speciesId) else nil
	local mat = if def then def.material else Enum.Material.Pebble
	local color = part.Color

	-- Don't persist a mid-flash Neon frame as the rest look.
	if part.Material ~= Enum.Material.Neon then
		mat = part.Material
		part:SetAttribute("OceanTD_RestR", color.R)
		part:SetAttribute("OceanTD_RestG", color.G)
		part:SetAttribute("OceanTD_RestB", color.B)
		part:SetAttribute("OceanTD_RestMaterial", mat.Name)
	end
	return mat, color
end

function CoralVisual.applyRestLook(part: BasePart)
	local mat, color = CoralVisual.readRestLook(part)
	part.Material = mat
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	local def = if typeof(speciesId) == "string" then SpeciesCatalog.get(speciesId) else nil
	if def then
		part.CanCollide = def.canCollide
	end
	if part:GetAttribute("OceanTD_CrabStunned") == true then
		part.Color = Color3.new(1, 1, 1)
		return
	end
	part.Color = color
end

return CoralVisual
