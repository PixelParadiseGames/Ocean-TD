-- Shared coral / placeable visuals. Ball species + mesh folder species (Sponge, SeaGrass, SeaFan, …).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpeciesCatalog = require(script.Parent.SpeciesCatalog)
local CoralSize = require(script.Parent.CoralSize)
local PlotOutlineColors = require(script.Parent.PlotOutlineColors)

local CoralVisual = {}

export type VisualOptions = {
	ghost: boolean?,
	valid: boolean?, -- ghost only: species color vs red when blocked
	color: Color3?,
	webColor: Color3?,
	diameter: number?, -- BrainCoral size bands; mesh height cue
	sizeClass: number?, -- 1=S 2=M 3=L (mesh species)
	variantIndex: number?, -- 1..5 mesh pick (SeaFan always 1)
	scaleMult: number?, -- random size jitter for mesh species
	scaleWidth: number?, -- SeaFan independent XZ jitter
	scaleHeight: number?, -- SeaFan independent Y jitter
	facingYaw: number?, -- SeaFan Y yaw in **plot-local** radians (survives plot reassignment)
	plotCFrame: CFrame?, -- plot bounds CF; required for SeaFan yaw to be plot-relative
}

local BRAIN_DIAMETER_MIN = 1.5
local BRAIN_DIAMETER_MAX = 9
local MESH_VARIANT_COUNT = 5
local MESH_SCALE_MIN = 0.88
local MESH_SCALE_MAX = 1.12
-- Fire Coral: wider per-place / per-size-upgrade jitter (±15%).
local FIRE_CORAL_SCALE_MIN = 0.85
local FIRE_CORAL_SCALE_MAX = 1.15
-- Zoas: 20% narrower scale spread than Fire Coral (±12%).
local ZOAS_SCALE_HALF_SPREAD = (FIRE_CORAL_SCALE_MAX - FIRE_CORAL_SCALE_MIN) * 0.5 * 0.8
local ZOAS_SCALE_MIN = 1 - ZOAS_SCALE_HALF_SPREAD
local ZOAS_SCALE_MAX = 1 + ZOAS_SCALE_HALF_SPREAD
-- Leather Coral: wide colony jitter so S/M/L placements don't look cloned (±25%).
local LEATHER_CORAL_SCALE_MIN = 0.75
local LEATHER_CORAL_SCALE_MAX = 1.25
local SEA_FAN_AXIS_MIN = 0.85
local SEA_FAN_AXIS_MAX = 1.15
-- SeaGrass authored meshes need a large in-game scale boost.
local SEA_GRASS_BASE_SCALE = 4
-- How far the lowest mesh point sits below the ray-hit surface.
-- Cap so tall SeaGrass (base scale ×4) is not buried by a huge % of height.
local MESH_GROUND_EMBED_RATIO = 0.08
local MESH_GROUND_EMBED_MIN = 0.15
local MESH_GROUND_EMBED_MAX = 0.55
local ZOAS_EXTRA_EMBED = 1

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

function CoralVisual.isSeaFan(speciesId: any): boolean
	return speciesId == "SeaFan"
end

function CoralVisual.isZoas(speciesId: any): boolean
	return speciesId == "Zoas"
end

function CoralVisual.isTreeCoral(speciesId: any): boolean
	return speciesId == "TreeCoral"
end

function CoralVisual.isLeatherCoral(speciesId: any): boolean
	return speciesId == "LeatherCoral"
end

-- Main + Accent mesh corals (Zoas, Tree Coral, Leather Coral) — not Sea Fan stem/web naming.
function CoralVisual.isMainAccentMesh(speciesId: any): boolean
	return CoralVisual.isZoas(speciesId)
		or CoralVisual.isTreeCoral(speciesId)
		or CoralVisual.isLeatherCoral(speciesId)
end

function CoralVisual.isDualColorMesh(speciesId: any): boolean
	return CoralVisual.isSeaFan(speciesId) or CoralVisual.isMainAccentMesh(speciesId)
end

-- Species that plant with a Y facing (plot-local). SeaFan is player-rotated; others roll random (no rotate chrome).
function CoralVisual.needsFacingYaw(speciesId: any): boolean
	return speciesId == "SeaFan"
		or speciesId == "FireCoral"
		or speciesId == "Zoas"
		or speciesId == "LeatherCoral"
end

function CoralVisual.randomFacingYaw(): number
	return math.random() * math.pi * 2
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

function CoralVisual.meshVariantCount(speciesId: string?): number
	if speciesId == "SeaFan" or speciesId == "FireCoral" or speciesId == "Zoas" or speciesId == "TreeCoral" or speciesId == "LeatherCoral" then
		return 1
	end
	return MESH_VARIANT_COUNT
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

function CoralVisual.randomMeshScale(speciesId: string?): number
	if speciesId == "FireCoral" then
		return FIRE_CORAL_SCALE_MIN + math.random() * (FIRE_CORAL_SCALE_MAX - FIRE_CORAL_SCALE_MIN)
	end
	if speciesId == "Zoas" or speciesId == "TreeCoral" then
		return ZOAS_SCALE_MIN + math.random() * (ZOAS_SCALE_MAX - ZOAS_SCALE_MIN)
	end
	if speciesId == "LeatherCoral" then
		return LEATHER_CORAL_SCALE_MIN + math.random() * (LEATHER_CORAL_SCALE_MAX - LEATHER_CORAL_SCALE_MIN)
	end
	return CoralVisual.randomSpongeScale()
end

function CoralVisual.sanitizeMeshScale(raw: any, speciesId: string?): number
	local n = tonumber(raw)
	if typeof(n) ~= "number" or n ~= n then
		return CoralVisual.randomMeshScale(speciesId)
	end
	return math.clamp(n, 0.7, 1.35)
end

function CoralVisual.randomMeshVariant(speciesId: string?): number
	local maxV = CoralVisual.meshVariantCount(speciesId)
	if maxV <= 1 then
		return 1
	end
	return math.random(1, maxV)
end

function CoralVisual.clampMeshVariant(raw: any, speciesId: string?): number
	local maxV = CoralVisual.meshVariantCount(speciesId)
	local n = math.floor(tonumber(raw) or 0)
	if n < 1 or n > maxV then
		return CoralVisual.randomMeshVariant(speciesId)
	end
	return n
end

function CoralVisual.randomSeaFanAxis(): number
	return SEA_FAN_AXIS_MIN + math.random() * (SEA_FAN_AXIS_MAX - SEA_FAN_AXIS_MIN)
end

function CoralVisual.sanitizeSeaFanAxis(raw: any): number
	local n = tonumber(raw)
	if typeof(n) ~= "number" or n ~= n then
		return CoralVisual.randomSeaFanAxis()
	end
	return math.clamp(n, 0.7, 1.35)
end

function CoralVisual.randomSeaFanScales(): (number, number, number)
	return CoralVisual.randomSeaFanAxis(), CoralVisual.randomSeaFanAxis(), CoralVisual.randomSeaFanAxis()
end

function CoralVisual.yawFromLookVector(look: Vector3): number
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-4 then
		return 0
	end
	flat = flat.Unit
	-- Matches CFrame.lookAt: LookVector (-Z) points along `flat`.
	return math.atan2(-flat.X, -flat.Z)
