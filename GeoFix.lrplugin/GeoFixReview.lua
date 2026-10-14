--[[----------------------------------------------------------------------------
GeoFixReview.lua

Test mode. Steps through each proposed match and shows the untagged photo next
to the geotagged donor so the pair can be checked by eye.

Previews come from LrPhoto:requestJpegThumbnail. The bound file path is what
the picture view actually displays, and it refreshes as you move between pairs.
f:catalog_photo does not reliably repaint when its photo changes.

On confirm, plan.matches is replaced with the pairs still checked. Returns
true only when there is something to write.
------------------------------------------------------------------------------]]

local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local GeoFixCore = require 'GeoFixCore'
local logger = require 'GeoFixLogger'

local bind = LrView.bind

local THUMB_W, THUMB_H = 400, 280
local REQUEST_W, REQUEST_H = 800, 560
local PLACEHOLDER = LrPathUtils.child(_PLUGIN.path, 'placeholder.png')

local GeoFixReview = {}

local function formatTime(t)
	if type(t) ~= 'number' then return 'unknown time' end
	local ok, formatted = pcall(LrDate.timeToUserFormat, t, '%Y-%m-%d %H:%M:%S')
	if ok and type(formatted) == 'string' then return formatted end
	return tostring(t)
end

local function formatGps(record)
	local gps = record.gps
	if type(gps) ~= 'table' or type(gps.latitude) ~= 'number' or type(gps.longitude) ~= 'number' then
		return 'no GPS'
	end
	local text = string.format('%.5f, %.5f', gps.latitude, gps.longitude)
	if type(record.altitude) == 'number' then
		text = text .. string.format('    %.0f m', record.altitude)
	end
	return text
end

local function deltaText(match, offset)
	local relation
	if match.delta == 0 then
		relation = 'Same capture time'
	elseif match.signedDelta < 0 then
		relation = 'Donor is ' .. GeoFixCore.formatDuration(match.delta) .. ' earlier'
	else
		relation = 'Donor is ' .. GeoFixCore.formatDuration(match.delta) .. ' later'
	end
	if offset ~= 0 then
		relation = string.format('%s   (clock offset %+d s applied to the untagged photo)', relation, offset)
	end
	return relation
end

local function photoColumn(f, heading, pathKey, statusKey, nameKey, metaKey)
	return f:column {
		spacing = f:control_spacing(),
		width = THUMB_W,

		f:static_text { title = heading, font = '<system/bold>' },

		f:picture {
			value = bind(pathKey),
			width = THUMB_W,
			height = THUMB_H,
			frame_width = 1,
		},

		f:static_text {
			title = bind(statusKey),
			width = THUMB_W,
			font = '<system/small>',
		},

		f:static_text {
			title = bind(nameKey),
			width = THUMB_W,
			height_in_lines = 2,
			font = '<system/small/bold>',
		},

		f:static_text {
			title = bind(metaKey),
			width = THUMB_W,
			height_in_lines = 2,
			font = '<system/small>',
		},
	}
end

