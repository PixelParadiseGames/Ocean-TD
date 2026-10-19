--!strict
--[[
	Join-intro fake backpack bind for InventoryUI.
	Extracted so InventoryUI.client stays under Luau's 200-local register limit.
]]

local GuiService = game:GetService("GuiService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemCatalog = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("ItemCatalog"))
local AudioSettings = require(ReplicatedStorage:WaitForChild("OceanTD"):WaitForChild("Shared"):WaitForChild("AudioSettings"))
local InventoryState = require(script.Parent:WaitForChild("InventoryState"))
local JoinIntroBackpackDemo = require(script.Parent:WaitForChild("JoinIntroBackpackDemo"))

local ADD_MAX_PRESS_TICK_ID = "rbxassetid://128707491647978"

local function playAddMaxPressTick()
	local s = Instance.new("Sound")
	s.Name = "OceanTD_JoinIntroAddMaxTick"
	s.SoundId = ADD_MAX_PRESS_TICK_ID
	s.Volume = 1.1
	s.Parent = SoundService
	AudioSettings.markPrioritySfx(s)
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
end

local JoinIntroBackpackUi = {}

export type MountDeps = {
	scroll: ScrollingFrame,
	panel: GuiObject,
	host: GuiObject,
	circle: GuiObject,
	itemButtons: { GuiButton },
	playClose: () -> (),
	applySlotOpenChrome: () -> (),
	applySlotClosedChrome: () -> (),
	syncBackpackGate: () -> (),
	refreshSeedCountBadges: () -> (),
}

function JoinIntroBackpackUi.mount(deps: MountDeps)
	local scroll = deps.scroll
	local panel = deps.panel
	local host = deps.host
	local circle = deps.circle
	local itemButtons = deps.itemButtons
	local playClose = deps.playClose
	local applySlotOpenChrome = deps.applySlotOpenChrome
	local applySlotClosedChrome = deps.applySlotClosedChrome
	local syncBackpackGate = deps.syncBackpackGate
	local refreshSeedCountBadges = deps.refreshSeedCountBadges

	local demoBlocker: TextButton? = nil
	local demoSavedActive: { [GuiObject]: boolean } = {}
	local hiddenPlaceholders: { GuiObject } = {}
	local demoCollapsed = false
	-- Bumps on cleanup so an in-flight BUILD pop tween cannot leave Slot4 at Scale=2 after Skip.
	local buildPopToken = 0
	local buildPopUp: Tween? = nil
	local buildPopDown: Tween? = nil

	local function canvasMaxY(): number
		local windowY = scroll.AbsoluteWindowSize.Y
		if windowY < 1 then
			windowY = scroll.AbsoluteSize.Y
		end
		return math.max(0, scroll.AbsoluteCanvasSize.Y - windowY)
	end

	local function resetBuildPopScale()
		buildPopToken += 1
		if buildPopUp then
			pcall(function()
				(buildPopUp :: Tween):Cancel()
			end)
			buildPopUp = nil
		end
		if buildPopDown then
			pcall(function()
				(buildPopDown :: Tween):Cancel()
			end)
			buildPopDown = nil
		end
		local pop = circle:FindFirstChild("_OceanTD_JoinIntroBuildPop")
		if pop and pop:IsA("UIScale") then
			pop.Scale = 1
		end
	end

	local function cleanupDemoState()
		if demoBlocker then
			demoBlocker:Destroy()
			demoBlocker = nil
		end
		resetBuildPopScale()
		pcall(function()
			local AutoPlantUI = require(script.Parent:WaitForChild("AutoPlantUI"))
			if AutoPlantUI.setJoinIntroDemo then
				AutoPlantUI.setJoinIntroDemo(false)
			end
		end)
		pcall(function()
			local AutoPlantHudSlot = require(script.Parent:WaitForChild("AutoPlantHudSlot"))
			if AutoPlantHudSlot.setForcedHidden then
				AutoPlantHudSlot.setForcedHidden(false)
			end
		end)
		for _, ph in ipairs(hiddenPlaceholders) do
			if ph.Parent then
				ph.Visible = true
			end
		end
		table.clear(hiddenPlaceholders)
		for btn, was in pairs(demoSavedActive) do
			if btn.Parent then
				btn.Active = was
			end
		end
		table.clear(demoSavedActive)
		scroll.ScrollingEnabled = true
		InventoryState.setJoinIntroDemo(false)
		syncBackpackGate()
		refreshSeedCountBadges()
	end

	JoinIntroBackpackDemo.bind({
		previewBuildBeforeOpen = function(durationSec: number, cancelled: (() -> boolean)?)
			demoCollapsed = false
			-- Unlock BUILD chrome + hide Auto Plant HUD; keep backpack closed.
			InventoryState.setJoinIntroDemo(true)
			syncBackpackGate()
			refreshSeedCountBadges()
			if InventoryState.isOpen() then
				InventoryState.setOpenForced(false)
			end
			applySlotClosedChrome()
			pcall(function()
				local AutoPlantHudSlot = require(script.Parent:WaitForChild("AutoPlantHudSlot"))
				if AutoPlantHudSlot.setForcedHidden then
					AutoPlantHudSlot.setForcedHidden(true)
				elseif AutoPlantHudSlot.setVisible then
					AutoPlantHudSlot.setVisible(false)
				end
			end)
			resetBuildPopScale()
			local myPop = buildPopToken
			local scale = circle:FindFirstChild("_OceanTD_JoinIntroBuildPop") :: UIScale?
			if not scale then
				scale = Instance.new("UIScale")
				scale.Name = "_OceanTD_JoinIntroBuildPop"
				scale.Parent = circle
			end
			local dur = math.max(0.05, durationSec)
			scale.Scale = 2
			local t0 = os.clock()
			while myPop == buildPopToken and scale.Parent do
				if cancelled and cancelled() then
					break
				end
				local u = math.clamp((os.clock() - t0) / dur, 0, 1)
				-- Ease out: oversized → normal by the time the backpack opens.
				local e = 1 - (1 - u) ^ 3
				scale.Scale = 2 + (1 - 2) * e
				if u >= 1 then
					break
				end
				task.wait()
			end
			if myPop == buildPopToken and scale.Parent then
				scale.Scale = 1
			end
		end,
		begin = function(_scrollSec: number)
			demoCollapsed = false
			InventoryState.setJoinIntroDemo(true)
			syncBackpackGate()
			refreshSeedCountBadges()
			InventoryState.setOpenForced(true)
			applySlotOpenChrome()
			scroll.ScrollingEnabled = false
			table.clear(demoSavedActive)
			table.clear(hiddenPlaceholders)
			pcall(function()
				local AutoPlantUI = require(script.Parent:WaitForChild("AutoPlantUI"))
				if AutoPlantUI.setJoinIntroDemo then
					AutoPlantUI.setJoinIntroDemo(true)
				end
			end)
			pcall(function()
				local AutoPlantHudSlot = require(script.Parent:WaitForChild("AutoPlantHudSlot"))
				if AutoPlantHudSlot.setForcedHidden then
					AutoPlantHudSlot.setForcedHidden(true)
				elseif AutoPlantHudSlot.setVisible then
					AutoPlantHudSlot.setVisible(false)
				end
			end)
			-- Preview already ran 2× → 1×; keep BUILD at normal size (no second pop).
			resetBuildPopScale()
			local scale = circle:FindFirstChild("_OceanTD_JoinIntroBuildPop") :: UIScale?
			if scale then
				scale.Scale = 1
			end
			for _, child in ipairs(scroll:GetDescendants()) do
				if child:IsA("GuiObject") and string.sub(child.Name, 1, 11) == "_LockedSlot" then
					if child.Visible then
						table.insert(hiddenPlaceholders, child)
						child.Visible = false
					end
				end
			end
			for _, btn in ipairs(itemButtons) do
				demoSavedActive[btn] = btn.Active
				btn.Active = false
				btn.AutoButtonColor = false
			end
			if demoBlocker and demoBlocker.Parent then
				demoBlocker:Destroy()
			end
			local block = Instance.new("TextButton")
			block.Name = "_OceanTD_JoinIntroBpBlock"
			block.BackgroundTransparency = 1
			block.Text = ""
			block.Size = UDim2.fromScale(1, 1)
			block.ZIndex = 80
			block.Active = true
			block.AutoButtonColor = false
			block.Parent = panel
			demoBlocker = block
			task.wait()
			scroll.CanvasPosition = Vector2.new(0, canvasMaxY())
			return true
		end,
		collapseAway = function()
			if demoCollapsed then
				return
			end
			demoCollapsed = true
			if demoBlocker then
				demoBlocker:Destroy()
				demoBlocker = nil
			end
			resetBuildPopScale()
			if InventoryState.isOpen() then
				InventoryState.setOpenForced(false)
			elseif host.Visible then
				playClose()
			end
			cleanupDemoState()
		end,
		finish = function()
			-- Always kill BUILD pop tweens — even if collapseAway already set demoCollapsed
			-- (race: collapseAway marks collapsed before reset finishes / yields).
			resetBuildPopScale()
			if demoCollapsed then
				if InventoryState.isOpen() then
					InventoryState.setOpenForced(false)
				end
				return
			end
			demoCollapsed = true
			cleanupDemoState()
			if InventoryState.isOpen() then
				InventoryState.setOpenForced(false)
			elseif host.Visible then
				host.Visible = false
				applySlotClosedChrome()
			end
		end,
		speciesBottomToTop = function()
			local ids: { string } = {}
			local seen: { [string]: boolean } = {}
			for i = #itemButtons, 1, -1 do
				local id = itemButtons[i]:GetAttribute("OceanTD_ItemId")
				if typeof(id) == "string" and not seen[id] and ItemCatalog.get(id) then
					seen[id] = true
					table.insert(ids, id)
				end
			end
			return ids
		end,
		slotScreenCenter = function(itemId: string)
			for _, btn in ipairs(itemButtons) do
				if btn:GetAttribute("OceanTD_ItemId") == itemId then
					local ap = btn.AbsolutePosition
					local asz = btn.AbsoluteSize
					local inset = GuiService:GetGuiInset()
					return Vector2.new(ap.X + inset.X + asz.X * 0.5, ap.Y + inset.Y + asz.Y * 0.5)
				end
			end
			return nil
		end,
		setScrollProgress = function(u: number)
			local maxY = canvasMaxY()
			local t = math.clamp(u, 0, 1)
			scroll.CanvasPosition = Vector2.new(0, maxY * (1 - t))
		end,
		addMaxScreenCenter = function()
			local AutoPlantUI = require(script.Parent:WaitForChild("AutoPlantUI"))
			local btn = AutoPlantUI.getAddMaxButton and AutoPlantUI.getAddMaxButton()
			if not (btn and btn.Parent) then
				return nil
			end
			local ap = btn.AbsolutePosition
			local asz = btn.AbsoluteSize
			local inset = GuiService:GetGuiInset()
			return Vector2.new(ap.X + inset.X + asz.X * 0.5, ap.Y + inset.Y + asz.Y * 0.5)
		end,
		playAddMaxPress = function()
			local AutoPlantUI = require(script.Parent:WaitForChild("AutoPlantUI"))
			local btn = AutoPlantUI.getAddMaxButton and AutoPlantUI.getAddMaxButton()
			-- Scale the shell (fill + stroke); text-only UIScale left the chrome unmoved.
			local shell: GuiObject? = if AutoPlantUI.getAddMaxShell then AutoPlantUI.getAddMaxShell() else nil
			if not shell then
				shell = if btn and btn.Parent and btn.Parent:IsA("GuiObject") then btn.Parent :: GuiObject else btn
			end
			if not (shell and shell.Parent and shell.Parent:IsA("GuiObject")) then
				return
			end
			scroll.CanvasPosition = Vector2.new(0, 0)
			task.wait() -- let scroll/layout settle so AbsoluteSize is valid
			if btn then
				local old = btn:FindFirstChildOfClass("UIScale")
				if old then
					old:Destroy()
				end
			end
			-- Holder keeps the list slot; shell centers inside so UIScale pivots from middle.
			local listParent = shell.Parent :: GuiObject
			local savedSize = shell.Size
			local savedOrder = shell.LayoutOrder
			local savedAp = shell.AnchorPoint
			local savedPos = shell.Position
			local holder = Instance.new("Frame")
			holder.Name = "_OceanTD_AddMaxPressHolder"
			holder.BackgroundTransparency = 1
			holder.BorderSizePixel = 0
			holder.ClipsDescendants = false
			holder.Size = savedSize
			holder.LayoutOrder = savedOrder
			holder.Parent = listParent
			shell.Parent = holder
			shell.AnchorPoint = Vector2.new(0.5, 0.5)
			shell.Position = UDim2.fromScale(0.5, 0.5)
			shell.Size = UDim2.fromScale(1, 1)
			local scale = shell:FindFirstChild("_OceanTD_AddMaxPressScale") :: UIScale?
			if not scale then
				scale = Instance.new("UIScale")
				scale.Name = "_OceanTD_AddMaxPressScale"
				scale.Parent = shell
			end
			scale.Scale = 1
			local twGrow = TweenService:Create(
				scale,
				TweenInfo.new(0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 2 }
			)
			local twPress = TweenService:Create(
				scale,
				TweenInfo.new(0.24, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Scale = 0.52 }
			)
			local twSettle = TweenService:Create(
				scale,
				TweenInfo.new(0.36, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }
			)
			twGrow:Play()
			twGrow.Completed:Wait()
			if scale.Parent then
				playAddMaxPressTick()
				twPress:Play()
				twPress.Completed:Wait()
			end
			if scale.Parent then
				twSettle:Play()
				twSettle.Completed:Wait()
			end
			if scale and scale.Parent then
				scale.Scale = 1
			end
			if shell.Parent then
				shell.Parent = listParent
				shell.Size = savedSize
				shell.LayoutOrder = savedOrder
				shell.AnchorPoint = savedAp
				shell.Position = savedPos
			end
			if holder.Parent then
				holder:Destroy()
			end
		end,
	})
end

return JoinIntroBackpackUi
