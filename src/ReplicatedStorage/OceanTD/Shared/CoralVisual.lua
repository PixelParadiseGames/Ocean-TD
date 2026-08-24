-- Shared coral / placeable visuals. Ball species + mesh folder species (Sponge, SeaGrass, …).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpeciesCatalog = require(script.Parent.SpeciesCatalog)
local CoralSize = require(script.Parent.CoralSize)

local CoralVisual = {}

export type VisualOptions = {
	ghost: boolean?,
	valid: boolean?, -- ghost only: species color vs red when blocked
	color: Color3?,
	diameter: number?, -- BrainCoral size bands; mesh height cue
	sizeClass: number?, -- 1=S 2=M 3=L (mesh species)
	variantIndex: number?, -- 1..5 mesh pick
	scaleMult: number?, -- random size jitter for mesh species
}

local BRAIN_DIAMETER_MIN = 1.5
local BRAIN_DIAMETER_MAX = 9
local MESH_VARIANT_COUNT = 5
local MESH_SCALE_MIN = 0.88
local MESH_SCALE_MAX = 1.12
-- SeaGrass authored meshes need a large in-game scale boost.
local SEA_GRASS_BASE_SCALE = 4
-- How far the lowest mesh point sits below the ray-hit surface.
-- Cap so tall SeaGrass (base scale ×4) is not buried by a huge % of height.
local MESH_GROUND_EMBED_RATIO = 0.08
local MESH_GROUND_EMBED_MIN = 0.15
local MESH_GROUND_EMBED_MAX = 0.55

local SIZE_PREFIX = {
	[1] = "Small",
	[2] = "Medium",
	[3] = "Large",
}

function CoralVisual.isMeshSpecies(speciesId: any): boolean
	if typeof(speciesId) ~= "string" then
		return false
	end
	local def = SpeciesCatalog.get(speciesId)
	return def ~= nil and typeof(def.meshFolder) == "string" and def.meshFolder ~= ""
end

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
	return math.random(1, MESH_VARIANT_COUNT)
end

function CoralVisual.clampSpongeVariant(raw: any): number
	local n = math.floor(tonumber(raw) or 0)
	if n < 1 or n > MESH_VARIANT_COUNT then
		return CoralVisual.randomSpongeVariant()
	end
	return n
end

function CoralVisual.randomSpongeScale(): number
	return MESH_SCALE_MIN + math.random() * (MESH_SCALE_MAX - MESH_SCALE_MIN)
end

function CoralVisual.sanitizeSpongeScale(raw: any): number
	local n = tonumber(raw)
	if typeof(n) ~= "number" or n ~= n then
		return CoralVisual.randomSpongeScale()
	end
	return math.clamp(n, 0.7, 1.35)
end

-- Aliases for mesh species (same variant/scale rules as Sponge).
CoralVisual.randomMeshVariant = CoralVisual.randomSpongeVariant
CoralVisual.clampMeshVariant = CoralVisual.clampSpongeVariant
CoralVisual.randomMeshScale = CoralVisual.randomSpongeScale
CoralVisual.sanitizeMeshScale = CoralVisual.sanitizeSpongeScale

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

local function meshEmbedDepth(part: BasePart): number
	return math.clamp(part.Size.Y * MESH_GROUND_EMBED_RATIO, MESH_GROUND_EMBED_MIN, MESH_GROUND_EMBED_MAX)
end

local function writeGridAnchor(part: BasePart, surfacePos: Vector3)
	part:SetAttribute("OceanTD_GridAnchorX", surfacePos.X)
	part:SetAttribute("OceanTD_GridAnchorY", surfacePos.Y)
	part:SetAttribute("OceanTD_GridAnchorZ", surfacePos.Z)
end

-- MeshPart Position is the Size-box center (Studio import). Bottom = Position.Y - Size.Y/2.
local function meshBottomY(part: BasePart): number
	return part.Position.Y - part.Size.Y * 0.5
end

local function meshSurfacePos(part: BasePart): Vector3
	local bottomY = meshBottomY(part)
	return Vector3.new(part.Position.X, bottomY + meshEmbedDepth(part), part.Position.Z)
end

function CoralVisual.readGridAnchor(part: BasePart): Vector3?
	local x = part:GetAttribute("OceanTD_GridAnchorX")
	local y = part:GetAttribute("OceanTD_GridAnchorY")
	local z = part:GetAttribute("OceanTD_GridAnchorZ")
	if typeof(x) == "number" and typeof(y) == "number" and typeof(z) == "number" then
		return Vector3.new(x, y, z)
	end
	if CoralVisual.isMeshSpecies(part:GetAttribute("OceanTD_SpeciesId")) then
		return meshSurfacePos(part)
	end
	return nil
