--!strict
--[[
	Reef health bar polish:
	- Main fill: bright red gradient at every health level
	- Empty track: black, 15% transparent
	- White trail scales down 1.25s after the main fill starts its shrink
	- Optional 💔 flight from world heart → bar, then fill tweens down
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local ReefHealthBarFx = {}

local RED_TOP = Color3.fromRGB(255, 120, 100)
local RED_BOT = Color3.fromRGB(255, 18, 18)
local TRAIL_WHITE = Color3.fromRGB(255, 255, 255)
local FILL_TWEEN_SEC = 0.4
local TRAIL_BEHIND_SEC = 1.25
local FLY_SEC = 0.55
local FLY_GUI_ORDER = 5200

export type State = {
	visualFrac: number,
	trailFrac: number,
	targetFrac: number,
	fillTween: Tween?,
	trailTween: Tween?,
	trailToken: number,
	-- Hunger fill-ahead: green catch-up delay (separate from reef-damage trailToken).
	fillCatchUpToken: number,
	fillCatchUpPending: boolean,
	flyBusy: boolean,
	pendingFrac: number?,
	rockToken: number,
}

local ROCK_SEC = 1
local ROCK_AMP_DEG = 20
-- Full left-right cycles over ROCK_SEC (starts hard, envelope softens).
local ROCK_CYCLES = 5

function ReefHealthBarFx.makeState(initialFrac: number?): State
	local f = math.clamp(if typeof(initialFrac) == "number" then initialFrac else 1, 0, 1)
	return {
		visualFrac = f,
		trailFrac = f,
		targetFrac = f,
		fillTween = nil,
		trailTween = nil,
		trailToken = 0,
		fillCatchUpToken = 0,
		fillCatchUpPending = false,
		flyBusy = false,
		pendingFrac = nil,
		rockToken = 0,
	}
end

-- Rock the bar ±AMP from center for ~1s; amplitude decays each swing.
-- ampScale: optional multiplier (e.g. 0.5 = half as aggressive as the health bar).
function ReefHealthBarFx.rockBar(bar: GuiObject?, state: State?, ampScale: number?)
	if not bar or not bar.Parent then
		return
	end
	local amp = ROCK_AMP_DEG * (if typeof(ampScale) == "number" then ampScale else 1)
	local my = 0
	if state then
		state.rockToken += 1
		my = state.rockToken
	end
	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if state and my ~= state.rockToken then
			if conn then
				conn:Disconnect()
			end
			return
		end
		if not bar.Parent then
			if conn then
				conn:Disconnect()
			end
			return
		end
		local u = math.clamp((os.clock() - t0) / ROCK_SEC, 0, 1)
		if u >= 1 then
			bar.Rotation = 0
			if conn then
				conn:Disconnect()
			end
			return
		end
		-- Soften each swing: strong at start, nearly still at the end.
		local envelope = (1 - u) * (1 - u)
		local osc = math.sin(u * math.pi * 2 * ROCK_CYCLES)
		bar.Rotation = amp * envelope * osc
	end)
end

function ReefHealthBarFx.colorForFrac(_frac: number): Color3
	return RED_BOT
end

function ReefHealthBarFx.transparencyForFrac(_frac: number): number
	return 0
end

-- Fill stays the same bright red gradient at every health level.
-- The empty track behind it is the black 15% bar background.
function ReefHealthBarFx.applyFillStyle(fill: Frame, _frac: number)
	fill.BackgroundColor3 = RED_BOT
	fill.BackgroundTransparency = 0
	local grad = fill:FindFirstChild("ReefRedGradient")
	if not (grad and grad:IsA("UIGradient")) then
		grad = Instance.new("UIGradient")
		grad.Name = "ReefRedGradient"
		grad.Rotation = 90
		grad.Parent = fill
	end
	local g = grad :: UIGradient
	g.Color = ColorSequence.new(RED_TOP, RED_BOT)
	g.Transparency = NumberSequence.new(0)
end

function ReefHealthBarFx.ensureTrail(bar: Frame, zIndex: number): Frame
	local existing = bar:FindFirstChild("TrailFill")
	if existing and existing:IsA("Frame") then
		return existing
	end
	if existing then
		existing:Destroy()
	end
	local trail = Instance.new("Frame")
	trail.Name = "TrailFill"
	trail.BackgroundColor3 = TRAIL_WHITE
	trail.BackgroundTransparency = 0.15
	trail.BorderSizePixel = 0
	trail.Size = UDim2.fromScale(1, 1)
	trail.ZIndex = zIndex
	trail.Parent = bar
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = trail
	return trail
end

local function cancelFill(state: State)
	if state.fillTween then
		state.fillTween:Cancel()
		state.fillTween = nil
	end
end

local function cancelTrail(state: State, trail: Frame?)
	if state.trailTween then
		state.trailTween:Cancel()
		state.trailTween = nil
		-- Keep trailFrac in sync with the live Size so a restart never snaps backward.
		if trail then
			state.trailFrac = trail.Size.X.Scale
		end
	end
end

local function scheduleTrailCatchUp(trail: Frame, state: State, targetFrac: number)
	state.trailToken += 1
	local my = state.trailToken
	task.delay(TRAIL_BEHIND_SEC, function()
		if my ~= state.trailToken then
			return
		end
		if not trail.Parent then
			return
		end
		cancelTrail(state)
		local from = state.trailFrac
		local to = math.clamp(targetFrac, 0, 1)
		if math.abs(from - to) < 0.001 then
			state.trailFrac = to
			trail.Size = UDim2.fromScale(to, 1)
			return
		end
		trail.Size = UDim2.fromScale(from, 1)
		local tw = TweenService:Create(
			trail,
			TweenInfo.new(FILL_TWEEN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(to, 1) }
		)
		state.trailTween = tw
		tw:Play()
		tw.Completed:Once(function()
			if state.trailTween == tw then
				state.trailTween = nil
				state.trailFrac = to
			end
		end)
	end)
end

function ReefHealthBarFx.snap(fill: Frame, trail: Frame?, frac: number, state: State)
	local f = math.clamp(frac, 0, 1)
	cancelFill(state)
	state.trailToken += 1
	cancelTrail(state)
	state.visualFrac = f
	state.targetFrac = f
	state.trailFrac = f
	state.pendingFrac = nil
	state.flyBusy = false
	fill.Size = UDim2.fromScale(f, 1)
	ReefHealthBarFx.applyFillStyle(fill, f)
	if trail then
		trail.Size = UDim2.fromScale(f, 1)
	end
end

-- Tween main fill down/up to frac; white trail follows the same shrink 2s later.
function ReefHealthBarFx.tweenTo(fill: Frame, trail: Frame?, frac: number, state: State, rockHost: GuiObject?)
	local f = math.clamp(frac, 0, 1)
	state.targetFrac = f
	cancelFill(state)

	if f >= state.visualFrac - 1e-4 then
		-- Heal / same: snap fill + trail together.
		ReefHealthBarFx.snap(fill, trail, f, state)
		return
	end

	if rockHost then
		ReefHealthBarFx.rockBar(rockHost, state)
	end

	local from = state.visualFrac
	fill.Size = UDim2.fromScale(from, 1)
	ReefHealthBarFx.applyFillStyle(fill, from)
	local tw = TweenService:Create(
		fill,
		TweenInfo.new(FILL_TWEEN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(f, 1) }
	)
	state.fillTween = tw
	tw:Play()

	-- Color eases with the fill via a short stepped update.
	local t0 = os.clock()
	local colorConn: RBXScriptConnection? = nil
	colorConn = RunService.RenderStepped:Connect(function()
		if state.fillTween ~= tw then
			if colorConn then
				colorConn:Disconnect()
			end
			return
		end
		local u = math.clamp((os.clock() - t0) / FILL_TWEEN_SEC, 0, 1)
		local cur = from + (f - from) * u
		ReefHealthBarFx.applyFillStyle(fill, cur)
		if u >= 1 then
			if colorConn then
				colorConn:Disconnect()
			end
		end
	end)

	tw.Completed:Once(function()
		if state.fillTween == tw then
			state.fillTween = nil
			state.visualFrac = f
			fill.Size = UDim2.fromScale(f, 1)
			ReefHealthBarFx.applyFillStyle(fill, f)
		end
		if colorConn then
			colorConn:Disconnect()
		end
	end)

	if trail then
		-- Keep trail at its current high water; shrink 2s after this fill starts.
		trail.Size = UDim2.fromScale(state.trailFrac, 1)
		scheduleTrailCatchUp(trail, state, f)
	end
end

function ReefHealthBarFx.flyBrokenHeart(fromWorld: Vector3, toGui: GuiObject, onArrive: (() -> ())?, flySec: number?)
	local sec = if typeof(flySec) == "number" and flySec > 0 then flySec else FLY_SEC
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		if onArrive then
			onArrive()
		end
		return
	end

	local cam = Workspace.CurrentCamera
	local startScreen: Vector2
	if cam then
		local sp = cam:WorldToViewportPoint(fromWorld)
		startScreen = Vector2.new(sp.X, sp.Y)
	else
		startScreen = Vector2.new(0, 0)
	end

	local sg = Instance.new("ScreenGui")
	sg.Name = "OceanTD_ReefBarHeartFly"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = FLY_GUI_ORDER
	sg.Parent = playerGui

	local holder = Instance.new("TextLabel")
	holder.Name = "Heart"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(42, 42)
	holder.Font = Enum.Font.SourceSansBold
	holder.Text = "💔"
	holder.TextColor3 = Color3.fromRGB(255, 35, 55)
	holder.TextScaled = true
	holder.TextStrokeTransparency = 0.3
	holder.TextStrokeColor3 = Color3.fromRGB(80, 0, 10)
	holder.Position = UDim2.fromOffset(startScreen.X, startScreen.Y)
	holder.ZIndex = 10
	holder.Parent = sg

	local scale = Instance.new("UIScale")
	scale.Scale = 1.15
	scale.Parent = holder

	local t0 = os.clock()
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if not holder.Parent or not toGui.Parent then
			if conn then
				conn:Disconnect()
			end
			if sg.Parent then
				sg:Destroy()
			end
			if onArrive then
				onArrive()
			end
			return
		end
		local u = math.clamp((os.clock() - t0) / sec, 0, 1)
		local e = u * u * (3 - 2 * u)
		local inset = GuiService:GetGuiInset()
		local ap = toGui.AbsolutePosition
		local asz = toGui.AbsoluteSize
		local tx = ap.X + inset.X + asz.X * 0.5
		local ty = ap.Y + inset.Y + asz.Y * 0.5
		local x = startScreen.X + (tx - startScreen.X) * e
		local y = startScreen.Y + (ty - startScreen.Y) * e
		-- Slight arc upward mid-flight.
		local arc = math.sin(u * math.pi) * 48
		holder.Position = UDim2.fromOffset(x, y - arc)
		scale.Scale = 1.15 - 0.35 * e
		if u >= 1 then
			if conn then
				conn:Disconnect()
			end
			if sg.Parent then
				sg:Destroy()
			end
			if onArrive then
				onArrive()
			end
		end
	end)
