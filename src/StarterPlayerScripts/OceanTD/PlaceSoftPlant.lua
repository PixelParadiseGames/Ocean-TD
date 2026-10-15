--!strict
--[[
	Soft-plant Confirm helpers for PlacementController.
	Extracted so PlacementController stays under Luau's 200-local limit.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local BrainStack = require(oceanRoot:WaitForChild("Shared"):WaitForChild("BrainStack"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlaceAimScreen = require(script.Parent:WaitForChild("PlaceAimScreen"))
local PlotCam2 = require(script.Parent:WaitForChild("PlotCam2"))
local PlotCam2Tune = require(script.Parent:WaitForChild("PlotCam2Tune"))
local PlantWorkerVfx = require(script.Parent:WaitForChild("PlantWorkerVfx"))

local PlaceSoftPlant = {}

-- Lazy: RelocateController → PlacementController → PlaceSoftPlant (cycle if top-level).
local function relocateController()
	return require(script.Parent:WaitForChild("RelocateController"))
end

-- World-space height of the planted / ghost coral (AABB). Prefer Model bounds when present.
function PlaceSoftPlant.measureCoralHeight(part: BasePart?): number?
	if not part or not part.Parent then
		return nil
	end
	local model = part:FindFirstAncestorOfClass("Model")
	if model then
		local ok, _cf, size = pcall(function()
			return model:GetBoundingBox()
		end)
		if ok and typeof(size) == "Vector3" and (size :: Vector3).Y > 0.5 then
			return (size :: Vector3).Y
		end
	end
	local top = part.Position.Y + part.Size.Y * 0.5
	local bot = part.Position.Y - part.Size.Y * 0.5
	for _, d in ipairs(part:GetDescendants()) do
		if d:IsA("BasePart") then
			local p = d :: BasePart
			top = math.max(top, p.Position.Y + p.Size.Y * 0.5)
			bot = math.min(bot, p.Position.Y - p.Size.Y * 0.5)
		end
	end
	return math.max(top - bot, part.Size.Y)
end

-- PlotCam place-focus (lean-in on coral) — disabled in build mode.
local PLACE_ZOOM_ENABLED = false

-- PlotCam: stash pre-place view, lean in on the coral, restore on PLANT / cancel.
-- heightStuds: mesh/ball height so S/M/L pullback matches real size (short vs tall species).
function PlaceSoftPlant.beginCamZoom(worldPos: Vector3?, sizeClass: number?, heightStuds: number?, speciesId: string?)
	if not PLACE_ZOOM_ENABLED then
		return
	end
	-- Studio / avatar-cam place: PlotCam2 may be inactive — start it and ask FreeCam
	-- to drive plotcam so the close-up tween actually runs (mobile is usually already on plotcam).
	if not PlotCam2.isActive() then
		PlotCam2.begin(nil)
	end
	local pg = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if pg then
		pg:SetAttribute("OceanTD_EnsurePlotCam", os.clock())
	end
	PlotCam2.beginPlaceZoom(worldPos, sizeClass, heightStuds, speciesId)
	-- Tune ± debug panel off during place (was on for baking seats).
	PlotCam2Tune.setPlaceZoomDebug(false)
end

function PlaceSoftPlant.retargetCamZoom(worldPos: Vector3?, sizeClass: number?, heightStuds: number?, speciesId: string?)
	if not PLACE_ZOOM_ENABLED then
		return
	end
	if not PlotCam2.isPlaceZoomActive() then
		PlaceSoftPlant.beginCamZoom(worldPos, sizeClass, heightStuds, speciesId)
		return
	end
	PlotCam2.retargetPlaceZoom(worldPos, sizeClass, heightStuds, speciesId)
end

function PlaceSoftPlant.updateCamZoom(worldPos: Vector3?)
	if not PLACE_ZOOM_ENABLED then
		return
	end
	if PlotCam2.isPlaceZoomActive() then
		PlotCam2.updatePlaceZoom(worldPos)
	end
end

function PlaceSoftPlant.endCamZoom()
	if PlotCam2.isPlaceZoomActive() then
		PlotCam2.endPlaceZoom()
	end
	PlotCam2Tune.setPlaceZoomDebug(false)
end

--[[
	Drag B (place-zoom soft-plant + relocate pick): coral follows cursor / finger ray.
	(Old Drag A virtual-stick crawl removed — it ran past the pointer off-screen.)
]]
local placeZoomDragPos: Vector3? = nil
local placeZoomDragScreen: Vector2? = nil -- current pointer (viewport)
local placeZoomDragConn: RBXScriptConnection? = nil
local placeZoomDragApply: ((Vector3) -> ())? = nil
local zoomDragRayParams: RaycastParams? = nil

local function stopZoomDragConn()
	if placeZoomDragConn then
		placeZoomDragConn:Disconnect()
		placeZoomDragConn = nil
	end
end

local function zoomDragAimScreen(screenPos: Vector2): Vector2
	-- Touch: raise so the plant sits above the thumb. Mouse: exact cursor.
	return PlaceAimScreen.raiseIfTouch(screenPos, true, false)
end

local function raycastZoomDrag(screenPos: Vector2): Vector3?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local aim = zoomDragAimScreen(screenPos)
	local ray = cam:ViewportPointToRay(aim.X, aim.Y)
	if not zoomDragRayParams then
		zoomDragRayParams = RaycastParams.new()
		zoomDragRayParams.FilterType = Enum.RaycastFilterType.Exclude
	end
	local exclude: { Instance } = {}
	local placed = Workspace:FindFirstChild("OceanTD_Placed")
	if placed then
		table.insert(exclude, placed)
	end
	local char = Players.LocalPlayer.Character
	if char then
		table.insert(exclude, char)
	end
	zoomDragRayParams.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 800, zoomDragRayParams)
	if hit then
		return hit.Position
	end
	local plot = ClientPlot.get()
	if plot and math.abs(ray.Direction.Y) > 1e-4 then
		local floorY = plot.cframe.Position.Y - plot.size.Y * 0.5
		local t = (floorY - ray.Origin.Y) / ray.Direction.Y
		if t == t and t > 0 then
			return ray.Origin + ray.Direction * t
		end
	end
	return nil
end

local function stepZoomDrag()
	if not PlotCam2.isPlaceZoomActive() then
		PlaceSoftPlant.endZoomDrag()
		return
	end
	local screen = placeZoomDragScreen
	local apply = placeZoomDragApply
	if not screen or not apply then
		return
	end
	-- Prefer live pointer so mouse can move without InputChanged gaps.
	local live = UserInputService:GetMouseLocation()
	if typeof(live) == "Vector2" then
		screen = live
		placeZoomDragScreen = live
	end
	local hit = raycastZoomDrag(screen)
	if not hit then
		return
	end
	placeZoomDragPos = hit
	apply(hit)
end

function PlaceSoftPlant.isZoomDragActive(): boolean
	return placeZoomDragPos ~= nil and PlotCam2.isPlaceZoomActive()
end

function PlaceSoftPlant.beginZoomDrag(originWorld: Vector3?, screenPos: Vector2?, apply: ((Vector3) -> ())?)
	PlaceSoftPlant.endZoomDrag()
	if not PlotCam2.isPlaceZoomActive() then
		return
	end
	if typeof(originWorld) ~= "Vector3" or typeof(screenPos) ~= "Vector2" then
		return
	end
	placeZoomDragScreen = screenPos
	placeZoomDragApply = apply
	local hit = raycastZoomDrag(screenPos) or originWorld
	placeZoomDragPos = hit
	apply(hit)
	stopZoomDragConn()
	placeZoomDragConn = RunService.Heartbeat:Connect(stepZoomDrag)
end

function PlaceSoftPlant.noteZoomDragScreen(screenPos: Vector2)
	if placeZoomDragPos and typeof(screenPos) == "Vector2" then
		placeZoomDragScreen = screenPos
	end
end

function PlaceSoftPlant.endZoomDrag()
	stopZoomDragConn()
	placeZoomDragPos = nil
	placeZoomDragScreen = nil
	placeZoomDragApply = nil
end

-- Legacy no-op kept so older call sites don't error mid-hot-reload.
function PlaceSoftPlant.scaleZoomDragWorld(rawWorld: Vector3): Vector3
	return rawWorld
end

local OUT_OF_PLOT_NUDGE_WAIT = 1
local OUT_OF_PLOT_NUDGE_HOLD = 1
local OUT_OF_PLOT_NUDGE_TWEEN = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)
local OUT_OF_PLOT_NUDGE_COOLDOWN = 4
local plotNudgeActive = false
local plotNudgeToken = 0
local outOfPlotSince: number? = nil
local plotNudgeCooldownUntil = 0

