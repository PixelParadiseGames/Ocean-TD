--!strict
-- Session gate: autosave / leave-save only after layoutLoaded.

local PlayerSession = {}

export type Session = {
	userId: number,
	layoutLoaded: boolean,
	plotId: string?,
	saving: boolean,
	plotLoading: boolean,
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
	}
	sessions[player] = session
	return session
end

function PlayerSession.markReady(player: Player, plotId: string)
	local session = sessions[player]
	if not session then
		return
	end
	session.layoutLoaded = true
	session.plotId = plotId
end

function PlayerSession.canSave(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and session.layoutLoaded == true and session.saving ~= true and session.plotLoading ~= true
end

-- Server plot mutations (slot load apply) while plotLoading blocks client saves.
function PlayerSession.canMutatePlot(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and session.layoutLoaded == true and session.saving ~= true
end

function PlayerSession.setPlotLoading(player: Player, loading: boolean)
	local session = sessions[player]
	if session then
		session.plotLoading = loading
	end
end

function PlayerSession.isPlotLoading(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and session.plotLoading == true
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
