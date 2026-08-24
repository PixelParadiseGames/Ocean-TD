-- Shared coral / placeable visuals. Ball species + mesh folder species (Sponge).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpeciesCatalog = require(script.Parent.SpeciesCatalog)
local CoralSize = require(script.Parent.CoralSize)

local CoralVisual = {}

export type VisualOptions = {
	ghost: boolean?,
	valid: boolean?, -- ghost only: species color vs red when blocked
	color: Color3?,
	diameter: number?, -- BrainCoral size bands; Sponge height cue
	sizeClass: number?, -- 1=S 2=M 3=L (mesh species)
	variantIndex: number?, -- 1..5 mesh pick
	scaleMult: number?, -- random size jitter for mesh species
}

local BRAIN_DIAMETER_MIN = 1.5
local BRAIN_DIAMETER_MAX = 9
local SPONGE_VARIANT_COUNT = 5
local SPONGE_SCALE_MIN = 0.88
local SPONGE_SCALE_MAX = 1.12
-- Lowest mesh point sits this fraction of mesh height below the ray-hit surface.
local SPONGE_GROUND_EMBED_RATIO = 0.10
local SPONGE_GROUND_EMBED_MIN = 0.20

local SIZE_PREFIX = {
	[1] = "Small",
	[2] = "Medium",
	[3] = "Large",
}

function CoralVisual.randomBrainDiameter(): number
	return 1.5 + math.random() * (4 - 1.5)
end

function CoralVisual.sanitizeBrainDiameter(raw: any): number
	local n = tonumber(raw)
	if typeof(n) ~= "number" or n ~= n then
		return CoralVisual.randomBrainDiameter()
	end
	return math.clamp(n, BRAIN_DIAMETER_MIN, BRAIN_DIAMETER_MAX)
end

function CoralVisual.randomSpongeVariant(): number
	return math.random(1, SPONGE_VARIANT_COUNT)
end

function CoralVisual.clampSpongeVariant(raw: any): number
	local n = math.floor(tonumber(raw) or 0)
	if n < 1 or n > SPONGE_VARIANT_COUNT then
		return CoralVisual.randomSpongeVariant()
	end
	return n
end

function CoralVisual.randomSpongeScale(): number
	return SPONGE_SCALE_MIN + math.random() * (SPONGE_SCALE_MAX - SPONGE_SCALE_MIN)
end

function CoralVisual.sanitizeSpongeScale(raw: any): number
	local n = tonumber(raw)
	if typeof(n) ~= "number" or n ~= n then
		return CoralVisual.randomSpongeScale()
	end
	return math.clamp(n, 0.7, 1.35)
end

local function applyPartFlags(part: BasePart, castShadow: boolean, canCollide: boolean)
	part.Anchored = true
	part.Massless = true
	part.CanCollide = canCollide
	part.CanTouch = false
	part.CanQuery = true
	part.CastShadow = castShadow
end

local function findMeshTemplate(folderName: string, sizeClass: number, variantIndex: number): MeshPart?
	local coralRoot = ReplicatedStorage:FindFirstChild("Coral")
	if not coralRoot then
		return nil
	end
	local folder = coralRoot:FindFirstChild(folderName)
	if not folder then
		return nil
	end
	local prefix = SIZE_PREFIX[CoralSize.clampTier(sizeClass)] or "Small"
	local modelName = prefix .. tostring(variantIndex)
	local model = folder:FindFirstChild(modelName)
	if not model then
		return nil
	end
	if model:IsA("MeshPart") then
		return model
	end
	local child = model:FindFirstChild(modelName) or model:FindFirstChildWhichIsA("MeshPart", true)
	if child and child:IsA("MeshPart") then
		return child
	end
	return nil
end

local function spongeEmbedDepth(part: BasePart): number
	return math.max(part.Size.Y * SPONGE_GROUND_EMBED_RATIO, SPONGE_GROUND_EMBED_MIN)
end