export type Env = {
	getConfirmPlantedPart: () -> BasePart?,
	getConfirmPlantedId: () -> string?,
	setConfirmPlantedPart: (BasePart?) -> (),
	setConfirmPlantedId: (string?) -> (),
	getSoftPlantOriginPos: () -> Vector3?,
	setSoftPlantOriginPos: (Vector3?) -> (),
	getPlaceAnchor: () -> Vector3?,
	setPlaceAnchor: (Vector3?) -> (),
	getConfirmPos: () -> Vector3?,
	setConfirmPos: (Vector3?) -> (),
	getValidSpot: () -> boolean,
	setValidSpot: (boolean) -> (),
	getRejectReason: () -> string?,
	setRejectReason: (string?) -> (),
	getGhostPlaceFacingYaw: () -> number?,
	getChromeAdorneePart: () -> BasePart?,
	getWarnLabel: () -> TextLabel?,
	getConfirmPowerupOpen: () -> boolean,
	setConfirmPowerupOpen: (boolean) -> (),
	bumpConfirmPlantToken: () -> (),
	resolvePlaceAnchor: (Vector3) -> Vector3,
	evaluatePos: (Vector3) -> (boolean, string?),
	getCamera: () -> Camera?,
	getSavedCameraCFrame: () -> CFrame?,
	log: (...any) -> (),
	setSuppressAimParkOnce: (boolean) -> (),
	forceExit: () -> (),
}

