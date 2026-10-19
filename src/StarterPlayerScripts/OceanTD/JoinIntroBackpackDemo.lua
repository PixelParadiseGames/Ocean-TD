--!strict
--[[
	Join-intro backpack showcase: InventoryUI binds handlers; JoinIntro drives begin/end/scroll.
]]

local JoinIntroBackpackDemo = {}

export type Handlers = {
	begin: (scrollSec: number) -> boolean,
	finish: () -> (),
	-- Shrink panel into BUILD (top-right) then hide — after ADD MAX orbs finish firing.
	collapseAway: (() -> ())?,
	-- BUILD only (no Auto Plant / lock): 2× → 1× over durationSec, backpack still closed.
	previewBuildBeforeOpen: ((durationSec: number, cancelled: (() -> boolean)?) -> ())?,
	speciesBottomToTop: () -> { string },
	slotScreenCenter: (itemId: string) -> Vector2?,
	setScrollProgress: (u: number) -> (),
	-- ADD MAX button: screen center + shrink/grow press for intro demo.
	addMaxScreenCenter: () -> Vector2?,
	playAddMaxPress: () -> (),
}

local handlers: Handlers? = nil

function JoinIntroBackpackDemo.bind(h: Handlers)
	handlers = h
end

function JoinIntroBackpackDemo.begin(scrollSec: number): boolean
	if not handlers then
		return false
	end
	return handlers.begin(scrollSec)
end

function JoinIntroBackpackDemo.previewBuildBeforeOpen(durationSec: number, cancelled: (() -> boolean)?)
	if handlers and handlers.previewBuildBeforeOpen then
		handlers.previewBuildBeforeOpen(durationSec, cancelled)
	end
end

function JoinIntroBackpackDemo.finish()
	if handlers then
		handlers.finish()
	end
end

function JoinIntroBackpackDemo.collapseAway()
	if handlers and handlers.collapseAway then
		handlers.collapseAway()
	end
end

function JoinIntroBackpackDemo.speciesBottomToTop(): { string }
	if not handlers then
		return {}
	end
	return handlers.speciesBottomToTop()
end

function JoinIntroBackpackDemo.slotScreenCenter(itemId: string): Vector2?
	if not handlers then
		return nil
	end
	return handlers.slotScreenCenter(itemId)
end

function JoinIntroBackpackDemo.setScrollProgress(u: number)
	if handlers then
		handlers.setScrollProgress(u)
	end
end

function JoinIntroBackpackDemo.addMaxScreenCenter(): Vector2?
	if not handlers then
		return nil
	end
	return handlers.addMaxScreenCenter()
end

function JoinIntroBackpackDemo.playAddMaxPress()
	if handlers then
		handlers.playAddMaxPress()
	end
end

function JoinIntroBackpackDemo.isBound(): boolean
	return handlers ~= nil
end

return JoinIntroBackpackDemo
