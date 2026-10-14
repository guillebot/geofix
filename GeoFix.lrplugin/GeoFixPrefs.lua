--[[----------------------------------------------------------------------------
GeoFixPrefs.lua

Persisted user settings (stored by Lightroom per plug-in).
------------------------------------------------------------------------------]]

local LrPrefs = import 'LrPrefs'

local GeoFixPrefs = {}

GeoFixPrefs.DEFAULTS = {
	-- Max time difference = maxDeltaValue * maxDeltaUnit seconds.
	maxDeltaValue = 10,
	maxDeltaUnit = 60,          -- 1 = seconds, 60 = minutes, 3600 = hours
	-- Seconds added to the untagged photo's capture time before matching.
	clockOffsetSeconds = 0,
	copyAltitude = true,
	includeSubfolders = false,
	selectUpdated = true,
	testMode = false,
	dryRun = false,
}

local KEYS = {
	'maxDeltaValue', 'maxDeltaUnit', 'clockOffsetSeconds',
	'copyAltitude', 'includeSubfolders', 'selectUpdated', 'testMode', 'dryRun',
}

local function prefs()
	return LrPrefs.prefsForPlugin()
end

--- Copies stored settings (or defaults) into a property table used by the UI.
function GeoFixPrefs.applyTo(props)
	local p = prefs()
	for _, key in ipairs(KEYS) do
		local v = p[key]
		if v == nil then v = GeoFixPrefs.DEFAULTS[key] end
		props[key] = v
	end
end

--- Stores the values from a UI property table.
function GeoFixPrefs.saveFrom(props)
	local p = prefs()
	for _, key in ipairs(KEYS) do
		p[key] = props[key]
	end
end

--- Resets stored settings to defaults.
function GeoFixPrefs.reset()
	local p = prefs()
	for _, key in ipairs(KEYS) do
		p[key] = GeoFixPrefs.DEFAULTS[key]
	end
end

return GeoFixPrefs