local env: Env? = nil

function PlaceSoftPlant.bind(e: Env)
	env = e
end

function PlaceSoftPlant.isPlotNudgeActive(): boolean
	return plotNudgeActive
end

function PlaceSoftPlant.resetOutOfPlotNudge()
	plotNudgeActive = false
	plotNudgeToken += 1
	outOfPlotSince = nil
	plotNudgeCooldownUntil = 0
end

local function startOutOfPlotCamNudge()
	local e = env
	if not e or plotNudgeActive then
		return
	end
	local camera = e.getCamera()
	local savedCameraCFrame = e.getSavedCameraCFrame()
	if not camera or not savedCameraCFrame then
		return
	end
	local plot = ClientPlot.get()
	if not plot then
		return
	end
	local from = savedCameraCFrame
	local focus = plot.cframe.Position
	if (focus - from.Position).Magnitude < 0.5 then
		return
	end
	local to = CFrame.lookAt(from.Position, focus)
	plotNudgeActive = true
	plotNudgeToken += 1
	local my = plotNudgeToken
	local twIn = TweenService:Create(camera, OUT_OF_PLOT_NUDGE_TWEEN, { CFrame = to })
	twIn:Play()
	task.spawn(function()
		twIn.Completed:Wait()
		if my ~= plotNudgeToken then
			return
		end
		task.wait(OUT_OF_PLOT_NUDGE_HOLD)
		if my ~= plotNudgeToken then
			return
		end
		local twOut = TweenService:Create(camera, OUT_OF_PLOT_NUDGE_TWEEN, { CFrame = from })
		twOut:Play()
		twOut.Completed:Wait()
		if my ~= plotNudgeToken then
			return
		end
		plotNudgeActive = false
		plotNudgeCooldownUntil = os.clock() + OUT_OF_PLOT_NUDGE_COOLDOWN
		outOfPlotSince = nil
	end)
