--!strict
-- Session gate: autosave / leave-save only after layoutLoaded.
-- plotOp mutex: clear / save / load / recycle cannot overlap.

local PlayerSession = {}

export type PlotOp = "idle" | "clearing" | "saving" | "loading" | "recycling"

export type Session = {
	userId: number,
	layoutLoaded: boolean,
	plotId: string?,
	saving: boolean,
	plotLoading: boolean,
	plotOp: PlotOp,
	tutorialFreeCoralSize: boolean,
}

local sessions: { [Player]: Session } = {}

function PlayerSession.get(player: Player): Session?
	return sessions[player]
end

function PlayerSession.begin(player: Player): Session
	local session: Session = {
		userId = player.UserId,
		layoutLoaded = false,
		plotId = nil,
		saving = false,
		plotLoading = false,
		plotOp = "idle",
		tutorialFreeCoralSize = false,
	}
	sessions[player] = session
	return session
end

function PlayerSession.grantTutorialFreeCoralSize(player: Player)
	local session = sessions[player]
	if session then
		session.tutorialFreeCoralSize = true
	end
end

-- Returns true once; subsequent calls false (consumed).
function PlayerSession.consumeTutorialFreeCoralSize(player: Player): boolean
	local session = sessions[player]
	if not session or not session.tutorialFreeCoralSize then
		return false
	end
	session.tutorialFreeCoralSize = false
	return true
end

function PlayerSession.markReady(player: Player, plotId: string)
	local session = sessions[player]
	if not session then
		return
	end
	session.layoutLoaded = true
	session.plotId = plotId
end

function PlayerSession.getPlotOp(player: Player): PlotOp
	local session = sessions[player]
	if not session then
		return "idle"
	end
	return session.plotOp
end

-- Acquire exclusive plot op. Only succeeds from idle (+ layout ready).
function PlayerSession.tryBeginPlotOp(player: Player, op: PlotOp): boolean
	if op == "idle" then
		return false
	end
	local session = sessions[player]
	if not session or session.layoutLoaded ~= true then
		return false
	end
	if session.plotOp ~= "idle" or session.saving == true or session.plotLoading == true then
		return false
	end
	session.plotOp = op
	if op == "saving" then
		session.saving = true
	elseif op == "loading" then
		session.plotLoading = true
	end
	return true
end

function PlayerSession.endPlotOp(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	session.plotOp = "idle"
	session.saving = false
	session.plotLoading = false
end

-- Autosave / place / move: only when no plot op is in flight.
function PlayerSession.canSave(player: Player): boolean
	local session = sessions[player]
	return session ~= nil
		and session.layoutLoaded == true
		and session.plotOp == "idle"
		and session.saving ~= true
		and session.plotLoading ~= true
end

-- Mutations while holding clear/load/recycle lock (or idle for legacy callers).
function PlayerSession.canMutatePlot(player: Player): boolean
	local session = sessions[player]
	if not session or session.layoutLoaded ~= true then
		return false
	end
	local op = session.plotOp
	return op == "idle" or op == "loading" or op == "clearing" or op == "recycling"
end

function PlayerSession.setPlotLoading(player: Player, loading: boolean)
	local session = sessions[player]
	if session then
		session.plotLoading = loading
	end
end

function PlayerSession.isPlotLoading(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and (session.plotLoading == true or session.plotOp == "loading")
end

function PlayerSession.setSaving(player: Player, saving: boolean)
	local session = sessions[player]
	if session then
		session.saving = saving
	end
end

function PlayerSession.remove(player: Player)
	sessions[player] = nil
end

return PlayerSession