end

--[[
	Drive bar to frac:
	- Heal / init: snap immediately
	- Damage: fly 💔 from world origin to bar, then tween fill; trail 2s behind
	getWorldOrigin may return nil (skips fly, tweens immediately)
]]
function ReefHealthBarFx.applyWithFly(
	fill: Frame,
	trail: Frame?,
	bar: GuiObject?,
	frac: number,
	state: State,
	getWorldOrigin: (() -> Vector3?)?
)
	local f = math.clamp(frac, 0, 1)

	-- Heal: snap fill + trail up immediately.
	if f > state.visualFrac + 1e-4 and f > state.targetFrac + 1e-4 then
		ReefHealthBarFx.snap(fill, trail, f, state)
		return
	end

	-- Already at / tweening toward this level (or higher).
	if f >= state.targetFrac - 1e-4 then
		if state.flyBusy or state.fillTween then
			return
		end
		if math.abs(f - state.visualFrac) > 1e-4 then
			ReefHealthBarFx.snap(fill, trail, f, state)
		else
			ReefHealthBarFx.applyFillStyle(fill, state.visualFrac)
		end
		return
	end

	-- Damage below current target: queue 💔 then tween.
	state.pendingFrac = if state.pendingFrac ~= nil then math.min(state.pendingFrac :: number, f) else f
	if state.flyBusy then
		return
	end
	state.flyBusy = true

	local function commit()
		local target = if state.pendingFrac ~= nil then state.pendingFrac :: number else f
		state.pendingFrac = nil
		state.flyBusy = false
		ReefHealthBarFx.tweenTo(fill, trail, target, state, bar)
	end

	local origin: Vector3? = nil
	if getWorldOrigin then
		local ok, pos = pcall(getWorldOrigin)
		if ok and typeof(pos) == "Vector3" then
			origin = pos
		end
	end

	if origin and bar then
		ReefHealthBarFx.flyBrokenHeart(origin, bar, commit)
	else
		commit()
	end