end

function PlaceSoftPlant.noteOutOfPlotAim(isOut: boolean)
	if not isOut then
		outOfPlotSince = nil
		return
	end
	if plotNudgeActive or os.clock() < plotNudgeCooldownUntil then
		return
	end
	if not outOfPlotSince then
		outOfPlotSince = os.clock()
	end
	if (os.clock() - outOfPlotSince) >= OUT_OF_PLOT_NUDGE_WAIT then
		startOutOfPlotCamNudge()
	end
end

function PlaceSoftPlant.updateAt(anchorPos: Vector3)
	local e = env
	if not e then
		return
	end
	local part = e.getConfirmPlantedPart()
	local plantedId = e.getConfirmPlantedId()
	if not plantedId then
		return
	end
	local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
	-- After size-upgrade mesh swap, soft-plant may still hold a destroyed stem.
	if RelocateController.isPlaceConfirmBridge() then
		local live = RelocateController.getSelectedPart()
		if live and live.Parent then
			local liveId = live:GetAttribute("OceanTD_PlaceId")
			if liveId == plantedId and live ~= part then
				e.setConfirmPlantedPart(live)
				part = live
			end
		end
	end
	if not part or not part.Parent then
		return
	end
	-- Bridge path resolves brain snap once inside RelocateController.updateAt.
	-- Pre-resolving here double-snapped / self-hosted and fought alignMeshToSurface.
	local rawPos = anchorPos
	local function alignPartDirect(resolved: Vector3)
		e.setPlaceAnchor(resolved)
		e.setConfirmPos(resolved)
		local ok, reason = e.evaluatePos(resolved)
		e.setValidSpot(ok)
		e.setRejectReason(reason)
		local sid = part:GetAttribute("OceanTD_SpeciesId")
		if BrainStack.isBrainId(sid) then
			-- Ball center = resolved pos (same as relocate); do not plant-foot align.
			local yaw = e.getGhostPlaceFacingYaw()
			if typeof(yaw) ~= "number" then
				yaw = CoralVisual.readFacingYaw(part)
			end
			local yawCf = CFrame.Angles(0, yaw :: number, 0)
			local mir = ClientPlot.get()
			if mir then
				yawCf = (mir.cframe - mir.cframe.Position) * yawCf
			end
			part.CFrame = CFrame.new(resolved) * yawCf
			part:SetAttribute("OceanTD_FacingYaw", yaw)
			part:SetAttribute("OceanTD_GridAnchorX", resolved.X)
			part:SetAttribute("OceanTD_GridAnchorY", resolved.Y)
			part:SetAttribute("OceanTD_GridAnchorZ", resolved.Z)
		elseif CoralVisual.needsFacingYaw(sid) then
			local yaw = e.getGhostPlaceFacingYaw()
			if typeof(yaw) ~= "number" then
				yaw = CoralVisual.readFacingYaw(part)
			end
			local mir = ClientPlot.get()
			CoralVisual.alignMeshToSurface(part, resolved, yaw, nil, if mir then mir.cframe else nil)
		elseif CoralVisual.isMeshSpecies(sid) then
			CoralVisual.alignMeshToSurface(part, resolved)
		else
			part.CFrame = CFrame.new(resolved)
		end
	end
	if RelocateController.isPlaceConfirmBridge() then
		local beforeFoot = CoralVisual.readGridAnchor(part) or part.Position
		local ok, reason = RelocateController.bridgePreviewAt(rawPos)
		-- busy / inactive / cine / pinch no-op: false,nil — move the stem ourselves.
		if ok == false and reason == nil then
			alignPartDirect(e.resolvePlaceAnchor(rawPos))
		else
			local live = RelocateController.getSelectedPart()
			local foot = if live and live.Parent
				then (CoralVisual.readGridAnchor(live) or live.Position)
				else rawPos
			-- Bridge claimed success but didn't move (e.g. updateAt early-out) — force align.
			if typeof(beforeFoot) == "Vector3"
				and typeof(foot) == "Vector3"
				and (foot - beforeFoot).Magnitude < 0.02
				and typeof(rawPos) == "Vector3"
				and (rawPos - beforeFoot).Magnitude > 0.15
			then
				alignPartDirect(e.resolvePlaceAnchor(rawPos))
			else
				e.setPlaceAnchor(foot)
				e.setConfirmPos(foot)
				e.setValidSpot(ok)
				e.setRejectReason(reason)
				anchorPos = foot
			end
		end
	else
		anchorPos = e.resolvePlaceAnchor(rawPos)
		alignPartDirect(anchorPos)
	end
	local chromeAdorneePart = e.getChromeAdorneePart()
	if chromeAdorneePart and chromeAdorneePart.Parent then
		local foot = e.getPlaceAnchor() or anchorPos
		local p = chromeAdorneePart.Position
		chromeAdorneePart.CFrame = CFrame.new(foot.X, p.Y, foot.Z)
	end
	local rejectReason = e.getRejectReason()
	PlaceSoftPlant.noteOutOfPlotAim(rejectReason == "Out Of Plot")
	ClientPlot.setOutOfPlotFlash(rejectReason == "Out Of Plot")
	local warnLabel = e.getWarnLabel()
	if warnLabel then
		if e.getValidSpot() or not rejectReason then
			warnLabel.Text = ""
			warnLabel.Visible = false
		else
			warnLabel.Text = rejectReason
			warnLabel.Visible = true
		end
	end
	-- Bridge preview can no-op (busy / cine hold) and leave Out Of Plot stuck; Placement
	-- evaluate ignores the soft-planted stem so back-in-plot restores PLANT chrome.
	local foot = e.getPlaceAnchor() or anchorPos
	if typeof(foot) == "Vector3" then
		local ok, reason = e.evaluatePos(foot)
		if ok and not e.getValidSpot() then
			e.setValidSpot(true)
			e.setRejectReason(nil)
			if warnLabel then
				warnLabel.Text = ""
				warnLabel.Visible = false
			end
			ClientPlot.setOutOfPlotFlash(false)
			PlaceSoftPlant.noteOutOfPlotAim(false)
		elseif not ok and reason ~= nil and not e.getValidSpot() then
			e.setRejectReason(reason)
		end
	end
