--!strict
--[[
	Soft-plant Confirm helpers for PlacementController.
	Extracted so PlacementController stays under Luau's 200-local limit.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local Remotes = require(oceanRoot:WaitForChild("Remotes"))
local CoralVisual = require(oceanRoot:WaitForChild("Shared"):WaitForChild("CoralVisual"))

local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlotCam2 = require(script.Parent:WaitForChild("PlotCam2"))
local PlotCam2Tune = require(script.Parent:WaitForChild("PlotCam2Tune"))

local PlaceSoftPlant = {}

-- PlotCam: stash pre-place view, lean in on the coral, restore on PLANT / cancel.
function PlaceSoftPlant.beginCamZoom(worldPos: Vector3?, sizeClass: number?)
	PlotCam2.beginPlaceZoom(worldPos, sizeClass)
	-- Right-side Plot Cam 2 tune (± rows + paste readout) while close-up is up.
	PlotCam2Tune.setPlaceZoomDebug(true)
	PlotCam2Tune.refresh()
end

function PlaceSoftPlant.retargetCamZoom(worldPos: Vector3?, sizeClass: number?)
	if not PlotCam2.isPlaceZoomActive() then
		PlaceSoftPlant.beginCamZoom(worldPos, sizeClass)
		return
	end
	PlotCam2.retargetPlaceZoom(worldPos, sizeClass)
	PlotCam2Tune.refresh()
end

function PlaceSoftPlant.updateCamZoom(worldPos: Vector3?)
	if PlotCam2.isPlaceZoomActive() then
		PlotCam2.updatePlaceZoom(worldPos)
	end
end

function PlaceSoftPlant.endCamZoom()
	PlotCam2.endPlaceZoom()
	PlotCam2Tune.setPlaceZoomDebug(false)
end

--[[
	Close-up drag: pull-distance velocity (not scaled raycasts).
	Holding farther from the press point keeps a slow crawl in that direction —
	no release/re-grab, and screen-edge terrain rays can't fling the coral.
]]
local ZOOM_DRAG_DEADZONE_PX = 16
local ZOOM_DRAG_FULL_PULL_PX = 110 -- reach max crawl speed
local ZOOM_DRAG_MIN_SPEED = 1.6 -- studs/sec just outside deadzone
local ZOOM_DRAG_MAX_SPEED = 12 -- studs/sec at full pull (precision, not sprint)
local ZOOM_DRAG_HEIGHT_REFRESH_SEC = 0.5 -- re-sample terrain Y so slopes don't bury the plant
local placeZoomDragPos: Vector3? = nil
local placeZoomDragScreen0: Vector2? = nil
local placeZoomDragScreen: Vector2? = nil
local placeZoomDragConn: RBXScriptConnection? = nil
local placeZoomDragApply: ((Vector3) -> ())? = nil
local placeZoomDragHeightAge = 0
local zoomDragHeightParams: RaycastParams? = nil

local function screenPullToWorldFlat(pull: Vector2): Vector3
	local cam = Workspace.CurrentCamera
	if not cam then
		return Vector3.new(pull.X, 0, pull.Y)
	end
	local right = cam.CFrame.RightVector
	local look = cam.CFrame.LookVector
	local flatRight = Vector3.new(right.X, 0, right.Z)
	local flatFwd = Vector3.new(look.X, 0, look.Z)
	if flatRight.Magnitude < 1e-3 then
		flatRight = Vector3.new(1, 0, 0)
	else
		flatRight = flatRight.Unit
	end
	if flatFwd.Magnitude < 1e-3 then
		flatFwd = Vector3.new(0, 0, -1)
	else
		flatFwd = flatFwd.Unit
	end
	-- Screen Y grows downward; negate so dragging up moves toward cam look.
	return flatRight * pull.X + flatFwd * (-pull.Y)
end

local function stopZoomDragConn()
	if placeZoomDragConn then
		placeZoomDragConn:Disconnect()
		placeZoomDragConn = nil
	end
end

local function sampleGroundY(at: Vector3): number?
	if not zoomDragHeightParams then
		zoomDragHeightParams = RaycastParams.new()
		zoomDragHeightParams.FilterType = Enum.RaycastFilterType.Exclude
	end
	local exclude: { Instance } = {}
	-- Skip all planted meshes (includes the coral being dragged).
	local placed = Workspace:FindFirstChild("OceanTD_Placed")
	if placed then
		table.insert(exclude, placed)
	end
	local char = Players.LocalPlayer.Character
	if char then
		table.insert(exclude, char)
	end
	zoomDragHeightParams.FilterDescendantsInstances = exclude
	local hit = Workspace:Raycast(Vector3.new(at.X, at.Y + 80, at.Z), Vector3.new(0, -200, 0), zoomDragHeightParams)
	if hit then
		return hit.Position.Y
	end
	local plot = ClientPlot.get()
	if plot then
		return plot.cframe.Position.Y - plot.size.Y * 0.5
	end
	return nil
end

local function refreshZoomDragHeight(pos: Vector3): Vector3
	local gy = sampleGroundY(pos)
	if typeof(gy) ~= "number" then
		return pos
	end
	return Vector3.new(pos.X, gy, pos.Z)
end

local function stepZoomDrag(dt: number)
	if not PlotCam2.isPlaceZoomActive() then
		PlaceSoftPlant.endZoomDrag()
		return
	end
	local pos = placeZoomDragPos
	local s0 = placeZoomDragScreen0
	local s1 = placeZoomDragScreen
	local apply = placeZoomDragApply
	if not pos or not s0 or not s1 or not apply then
		return
	end
	placeZoomDragHeightAge += dt
	local heightDue = placeZoomDragHeightAge >= ZOOM_DRAG_HEIGHT_REFRESH_SEC
	if heightDue then
		placeZoomDragHeightAge = 0
		pos = refreshZoomDragHeight(pos)
		placeZoomDragPos = pos
	end

	local pull = s1 - s0
	local mag = pull.Magnitude
	local over = mag - ZOOM_DRAG_DEADZONE_PX
	if over <= 0 then
		if heightDue then
			apply(pos)
		end
		return
	end
	-- Cap pull so "finger at screen edge" doesn't explode speed.
	local t = math.clamp(over / ZOOM_DRAG_FULL_PULL_PX, 0, 1)
	-- Ease-in: small pulls stay very slow; long holds ramp up.
	local eased = t * t
	local speed = ZOOM_DRAG_MIN_SPEED + (ZOOM_DRAG_MAX_SPEED - ZOOM_DRAG_MIN_SPEED) * eased
	local dir = screenPullToWorldFlat(pull)
	if dir.Magnitude < 1e-3 then
		if heightDue then
			apply(pos)
		end
		return
	end
	local nextPos = pos + dir.Unit * (speed * math.clamp(dt, 0, 0.05))
	-- Keep last sampled ground Y between refreshes (XZ crawl only).
	nextPos = Vector3.new(nextPos.X, pos.Y, nextPos.Z)
	placeZoomDragPos = nextPos
	apply(nextPos)
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
	placeZoomDragPos = refreshZoomDragHeight(originWorld)
	placeZoomDragScreen0 = screenPos
	placeZoomDragScreen = screenPos
	placeZoomDragApply = apply
	placeZoomDragHeightAge = 0
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
	placeZoomDragScreen0 = nil
	placeZoomDragScreen = nil
	placeZoomDragApply = nil
	placeZoomDragHeightAge = 0
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
	if not part or not part.Parent or not plantedId then
		return
	end
	anchorPos = e.resolvePlaceAnchor(anchorPos)
	e.setPlaceAnchor(anchorPos)
	e.setConfirmPos(anchorPos)
	PlaceSoftPlant.updateCamZoom(anchorPos)
	local RelocateController = require(script.Parent:WaitForChild("RelocateController"))
	if RelocateController.isPlaceConfirmBridge() then
		local ok, reason = RelocateController.bridgePreviewAt(anchorPos)
		e.setValidSpot(ok)
		e.setRejectReason(reason)
	else
		local ok, reason = e.evaluatePos(anchorPos)
		e.setValidSpot(ok)
		e.setRejectReason(reason)
		local yaw = e.getGhostPlaceFacingYaw()
		if typeof(yaw) ~= "number" then
			yaw = CoralVisual.readFacingYaw(part)
		end
		if CoralVisual.needsFacingYaw(part:GetAttribute("OceanTD_SpeciesId")) and typeof(yaw) == "number" then
			local mir = ClientPlot.get()
			CoralVisual.alignMeshToSurface(part, anchorPos, yaw, nil, if mir then mir.cframe else nil)
		elseif CoralVisual.isMeshSpecies(part:GetAttribute("OceanTD_SpeciesId")) then
			CoralVisual.alignMeshToSurface(part, anchorPos)
		else
			part.CFrame = CFrame.new(anchorPos)
		end
	end
	local chromeAdorneePart = e.getChromeAdorneePart()
	if chromeAdorneePart and chromeAdorneePart.Parent then
		local p = chromeAdorneePart.Position
		chromeAdorneePart.CFrame = CFrame.new(anchorPos.X, p.Y, anchorPos.Z)
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

function PlaceSoftPlant.finishConfirm()
	local e = env
	if not e then
		return
	end
	local part = e.getConfirmPlantedPart()
	local id = e.getConfirmPlantedId()
	local toPos = e.getPlaceAnchor()
	if part and part.Parent then
		toPos = e.getPlaceAnchor() or CoralVisual.readGridAnchor(part) or part.Position
	end
	local fromPos = e.getSoftPlantOriginPos() or toPos
	local yaw = e.getGhostPlaceFacingYaw()
	if part and part.Parent and typeof(id) == "string" and id ~= "" and typeof(toPos) == "Vector3" then
		if typeof(yaw) ~= "number" then
			yaw = CoralVisual.readFacingYaw(part)
		end
		pcall(function()
			Remotes.getFunction("RequestMove"):InvokeServer(id, fromPos, toPos, yaw, nil)
		end)
	end
	-- Restore pre-place PlotCam before exit tears down confirm.
	PlaceSoftPlant.endCamZoom()
	PlaceSoftPlant.clearState(false)
	e.setSuppressAimParkOnce(true)
	e.forceExit()
end

return PlaceSoftPlant
