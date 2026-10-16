--!strict
--[[
	IntroPosition is authored once under Workspace.Plots.IntroElements (Plot1 space).
	Server places an invisible marker Part per plot under:
	  Workspace.Plots.OceanTD_IntroPadMarkers.<PlotId>
	(same remap as JoinIntro / ClientPlot.remapCFrameFromPlot1).

	Plot2..N are RingMath poses — there is often no Workspace.Plots.PlotN folder,
	so markers must NOT be parented under those missing folders.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local IntroPad = {}

IntroPad.ON_PAD_ATTR = "OceanTD_OnIntroPad"
IntroPad.PAD_POS_ATTR = "OceanTD_IntroPadPos" -- Vector3, remapped for that player
IntroPad.MARKERS_FOLDER = "OceanTD_IntroPadMarkers"
IntroPad.AUTHORED_MARKER_NAME = "_OceanTD_IntroPadAuthored"

local RADIUS = 18
local Y_BELOW = 24
local Y_ABOVE = 48

local FALLBACK_SIBLINGS = { "CamStartFocus", "CamEndFocus", "CamStart", "CamEnd" }

-- Match JoinIntro.worldCFrameOf so pad pose == intro stand pose.
local function worldCFrameOf(inst: Instance): CFrame?
	if inst:IsA("BasePart") then
		return inst.CFrame
	end
	if inst:IsA("Model") then
		return (inst :: Model):GetPivot()
	end
	if inst:IsA("Attachment") then
		return (inst :: Attachment).WorldCFrame
	end
	local part = inst:FindFirstChildWhichIsA("BasePart", true)
	if part then
		return part.CFrame
	end
	local att = inst:FindFirstChildWhichIsA("Attachment", true)
	if att then
		return att.WorldCFrame
	end
	return nil
end

local function findNamed(root: Instance, name: string): Instance?
	local direct = root:FindFirstChild(name)
	if direct then
		return direct
	end
	return root:FindFirstChild(name, true)
end

function IntroPad.findAuthoredHost(): Instance?
	local plots = Workspace:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	local folder = plots:FindFirstChild("IntroElements") or plots:FindFirstChild("Intro")
	if not folder then
		return nil
	end
	return findNamed(folder, "IntroPosition")
end

local function fallbackCFrameNear(host: Instance): CFrame?
	local folder = host.Parent
	if not folder then
		return nil
	end
	for _, name in ipairs(FALLBACK_SIBLINGS) do
		local sib = findNamed(folder, name)
		if sib then
			local cf = worldCFrameOf(sib)
			if cf then
				return cf
			end
		end
	end
	local sum = Vector3.zero
	local n = 0
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("BasePart") then
			sum += d.Position
			n += 1
		end
	end
	if n > 0 then
		return CFrame.new(sum / n)
	end
	return nil
end

function IntroPad.getAuthoredCFrame(): CFrame?
	local host = IntroPad.findAuthoredHost()
	if not host then
		return nil
	end
	if host:IsA("BasePart") then
		return host.CFrame
	end
	local synthetic = host:FindFirstChild(IntroPad.AUTHORED_MARKER_NAME)
	-- Prefer real authored geometry over a stale empty-folder fallback marker.
	for _, d in ipairs(host:GetDescendants()) do
		if d:IsA("BasePart") and d ~= synthetic then
			return d.CFrame
		end
	end
	if host:IsA("Model") then
		return (host :: Model):GetPivot()
	end
	if synthetic and synthetic:IsA("BasePart") then
		return synthetic.CFrame
	end
	local att = host:FindFirstChildWhichIsA("Attachment", true)
	if att then
		return att.WorldCFrame
	end
	return fallbackCFrameNear(host)
end

function IntroPad.remapFromPlot1(authoredCf: CFrame, plot1Cf: CFrame, targetRingCf: CFrame): CFrame
	return targetRingCf * plot1Cf:ToObjectSpace(authoredCf)
end

function IntroPad.getMarkersFolder(): Folder?
	local plots = Workspace:FindFirstChild("Plots")
	local parent: Instance = if plots then plots else Workspace
	local existing = parent:FindFirstChild(IntroPad.MARKERS_FOLDER)
	if existing and existing:IsA("Folder") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	if not RunService:IsServer() then
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = IntroPad.MARKERS_FOLDER
	folder.Parent = parent
	return folder
end

local function styleMarker(marker: BasePart, cf: CFrame)
	marker.CFrame = cf
	marker.Size = Vector3.new(4, 1, 4)
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.CastShadow = false
	marker.Transparency = 1
	marker.Color = Color3.fromRGB(50, 230, 110)
	marker.Material = Enum.Material.SmoothPlastic
	marker.TopSurface = Enum.SurfaceType.Smooth
	marker.BottomSurface = Enum.SurfaceType.Smooth
end

local function makeMarker(name: string, cf: CFrame, parent: Instance): BasePart
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("BasePart") then
		styleMarker(existing, cf)
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local marker = Instance.new("Part")
	marker.Name = name
	styleMarker(marker, cf)
	marker.Parent = parent
	return marker
end

-- Server: authored IntroPosition → one marker Part named Plot1..PlotN under OceanTD_IntroPadMarkers.
function IntroPad.syncPlotMarkers(plot1Cf: CFrame, slots: { { plotId: string, ringCFrame: CFrame } }): number
	if not RunService:IsServer() then
		return 0
	end
	local host = IntroPad.findAuthoredHost()
	if not host then
		warn("[IntroPad] Workspace.Plots.IntroElements.IntroPosition missing (server)")
		return 0
	end

	local authoredCf = IntroPad.getAuthoredCFrame()
	if not authoredCf then
		local fb = fallbackCFrameNear(host)
		if not fb then
			warn("[IntroPad] IntroPosition empty and no sibling poses to place authored marker")
			return 0
		end
		authoredCf = fb
		warn("[IntroPad] IntroPosition empty — using sibling fallback pose", fb.Position)
	end

	if not host:IsA("BasePart") then
		makeMarker(IntroPad.AUTHORED_MARKER_NAME, authoredCf, host)
		authoredCf = IntroPad.getAuthoredCFrame() or authoredCf
	end

	local markersFolder = IntroPad.getMarkersFolder()
	if not markersFolder then
		warn("[IntroPad] Could not create markers folder")
		return 0
	end

	if #slots == 0 then
		warn("[IntroPad] syncPlotMarkers called with 0 slots")
		return 0
	end

	local n = 0
	local sample: string? = nil
	for _, slot in ipairs(slots) do
		local padCf = IntroPad.remapFromPlot1(authoredCf, plot1Cf, slot.ringCFrame)
		makeMarker(slot.plotId, padCf, markersFolder)
		n += 1
		if not sample then
			sample = string.format(
				"%s@%s",
				slot.plotId,
				tostring(padCf.Position)
			)
		end
	end
	print(
		"[IntroPad] Synced",
		n,
		"per-plot markers → Plots." .. IntroPad.MARKERS_FOLDER,
		"authored=",
		authoredCf.Position,
		"plot1=",
		plot1Cf.Position,
		"eg",
		sample
	)
	return n
end

function IntroPad.getPlotMarker(plotId: string): BasePart?
	local plots = Workspace:FindFirstChild("Plots")
	local markers = (plots and plots:FindFirstChild(IntroPad.MARKERS_FOLDER))
		or Workspace:FindFirstChild(IntroPad.MARKERS_FOLDER)
	if not markers then
		return nil
	end
	local marker = markers:FindFirstChild(plotId)
	if marker and marker:IsA("BasePart") then
		return marker
	end
	return nil
end

function IntroPad.getPadWorldPositionsForPlayer(player: Player): { Vector3 }
	local out: { Vector3 } = {}
	local seen: { [string]: boolean } = {}

	local function add(pos: Vector3)
		local key = string.format("%.1f_%.1f_%.1f", pos.X, pos.Y, pos.Z)
		if seen[key] then
			return
		end
		seen[key] = true
		table.insert(out, pos)
	end

	-- Remapped per-plot marker / attr only. Do NOT use raw Studio IntroPosition —
	-- that is Plot1-authored world space and is wrong for Plot2..N (and can sit on spawn).
	local plotId = player:GetAttribute("OceanTD_PlotId")
	if typeof(plotId) == "string" then
		local marker = IntroPad.getPlotMarker(plotId)
		if marker then
			add(marker.Position)
		end
	end
	local attr = player:GetAttribute(IntroPad.PAD_POS_ATTR)
	if typeof(attr) == "Vector3" then
		add(attr)
	end
	return out
end

function IntroPad.getPadWorldPosForPlayer(player: Player): Vector3?
	local pads = IntroPad.getPadWorldPositionsForPlayer(player)
	return pads[1]
end

function IntroPad.containsWorldPos(worldPos: Vector3, padPos: Vector3): boolean
	local delta = worldPos - padPos
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude > RADIUS then
		return false
	end
	return delta.Y >= -Y_BELOW and delta.Y <= Y_ABOVE
end

function IntroPad.isPlayerOnPad(player: Player): boolean
	local char = player.Character
	if not char then
		return false
	end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return false
	end
	local pads = IntroPad.getPadWorldPositionsForPlayer(player)
	for _, padPos in ipairs(pads) do
		if IntroPad.containsWorldPos(hrp.Position, padPos) then
			return true
		end
	end
	return false
end

function IntroPad.debugStatus(player: Player?): string
	if not player then
		local authored = IntroPad.getAuthoredCFrame()
		return if authored then string.format("authored@%s", tostring(authored.Position)) else "no-authored"
	end
	local pads = IntroPad.getPadWorldPositionsForPlayer(player)
	if #pads == 0 then
		local plotId = player:GetAttribute("OceanTD_PlotId")
		return string.format("no-pad-pos plotId=%s", tostring(plotId))
	end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not (hrp and hrp:IsA("BasePart")) then
		return "no-hrp"
	end
	local bestFlat = math.huge
	local bestY = 0
	local bestPad = pads[1]
	for _, padPos in ipairs(pads) do
		local delta = hrp.Position - padPos
		local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude
		if flat < bestFlat then
			bestFlat = flat
			bestY = delta.Y
			bestPad = padPos
		end
	end
	local on = IntroPad.isPlayerOnPad(player)
	return string.format(
		"on=%s flat=%.1f y=%.1f nearestPad=%s pads=%d plot=%s",
		tostring(on),
		bestFlat,
		bestY,
		tostring(bestPad),
		#pads,
		tostring(player:GetAttribute("OceanTD_PlotId"))
	)
end

return IntroPad