end

-- recycleAbandoned=true: RequestRecycle so seeds/hues return (backpack close / Esc / no PLANT).
-- recycleAbandoned=false: keep the coral (player hit PLANT).
function PlaceSoftPlant.clearState(recycleAbandoned: boolean)
	local e = env
	if not e then
		return
	end
	local plantedId = e.getConfirmPlantedId()
	local plantedPart = e.getConfirmPlantedPart()
	local worldPos: Vector3? = e.getPlaceAnchor() or e.getConfirmPos()
	if plantedPart and plantedPart.Parent then
		worldPos = CoralVisual.readGridAnchor(plantedPart) or plantedPart.Position
	end

	e.bumpConfirmPlantToken()
	local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
	if e.getConfirmPowerupOpen() or RelocateController.isPlaceConfirmBridge() then
		pcall(function()
			RelocateController.cancel(true)
		end)
	end
	e.setConfirmPowerupOpen(false)
	e.setConfirmPlantedPart(nil)
	e.setConfirmPlantedId(nil)
	e.setSoftPlantOriginPos(nil)

	if not recycleAbandoned then
		return
	end
	if typeof(plantedId) ~= "string" or plantedId == "" or typeof(worldPos) ~= "Vector3" then
		return
	end
	local ok, result = pcall(function()
		return Remotes.getFunction("RequestRecycle"):InvokeServer(plantedId, worldPos)
	end)
	if ok and typeof(result) == "table" and result.ok == true then
		if typeof(result.inventory) == "table" then
			InventoryState.setSeedCounts(result.inventory)
		end
		e.log("Soft-plant recycled (confirm abandoned)", plantedId)
	else
		warn("[PLACE] Soft-plant recycle failed", plantedId, result)
	end
