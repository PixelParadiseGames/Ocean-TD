--!strict
--[[
	Torso-locked ✓/X layout helpers for PlacementController.
	Extracted so PlacementController stays under Luau's 200-local limit.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer

local PlaceConfirmChrome = {}

local BTN_FALLBACK_BOTTOM_PAD = 28
-- HRP is at the waist; keep ✓/X on the belt line (was 1.35 ≈ chest/head).
local BELT_OFFSET = CFrame.new(0, -0.35, 0)
-- Never smaller than this on screen (freecam / zoomed-out cameras).
local MIN_BTN_PX = 52
-- Beyond this distance, pin to screen space so Offset billboards can't go unreadably small.
local SCREEN_LAYOUT_DIST = 28

function PlaceConfirmChrome.ensureAdornee(existing: BasePart?): BasePart?
	local char = player.Character
	if not char then
		return nil
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return nil
	end
	local part = existing
	if part and part.Parent == char then
		local weld = part:FindFirstChildOfClass("Weld")
		if weld and weld:IsA("Weld") and weld.Part0 == root and weld.Part1 == part then
			weld.C0 = BELT_OFFSET
			weld.C1 = CFrame.new()
			return part
		end
		part:Destroy()
		part = nil
	elseif part then
		part:Destroy()
		part = nil
	end
	part = Instance.new("Part")
	part.Name = "OceanTD_PlaceChromeAdornee"
	part.Size = Vector3.new(0.15, 0.15, 0.15)
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Anchored = false
	part.CastShadow = false
	part.Parent = char
	local weld = Instance.new("Weld")
	weld.Part0 = root
	weld.Part1 = part
	weld.C0 = BELT_OFFSET
	weld.C1 = CFrame.new()
	weld.Parent = part
	return part
end

function PlaceConfirmChrome.screenPos(adornee: BasePart?): Vector2
	local cam = Workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(800, 600)
	local inset = GuiService:GetGuiInset()
	local fallback = Vector2.new(vp.X * 0.5 + inset.X, vp.Y - BTN_FALLBACK_BOTTOM_PAD)
	if not cam then
		return fallback
	end
	local world: Vector3? = if adornee then adornee.Position else nil
	if not world then
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			world = (root.CFrame * BELT_OFFSET).Position
		else
			return fallback
		end
	end
	local sp, onScreen = cam:WorldToScreenPoint(world)
	if not onScreen or sp.Z <= 0 then
		return fallback
	end
	return Vector2.new(sp.X, sp.Y)
end

function PlaceConfirmChrome.layoutAt(
	chrome: Vector2,
	btnSize: number,
	confirmGui: ScreenGui?,
	chromeBillboard: BillboardGui?,
	checkBtn: TextButton?,
	cancelBtn: TextButton?
)
	local s = btnSize
	local gap = 6
	if not confirmGui then
		return
	end
	if chromeBillboard then
		chromeBillboard.Enabled = false
	end
	local showCheck = checkBtn ~= nil and checkBtn.Visible
	if checkBtn then
		if checkBtn.Parent ~= confirmGui then
			checkBtn.Parent = confirmGui
		end
		checkBtn.AnchorPoint = Vector2.new(0.5, 0.5)
		checkBtn.Size = UDim2.fromOffset(s, s)
		if showCheck then
			checkBtn.Position = UDim2.fromOffset(chrome.X - (s * 0.5 + gap), chrome.Y)
		else
			checkBtn.Position = UDim2.fromOffset(chrome.X, chrome.Y)
		end
	end
	if cancelBtn then
		if cancelBtn.Parent ~= confirmGui then
			cancelBtn.Parent = confirmGui
		end
		cancelBtn.AnchorPoint = Vector2.new(0.5, 0.5)
		cancelBtn.Size = UDim2.fromOffset(s, s)
		if showCheck then
			cancelBtn.Position = UDim2.fromOffset(chrome.X + (s * 0.5 + gap), chrome.Y)
		else
			cancelBtn.Position = UDim2.fromOffset(chrome.X, chrome.Y)
		end
	end
end

function PlaceConfirmChrome.layoutOnTorso(
	btnSize: number,
	playerGui: PlayerGui,
	confirmGui: ScreenGui?,
	chromeBillboard: BillboardGui?,
	chromeAdornee: BasePart?,
	checkBtn: TextButton?,
	cancelBtn: TextButton?
): (BillboardGui?, BasePart?)
	local s = math.max(btnSize, MIN_BTN_PX)
	local gap = 6
	local adornee = PlaceConfirmChrome.ensureAdornee(chromeAdornee)
	if not adornee or not checkBtn or not cancelBtn or not confirmGui then
		PlaceConfirmChrome.layoutAt(
			PlaceConfirmChrome.screenPos(adornee),
			s,
			confirmGui,
			chromeBillboard,
			checkBtn,
			cancelBtn
		)
		return chromeBillboard, adornee
	end

	-- Far camera (freecam / zoomed out): screen-space so buttons stay tappable.
	local cam = Workspace.CurrentCamera
	local far = false
	if cam then
		far = (cam.CFrame.Position - adornee.Position).Magnitude >= SCREEN_LAYOUT_DIST
	end
	if far then
		if chromeBillboard then
			chromeBillboard.Enabled = false
		end
		PlaceConfirmChrome.layoutAt(
			PlaceConfirmChrome.screenPos(adornee),
			s,
			confirmGui,
			chromeBillboard,
			checkBtn,
			cancelBtn
		)
		return chromeBillboard, adornee
	end

	local bb = chromeBillboard
	if not bb or not bb.Parent then
		bb = Instance.new("BillboardGui")
		bb.Name = "OceanTD_PlaceChromeBillboard"
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		bb.MaxDistance = 1000
		bb.Active = true
		bb.ResetOnSpawn = false
		bb.Parent = playerGui
	end
	bb.Adornee = adornee
	bb.Enabled = true
	bb.StudsOffsetWorldSpace = Vector3.zero
	bb.StudsOffset = Vector3.zero
	bb.ExtentsOffsetWorldSpace = Vector3.zero
	-- Floor how small distance-scaled billboards can get (ignored when < 0).
	pcall(function()
		(bb :: any).DistanceUpperLimit = SCREEN_LAYOUT_DIST
	end)
	local showCheck = checkBtn.Visible
	-- Offset = constant on-screen pixels (not studs).
	if showCheck then
		bb.Size = UDim2.fromOffset(s * 2 + gap * 2 + 8, s + 8)
	else
		bb.Size = UDim2.fromOffset(s + 8, s + 8)
	end
	if checkBtn.Parent ~= bb then
		checkBtn.Parent = bb
	end
	if cancelBtn.Parent ~= bb then
		cancelBtn.Parent = bb
	end
	checkBtn.Size = UDim2.fromOffset(s, s)
	cancelBtn.Size = UDim2.fromOffset(s, s)
	if showCheck then
		checkBtn.AnchorPoint = Vector2.new(1, 0.5)
		checkBtn.Position = UDim2.new(0.5, -gap, 0.5, 0)
		cancelBtn.AnchorPoint = Vector2.new(0, 0.5)
		cancelBtn.Position = UDim2.new(0.5, gap, 0.5, 0)
	else
		cancelBtn.AnchorPoint = Vector2.new(0.5, 0.5)
		cancelBtn.Position = UDim2.fromScale(0.5, 0.5)
		checkBtn.AnchorPoint = Vector2.new(0.5, 0.5)
		checkBtn.Position = UDim2.fromScale(0.5, 0.5)
	end
	return bb, adornee
end

return PlaceConfirmChrome