local function spongeBottomY(part: BasePart): number
	return part.Position.Y - part.Size.Y * 0.5
end

local function writeGridAnchor(part: BasePart, surfacePos: Vector3)
	part:SetAttribute("OceanTD_GridAnchorX", surfacePos.X)
	part:SetAttribute("OceanTD_GridAnchorY", surfacePos.Y)
	part:SetAttribute("OceanTD_GridAnchorZ", surfacePos.Z)
end

function CoralVisual.readGridAnchor(part: BasePart): Vector3?
	local x = part:GetAttribute("OceanTD_GridAnchorX")
	local y = part:GetAttribute("OceanTD_GridAnchorY")
	local z = part:GetAttribute("OceanTD_GridAnchorZ")
	if typeof(x) == "number" and typeof(y) == "number" and typeof(z) == "number" then
		return Vector3.new(x, y, z)
	end
	if part:GetAttribute("OceanTD_SpeciesId") == "Sponge" then
		local bottomY = spongeBottomY(part)
		return Vector3.new(part.Position.X, bottomY + spongeEmbedDepth(part), part.Position.Z)
	end
	return nil
end

-- Ray hit = terrain surface. Shift pivot so the mesh bottom tucks in slightly (not half buried).
local function alignSpongeToSurface(part: BasePart, surfacePos: Vector3)
	part.CFrame = CFrame.new(surfacePos)
	local bottomY = spongeBottomY(part)
	local targetBottomY = surfacePos.Y - spongeEmbedDepth(part)
	local dy = targetBottomY - bottomY
	if math.abs(dy) > 0.001 then
		part.CFrame = part.CFrame + Vector3.new(0, dy, 0)
	end
	writeGridAnchor(part, surfacePos)
end

local function spongeSurfacePos(part: BasePart): Vector3
	local embed = spongeEmbedDepth(part)
	local bottomY = spongeBottomY(part)
	return Vector3.new(part.Position.X, bottomY + embed, part.Position.Z)
end

local function finishLook(part: BasePart, def: any, opts: VisualOptions, color: Color3)
	local ghost = opts.ghost == true
	if ghost then
		local valid = opts.valid ~= false
		part.Color = if valid then color else Color3.fromRGB(220, 70, 70)
		part.Transparency = 0.45
		part.Material = Enum.Material.ForceField
		applyPartFlags(part, false, false)
		part:SetAttribute("OceanTD_GhostBaseR", color.R)
		part:SetAttribute("OceanTD_GhostBaseG", color.G)
		part:SetAttribute("OceanTD_GhostBaseB", color.B)
	else
		part.Color = color
		part.Transparency = 0
		-- Mesh imports keep Studio/FBX material; ball species use catalog material.
		if not def.meshFolder then
			part.Material = def.material
		end
		applyPartFlags(part, def.castShadow, def.canCollide)
		part:SetAttribute("OceanTD_RestR", color.R)
		part:SetAttribute("OceanTD_RestG", color.G)
		part:SetAttribute("OceanTD_RestB", color.B)
		part:SetAttribute("OceanTD_RestMaterial", part.Material.Name)
	end
	part:SetAttribute("OceanTD_SpeciesId", def.speciesId)
	part:SetAttribute("OceanTD_ItemId", def.itemId)
end

local function createSponge(def: any, worldPos: Vector3, opts: VisualOptions): BasePart?
	local sizeClass = CoralSize.clampTier(opts.sizeClass or 1)
	local variantIndex = CoralVisual.clampSpongeVariant(opts.variantIndex)
	local scaleMult = CoralVisual.sanitizeSpongeScale(opts.scaleMult)
	local template = findMeshTemplate("Sponge", sizeClass, variantIndex)
	if not template then
		warn("[CoralVisual] Missing Sponge mesh", SIZE_PREFIX[sizeClass], variantIndex)
		return nil
	end
	local part = template:Clone()
	part.Name = def.speciesId
	part:ClearAllChildren()
	part.Size = template.Size * scaleMult
	alignSpongeToSurface(part, worldPos)

	local color = opts.color or SpeciesCatalog.randomColor(def)
	finishLook(part, def, opts, color)

	part:SetAttribute("OceanTD_Diameter", part.Size.Y)
	part:SetAttribute("OceanTD_SizeClass", sizeClass)
	part:SetAttribute("OceanTD_SizeTier", sizeClass)
	part:SetAttribute("OceanTD_VariantIndex", variantIndex)
	part:SetAttribute("OceanTD_ScaleMult", scaleMult)
	return part