end

function PlaceSoftPlant.recycleOrphan(placedId: string, worldPos: Vector3)
	local e = env
	local ok, result = pcall(function()
		return Remotes.getFunction("RequestRecycle"):InvokeServer(placedId, worldPos)
	end)
	if ok and typeof(result) == "table" and result.ok == true then
		if typeof(result.inventory) == "table" then
			InventoryState.setSeedCounts(result.inventory)
		end
		if e then
			e.log("Soft-plant recycled (orphan)", placedId)
		end
	else
		warn("[PLACE] Orphan soft-plant recycle failed", placedId, result)
	end
end

local finishConfirmBusy = false

function PlaceSoftPlant.finishConfirm()
	local e = env
	-- Activated + MouseButton1Click both fire commit — guard before any yield.
	if not e or finishConfirmBusy then
		return
	end
	local part = e.getConfirmPlantedPart()
	local id = e.getConfirmPlantedId()
	if typeof(id) ~= "string" or id == "" then
		return
	end
	finishConfirmBusy = true

	local toPos = e.getPlaceAnchor()
	if part and part.Parent then
		toPos = e.getPlaceAnchor() or CoralVisual.readGridAnchor(part) or part.Position
	end
	local fromPos = e.getSoftPlantOriginPos() or toPos
	local yaw = e.getGhostPlaceFacingYaw()
	if part and part.Parent and typeof(yaw) ~= "number" then
		yaw = CoralVisual.readFacingYaw(part)
	end
	-- Capture before clearState / exit wipe confirm refs.
	local workerPart = if part and part.Parent then part else nil
	local Relocate = relocateController()
	-- Close place-bridge Relocate so power chrome isn't glued to a buried coral.
	if Relocate.isPlaceConfirmBridge() then
		Relocate.cancel(true)
	end
	-- Clear planted id NOW so a second PLANT click can't re-enter during RequestMove.
	PlaceSoftPlant.endCamZoom()
	PlaceSoftPlant.clearState(false)
	e.setSuppressAimParkOnce(true)
	e.forceExit()

	local moveCommitted = false
	local function commitMoveAfterRise()
		if moveCommitted then
			return
		end
		moveCommitted = true
		if not workerPart or not workerPart.Parent then
			return
		end
		if typeof(toPos) ~= "Vector3" then
			return
		end
		local moveFrom = if typeof(fromPos) == "Vector3" then fromPos else toPos
		pcall(function()
			Remotes.getFunction("RequestMove"):InvokeServer(id, moveFrom, toPos, yaw, nil)
		end)
	end

	-- Soft-plant ✓ / PLANT: chrome is gone — Lego worker dash+dig (dig cam zooms avatar).
	-- RequestMove AFTER rise: server CFrame write mid-bury snaps the coral back up.
	-- Do not auto-reselect the coral after the rise.
	local startedWorker = false
	if typeof(toPos) == "Vector3" then
		startedWorker = PlantWorkerVfx.playAt(toPos, {
			coralPart = workerPart,
			onDone = function()
				commitMoveAfterRise()
				finishConfirmBusy = false
			end,
		}) == true
	end
	if not startedWorker then
		commitMoveAfterRise()
		finishConfirmBusy = false
	else
		-- If worker is cancelled (no onDone), still commit move + unlock.
		task.spawn(function()
			local t0 = os.clock()
			local gui = Players.LocalPlayer:FindFirstChild("PlayerGui")
			while finishConfirmBusy and os.clock() - t0 < 12 do
				local busy = gui and gui:GetAttribute("OceanTD_PlantWorkerBusy") == true
				if not busy and os.clock() - t0 > 0.35 then
					break
				end
				task.wait(0.1)
			end
			if finishConfirmBusy then
				commitMoveAfterRise()
				finishConfirmBusy = false
			end
		end)
	end
end

return PlaceSoftPlant
