--!strict
--[[
	ADD MAX cinematic: full 360° orbit around plot center when planting >100.
	Owns Scriptable cam while busy (FreeCam yields on OceanTD_AddMaxCamBusy).

	1) Tween into default Plot Cam seat (yaw -180, plot center)
	2) Orbit 360° (start = end = that seat), slow zoom-out mid-spin then back
	3) Tween to the player's original view (or Off if they were on avatar cam)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ClientPlot = require(script.Parent:WaitForChild("ClientPlot"))
local PlotCam2 = require(script.Parent:WaitForChild("PlotCam2"))

local AddMaxOrbitCam = {}

local ATTR_BUSY = "OceanTD_AddMaxCamBusy"
local TWEEN_IN_SEC = 1.35
local TWEEN_OUT_SEC = 1.35
-- Extra studs of pull-back at mid-orbit; returns to start dist as the 360 finishes.
local ORBIT_ZOOM_OUT_STUDS = 110

local startToken = 0
local busy = false
local savedSnap: PlotCam2.ViewSnapshot? = nil
local seatSnap: PlotCam2.ViewSnapshot? = nil -- default plot seat we orbit from/to
local restoreToOff = false
local phase: "in" | "orbit" | "out" | "idle" = "idle"
local phaseT0 = 0
local orbitSpanSec = 8
local outFromYaw = 0
local orbitYaw0 = -180
local stepConn: RBXScriptConnection? = nil

local function playerGui(): PlayerGui?
	local p = Players.LocalPlayer
	local pg = p and p:FindFirstChildOfClass("PlayerGui")
	return if pg and pg:IsA("PlayerGui") then pg else nil
end

local function setBusyAttr(on: boolean)
	busy = on
	local pg = playerGui()
	if pg then
		pg:SetAttribute(ATTR_BUSY, on)
	end
	PlotCam2.setCinematicLock(on)
end

local function smoothstep(t: number): number
	local u = math.clamp(t, 0, 1)
	return u * u * (3 - 2 * u)
end

local function forceCamMode(mode: string)
	local pg = playerGui()
	if not pg then
		return
	end
	pg:SetAttribute("OceanTD_ForceCamMode", mode)
	pg:SetAttribute("OceanTD_ForceCamStamp", os.clock())
end

local function disconnectStep()
	if stepConn then
		stepConn:Disconnect()
		stepConn = nil
	end
end

local function pushCamFromPlotCam2()
	local cf = PlotCam2.getCFrame()
	local cam = Workspace.CurrentCamera
	if cf and cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CameraSubject = nil
		cam.CFrame = cf
	end
end

local function pushPose(yaw: number, dist: number?)
	local cf = PlotCam2.cinematicPose(yaw, dist)
	local cam = Workspace.CurrentCamera
	if cf and cam then
		cam.CameraType = Enum.CameraType.Scriptable
		cam.CameraSubject = nil
		cam.CFrame = cf
	end
end

local function finishClear()
	disconnectStep()
	phase = "idle"
	setBusyAttr(false)
	if restoreToOff then
		restoreToOff = false
		forceCamMode("off")
	end
	savedSnap = nil
	seatSnap = nil
end

local function ensurePlotCam(): boolean
	if PlotCam2.isActive() then
		return true
	end
	local pg = playerGui()
	if not pg or not ClientPlot.get() then
		return false
	end
	forceCamMode("plotcam")
	pg:SetAttribute("OceanTD_EnsurePlotCam", os.clock())
	for _ = 1, 60 do
		if PlotCam2.isActive() then
			return true
		end
		task.wait()
	end
	return PlotCam2.isActive()
end

local function buildDefaultSeat(from: PlotCam2.ViewSnapshot): PlotCam2.ViewSnapshot?
	local plot = ClientPlot.get()
	if not plot then
		return nil
	end
	local gy = plot.cframe.Position.Y - plot.size.Y * 0.5 + from.focusHeight
	return {
		focus = Vector3.new(plot.cframe.Position.X, gy, plot.cframe.Position.Z),
		pitchDeg = from.pitchDeg,
		distOffset = from.distOffset,
		focusHeight = from.focusHeight,
		yawDeg = PlotCam2.getDefaultYawDeg(),
		yawBiasDeg = from.yawBiasDeg,
		liveDist = from.liveDist,
	}
end