end

-- Legacy name used by callers that snap/tween without fly.
function ReefHealthBarFx.apply(fill: Frame, trail: Frame?, frac: number, state: State)
	local f = math.clamp(frac, 0, 1)
	if f >= state.visualFrac - 1e-4 then
		ReefHealthBarFx.snap(fill, trail, f, state)
	else
		ReefHealthBarFx.tweenTo(fill, trail, f, state)
	end
end

-- Size-only snap (keeps the caller's fill color — used by hunger).
function ReefHealthBarFx.snapSizes(fill: Frame, trail: Frame?, frac: number, state: State)
	local f = math.clamp(frac, 0, 1)
	cancelFill(state)
	state.trailToken += 1
	state.fillCatchUpToken += 1
	state.fillCatchUpPending = false
	cancelTrail(state, trail)
	state.visualFrac = f
	state.targetFrac = f
	state.trailFrac = f
	state.pendingFrac = nil
	state.flyBusy = false
	fill.Size = UDim2.fromScale(f, 1)
	if trail then
		trail.Size = UDim2.fromScale(f, 1)
	end
end

local function scheduleFillCatchUp(fill: Frame, state: State)
	-- Don't reset the delay on every hunger bump — green should catch the latest target
	-- after one TRAIL_BEHIND_SEC from the first rise while feeding is continuous.
	if state.fillCatchUpPending then
		return
	end
	state.fillCatchUpPending = true
	state.fillCatchUpToken += 1
	local my = state.fillCatchUpToken
	task.delay(TRAIL_BEHIND_SEC, function()
		if my ~= state.fillCatchUpToken then
			return
		end
		state.fillCatchUpPending = false
		if not fill.Parent then
			return
		end
		cancelFill(state)
		local from = state.visualFrac
		-- Use latest target (may have risen while we waited).
		local to = math.clamp(state.targetFrac, 0, 1)
		if math.abs(from - to) < 0.001 then
			state.visualFrac = to
			fill.Size = UDim2.fromScale(to, 1)
			return
		end
		fill.Size = UDim2.fromScale(from, 1)
		local tw = TweenService:Create(
			fill,
			TweenInfo.new(FILL_TWEEN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(to, 1) }
		)
		state.fillTween = tw
		tw:Play()
		tw.Completed:Once(function()
			if state.fillTween == tw then
				state.fillTween = nil
				state.visualFrac = to
				fill.Size = UDim2.fromScale(to, 1)
				-- Target moved further while green was tweening — schedule another catch-up.
				if state.targetFrac > state.visualFrac + 1e-4 then
					scheduleFillCatchUp(fill, state)
				end
			end
		end)
	end)
end

--[[
	Hunger / feed progress (reverse of reef damage trail):
	- White trail fills immediately
	- Colored fill on top catches up after TRAIL_BEHIND_SEC
]]
function ReefHealthBarFx.applyFillAhead(fill: Frame, trail: Frame?, frac: number, state: State)
	local f = math.clamp(frac, 0, 1)

	-- Reset / shrink: snap both together.
	if f < state.targetFrac - 1e-4 or f < state.trailFrac - 1e-4 then
		ReefHealthBarFx.snapSizes(fill, trail, f, state)
		return
	end

	-- Already at / targeting this level.
	if f <= state.targetFrac + 1e-4 then
		return
	end

	state.targetFrac = f

	-- White trail grows now.
	if trail then
		cancelTrail(state, trail)
		local from = state.trailFrac
		local to = f
		if math.abs(from - to) < 0.001 then
			state.trailFrac = to
			trail.Size = UDim2.fromScale(to, 1)
		elseif from < to then
			trail.Size = UDim2.fromScale(from, 1)
			local tw = TweenService:Create(
				trail,
				TweenInfo.new(FILL_TWEEN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Size = UDim2.fromScale(to, 1) }
			)
			state.trailTween = tw
			tw:Play()
			tw.Completed:Once(function()
				if state.trailTween ~= tw then
					return
				end
				state.trailTween = nil
				state.trailFrac = math.max(to, trail.Size.X.Scale)
				-- Progress rose again during the tween — extend without snapping down.
				if state.targetFrac > state.trailFrac + 1e-4 then
					local extendTo = state.targetFrac
					local extendFrom = state.trailFrac
					trail.Size = UDim2.fromScale(extendFrom, 1)
					local tw2 = TweenService:Create(
						trail,
						TweenInfo.new(FILL_TWEEN_SEC, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Size = UDim2.fromScale(extendTo, 1) }
					)
					state.trailTween = tw2
					tw2:Play()
					tw2.Completed:Once(function()
						if state.trailTween == tw2 then
							state.trailTween = nil
							state.trailFrac = math.max(extendTo, trail.Size.X.Scale)
						end
					end)
				end
			end)
		else
			-- from >= to after sync: keep the higher live Size; never flash backward.
			state.trailFrac = from
		end
	else
		state.trailFrac = f
	end

	-- Green fill delayed (one shared timer; does not reset on each bump).
	scheduleFillCatchUp(fill, state)
end

return ReefHealthBarFx
