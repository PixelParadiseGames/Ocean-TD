--!strict
--[[
	Placement raycasts + spot validation for PlacementController.
	Extracted so PlacementController stays under Luau's 200-local limit.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local oceanRoot = ReplicatedStorage:WaitForChild("OceanTD")
local SkillStages = require(oceanRoot:WaitForChild("Shared"):WaitForChild("SkillStages"))

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlacedCoralIndex = require(script.Parent:WaitForChild("PlacedCoralIndex"))
local PlaceAimScreen = require(script.Parent:WaitForChild("PlaceAimScreen"))
local SkillPowerUpUI = require(script.Parent:WaitForChild("SkillPowerUpUI"))

local PlaceRaycast = {}

local placeRayParams: RaycastParams? = nil
local aimRayAccum = 0
local lastAimScreen: Vector2? = nil

local AIM_RAYCAST_HZ = 25
local AIM_RAYCAST_DT = 1 / AIM_RAYCAST_HZ
local AIM_MOVE_PX = 1

export type ExcludeRefs = {
	ghost: BasePart?,
	outgoingGhost: BasePart?,
	character: Model?,
}

function PlaceRaycast.findBlockingCoral(worldPos: Vector3): BasePart?
	local plot = ClientPlot.get()
	if not plot then
		return nil
	end
	return PlacedCoralIndex.getAtWorld(plot.plotId, worldPos, plot.cframe, nil)
end

function PlaceRaycast.isSpotTaken(worldPos: Vector3): boolean
	return PlaceRaycast.findBlockingCoral(worldPos) ~= nil
end

function PlaceRaycast.evaluatePos(worldPos: Vector3): (boolean, string?)
	local placeMax = SkillStages.placeMoreMaxAtStage(SkillPowerUpUI.getStage("PlaceMore"))
	if PlacedCoralIndex.countLocal() >= placeMax then
		return false, "Max Placed"
	end
	if not ClientPlot.isInside(worldPos) then
		return false, "Out Of Plot"
	end
	if PlaceRaycast.isSpotTaken(worldPos) then
		return false, "Spot Taken"
	end
	return true, nil
end

local function preparePlaceRayParams(exclude: ExcludeRefs)
	if not placeRayParams then
		placeRayParams = RaycastParams.new()
		placeRayParams.FilterType = Enum.RaycastFilterType.Exclude
	end
	local list: { Instance } = {}
	if exclude.ghost then
		table.insert(list, exclude.ghost)
	end
	if exclude.outgoingGhost then
		table.insert(list, exclude.outgoingGhost)
	end
	local placed = Workspace:FindFirstChild("OceanTD_Placed")
	if placed then
		table.insert(list, placed)
	end
	if exclude.character then
		table.insert(list, exclude.character)
	end
	placeRayParams.FilterDescendantsInstances = list
end

function PlaceRaycast.cast(origin: Vector3, direction: Vector3, exclude: ExcludeRefs): Vector3?
	preparePlaceRayParams(exclude)
	local hit = Workspace:Raycast(origin, direction.Unit * 800, placeRayParams)
	if hit then
		return hit.Position
	end
	local plot = ClientPlot.get()
	if plot then
		local plotOrigin = plot.cframe.Position
		local t = (plotOrigin.Y - origin.Y) / direction.Y
		if t == t and t > 0 then
			return origin + direction.Unit * t
		end
	end
	return nil
end

function PlaceRaycast.pointer(screenPos: Vector2, exclude: ExcludeRefs): Vector3?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end
	local ray = cam:ScreenPointToRay(screenPos.X, screenPos.Y)
	return PlaceRaycast.cast(ray.Origin, ray.Direction, exclude)
end

export type ParkOpts = {
	screenPos: Vector2?,
	aimRaiseForTouch: boolean,
	gamepadPlacement: boolean,
	placeAnchor: Vector3?,
	ghostPos: Vector3?,
	exclude: ExcludeRefs,
}

function PlaceRaycast.resolveParkPos(opts: ParkOpts): Vector3?
	local screenPos = opts.screenPos
	if screenPos then
		local raised = PlaceAimScreen.raiseIfTouch(screenPos, opts.aimRaiseForTouch, opts.gamepadPlacement)
		local hit = PlaceRaycast.pointer(raised, opts.exclude)
		if hit then
			return hit
		end
		if raised ~= screenPos then
			hit = PlaceRaycast.pointer(screenPos, opts.exclude)
			if hit then
				return hit
			end
		end
	end
	if opts.placeAnchor then
		return opts.placeAnchor
	end
	return opts.ghostPos
end

export type PlaceAimOpts = {
	gamepadPlacement: boolean,
	aimRaiseForTouch: boolean,
	gamepadCursor: Vector2?,
	aimPinnedToCenter: boolean,
	exclude: ExcludeRefs,
}

function PlaceRaycast.getPlaceAimScreenPos(opts: PlaceAimOpts): Vector2
	return PlaceAimScreen.getPlaceAimPos(opts.gamepadPlacement, opts.gamepadCursor, opts.aimPinnedToCenter, opts.aimRaiseForTouch)
end

function PlaceRaycast.forPlace(opts: PlaceAimOpts): Vector3?
	local player = Players.LocalPlayer
	if not opts.gamepadPlacement and not PlaceAimScreen.isTouchAim(opts.aimRaiseForTouch, opts.gamepadPlacement) then
		local mouse = player:GetMouse()
		local unit = mouse.UnitRay
		return PlaceRaycast.cast(unit.Origin, unit.Direction, opts.exclude)
	end
	return PlaceRaycast.pointer(PlaceRaycast.getPlaceAimScreenPos(opts), opts.exclude)
end

function PlaceRaycast.resetAimThrottle()
	aimRayAccum = 0
	lastAimScreen = nil
end

function PlaceRaycast.aimThrottled(dt: number, opts: PlaceAimOpts, placeAnchor: Vector3?): Vector3?
	local screen = PlaceRaycast.getPlaceAimScreenPos(opts)
	aimRayAccum += dt
	local moved = lastAimScreen == nil or (screen - lastAimScreen).Magnitude >= AIM_MOVE_PX
	if moved or aimRayAccum >= AIM_RAYCAST_DT then
		aimRayAccum = 0
		lastAimScreen = screen
		return PlaceRaycast.forPlace(opts)
	end
	return placeAnchor
end

return PlaceRaycast
