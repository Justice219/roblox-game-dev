--!strict
-- StudTextureConfig — retry budget of Widgets/StudTexture's uploaded-image fallback (ported from
-- RoBeasts). Only used when the client cannot build the local EditableImage stud tile.
-- One initial fetch plus three delayed retries. Only a later panel-open/bind refresh can
-- rearm after cooldown, keeping an extended outage bounded without stranding the session.
return table.freeze({
	MaxAttempts = 4,
	RetrySeconds = table.freeze({ 1, 3, 10 }),
	RearmSeconds = 60,
})