end

function CoralVisual.readFacingYaw(part: BasePart): number
	-- Attribute is the only source of truth (set on place / rotate / hydrate).
	-- Do not re-derive from LookVector — mesh imports often disagree with Angles(0,yaw,0).
	local yaw = part:GetAttribute("OceanTD_FacingYaw")
	if typeof(yaw) == "number" and yaw == yaw then
		return yaw
	end
	return 0
end

local function applyPartFlags(part: BasePart, castShadow: boolean, canCollide: boolean, speciesId: string?)
	part.Anchored = true
	part.Massless = true
	part.CanCollide = canCollide
	part.CanTouch = false
	part.CanQuery = true
	part.CastShadow = castShadow
	-- Fire Coral: walkable but no trampoline bounce.
	local id = speciesId or part:GetAttribute("OceanTD_SpeciesId")
	if canCollide and (id == "FireCoral" or id == "Zoas" or id == "TreeCoral" or id == "LeatherCoral") then
		local density = 0.7
		local friction = 0.5
		local frictionWeight = 1
		pcall(function()
			local props = part.CurrentPhysicalProperties
			density = props.Density
			friction = props.Friction
			frictionWeight = props.FrictionWeight
		end)
		part.CustomPhysicalProperties = PhysicalProperties.new(density, friction, 0, frictionWeight, 100)
	end
end

local function findMeshFolder(folderName: string): Instance?
	local coralRoot = ReplicatedStorage:FindFirstChild("Coral")
	if not coralRoot then
		return nil
	end
	return coralRoot:FindFirstChild(folderName)
end

-- Studio Fire Coral layout (authored):
--   ReplicatedStorage.Coral["Fire Coral"].FireCoral_Small.Small1
--   …FireCoral_Medium.Med1
--   …FireCoral_Large.Large1
local FIRE_CORAL_WRAPPER = {
	[1] = "FireCoral_Small",
	[2] = "FireCoral_Medium",
	[3] = "FireCoral_Large",
}
local FIRE_CORAL_MESH_NAMES = {
	[1] = { "Small1" },
	[2] = { "Med1", "Medium1" },
	[3] = { "Large1" },
}

-- Studio Zoas layout (one Model per size — import combined FBX from Models/Zoas/):
--   ReplicatedStorage.Coral.Zoas.ZoaSmall  → MeshParts Main, Accent (aligned in one FBX)
--   …ZoaMed, ZoaLarge
local ZOAS_MODEL_NAMES = {
	[1] = "ZoaSmall",
	[2] = "ZoaMed",
	[3] = "ZoaLarge",
}

-- Studio Tree Coral layout (one Model per size — combined Main + Accent FBX):
--   ReplicatedStorage.Coral.TreeCoral.TreeSmall  → MeshParts Main, Accent + Food1..N
--   TreeLarge may include hidden Part "Collider" (×N) — cloned as the only walk surfaces.
local TREE_CORAL_MODEL_NAMES = {
	[1] = "TreeSmall",
	[2] = "TreeMed",
	[3] = "TreeLarge",
}

local TREE_CORAL_TIER_SCALE = {
	[1] = 1.20, -- small +20%
	[2] = 1.70, -- medium +70%
	[3] = 1.40, -- large +40%
}

-- Studio Leather Coral layout (one Model per size — combined Main + Accent FBX):
--   ReplicatedStorage.Coral.Leather.LeatherSmall  → MeshParts Main*, Accent + Food1..N + Collider*
--   …LeatherMed, LeatherLarge
local LEATHER_CORAL_MODEL_NAMES = {
	[1] = "LeatherSmall",
	[2] = "LeatherMed",
	[3] = "LeatherLarge",
}

local MAIN_ACCENT_MESH = {
	Zoas = { folder = "Zoas", models = ZOAS_MODEL_NAMES, stemName = "Zoas", attachFood = false, attachWalkColliders = false },
	TreeCoral = { folder = "TreeCoral", models = TREE_CORAL_MODEL_NAMES, stemName = "TreeCoral", attachFood = true, attachWalkColliders = true },
	LeatherCoral = { folder = "Leather", models = LEATHER_CORAL_MODEL_NAMES, stemName = "LeatherCoral", attachFood = true, attachWalkColliders = true },
}

local function mainAccentEffectiveScale(speciesId: string, scaleMult: number, sizeClass: number): number
	if speciesId == "TreeCoral" then
		local tier = CoralSize.clampTier(sizeClass)
		return scaleMult * (TREE_CORAL_TIER_SCALE[tier] or 1)
	end
	return scaleMult
end

local function matchMainAccentPartName(name: string, kind: "main" | "accent"): boolean
	local lower = string.lower(name)
	if kind == "accent" then
		return lower == "accent" or string.find(lower, "accent", 1, true) ~= nil
	end
	return lower == "main" or string.find(lower, "main", 1, true) ~= nil
end

local function findMainAccentModel(speciesId: string, sizeClass: number): Model?
	local cfg = MAIN_ACCENT_MESH[speciesId]
	if not cfg then
		return nil
	end
	local folder = findMeshFolder(cfg.folder)
	if not folder then
		return nil
	end
	local tier = CoralSize.clampTier(sizeClass)
	local modelName = cfg.models[tier]
	if not modelName then
		return nil
	end
	local model = folder:FindFirstChild(modelName)
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

local function findMainAccentTemplatePart(model: Model, kind: "main" | "accent"): MeshPart?
	local preferred = if kind == "main" then { "Main" } else { "Accent" }
	for _, name in ipairs(preferred) do
		local child = model:FindFirstChild(name)
		if child and child:IsA("MeshPart") then
			return child
		end
	end
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("MeshPart") and matchMainAccentPartName(child.Name, kind) then
			return child
		end
	end
	if kind == "main" then
		return model:FindFirstChildWhichIsA("MeshPart", true)
	end
	return nil
end

local function findZoasModel(sizeClass: number): Model?
	return findMainAccentModel("Zoas", sizeClass)
end

local function findTreeCoralModel(sizeClass: number): Model?
	return findMainAccentModel("TreeCoral", sizeClass)
end

local function findZoasTemplatePart(model: Model, kind: "main" | "accent"): MeshPart?
	return findMainAccentTemplatePart(model, kind)
end

local function findFireCoralTemplate(folder: Instance, sizeClass: number): MeshPart?
	local tier = CoralSize.clampTier(sizeClass)
	local wrapper = folder:FindFirstChild(FIRE_CORAL_WRAPPER[tier])
	if not wrapper then
		return nil
	end
	local names = FIRE_CORAL_MESH_NAMES[tier]
	if names then
		for _, name in ipairs(names) do
			local child = wrapper:FindFirstChild(name)
			if child and child:IsA("MeshPart") then
				return child
			end
		end
	end
	local any = wrapper:FindFirstChildWhichIsA("MeshPart", true)
	if any and any:IsA("MeshPart") then
		return any
	end
	return nil
end

local function findMeshTemplate(folderName: string, sizeClass: number, variantIndex: number): MeshPart?
	local folder = findMeshFolder(folderName)
	if not folder then
		return nil
	end
	if folderName == "Fire Coral" then
		return findFireCoralTemplate(folder, sizeClass)
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