end

local function createBall(def: any, worldPos: Vector3, opts: VisualOptions): BasePart?
	local diameter = opts.diameter or def.diameter
	if typeof(diameter) ~= "number" or diameter ~= diameter or diameter <= 0 then
		diameter = def.diameter
	end
	local part = Instance.new("Part")
	part.Name = def.speciesId
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(diameter, diameter, diameter)
	part.CFrame = CFrame.new(worldPos)

	local color = opts.color or SpeciesCatalog.randomColor(def)
	finishLook(part, def, opts, color)
	part:SetAttribute("OceanTD_Diameter", diameter)
	return part
end

function CoralVisual.create(speciesId: string, worldPos: Vector3, opts: VisualOptions?): BasePart?
	local def = SpeciesCatalog.get(speciesId)
	if not def then
		return nil
	end
	opts = opts or {}
	if def.meshFolder == "Sponge" or speciesId == "Sponge" then
		return createSponge(def, worldPos, opts)
	end
	return createBall(def, worldPos, opts)
end

local function copyAttributes(from: Instance, to: Instance)
	for name, value in from:GetAttributes() do
		to:SetAttribute(name, value)
	end
end

-- Swap mesh/size (upgrade). Returns replacement part + height/variant/scale.
function CoralVisual.restyleSponge(
	part: BasePart,
	sizeClass: number,
	variantIndex: number?,
	scaleMult: number?
): (BasePart?, number?, number?, number?)
	local class = CoralSize.clampTier(sizeClass)
	local variant = CoralVisual.clampSpongeVariant(variantIndex)
	local scale = CoralVisual.sanitizeSpongeScale(scaleMult)
	local template = findMeshTemplate("Sponge", class, variant)
	if not template then
		warn("[CoralVisual] Missing Sponge mesh for restyle", SIZE_PREFIX[class], variant)
		return nil
	end

	local surfacePos = spongeSurfacePos(part)
	local parent = part.Parent
	local _, color = CoralVisual.readRestLook(part)
	local newPart = template:Clone()
	newPart.Name = part.Name
	newPart:ClearAllChildren()
	newPart.Size = template.Size * scale
	alignSpongeToSurface(newPart, surfacePos)
	copyAttributes(part, newPart)
	newPart:SetAttribute("OceanTD_Diameter", newPart.Size.Y)
	newPart:SetAttribute("OceanTD_SizeClass", class)
	newPart:SetAttribute("OceanTD_VariantIndex", variant)
	newPart:SetAttribute("OceanTD_ScaleMult", scale)
	newPart.Material = template.Material
	newPart.Color = color
	newPart.Transparency = 0
	newPart:SetAttribute("OceanTD_RestMaterial", template.Material.Name)
	applyPartFlags(newPart, false, true)

	newPart.Parent = parent
	part:Destroy()
	return newPart, newPart.Size.Y, variant, scale
end

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

function CoralVisual.setRestColor(part: BasePart, color: Color3)
	part:SetAttribute("OceanTD_RestR", color.R)
	part:SetAttribute("OceanTD_RestG", color.G)
	part:SetAttribute("OceanTD_RestB", color.B)
	if part:GetAttribute("OceanTD_CrabStunned") == true then
		return
	end
	part.Color = color
end

function CoralVisual.alignSpongeToSurface(part: BasePart, surfacePos: Vector3)
	alignSpongeToSurface(part, surfacePos)
end

return CoralVisual
