--!strict
--[[
	Short camera zoom punches for join-intro ink beats.
	Owns Scriptable cam while busy (FreeCam yields on OceanTD_IntroCamPunchBusy).

	Join intro keeps OceanTD_JoinIntroBusy and routes FreeCam through SkyCam
	(PlotCam2 is not active), so punches must not depend on PlotCam2.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local IntroCamPunch = {}

local ATTR_BUSY = "OceanTD_IntroCamPunchBusy"

local token = 0
local busy = false
local holdFocusFn: (() -> Vector3?)? = nil
local releaseRequested = false
local releaseOutSec = 0.35
-- When true, hold keeps the zoomed pose frozen (no per-frame focus tracking).
local freezeHoldFocus = false
local frozenHoldFocus: Vector3? = nil

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
end

local function smoothstep(t: number): number
	local u = math.clamp(t, 0, 1)
	return u * u * (3 - 2 * u)
end

local function resolveFocus(cam: Camera, worldFocus: Vector3?): Vector3
	if typeof(worldFocus) == "Vector3" then
		return worldFocus :: Vector3
	end
	return cam.CFrame.Position + cam.CFrame.LookVector * 80
end

-- Blend from the exact start CFrame into a closer pose — no snap on frame 0.
-- Look aim only shifts halfway toward the focus (50% less yaw/pitch punch).
local LOOK_SHIFT = 0.5
local function poseAtBlend(startCf: CFrame, foc: Vector3, closerFrac: number, blend: number): CFrame
	local b = smoothstep(math.clamp(blend, 0, 1))
	local closer = math.clamp(closerFrac, 0.05, 0.6)
	local goalPos = startCf.Position:Lerp(foc, closer)
	local dist = math.max((startCf.Position - foc).Magnitude, 8)
	local startLookAt = startCf.Position + startCf.LookVector * dist
	local lookAt = startLookAt:Lerp(foc, LOOK_SHIFT)
	local goalCf = CFrame.lookAt(goalPos, lookAt)
	return startCf:Lerp(goalCf, b)
end

export type PunchHandle = {
	token: number,
	release: (outSec: number?) -> (),
}

export type BeginHoldOpts = {
	-- If true, after ease-in keep a fixed look target (no fish tracking).
	freezeFocus: boolean?,
}

--[[
	Quick zoom in toward worldFocus, hold until release(outSec), then ease back.
	closerFrac 0.2 = move 20% of the way from the current cam pos toward the focus.
]]
function IntroCamPunch.beginHold(
	worldFocus: Vector3?,
	closerFrac: number?,
	inSec: number?,
	opts: BeginHoldOpts?
): PunchHandle?
	local cam = Workspace.CurrentCamera
	if not cam then
		return nil
	end

	token += 1
	local my = token
	releaseRequested = false
	releaseOutSec = 0.35
	local closer = if typeof(closerFrac) == "number" then math.clamp(closerFrac, 0.05, 0.6) else 0.25
	local easeIn = if typeof(inSec) == "number" and inSec > 0 then inSec else 0.2
	freezeHoldFocus = opts ~= nil and opts.freezeFocus == true
	frozenHoldFocus = nil

	if typeof(worldFocus) == "Vector3" then
		local fixed = worldFocus :: Vector3
		holdFocusFn = function()
			return fixed
		end
		if freezeHoldFocus then
			frozenHoldFocus = fixed
		end
	else
		holdFocusFn = nil
	end

	local startCf = cam.CFrame
	setBusyAttr(true)

	task.spawn(function()
		local t0 = os.clock()
		local easedIn = false
		while my == token and not releaseRequested do
			local live = Workspace.CurrentCamera
			if not live then
				break
			end
			local elapsed = os.clock() - t0
			local u = if elapsed < easeIn then smoothstep(elapsed / easeIn) else 1
			if u >= 1 and not easedIn then
				easedIn = true
				-- Lock look target at the end of the ease-in (hold still).
				if freezeHoldFocus then
					local focRaw = if holdFocusFn then holdFocusFn() else worldFocus
					frozenHoldFocus = resolveFocus(live, focRaw)
				end
			end
			local foc: Vector3
			if freezeHoldFocus and frozenHoldFocus then
				foc = frozenHoldFocus
			else
				local focRaw = if holdFocusFn then holdFocusFn() else worldFocus
				foc = resolveFocus(live, focRaw)
			end
			live.CameraType = Enum.CameraType.Scriptable
			live.CameraSubject = nil
			live.CFrame = poseAtBlend(startCf, foc, closer, u)
			RunService.RenderStepped:Wait()
		end
		if my ~= token then
			return
		end
		local outSec = math.max(0.12, releaseOutSec)
		local tOut = os.clock()
		local liveOut = Workspace.CurrentCamera
		local fromCf = if liveOut then liveOut.CFrame else startCf
		while my == token do
			local live = Workspace.CurrentCamera
			if not live then
				break
			end
			local u = 1 - smoothstep((os.clock() - tOut) / outSec)
			if u <= 0.001 then
				break
			end
			live.CameraType = Enum.CameraType.Scriptable
			live.CameraSubject = nil
			live.CFrame = fromCf:Lerp(startCf, 1 - u)
			RunService.RenderStepped:Wait()
		end
		if my == token then
			local live = Workspace.CurrentCamera
			if live then
				live.CameraType = Enum.CameraType.Scriptable
				live.CameraSubject = nil
				live.CFrame = startCf
			end
			setBusyAttr(false)
			holdFocusFn = nil
			frozenHoldFocus = nil
			freezeHoldFocus = false
		end
	end)

	return {
		token = my,
		release = function(outSec: number?)
			if my ~= token or releaseRequested then
				return
			end
			if typeof(outSec) == "number" and outSec > 0 then
				releaseOutSec = outSec
			end
			releaseRequested = true
		end,
	}
end

function IntroCamPunch.setHoldFocus(getFocus: (() -> Vector3?)?)
	holdFocusFn = getFocus
end

-- One-shot: in → hold → out. Fire-and-forget.
function IntroCamPunch.pulse(worldFocus: Vector3?, closerFrac: number?, inSec: number?, holdSec: number?, outSec: number?)
	local handle = IntroCamPunch.beginHold(worldFocus, closerFrac, inSec)
	if not handle then
		return
	end
	local hold = if typeof(holdSec) == "number" then holdSec else 2
	local easeIn = if typeof(inSec) == "number" then inSec else 0.2
	task.delay(hold + easeIn, function()
		handle.release(outSec)
	end)
end

function IntroCamPunch.cancel()
	token += 1
	releaseRequested = true
	holdFocusFn = nil
	frozenHoldFocus = nil
	freezeHoldFocus = false
	if busy then
		setBusyAttr(false)
	end
end

function IntroCamPunch.isBusy(): boolean
	return busy
end

return IntroCamPunch