local function findSeaFanModel(sizeClass: number, variantIndex: number): Model?
	local folder = findMeshFolder("Seafan")
	if not folder then
		return nil
	end
	local prefix = SIZE_PREFIX[CoralSize.clampTier(sizeClass)] or "Small"
	local modelName = prefix .. tostring(math.clamp(variantIndex, 1, 1))
	local model = folder:FindFirstChild(modelName)
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

local function meshEmbedDepth(part: BasePart): number
	local depth = math.clamp(part.Size.Y * MESH_GROUND_EMBED_RATIO, MESH_GROUND_EMBED_MIN, MESH_GROUND_EMBED_MAX)
	if CoralVisual.isZoas(part:GetAttribute("OceanTD_SpeciesId")) or CoralVisual.isLeatherCoral(part:GetAttribute("OceanTD_SpeciesId")) then
		depth += ZOAS_EXTRA_EMBED
	end
	return depth
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
-- Mesh stays non-collidable so it never blocks grabbing the climb volume.
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

	-- Only the center truss collides; mesh must not push the player off the climb.
	part.CanCollide = false

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

	truss.CanCollide = true
	local cross = math.clamp(math.min(part.Size.X, part.Size.Z) * 0.5, 1.5, 5)
	truss.Size = Vector3.new(cross, math.max(part.Size.Y, 1), cross)
	truss.CFrame = part.CFrame
end

local function scaleCFrameTranslation(rel: CFrame, sx: number, sy: number, sz: number): CFrame
	local p = rel.Position
	return CFrame.new(p.X * sx, p.Y * sy, p.Z * sz) * (rel - p)
end

-- Weld (not WeldConstraint) so grow/shrink can rescale C0 with the stem.
local function weldChildToStem(stem: BasePart, child: BasePart, relCf: CFrame)
	child.Anchored = false
	child.Massless = true
	child.CanTouch = false
	local existing = child:FindFirstChild("OceanTD_StemWeld")
	if existing then
		existing:Destroy()
	end
	local weld = Instance.new("Weld")
	weld.Name = "OceanTD_StemWeld"
	weld.Part0 = stem
	weld.Part1 = child
	weld.C0 = relCf
	weld.C1 = CFrame.new()
	weld.Parent = child
	-- Base (mult=1) offset for cinematic scale.
	child:SetAttribute("OceanTD_FullX", child.Size.X)
	child:SetAttribute("OceanTD_FullY", child.Size.Y)
	child:SetAttribute("OceanTD_FullZ", child.Size.Z)
	child:SetAttribute("OceanTD_RelX", relCf.Position.X)
	child:SetAttribute("OceanTD_RelY", relCf.Position.Y)
	child:SetAttribute("OceanTD_RelZ", relCf.Position.Z)
	local rx, ry, rz = relCf:ToEulerAnglesYXZ()
	child:SetAttribute("OceanTD_RelRX", rx)
	child:SetAttribute("OceanTD_RelRY", ry)
	child:SetAttribute("OceanTD_RelRZ", rz)
end

local function matchSeaFanPartName(name: string, kind: "stem" | "web"): boolean
	local lower = string.lower(name)
	if kind == "web" then
		return lower == "web" or string.find(lower, "web", 1, true) ~= nil
	end
	return lower == "stem" or string.find(lower, "stem", 1, true) ~= nil
end

local function findSeaFanTemplatePart(model: Model, kind: "stem" | "web"): BasePart?
	local preferred = if kind == "stem" then { "Stem", "SeaFanStem" } else { "Web", "SeaFanWeb", "FanWeb" }
	for _, name in ipairs(preferred) do
		local child = model:FindFirstChild(name)
		if child and child:IsA("BasePart") then
			return child
		end
	end
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("BasePart") and matchSeaFanPartName(child.Name, kind) then
			return child
		end
	end
	return nil
end

local function getSeaFanWeb(stem: BasePart): BasePart?
	local web = stem:FindFirstChild("Web")
	if web and web:IsA("BasePart") then
		return web
	end
	for _, child in ipairs(stem:GetChildren()) do
		if child:IsA("BasePart") and matchSeaFanPartName(child.Name, "web") and child ~= stem then
			return child
		end
	end
	return nil
end

local function getAccentPart(stem: BasePart): BasePart?
	if CoralVisual.isMainAccentMesh(stem:GetAttribute("OceanTD_SpeciesId")) then
		local accent = stem:FindFirstChild("Accent")
		if accent and accent:IsA("BasePart") then
			return accent
		end
	end
	return getSeaFanWeb(stem)
end

local function readWebRestColor(stem: BasePart): Color3?
	local r = stem:GetAttribute("OceanTD_WebRestR")
	local g = stem:GetAttribute("OceanTD_WebRestG")
	local b = stem:GetAttribute("OceanTD_WebRestB")
	if typeof(r) == "number" and typeof(g) == "number" and typeof(b) == "number" then
		return Color3.new(r, g, b)
	end
	local web = getAccentPart(stem)
	if web then
		return web.Color
	end
	return nil
end

function CoralVisual.randomizeAccentPaint(stem: BasePart, stemColorIndex: number): (Color3, number?)
	if CoralVisual.isMainAccentMesh(stem:GetAttribute("OceanTD_SpeciesId")) then
		return PlotOutlineColors.randomBrightAccent(), nil
	end
	return CoralVisual.randomizeWebInHue(stem, stemColorIndex)
end

function CoralVisual.readWebColorIndex(stem: BasePart): number?
	local idx = stem:GetAttribute("OceanTD_WebColorIndex")
	if typeof(idx) == "number" then
		return PlotOutlineColors.clampCoralIndex(idx)
	end
	return nil
end

function CoralVisual.pickDifferentWebColorIndex(stemColorIndex: number, preferKeep: number?): number
	-- Web stays in the stem's palette family (same hue swatch).
	return PlotOutlineColors.clampCoralIndex(preferKeep or stemColorIndex)
end

function CoralVisual.pickDifferentWebPaint(stemColorIndex: number, _preferKeepIndex: number?): (Color3, number)
	local webIdx = PlotOutlineColors.clampCoralIndex(stemColorIndex)
	return PlotOutlineColors.randomHueVariant(webIdx), webIdx
end

-- Independent shade of the same hue family as the stem swatch.
function CoralVisual.randomizeWebInHue(_stem: BasePart, stemColorIndex: number): (Color3, number)
	local webIdx = PlotOutlineColors.clampCoralIndex(stemColorIndex)
	return PlotOutlineColors.randomHueVariant(webIdx), webIdx
end

function CoralVisual.setWebRestColor(stem: BasePart, color: Color3, webColorIndex: number?)
	stem:SetAttribute("OceanTD_WebRestR", color.R)
	stem:SetAttribute("OceanTD_WebRestG", color.G)
	stem:SetAttribute("OceanTD_WebRestB", color.B)
	if typeof(webColorIndex) == "number" then
		stem:SetAttribute("OceanTD_WebColorIndex", PlotOutlineColors.clampCoralIndex(webColorIndex))
	end
	local web = getAccentPart(stem)
	if not web then
		return
	end
	if stem:GetAttribute("OceanTD_CrabStunned") == true then
		return
	end
	-- Authored FBX textures are often warm oranges; clear so Part.Color is the hue source.
	if web:IsA("MeshPart") then
		pcall(function()
			(web :: MeshPart).TextureID = ""
		end)
	end
	if web.Material ~= Enum.Material.ForceField then
		web.Color = color
	end
