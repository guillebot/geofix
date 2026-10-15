--[[----------------------------------------------------------------------------
GeoFixPrefs.lua

Persisted user settings (stored by Lightroom per plug-in).
------------------------------------------------------------------------------]]

local LrPrefs = import 'LrPrefs'

local GeoFixPrefs = {}

GeoFixPrefs.DEFAULTS = {
	-- Max time difference = maxDeltaValue * maxDeltaUnit seconds.
	-- This is the nearest-photo fallback window, not the interpolation gap.
	maxDeltaValue = 10,
	maxDeltaUnit = 60,          -- 1 = seconds, 60 = minutes, 3600 = hours
	-- Seconds added to the untagged photo's capture time before matching.
	clockOffsetSeconds = 0,
	copyAltitude = true,
	-- tree = root folder and every subfolder, one project.
	-- folder = the selected folder only. selection = the current selection.
	scope = 'tree',
	interpolate = true,
	maxInterpValue = 2,
	maxInterpUnit = 3600,
	maxSpeedKmh = 250,
	writeReport = false,
	selectUpdated = true,
	testMode = false,
	dryRun = false,
}

local KEYS = {
	'maxDeltaValue', 'maxDeltaUnit', 'clockOffsetSeconds',
	'copyAltitude', 'scope', 'interpolate', 'maxInterpValue', 'maxInterpUnit',
	'maxSpeedKmh', 'writeReport', 'selectUpdated', 'testMode', 'dryRun',
}

local function prefs()
	return LrPrefs.prefsForPlugin()
end

local function validScope(value)
	return value == 'tree' or value == 'folder' or value == 'selection'
end

--- Copies stored settings (or defaults) into a property table used by the UI.
function GeoFixPrefs.applyTo(props)
	local p = prefs()
	for _, key in ipairs(KEYS) do
		local v = p[key]
		if v == nil then v = GeoFixPrefs.DEFAULTS[key] end
		if key == 'scope' and not validScope(v) then
			v = GeoFixPrefs.DEFAULTS.scope
		end
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
