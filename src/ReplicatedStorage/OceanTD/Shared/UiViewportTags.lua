--!strict
--[[
	CollectionService tags for resolution-class ScreenGuis.

	In Studio: tag ScreenGuis "Mobile" or "720p" (Tag Editor).
	Known right HUDs are also toggled by name even if a tag is missing:
	  StarterGui.MobileRightHUD  → phones / short edge under 720
	  StarterGui.720pRightHUD    → tablets & desktop (720p+ short edge)

	Classification notes:
	- Prefer the *short* edge (not Y) so landscape phones aren't flipped.
	- High-DPI phones can report short edge ≥720; phone-aspect + touch-only
	  still maps to Mobile (Studio device emulator often keeps short edge <720).
]]

local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local UiViewportTags = {
	MOBILE = "Mobile",
	P720 = "720p",
	MAIN_HUD = "MainHUD",
	MOBILE_RIGHT_HUD = "MobileRightHUD",
	P720_RIGHT_HUD = "720pRightHUD",
	-- Short-edge breakpoint (720p class).
	HEIGHT_BREAKPOINT = 720,
	-- Touch HUD sits above default TouchGui so right-side slots receive taps.
	RIGHT_HUD_DISPLAY_ORDER = 250,
}

function UiViewportTags.readViewport(): Vector2
	local cam = Workspace.CurrentCamera
	if cam then
		return cam.ViewportSize
	end
	return Vector2.new(1280, 720)
end

--[[
	false → MobileRightHUD, true → 720pRightHUD
]]
function UiViewportTags.is720p(viewport: Vector2?): boolean
	local vp = viewport or UiViewportTags.readViewport()
	local short = math.min(vp.X, vp.Y)
	local long = math.max(vp.X, vp.Y)
	if short < 1 then
		return false
	end
	local aspect = long / short
	-- Real phones: touch without a hardware keyboard, tall aspect, even if DPI ≥720.
	-- Studio's device emulator usually still has KeyboardEnabled from the PC — then
	-- short-edge <720 keeps Mobile, matching what already worked in the emulator.
	local touchPhone = UserInputService.TouchEnabled
		and not UserInputService.KeyboardEnabled
		and aspect >= 1.6
	if touchPhone then
		return false
	end
	return short >= UiViewportTags.HEIGHT_BREAKPOINT
end

function UiViewportTags.isMobile(viewport: Vector2?): boolean
	return not UiViewportTags.is720p(viewport)
end

function UiViewportTags.preferredRightHudName(is720p: boolean): string
	return if is720p then UiViewportTags.P720_RIGHT_HUD else UiViewportTags.MOBILE_RIGHT_HUD
end

local function hasQuickbarSlot4(gui: Instance): boolean
	if not gui:IsA("ScreenGui") then
		return false
	end
	local quickbar = gui:FindFirstChild("Quickbar")
	if not quickbar then
		return false
	end
	local slot4 = quickbar:FindFirstChild("Slot4")
	return slot4 ~= nil and slot4:IsA("GuiObject")
end

function UiViewportTags.hasQuickbarSlot4(gui: Instance): boolean
	return hasQuickbarSlot4(gui)
end

local function scoreCandidate(gui: ScreenGui, want720p: boolean): number
	local hasMobile = CollectionService:HasTag(gui, UiViewportTags.MOBILE)
	local has720 = CollectionService:HasTag(gui, UiViewportTags.P720)
	local hasMain = CollectionService:HasTag(gui, UiViewportTags.MAIN_HUD)
	local score = 0
	if hasMain then
		score += 10
	end
	if want720p and has720 then
		score += 100
	elseif not want720p and hasMobile then
		score += 100
	elseif want720p and hasMobile then
		score -= 50
	elseif not want720p and has720 then
		score -= 50
	end
	if gui.Enabled then
		score += 5
	end
	local n = string.lower(gui.Name)
	if string.find(n, "main", 1, true) or string.find(n, "quickbar", 1, true) then
		score += 3
	end
	if string.find(n, "right", 1, true) then
		score += 2
	end
	if want720p and string.find(n, "720", 1, true) then
		score += 40
	end
	if not want720p and string.find(n, "mobile", 1, true) then
		score += 40
	end
	return score
end

function UiViewportTags.listMainHudCandidates(playerGui: PlayerGui): { ScreenGui }
	local tagged = CollectionService:GetTagged(UiViewportTags.MAIN_HUD)
	local out: { ScreenGui } = {}
	local seen: { [ScreenGui]: boolean } = {}
	for _, inst in ipairs(tagged) do
		if inst:IsA("ScreenGui") and inst:IsDescendantOf(playerGui) and hasQuickbarSlot4(inst) then
			seen[inst] = true
			table.insert(out, inst)
		end
	end
	for _, child in ipairs(playerGui:GetChildren()) do
		if child:IsA("ScreenGui") and not seen[child] and hasQuickbarSlot4(child) then
			table.insert(out, child)
		end
	end
	return out
end

function UiViewportTags.pickMainHud(playerGui: PlayerGui): ScreenGui?
	local want720p = UiViewportTags.is720p(UiViewportTags.readViewport())
	local preferredName = UiViewportTags.preferredRightHudName(want720p)
	local preferred = playerGui:FindFirstChild(preferredName)
	if preferred and preferred:IsA("ScreenGui") and hasQuickbarSlot4(preferred) then
		return preferred
	end

	local best: ScreenGui? = nil
	local bestScore = -1e9
	for _, gui in ipairs(UiViewportTags.listMainHudCandidates(playerGui)) do
		local skipWrongKnown = (gui.Name == UiViewportTags.MOBILE_RIGHT_HUD and want720p)
			or (gui.Name == UiViewportTags.P720_RIGHT_HUD and not want720p)
		if not skipWrongKnown then
			local s = scoreCandidate(gui, want720p)
			if s > bestScore then
				bestScore = s
				best = gui
			end
		end
	end
	return best
end

function UiViewportTags.waitMainHud(playerGui: PlayerGui, timeoutSec: number?): ScreenGui
	local deadline = os.clock() + (timeoutSec or 60)
	while os.clock() < deadline do
		local vp = UiViewportTags.readViewport()
		if vp.X >= 64 and vp.Y >= 64 then
			break
		end
		task.wait(0.05)
	end
	-- Let landscape lock settle on real devices.
	task.wait(0.15)
	while os.clock() < deadline do
		local hud = UiViewportTags.pickMainHud(playerGui)
		if hud then
			return hud
		end
		local legacy = playerGui:FindFirstChild("MainHUD")
		if legacy and legacy:IsA("ScreenGui") and hasQuickbarSlot4(legacy) then
			return legacy
		end
		task.wait(0.1)
	end
	error(
		"[UI] No Main HUD ScreenGui with Quickbar.Slot4 found. "
			.. "Expected PlayerGui.MobileRightHUD or PlayerGui.720pRightHUD — author in Studio"
	)
end

return UiViewportTags