end

-- Forward-declare so applySeaFanScaleMult can call it.
local alignMeshToSurface: (BasePart, Vector3, number?, CFrame?) -> ()

-- Scale Stem + welded Web/Food together (cinematic grow/shrink).
function CoralVisual.applySeaFanScaleMult(stem: BasePart, stemFullSize: Vector3, mult: number, surfacePos: Vector3?)
	local m = math.max(mult, 0.01)
	stem.Size = stemFullSize * m
	for _, ch in ipairs(stem:GetChildren()) do
		if ch:IsA("BasePart") then
			local fx = ch:GetAttribute("OceanTD_FullX")
			local fy = ch:GetAttribute("OceanTD_FullY")
			local fz = ch:GetAttribute("OceanTD_FullZ")
			if typeof(fx) == "number" and typeof(fy) == "number" and typeof(fz) == "number" then
				ch.Size = Vector3.new(fx, fy, fz) * m
			end
			local rx = ch:GetAttribute("OceanTD_RelX")
			local ry = ch:GetAttribute("OceanTD_RelY")
			local rz = ch:GetAttribute("OceanTD_RelZ")
			local rrx = ch:GetAttribute("OceanTD_RelRX")
			local rry = ch:GetAttribute("OceanTD_RelRY")
			local rrz = ch:GetAttribute("OceanTD_RelRZ")
			local weld = ch:FindFirstChild("OceanTD_StemWeld")
			if weld and weld:IsA("Weld") and typeof(rx) == "number" and typeof(ry) == "number" and typeof(rz) == "number" then
				local rot = CFrame.Angles(
					if typeof(rrx) == "number" then rrx else 0,
					if typeof(rry) == "number" then rry else 0,
					if typeof(rrz) == "number" then rrz else 0
				)
				weld.C0 = CFrame.new(rx * m, ry * m, rz * m) * rot
			end
		end
	end
	if surfacePos then
		alignMeshToSurface(stem, surfacePos)
	end
end

function CoralVisual.clearSeaFanClientHide(stem: BasePart)
	stem.LocalTransparencyModifier = 0
	for _, ch in ipairs(stem:GetChildren()) do
		if ch:IsA("BasePart") then
			ch.LocalTransparencyModifier = 0
		end
	end
end