local function lerpSnap(from: PlotCam2.ViewSnapshot, to: PlotCam2.ViewSnapshot, u: number)
	PlotCam2.applyViewSnapshot({
		focus = from.focus:Lerp(to.focus, u),
		pitchDeg = from.pitchDeg + (to.pitchDeg - from.pitchDeg) * u,
		distOffset = from.distOffset + (to.distOffset - from.distOffset) * u,
		focusHeight = from.focusHeight + (to.focusHeight - from.focusHeight) * u,
		yawDeg = from.yawDeg + (to.yawDeg - from.yawDeg) * u,
		yawBiasDeg = from.yawBiasDeg + (to.yawBiasDeg - from.yawBiasDeg) * u,
		liveDist = from.liveDist + (to.liveDist - from.liveDist) * u,
	})
	pushCamFromPlotCam2()
end

local function step()
	if not PlotCam2.isActive() then
		return
	end
	local now = os.clock()
	if phase == "in" then
		local from = savedSnap
		local to = seatSnap
		if not from or not to then
			finishClear()
			return
		end
		local u = smoothstep((now - phaseT0) / TWEEN_IN_SEC)
		lerpSnap(from, to, u)
		if now - phaseT0 >= TWEEN_IN_SEC then
			PlotCam2.applyViewSnapshot(to)
			pushCamFromPlotCam2()
			phase = "orbit"
			phaseT0 = now
			orbitYaw0 = to.yawDeg
		end
	elseif phase == "orbit" then
		local seat = seatSnap
		if not seat then
			return
		end
		local u = smoothstep(math.clamp((now - phaseT0) / math.max(orbitSpanSec, 0.05), 0, 1))
		-- Full 360°; start and end at default plot seat yaw.
		local yaw = orbitYaw0 + 360 * u
		-- Zoom out mid-spin, back to seat distance as we complete the circle.
		local dist = seat.liveDist + ORBIT_ZOOM_OUT_STUDS * math.sin(math.pi * u)
		pushPose(yaw, dist)
		if u >= 1 then
			pushPose(orbitYaw0, seat.liveDist)
		end
	elseif phase == "out" then
		local snap = savedSnap
		local seat = seatSnap
		if not snap then
			finishClear()
			return
		end
		-- Blend from default seat (post-360) back to the player's original view.
		local from = seat or {
			focus = PlotCam2.getFocus(),
			pitchDeg = PlotCam2.getTune().pitchDeg,
			distOffset = PlotCam2.getTune().distOffset,
			focusHeight = PlotCam2.getTune().focusHeight,
			yawDeg = outFromYaw,
			yawBiasDeg = PlotCam2.getTune().yawBiasDeg,
			liveDist = PlotCam2.getLiveDist(),
		}
		local u = smoothstep((now - phaseT0) / TWEEN_OUT_SEC)
		lerpSnap(from, snap, u)
		if now - phaseT0 >= TWEEN_OUT_SEC then
			PlotCam2.applyViewSnapshot(snap)
			pushCamFromPlotCam2()
			finishClear()
		end
	end
end

local function connectStep()
	if stepConn then
		return
	end
	stepConn = RunService.RenderStepped:Connect(step)
end

function AddMaxOrbitCam.isBusy(): boolean
	return busy
end

function AddMaxOrbitCam.stop()
	if phase == "idle" or phase == "out" then
		return
	end
	if not busy then
		return
	end
	-- Snap yaw back onto the default seat angle before restoring the player view.
	if seatSnap and PlotCam2.isActive() then
		pushPose(seatSnap.yawDeg, seatSnap.liveDist)
	end
	outFromYaw = if seatSnap then seatSnap.yawDeg elseif PlotCam2.isActive() then PlotCam2.getTune().yawDeg else orbitYaw0
	phase = "out"
	phaseT0 = os.clock()
	connectStep()
end

function AddMaxOrbitCam.begin(orbitDurationSec: number)
	startToken += 1
	local my = startToken
	disconnectStep()
	phase = "idle"
	savedSnap = nil
	seatSnap = nil
	restoreToOff = false
	setBusyAttr(false)

	local sec = tonumber(orbitDurationSec)
	orbitSpanSec = math.max(4, if typeof(sec) == "number" and sec == sec then sec else 8)

	task.spawn(function()
		local startedOnPlot = PlotCam2.isActive()
		if not ensurePlotCam() then
			warn("[AddMaxOrbitCam] could not enter Plot Cam — orbit skipped")
			return
		end
		if my ~= startToken then
			return
		end

		restoreToOff = not startedOnPlot
		savedSnap = PlotCam2.captureView()
		if not savedSnap then
			warn("[AddMaxOrbitCam] no PlotCam2 snapshot — orbit skipped")
			return
		end

		seatSnap = buildDefaultSeat(savedSnap)
		if not seatSnap then
			warn("[AddMaxOrbitCam] no default seat — orbit skipped")
			return
		end

		orbitYaw0 = seatSnap.yawDeg
		phaseT0 = os.clock()
		phase = "in"
		setBusyAttr(true)
		connectStep()
	end)
end

return AddMaxOrbitCam