end

-- Humanoids only climb TrussParts; invisible truss tracks the SeaGrass mesh.
local function syncSeaGrassClimb(part: BasePart)
	if part:GetAttribute("OceanTD_SpeciesId") ~= "SeaGrass" then
		return
	end
	-- Ghosts / force-field previews are not climbable.
	if part.Material == Enum.Material.ForceField or part.Transparency > 0.2 then
		local existing = part:FindFirstChild("OceanTD_Climb")
		if existing then
			existing:Destroy()
		end
		return
	end

	local truss = part:FindFirstChild("OceanTD_Climb")
	if not truss or not truss:IsA("TrussPart") then
		if truss then
			truss:Destroy()
		end
		truss = Instance.new("TrussPart")
		truss.Name = "OceanTD_Climb"
		truss.Transparency = 1
		truss.CanCollide = true
		truss.CanQuery = false
		truss.CanTouch = false
		truss.CastShadow = false
		truss.Massless = true
		truss.Anchored = false
		truss.Parent = part
		local weld = Instance.new("WeldConstraint")
		weld.Name = "OceanTD_ClimbWeld"
		weld.Part0 = part
		weld.Part1 = truss
		weld.Parent = truss
	end

	local cross = math.clamp(math.min(part.Size.X, part.Size.Z) * 0.5, 1.5, 5)
	truss.Size = Vector3.new(cross, math.max(part.Size.Y, 1), cross)
	truss.CFrame = part.CFrame
end

-- Plant Size-box bottom on surfacePos (world). One PivotTo — no additive CFrame math.
local function alignMeshToSurface(part: BasePart, surfacePos: Vector3)
	pcall(function()
		(part :: any).PivotOffset = CFrame.new()
	end)
	local embed = meshEmbedDepth(part)
	local target = Vector3.new(surfacePos.X, surfacePos.Y - embed + part.Size.Y * 0.5, surfacePos.Z)
	part:PivotTo(CFrame.new(target))
	writeGridAnchor(part, surfacePos)
	syncSeaGrassClimb(part)
end

local function prepareMeshClone(template: MeshPart, name: string, size: Vector3): MeshPart
	local part = template:Clone()
	part.Name = name
	part:ClearAllChildren()
	pcall(function()
		part.PivotOffset = CFrame.new()
	end)
	part.Size = size
	part.CFrame = CFrame.new()
	return part
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

local function createMeshSpecies(def: any, worldPos: Vector3, opts: VisualOptions): BasePart?
	local folderName = def.meshFolder
	if typeof(folderName) ~= "string" or folderName == "" then
		return nil
	end
	local sizeClass = CoralSize.clampTier(opts.sizeClass or 1)
	local variantIndex = CoralVisual.clampMeshVariant(opts.variantIndex)
	local scaleMult = CoralVisual.sanitizeMeshScale(opts.scaleMult)
	local template = findMeshTemplate(folderName, sizeClass, variantIndex)
	if not template then
		warn("[CoralVisual] Missing mesh", folderName, SIZE_PREFIX[sizeClass], variantIndex)
		return nil
	end
	local baseScale = if def.speciesId == "SeaGrass" then SEA_GRASS_BASE_SCALE else 1
	local part = prepareMeshClone(template, def.speciesId, template.Size * scaleMult * baseScale)
	alignMeshToSurface(part, worldPos)

	-- SeaGrass: keep imported mesh green as starting color unless paint/ghost overrides.
	local color = opts.color
	if not color then
		if def.speciesId == "SeaGrass" then
			color = template.Color
		else
			color = SpeciesCatalog.randomColor(def)
		end
	end
	finishLook(part, def, opts, color)

	part:SetAttribute("OceanTD_Diameter", part.Size.Y)
	part:SetAttribute("OceanTD_SizeClass", sizeClass)
	part:SetAttribute("OceanTD_SizeTier", sizeClass)
	part:SetAttribute("OceanTD_VariantIndex", variantIndex)
	part:SetAttribute("OceanTD_ScaleMult", scaleMult)
	syncSeaGrassClimb(part)
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
	if typeof(def.meshFolder) == "string" and def.meshFolder ~= "" then
		return createMeshSpecies(def, worldPos, opts)
	end
	return createBall(def, worldPos, opts)