-- Plant Size-box bottom on surfacePos (world). One PivotTo — no additive CFrame math.
-- facingYaw is plot-local (relative to plotCFrame's Y). Same save works on any plot slot.
-- rotationOverride: keep exact world rotation (SeaFan upgrade — no yaw spin).
alignMeshToSurface = function(part: BasePart, surfacePos: Vector3, facingYaw: number?, rotationOverride: CFrame?, plotCFrame: CFrame?)
	pcall(function()
		(part :: any).PivotOffset = CFrame.new()
	end)
	local embed = meshEmbedDepth(part)
	local target = Vector3.new(surfacePos.X, surfacePos.Y - embed + part.Size.Y * 0.5, surfacePos.Z)
	if rotationOverride then
		part:PivotTo(CFrame.new(target) * (rotationOverride - rotationOverride.Position))
		-- Keep stamped plot-local yaw; do not re-derive from LookVector.
		if typeof(part:GetAttribute("OceanTD_FacingYaw")) ~= "number" then
			part:SetAttribute("OceanTD_FacingYaw", facingYaw or 0)
		end
	else
		local yaw = facingYaw
		local needsYaw = CoralVisual.needsFacingYaw(part:GetAttribute("OceanTD_SpeciesId"))
		if typeof(yaw) ~= "number" or yaw ~= yaw then
			yaw = if needsYaw then CoralVisual.readFacingYaw(part) else nil
		end
		if typeof(yaw) == "number" and yaw == yaw then
			local yawCf = CFrame.Angles(0, yaw, 0)
			if plotCFrame then
				yawCf = (plotCFrame - plotCFrame.Position) * yawCf
			end
			part:PivotTo(CFrame.new(target) * yawCf)
			part:SetAttribute("OceanTD_FacingYaw", yaw)
		else
			part:PivotTo(CFrame.new(target))
		end
	end
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
		applyPartFlags(part, false, false, def.speciesId)
		part:SetAttribute("OceanTD_GhostBaseR", color.R)
		part:SetAttribute("OceanTD_GhostBaseG", color.G)
		part:SetAttribute("OceanTD_GhostBaseB", color.B)
	else
		part.Color = color
		local restT = part:GetAttribute("OceanTD_RestTransparency")
		if typeof(restT) == "number" then
			part.Transparency = restT
		elseif not def.meshFolder then
		part.Transparency = 0
		end
		-- else keep template/mesh transparency
		-- Mesh imports keep Studio/FBX material; ball species use catalog material.
		if not def.meshFolder then
		part.Material = def.material
		end
		applyPartFlags(part, def.castShadow, def.canCollide, def.speciesId)
		part:SetAttribute("OceanTD_RestR", color.R)
		part:SetAttribute("OceanTD_RestG", color.G)
		part:SetAttribute("OceanTD_RestB", color.B)
		part:SetAttribute("OceanTD_RestMaterial", part.Material.Name)
	end
	part:SetAttribute("OceanTD_SpeciesId", def.speciesId)
	part:SetAttribute("OceanTD_ItemId", def.itemId)
end

local function finishSeaFanLook(stem: BasePart, web: BasePart?, def: any, opts: VisualOptions, stemColor: Color3, webColor: Color3)
	finishLook(stem, def, opts, stemColor)
	if not web then
		return
	end
	local ghost = opts.ghost == true
	if ghost then
		local valid = opts.valid ~= false
		web.Color = if valid then webColor else Color3.fromRGB(220, 70, 70)
		web.Transparency = 0.45
		web.Material = Enum.Material.ForceField
		web.CanCollide = false
		web.CanQuery = false
		web.CastShadow = false
		stem:SetAttribute("OceanTD_GhostWebR", webColor.R)
		stem:SetAttribute("OceanTD_GhostWebG", webColor.G)
		stem:SetAttribute("OceanTD_GhostWebB", webColor.B)
	else
		web.Color = webColor
		if web:IsA("MeshPart") then
			pcall(function()
				(web :: MeshPart).TextureID = ""
			end)
		end
		local webT = stem:GetAttribute("OceanTD_WebRestTransparency")
		if typeof(webT) == "number" then
			web.Transparency = webT
		end
		web.CanCollide = def.canCollide
		web.CanQuery = true
		web.CastShadow = def.castShadow
		stem:SetAttribute("OceanTD_WebRestR", webColor.R)
		stem:SetAttribute("OceanTD_WebRestG", webColor.G)
		stem:SetAttribute("OceanTD_WebRestB", webColor.B)
	end
end

local function assembleSeaFanFromTemplate(
	templateModel: Model,
	sizeClass: number,
	scaleMult: number,
	scaleWidth: number,
	scaleHeight: number
): (MeshPart?, BasePart?)
	local tStem = findSeaFanTemplatePart(templateModel, "stem")
	if not tStem or not tStem:IsA("MeshPart") then
		-- Last resort: first MeshPart that is not the web.
		for _, child in ipairs(templateModel:GetChildren()) do
			if child:IsA("MeshPart") and not matchSeaFanPartName(child.Name, "web") then
				tStem = child
				break
			end
		end
	end
	if not tStem or not tStem:IsA("MeshPart") then
		return nil, nil
	end
	local tWeb = findSeaFanTemplatePart(templateModel, "web")
	if tWeb == tStem then
		tWeb = nil
	end

	local sx = scaleMult * scaleWidth
	local sy = scaleMult * scaleHeight
	local sz = scaleMult * scaleWidth

	local stem = tStem:Clone()
	stem.Name = "SeaFan"
	-- Drop Studio welds / scripts; keep mesh only — children re-added below.
	local stemTransparency = tStem.Transparency
	stem:ClearAllChildren()
	pcall(function()
		stem.PivotOffset = CFrame.new()
	end)
	stem.Size = Vector3.new(tStem.Size.X * sx, tStem.Size.Y * sy, tStem.Size.Z * sz)
	stem.CFrame = CFrame.new()
	stem.Transparency = stemTransparency
	stem:SetAttribute("OceanTD_RestTransparency", stemTransparency)

	local web: BasePart? = nil
	if tWeb and tWeb:IsA("BasePart") then
		local webTransparency = tWeb.Transparency
		web = tWeb:Clone()
		web.Name = "Web"
		web:ClearAllChildren()
		if web:IsA("MeshPart") then
			pcall(function()
				(web :: MeshPart).TextureID = ""
			end)
		end
		web.Size = Vector3.new(tWeb.Size.X * sx, tWeb.Size.Y * sy, tWeb.Size.Z * sz)
		web.Transparency = webTransparency
		stem:SetAttribute("OceanTD_WebRestTransparency", webTransparency)
		local rel = scaleCFrameTranslation(tStem.CFrame:ToObjectSpace(tWeb.CFrame), sx, sy, sz)
		web.CFrame = stem.CFrame * rel
		web.Parent = stem
		weldChildToStem(stem, web, rel)
	end

	-- Food markers (ammo anchors): Food1..N on each size model (model root or under Stem).
	-- Large layout is only a fallback if this size's markers are missing.
	local function findFoodMarker(host: Instance, index: number): BasePart?
		local name = "Food" .. tostring(index)
		local direct = host:FindFirstChild(name)
		if direct and direct:IsA("BasePart") then
			return direct
		end
		local deep = host:FindFirstChild(name, true)
		if deep and deep:IsA("BasePart") then
			return deep
		end
		return nil
	end

	local function attachFoodFrom(srcHost: Instance, stemRef: BasePart, count: number)
		for i = 1, count do
			local src = findFoodMarker(srcHost, i)
			if src then
				local food = src:Clone()
				food.Name = "Food" .. tostring(i)
				food:ClearAllChildren()
				food.Transparency = 1
				food.CanCollide = false
				food.CanQuery = false
				food.CanTouch = false
				food.CastShadow = false
				food.Size = Vector3.new(
					math.max(src.Size.X * sx, 0.2),
					math.max(src.Size.Y * sy, 0.2),
					math.max(src.Size.Z * sz, 0.2)
				)
				local rel = scaleCFrameTranslation(stemRef.CFrame:ToObjectSpace(src.CFrame), sx, sy, sz)
				food.CFrame = stem.CFrame * rel
				food.Parent = stem
				weldChildToStem(stem, food, rel)
			end
		end
	end

	local wantFood = if sizeClass >= 3 then 4 elseif sizeClass == 2 then 3 else 1
	local hadFood = false
	for i = 1, wantFood do
		if findFoodMarker(templateModel, i) then
			hadFood = true
			break
		end
	end
	if hadFood then
		attachFoodFrom(templateModel, tStem, wantFood)
	else
		local large = findSeaFanModel(3, 1)
		local largeStem = large and findSeaFanTemplatePart(large, "stem")
		if large and largeStem and largeStem:IsA("BasePart") then
			attachFoodFrom(large, largeStem, wantFood)
		end
	end

	return stem, web
end

local function createSeaFan(def: any, worldPos: Vector3, opts: VisualOptions): BasePart?
	local sizeClass = CoralSize.clampTier(opts.sizeClass or 1)
	local variantIndex = CoralVisual.clampMeshVariant(opts.variantIndex, "SeaFan")
	local scaleMult = CoralVisual.sanitizeSeaFanAxis(opts.scaleMult)
	local scaleWidth = CoralVisual.sanitizeSeaFanAxis(opts.scaleWidth)
	local scaleHeight = CoralVisual.sanitizeSeaFanAxis(opts.scaleHeight)
	local template = findSeaFanModel(sizeClass, variantIndex)
	if not template then
		warn("[CoralVisual] Missing SeaFan model", SIZE_PREFIX[sizeClass], variantIndex)
		return nil
	end

	local stem, web = assembleSeaFanFromTemplate(template, sizeClass, scaleMult, scaleWidth, scaleHeight)
	if not stem then
		return nil
	end

	local facingYaw = opts.facingYaw
	if typeof(facingYaw) ~= "number" or facingYaw ~= facingYaw then
		facingYaw = 0
	end

	-- Default: keep imported Stem/Web colors (like SeaGrass). Paint only when opts.color set.
	local stemColor = opts.color
	local webColor = opts.webColor
	if not stemColor then
		stemColor = stem.Color
	end
	if not webColor then
		webColor = if web then web.Color else stemColor
	end
	-- Stamp SpeciesId before plant so yaw path is unambiguous; then plant with plot-local facingYaw.
	finishSeaFanLook(stem, web, def, opts, stemColor, webColor)
	alignMeshToSurface(stem, worldPos, facingYaw, nil, opts.plotCFrame)

	stem:SetAttribute("OceanTD_Diameter", stem.Size.Y)
	stem:SetAttribute("OceanTD_SizeClass", sizeClass)
	stem:SetAttribute("OceanTD_SizeTier", sizeClass)
	stem:SetAttribute("OceanTD_VariantIndex", variantIndex)
	stem:SetAttribute("OceanTD_ScaleMult", scaleMult)
	stem:SetAttribute("OceanTD_ScaleWidth", scaleWidth)
	stem:SetAttribute("OceanTD_ScaleHeight", scaleHeight)
	stem:SetAttribute("OceanTD_FacingYaw", facingYaw)
	return stem
end

local function findFoodMarker(host: Instance, index: number): BasePart?
	local name = "Food" .. tostring(index)
	local direct = host:FindFirstChild(name)
	if direct and direct:IsA("BasePart") then
		return direct
	end
	local deep = host:FindFirstChild(name, true)
	if deep and deep:IsA("BasePart") then
		return deep
	end
	return nil
end

local function attachFoodFromTemplate(
	templateModel: Model,
	stem: BasePart,
	tMain: BasePart,
	sx: number,
	sy: number,
	sz: number,
	sizeClass: number
)
	local function attachFrom(srcHost: Instance, stemRef: BasePart, count: number)
		for i = 1, count do
			local src = findFoodMarker(srcHost, i)
			if src then
				local food = src:Clone()
				food.Name = "Food" .. tostring(i)
				food:ClearAllChildren()
				food.Transparency = 1
				food.CanCollide = false
				food.CanQuery = false
				food.CanTouch = false
				food.CastShadow = false
				food.Size = Vector3.new(
					math.max(src.Size.X * sx, 0.2),
					math.max(src.Size.Y * sy, 0.2),
					math.max(src.Size.Z * sz, 0.2)
				)
				local rel = scaleCFrameTranslation(stemRef.CFrame:ToObjectSpace(src.CFrame), sx, sy, sz)
				food.CFrame = stem.CFrame * rel
				food.Parent = stem
				weldChildToStem(stem, food, rel)
			end
		end
	end

	local wantFood = if sizeClass >= 3 then 4 elseif sizeClass == 2 then 3 else 1
	local hadFood = false
	for i = 1, wantFood do
		if findFoodMarker(templateModel, i) then
			hadFood = true
			break
		end
	end
	if hadFood then
		attachFrom(templateModel, tMain, wantFood)
	end
end

local function isWalkColliderPart(part: BasePart): boolean
	return string.lower(part.Name) == "collider"
end

local function collectTemplateWalkColliders(model: Model): { BasePart }
	local out: { BasePart } = {}
	for _, ch in ipairs(model:GetDescendants()) do
		if ch:IsA("BasePart") and isWalkColliderPart(ch) then
			table.insert(out, ch)
		end
	end
	return out
end

-- Hidden template Collider parts → welded walk volumes (Tree Coral large uses simplified stand geometry).
local function attachWalkCollidersFromTemplate(
	templateModel: Model,
	stem: BasePart,
	tMain: BasePart,
	sx: number,
	sy: number,
	sz: number
): number
	local count = 0
	for _, src in ipairs(collectTemplateWalkColliders(templateModel)) do
		local col = src:Clone()
		col.Name = "Collider"
		col:ClearAllChildren()
		col.Size = Vector3.new(
			math.max(src.Size.X * sx, 0.05),
			math.max(src.Size.Y * sy, 0.05),
			math.max(src.Size.Z * sz, 0.05)
		)
		local rel = scaleCFrameTranslation(tMain.CFrame:ToObjectSpace(src.CFrame), sx, sy, sz)
		col.CFrame = stem.CFrame * rel
		col.Parent = stem
		weldChildToStem(stem, col, rel)
		count += 1
	end
	return count
end

local function applyWalkColliderFlags(part: BasePart)
	part.Massless = true
	part.Anchored = false
	part.CanCollide = true
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	local density = 0.7
	local friction = 0.5
	local frictionWeight = 1
	pcall(function()
		local props = part.CurrentPhysicalProperties
		density = props.Density
		friction = props.Friction
		frictionWeight = props.FrictionWeight
	end)
	part.CustomPhysicalProperties = PhysicalProperties.new(density, friction, 0, frictionWeight, 100)
end

local function applyTreeCoralWalkCollision(stem: BasePart, accent: BasePart?, ghost: boolean)
	if stem:GetAttribute("OceanTD_WalkColliders") ~= true then
		return
	end
	if ghost then
		stem.CanCollide = false
		if accent then
			accent.CanCollide = false
		end
		for _, ch in ipairs(stem:GetChildren()) do
			if ch:IsA("BasePart") and isWalkColliderPart(ch) then
				ch.CanCollide = false
				ch.Transparency = 1
			end
		end
		return
	end
	stem.CanCollide = false
	stem.CanQuery = true
	if accent then
		accent.CanCollide = false
		accent.CanQuery = true
	end
	for _, ch in ipairs(stem:GetChildren()) do
		if ch:IsA("BasePart") and isWalkColliderPart(ch) then
			applyWalkColliderFlags(ch)
		end
	end
end

local function assembleMainAccentFromTemplate(
	speciesId: string,
	templateModel: Model,
	scaleMult: number,
	sizeClass: number
): (MeshPart?, BasePart?)
	local cfg = MAIN_ACCENT_MESH[speciesId]
	if not cfg then
		return nil, nil
	end
	local tMain = findMainAccentTemplatePart(templateModel, "main")
	local tAccent = findMainAccentTemplatePart(templateModel, "accent")
	if not tMain or not tMain:IsA("MeshPart") then
		return nil, nil
	end
	if not tAccent or not tAccent:IsA("BasePart") then
		tAccent = nil
	end

	local s = mainAccentEffectiveScale(speciesId, scaleMult, sizeClass)

	local stem = tMain:Clone()
	stem.Name = cfg.stemName
	stem:ClearAllChildren()
	pcall(function()
		stem.PivotOffset = CFrame.new()
	end)
	stem.Size = tMain.Size * s
	stem.CFrame = CFrame.new()
	stem.Transparency = tMain.Transparency
	stem:SetAttribute("OceanTD_RestTransparency", tMain.Transparency)

	local accent: BasePart? = nil
	if tAccent and tAccent:IsA("BasePart") then
		local accentTransparency = tAccent.Transparency
		accent = tAccent:Clone()
		accent.Name = "Accent"
		accent:ClearAllChildren()
		if accent:IsA("MeshPart") then
			pcall(function()
				(accent :: MeshPart).TextureID = ""
			end)
		end
		accent.Size = tAccent.Size * s
		accent.Transparency = accentTransparency
		stem:SetAttribute("OceanTD_WebRestTransparency", accentTransparency)
		local rel = tMain.CFrame:ToObjectSpace(tAccent.CFrame)
		rel = scaleCFrameTranslation(rel, s, s, s)
		accent.CFrame = stem.CFrame * rel
		accent.Parent = stem
		weldChildToStem(stem, accent, rel)
	end

	if cfg.attachFood then
		attachFoodFromTemplate(templateModel, stem, tMain, s, s, s, sizeClass)
	end

	if cfg.attachWalkColliders then
		local n = attachWalkCollidersFromTemplate(templateModel, stem, tMain, s, s, s)
		if n > 0 then
			stem:SetAttribute("OceanTD_WalkColliders", true)
		else
			stem:SetAttribute("OceanTD_WalkColliders", nil)
		end
	end

	return stem, accent
end

local function assembleZoasFromTemplate(templateModel: Model, scaleMult: number): (MeshPart?, BasePart?)
	return assembleMainAccentFromTemplate("Zoas", templateModel, scaleMult, 1)
end

local function assembleTreeCoralFromTemplate(templateModel: Model, scaleMult: number, sizeClass: number): (MeshPart?, BasePart?)
	return assembleMainAccentFromTemplate("TreeCoral", templateModel, scaleMult, sizeClass)
end

local function createMainAccentMesh(
	speciesId: string,
	def: any,
	worldPos: Vector3,
	opts: VisualOptions,
	useFacingYaw: boolean
): BasePart?
	local sizeClass = CoralSize.clampTier(opts.sizeClass or 1)
	local variantIndex = CoralVisual.clampMeshVariant(opts.variantIndex, speciesId)
	local scaleMult = CoralVisual.sanitizeMeshScale(opts.scaleMult, speciesId)
	local template = findMainAccentModel(speciesId, sizeClass)
	if not template then
		warn("[CoralVisual] Missing", speciesId, "model", SIZE_PREFIX[sizeClass])
		return nil
	end

	local facingYaw: number? = nil
	if useFacingYaw then
		facingYaw = opts.facingYaw
		if typeof(facingYaw) ~= "number" or facingYaw ~= facingYaw then
			facingYaw = CoralVisual.randomFacingYaw()
		end
	end

	local tMain = findMainAccentTemplatePart(template, "main")
	local tAccent = findMainAccentTemplatePart(template, "accent")
	local stem, accent = assembleMainAccentFromTemplate(speciesId, template, scaleMult, sizeClass)
	if not stem then
		return nil
	end

	local stemColor = opts.color or (if tMain then tMain.Color else Color3.new(1, 1, 1))
	local accentColor = opts.webColor or (if tAccent and tAccent:IsA("BasePart") then tAccent.Color else stemColor)
	finishSeaFanLook(stem, accent, def, opts, stemColor, accentColor)
	applyTreeCoralWalkCollision(stem, accent, opts.ghost == true)
	alignMeshToSurface(stem, worldPos, facingYaw, nil, opts.plotCFrame)

	stem:SetAttribute("OceanTD_Diameter", stem.Size.Y)
	stem:SetAttribute("OceanTD_SizeClass", sizeClass)
	stem:SetAttribute("OceanTD_SizeTier", sizeClass)
	stem:SetAttribute("OceanTD_VariantIndex", variantIndex)
	stem:SetAttribute("OceanTD_ScaleMult", scaleMult)
	if typeof(facingYaw) == "number" then
		stem:SetAttribute("OceanTD_FacingYaw", facingYaw)
	end
	return stem
end

local function createZoas(def: any, worldPos: Vector3, opts: VisualOptions): BasePart?
	return createMainAccentMesh("Zoas", def, worldPos, opts, true)
end

local function createTreeCoral(def: any, worldPos: Vector3, opts: VisualOptions): BasePart?
	return createMainAccentMesh("TreeCoral", def, worldPos, opts, false)
end

local function createLeatherCoral(def: any, worldPos: Vector3, opts: VisualOptions): BasePart?
	return createMainAccentMesh("LeatherCoral", def, worldPos, opts, true)
end

local function createMeshSpecies(def: any, worldPos: Vector3, opts: VisualOptions): BasePart?
	if def.speciesId == "SeaFan" then
		return createSeaFan(def, worldPos, opts)
	end
	if def.speciesId == "Zoas" then
		return createZoas(def, worldPos, opts)
	end
	if def.speciesId == "TreeCoral" then
		return createTreeCoral(def, worldPos, opts)
	end
	if def.speciesId == "LeatherCoral" then
		return createLeatherCoral(def, worldPos, opts)
	end
	local folderName = def.meshFolder
	if typeof(folderName) ~= "string" or folderName == "" then
		return nil
	end
	local sizeClass = CoralSize.clampTier(opts.sizeClass or 1)
	local variantIndex = CoralVisual.clampMeshVariant(opts.variantIndex, def.speciesId)
	local scaleMult = CoralVisual.sanitizeMeshScale(opts.scaleMult, def.speciesId)
	local template = findMeshTemplate(folderName, sizeClass, variantIndex)
	if not template then
		warn("[CoralVisual] Missing mesh", folderName, SIZE_PREFIX[sizeClass], variantIndex)
		return nil
	end
	local baseScale = if def.speciesId == "SeaGrass" then SEA_GRASS_BASE_SCALE else 1
	local part = prepareMeshClone(template, def.speciesId, template.Size * scaleMult * baseScale)
	-- Stamp SpeciesId before plant so yaw path is unambiguous.
	part:SetAttribute("OceanTD_SpeciesId", def.speciesId)
	local facingYaw: number? = nil
	if CoralVisual.needsFacingYaw(def.speciesId) then
		facingYaw = opts.facingYaw
		if typeof(facingYaw) ~= "number" or facingYaw ~= facingYaw then
			facingYaw = CoralVisual.randomFacingYaw()
		end
	end
	alignMeshToSurface(part, worldPos, facingYaw, nil, opts.plotCFrame)

	-- SeaGrass / FireCoral: keep imported mesh Color as starting color unless paint/ghost overrides.
	local color = opts.color
	if not color then
		if def.speciesId == "SeaGrass" or def.speciesId == "FireCoral" or def.speciesId == "Zoas" or def.speciesId == "TreeCoral" or def.speciesId == "LeatherCoral" then
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
	if typeof(facingYaw) == "number" then
		part:SetAttribute("OceanTD_FacingYaw", facingYaw)
	end
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
-- SeaGrass / SeaFan: fresh Clone + plant like create() — ApplyMesh kept Medium/Large pivots and slid the visual.
function CoralVisual.restyleSponge(
	part: BasePart,
	sizeClass: number,
	variantIndex: number?,
	scaleMult: number?,
	surfacePosOpt: Vector3?,
	scaleWidthOpt: number?,
	scaleHeightOpt: number?
): (BasePart?, number?, number?, number?)
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	local def = if typeof(speciesId) == "string" then SpeciesCatalog.get(speciesId) else nil
	local folderName = if def and typeof(def.meshFolder) == "string" then def.meshFolder else "Sponge"
	local class = CoralSize.clampTier(sizeClass)
	local variant = CoralVisual.clampMeshVariant(variantIndex, if typeof(speciesId) == "string" then speciesId else nil)
	local scale = if speciesId == "SeaFan"
		then CoralVisual.sanitizeSeaFanAxis(scaleMult)
		else CoralVisual.sanitizeMeshScale(scaleMult, if typeof(speciesId) == "string" then speciesId else nil)
	local surfacePos = surfacePosOpt or CoralVisual.readGridAnchor(part) or meshSurfacePos(part)
	local _, color = CoralVisual.readRestLook(part)

	-- SeaFan: rebuild Stem+Web model (preserves yaw + dual colors).
	if speciesId == "SeaFan" then
		local scaleWidth = CoralVisual.sanitizeSeaFanAxis(scaleWidthOpt or part:GetAttribute("OceanTD_ScaleWidth"))
		local scaleHeight = CoralVisual.sanitizeSeaFanAxis(scaleHeightOpt or part:GetAttribute("OceanTD_ScaleHeight"))
		-- New independent axis rolls on each size change when caller passes fresh randoms.
		if scaleWidthOpt == nil then
			scaleWidth = CoralVisual.randomSeaFanAxis()
		end
		if scaleHeightOpt == nil then
			scaleHeight = CoralVisual.randomSeaFanAxis()
		end
		-- Keep exact planted rotation — do not rebuild yaw (avoids spin on upgrade).
		local keepRotation = part.CFrame
		local webColor = readWebRestColor(part) or color
		local parent = part.Parent
		local keep: { [string]: any } = {}
		for name, value in part:GetAttributes() do
			keep[name] = value
		end
		part:Destroy()

		local template = findSeaFanModel(class, variant)
		if not template then
			warn("[CoralVisual] Missing SeaFan for restyle", SIZE_PREFIX[class], variant)
			return nil
		end
		local newStem, newWeb = assembleSeaFanFromTemplate(template, class, scale, scaleWidth, scaleHeight)
		if not newStem then
			return nil
		end
		for name, value in keep do
			newStem:SetAttribute(name, value)
		end
		newStem:SetAttribute("OceanTD_Diameter", newStem.Size.Y)
		newStem:SetAttribute("OceanTD_SizeClass", class)
		newStem:SetAttribute("OceanTD_VariantIndex", variant)
		newStem:SetAttribute("OceanTD_ScaleMult", scale)
		newStem:SetAttribute("OceanTD_ScaleWidth", scaleWidth)
		newStem:SetAttribute("OceanTD_ScaleHeight", scaleHeight)
		newStem:SetAttribute("OceanTD_CineShrunk", nil)
		newStem:SetAttribute("OceanTD_CineFullX", nil)
		newStem:SetAttribute("OceanTD_CineFullY", nil)
		newStem:SetAttribute("OceanTD_CineFullZ", nil)
		newStem:SetAttribute("OceanTD_CinePrep", nil)
		finishSeaFanLook(newStem, newWeb, def or { speciesId = "SeaFan", itemId = "SeaFan", castShadow = false, canCollide = true }, { ghost = false }, color, webColor)
		alignMeshToSurface(newStem, surfacePos, nil, keepRotation)
		newStem.Parent = parent
		return newStem, newStem.Size.Y, variant, scale
	end

	-- Main + Accent mesh corals (Zoas, Tree Coral): rebuild Main+Accent (preserves rotation + dual colors).
	if CoralVisual.isMainAccentMesh(speciesId) then
		local keepRotation = part.CFrame
		local accentColor = readWebRestColor(part) or color
		local parent = part.Parent
		local keep: { [string]: any } = {}
		for name, value in part:GetAttributes() do
			keep[name] = value
		end
		part:Destroy()

		local template = findMainAccentModel(speciesId, class)
		if not template then
			warn("[CoralVisual] Missing", speciesId, "for restyle", SIZE_PREFIX[class])
			return nil
		end
		local newStem, newAccent = assembleMainAccentFromTemplate(speciesId, template, scale, class)
		if not newStem then
			return nil
		end
		for name, value in keep do
			newStem:SetAttribute(name, value)
		end
		newStem:SetAttribute("OceanTD_Diameter", newStem.Size.Y)
		newStem:SetAttribute("OceanTD_SizeClass", class)
		newStem:SetAttribute("OceanTD_VariantIndex", variant)
		newStem:SetAttribute("OceanTD_ScaleMult", scale)
		newStem:SetAttribute("OceanTD_CineShrunk", nil)
		newStem:SetAttribute("OceanTD_CineFullX", nil)
		newStem:SetAttribute("OceanTD_CineFullY", nil)
		newStem:SetAttribute("OceanTD_CineFullZ", nil)
		newStem:SetAttribute("OceanTD_CinePrep", nil)
		local itemId = if def and typeof(def.itemId) == "string" then def.itemId else speciesId
		finishSeaFanLook(
			newStem,
			newAccent,
			def or { speciesId = speciesId, itemId = itemId, castShadow = false, canCollide = true },
			{ ghost = false },
			color,
			accentColor
		)
		applyTreeCoralWalkCollision(newStem, newAccent, false)
		alignMeshToSurface(newStem, surfacePos, nil, keepRotation)
		newStem.Parent = parent
		return newStem, newStem.Size.Y, variant, scale
	end

	local template = findMeshTemplate(folderName, class, variant)
	if not template then
		warn("[CoralVisual] Missing mesh for restyle", folderName, SIZE_PREFIX[class], variant)
		return nil
	end

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
		applyPartFlags(target, castShadow, canCollide, if typeof(speciesId) == "string" then speciesId else nil)
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
	local keepYaw: number? = nil
	if CoralVisual.needsFacingYaw(speciesId) then
		keepYaw = CoralVisual.readFacingYaw(part)
	end
	alignMeshToSurface(part, surfacePos, keepYaw)
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
	if speciesId == "SeaGrass" then
		-- Mesh stays non-collidable; climb truss is the only collider.
		syncSeaGrassClimb(part)
	end
	if part:GetAttribute("OceanTD_CrabStunned") == true then
		part.Color = Color3.new(1, 1, 1)
		local web = getAccentPart(part)
		if web then
			web.Color = Color3.new(1, 1, 1)
		end
		return
	end
	part.Color = color
	if CoralVisual.isDualColorMesh(speciesId) then
		local web = getAccentPart(part)
		local webColor = readWebRestColor(part)
		if web and webColor then
			web.Color = webColor
			if def then
				web.CanCollide = def.canCollide
			end
		end
	end
end

function CoralVisual.setRestColor(part: BasePart, color: Color3, webColor: Color3?, webColorIndex: number?)
	part:SetAttribute("OceanTD_RestR", color.R)
	part:SetAttribute("OceanTD_RestG", color.G)
	part:SetAttribute("OceanTD_RestB", color.B)
	if part:GetAttribute("OceanTD_CrabStunned") == true then
		return
	end
	if part:IsA("MeshPart") then
		pcall(function()
			(part :: MeshPart).TextureID = ""
		end)
	end
	part.Color = color
	local speciesId = part:GetAttribute("OceanTD_SpeciesId")
	if CoralVisual.isDualColorMesh(speciesId) then
		local paintWeb = webColor
		local webIdx = webColorIndex
		if not paintWeb then
			local idx = part:GetAttribute("OceanTD_ColorIndex")
			if typeof(idx) == "number" then
				paintWeb, webIdx = CoralVisual.randomizeAccentPaint(part, idx)
			else
				paintWeb = readWebRestColor(part) or color
			end
		end
		CoralVisual.setWebRestColor(part, paintWeb, webIdx)
	end
end

function CoralVisual.alignSpongeToSurface(part: BasePart, surfacePos: Vector3, facingYaw: number?, rotationOverride: CFrame?, plotCFrame: CFrame?)
	alignMeshToSurface(part, surfacePos, facingYaw, rotationOverride, plotCFrame)
end

CoralVisual.alignMeshToSurface = CoralVisual.alignSpongeToSurface

-- Ghost validity flash: paint Stem + Web together for SeaFan.
function CoralVisual.setGhostValidColors(part: BasePart, valid: boolean, baseColor: Color3?, invalidColor: Color3)
	local stemColor = baseColor or part.Color
	if valid then
		part.Color = stemColor
	else
		part.Color = invalidColor
	end
	if not CoralVisual.isDualColorMesh(part:GetAttribute("OceanTD_SpeciesId")) then
		return
	end
	local web = getAccentPart(part)
	if not web then
		return
	end
	if valid then
		local wr = part:GetAttribute("OceanTD_GhostWebR")
		local wg = part:GetAttribute("OceanTD_GhostWebG")
		local wb = part:GetAttribute("OceanTD_GhostWebB")
		if typeof(wr) == "number" and typeof(wg) == "number" and typeof(wb) == "number" then
			web.Color = Color3.new(wr, wg, wb)
		else
			web.Color = stemColor
		end
	else
		web.Color = invalidColor
	end
end

return CoralVisual