--- Presents the side-by-side review. May shrink plan.matches to the accepted pairs.
-- @return true when the user confirmed and at least one pair should be written
function GeoFixReview.show(context, plan, settings)
	local matches = plan.matches
	local matchCount = #matches
	local offset = tonumber(settings.clockOffsetSeconds) or 0

	local included = {}
	for i = 1, matchCount do included[i] = true end

	local props = LrBinding.makePropertyTable(context)
	props.index = 1
	props.include = true
	props.targetPath = PLACEHOLDER
	props.donorPath = PLACEHOLDER
	props.targetStatus = ' '
	props.donorStatus = ' '
	props.targetName = ''
	props.donorName = ''
	props.targetMeta = ''
	props.donorMeta = ''
	props.positionLabel = ''
	props.deltaLabel = ''
	props.selectedLabel = string.format('%d of %d selected', matchCount, matchCount)

	local tokens = { target = 0, donor = 0 }
	local suppress = false

	local function selectedCount()
		local n = 0
		for i = 1, matchCount do
			if included[i] then n = n + 1 end
		end
		return n
	end

	local function refreshSelectedLabel()
		props.selectedLabel = string.format('%d of %d selected', selectedCount(), matchCount)
	end

	props:addObserver('include', function()
		if suppress then return end
		included[props.index] = props.include and true or false
		refreshSelectedLabel()
	end)

	-- The callback is delivered on the task scheduler. Sleeping until it arrives
	-- (here, and inside the dialog button actions) is what lets the preview
	-- paint before the user looks at the pair.
	local function beginThumb(which, photo)
		tokens[which] = tokens[which] + 1
		local mine = tokens[which]
		local state = { done = false }
		props[which .. 'Path'] = PLACEHOLDER
		props[which .. 'Status'] = 'Loading preview...'
		photo:requestJpegThumbnail(REQUEST_W, REQUEST_H, function(path, err)
			if tokens[which] == mine then
				if type(path) == 'string' and path ~= '' then
					props[which .. 'Path'] = path
					props[which .. 'Status'] = ' '
				else
					props[which .. 'Path'] = PLACEHOLDER
					props[which .. 'Status'] = 'Preview unavailable'
					logger:warn(string.format('thumbnail failed (%s): %s', which, tostring(err)))
				end
			end
			state.done = true
		end)
		return state
	end

	local function waitForThumbs(states)
		local waits = 0
		while waits < 100 do
			local pending = false
			for _, state in ipairs(states) do
				if not state.done then pending = true end
			end
			if not pending then return end
			LrTasks.sleep(0.05)
			waits = waits + 1
		end
		logger:warn('thumbnail request timed out')
	end

	local function showAt(i)
		local match = matches[i]
		props.index = i
		props.positionLabel = string.format('%d  /  %d', i, matchCount)
		props.targetName = match.target.name
		props.donorName = match.donor.name
		props.targetMeta = formatTime(match.target.time) .. '\nno GPS'
		props.donorMeta = formatTime(match.donor.time) .. '\n' .. formatGps(match.donor)
		props.deltaLabel = deltaText(match, offset)
		suppress = true
		props.include = included[i] and true or false
		suppress = false
		local thumbs = {
			target = beginThumb('target', match.target.photo),
			donor = beginThumb('donor', match.donor.photo),
		}
		waitForThumbs({ thumbs.target, thumbs.donor })
		if not thumbs.target.done then props.targetStatus = 'Preview timed out' end
		if not thumbs.donor.done then props.donorStatus = 'Preview timed out' end
	end

	local summary = string.format(
		'%d match(es) within %s.    %d already had GPS, %d outside the window, %d without a capture time.',
		matchCount,
		GeoFixCore.formatDuration(settings.maxDeltaSeconds),
		#plan.alreadyTagged,
		#plan.tooFar,
		#plan.noTimestamp)

	local hint = settings.dryRun
		and 'Dry run: look through the pairs. Nothing will be written.'
		or 'Uncheck a match, or skip it, to leave that photo unchanged.'

	local f = LrView.osFactory()

	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),

		f:static_text {
			title = summary,
			width = THUMB_W * 2 + 24,
			height_in_lines = 2,
		},

		f:static_text { title = hint, font = '<system/small>' },

		f:separator { fill_horizontal = 1 },

		f:row {
			spacing = f:control_spacing(),
			f:static_text { title = bind 'positionLabel', width_in_chars = 14, font = '<system/bold>' },
			f:checkbox { title = 'Apply this match', value = bind 'include' },
			f:spacer { fill_horizontal = 1 },
			f:static_text { title = bind 'selectedLabel' },
		},

		f:row {
			spacing = f:control_spacing() * 2,
			photoColumn(f, 'Without GPS  (will receive coordinates)', 'targetPath', 'targetStatus', 'targetName', 'targetMeta'),
			photoColumn(f, 'Geotagged photo  (donor)', 'donorPath', 'donorStatus', 'donorName', 'donorMeta'),
		},

		f:static_text { title = bind 'deltaLabel', font = '<system/bold>' },

		f:row {
			spacing = f:control_spacing(),
			f:push_button {
				title = 'Previous',
				enabled = bind {
					key = 'index',
					transform = function(value)
						return (tonumber(value) or 1) > 1
					end,
				},
				action = function()
					if props.index > 1 then showAt(props.index - 1) end
				end,
			},
			f:push_button {
				title = 'Next',
				enabled = bind {
					key = 'index',
					transform = function(value)
						return (tonumber(value) or 1) < matchCount
					end,
				},
				action = function()
					if props.index < matchCount then showAt(props.index + 1) end
				end,
			},
			f:push_button {
				title = 'Skip this match',
				action = function()
					included[props.index] = false
					suppress = true
					props.include = false
					suppress = false
					refreshSelectedLabel()
					if props.index < matchCount then showAt(props.index + 1) end
				end,
			},
		},
	}

	showAt(1)

	local canApply = not settings.dryRun
	local result = LrDialogs.presentModalDialog {
		title = canApply and 'GeoFix: Verify matches' or 'GeoFix: Verify matches (dry run)',
		contents = contents,
		actionVerb = canApply and 'Apply selected' or 'Close',
		cancelVerb = canApply and 'Cancel' or '< exclude >',
	}

	if not canApply or result ~= 'ok' then return false end

	local kept = {}
	for i, match in ipairs(matches) do
		if included[i] then kept[#kept + 1] = match end
	end

	logger:info(string.format('test mode kept %d of %d match(es)', #kept, matchCount))

	if #kept == 0 then
		LrDialogs.message('GeoFix', 'Every match was skipped, so nothing was changed.', 'info')
		return false
	end

	plan.matches = kept
	return true
end

return GeoFixReview