end

-- Swap mesh/size (upgrade).
-- Sponge: ApplyMesh in place (works).
-- SeaGrass: fresh Clone + plant like create() — ApplyMesh kept Medium/Large pivots and slid the visual.
function CoralVisual.restyleSponge(
	part: BasePart,
	sizeClass: number,
	variantIndex: number?,
	scaleMult: number?,
	surfacePosOpt: Vector3?
): (BasePart?, number?, number?, number?)
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	local def = if typeof(speciesId) == "string" then SpeciesCatalog.get(speciesId) else nil
	local folderName = if def and typeof(def.meshFolder) == "string" then def.meshFolder else "Sponge"
	local class = CoralSize.clampTier(sizeClass)
	local variant = CoralVisual.clampMeshVariant(variantIndex)
	local scale = CoralVisual.sanitizeMeshScale(scaleMult)
	local template = findMeshTemplate(folderName, class, variant)
	if not template then
		warn("[CoralVisual] Missing mesh for restyle", folderName, SIZE_PREFIX[class], variant)
		return nil
	end

	local surfacePos = surfacePosOpt or CoralVisual.readGridAnchor(part) or meshSurfacePos(part)
	local _, color = CoralVisual.readRestLook(part)
	local baseScale = if speciesId == "SeaGrass" then SEA_GRASS_BASE_SCALE else 1
	local newSize = template.Size * scale * baseScale
	local castShadow = if def then def.castShadow else false
	local canCollide = if def then def.canCollide else true

	local function finishAttrs(target: BasePart)
		target:SetAttribute("OceanTD_Diameter", target.Size.Y)
		target:SetAttribute("OceanTD_SizeClass", class)
		target:SetAttribute("OceanTD_VariantIndex", variant)
		target:SetAttribute("OceanTD_ScaleMult", scale)
		target:SetAttribute("OceanTD_CineShrunk", nil)
		target:SetAttribute("OceanTD_CineFullX", nil)
		target:SetAttribute("OceanTD_CineFullY", nil)
		target:SetAttribute("OceanTD_CineFullZ", nil)
		target:SetAttribute("OceanTD_CinePrep", nil)
		target:SetAttribute("OceanTD_RestMaterial", template.Material.Name)
		target.Material = template.Material
		target.Color = color
		target.Transparency = 0
		applyPartFlags(target, castShadow, canCollide)
	end

	-- SeaGrass: same as first place — plant unparented, then parent (avoids origin-scale jump).
	if speciesId == "SeaGrass" then
		local parent = part.Parent
		local keep: { [string]: any } = {}
		for name, value in part:GetAttributes() do
			keep[name] = value
		end
		part:Destroy()

		local newPart = prepareMeshClone(template, "SeaGrass", newSize)
		for name, value in keep do
			newPart:SetAttribute(name, value)
		end
		finishAttrs(newPart)
		alignMeshToSurface(newPart, surfacePos)
		newPart.Parent = parent
		local embed = meshEmbedDepth(newPart)
		local target = Vector3.new(surfacePos.X, surfacePos.Y - embed + newPart.Size.Y * 0.5, surfacePos.Z)
		newPart:PivotTo(CFrame.new(target))
		writeGridAnchor(newPart, surfacePos)
		syncSeaGrassClimb(newPart)
		return newPart, newPart.Size.Y, variant, scale
	end

	-- Sponge (and other mesh species): ApplyMesh in place.
	if not part:IsA("MeshPart") then
		warn("[CoralVisual] restyle expected MeshPart", part:GetFullName())
		return nil
	end
	local climb = part:FindFirstChild("OceanTD_Climb")
	if climb then
		climb:Destroy()
	end
	local applied = pcall(function()
		(part :: MeshPart):ApplyMesh(template)
	end)
	if not applied then
		warn("[CoralVisual] ApplyMesh failed", folderName, SIZE_PREFIX[class], variant)
		return nil
	end
	pcall(function()
		(part :: MeshPart).PivotOffset = CFrame.new()
	end)
	part.Size = newSize
	finishAttrs(part)
	alignMeshToSurface(part, surfacePos)
	return part, newSize.Y, variant, scale
end

CoralVisual.restyleMesh = CoralVisual.restyleSponge

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
	alignMeshToSurface(part, surfacePos)
end

CoralVisual.alignMeshToSurface = CoralVisual.alignSpongeToSurface

return CoralVisual
