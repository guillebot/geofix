--[[----------------------------------------------------------------------------
GeoFixReview.lua

Test mode. Steps through each proposed match and shows the untagged photo next
to the geotagged donor so the pair can be checked by eye.

Previews are f:catalog_photo bound to the LrPhoto already in the library
(targetPhoto / donorPhoto). Lightroom paints the library preview, so this does
not call requestJpegThumbnail. Encoding a Canon R6 RAW at 800x560 often takes
longer than a few seconds, and the callback is not delivered if the requesting
task stops yielding or if the callback itself yields.

catalog_photo ignores an in-place change of the bound photo. Each index change
clears the property and then sets the LrPhoto again, from a task, after the
dialog is on screen.

On confirm, plan.matches is replaced with the pairs still checked. Returns
true only when there is something to write.
------------------------------------------------------------------------------]]

local LrBinding = import 'LrBinding'
local LrDate = import 'LrDate'
local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local GeoFixCore = require 'GeoFixCore'
local logger = require 'GeoFixLogger'

local bind = LrView.bind

local THUMB_W, THUMB_H = 400, 280

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

local function photoColumn(f, heading, photoKey, statusKey, nameKey, metaKey)
	return f:column {
		spacing = f:control_spacing(),
		width = THUMB_W,

		f:static_text {
			title = heading,
			font = '<system/bold>',
			width = THUMB_W,
			height_in_lines = 2,
		},

		f:catalog_photo {
			photo = bind(photoKey),
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
	props.targetPhoto = nil
	props.donorPhoto = nil
	props.targetStatus = ' '
	props.donorStatus = ' '
	props.targetName = ''
	props.donorName = ''
	props.targetMeta = ''
	props.donorMeta = ''
	props.positionLabel = ''
	props.deltaLabel = ''
	props.donorHeading = 'Geotagged photo (donor)'
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

	-- catalog_photo keeps the previous image when the bound LrPhoto is replaced
	-- in place. Clear both bindings, yield so the views notice, then set the
	-- photos for this pair. A superseded navigation must not write the pair it
	-- no longer owns. The sleep runs only from a task (button actions and the
	-- first paint start one before calling showAt).
	local function showPhotos(match)
		tokens.target = tokens.target + 1
		tokens.donor = tokens.donor + 1
		local targetMine = tokens.target
		local donorMine = tokens.donor
		props.targetPhoto = nil
		props.donorPhoto = nil
		props.targetStatus = ' '
		props.donorStatus = ' '
		LrTasks.sleep(0.01)
		if tokens.target ~= targetMine or tokens.donor ~= donorMine then return end
		props.targetPhoto = match.target.photo
		props.donorPhoto = match.donor.photo
	end

	local function showAt(i)
		local match = matches[i]
		props.index = i
		props.positionLabel = string.format('%d  /  %d', i, matchCount)
		props.targetName = match.target.name
		props.donorName = match.donor.name
		props.targetMeta = formatTime(match.target.time) .. '\nno GPS'
		props.donorMeta = formatTime(match.donor.time) .. '\n' .. formatGps(match.donor)
		if match.method == 'interpolated' then
			props.donorHeading = 'Closer geotagged photo'
		else
			props.donorHeading = 'Geotagged photo (donor)'
		end
		props.deltaLabel = GeoFixCore.deltaLabel(match, offset)
		suppress = true
		props.include = included[i] and true or false
		suppress = false
		showPhotos(match)
	end

	local counts = plan.counts or { interpolated = 0, nearest = 0, exact = 0 }
	local summary = string.format(
		'%d match(es): %d interpolated, %d nearest, %d exact.    %d already had GPS, %d outside the window, %d without a capture time.',
		matchCount,
		counts.interpolated or 0,
		counts.nearest or 0,
		counts.exact or 0,
		#plan.alreadyTagged,
		#plan.tooFar,
		#plan.noTimestamp)

	local hint = settings.dryRun
		and 'Dry run: look through the pairs. Nothing will be written.'
		or 'Uncheck a match, or skip it, to leave that photo unchanged.'
	if (counts.interpolated or 0) > 0 then
		hint = hint .. ' Interpolated matches write a point between the surrounding photos; the photo on the right is only the closer one.'
	end

	local f = LrView.osFactory()

	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),

		f:static_text {
			title = summary,
			width = THUMB_W * 2 + 24,
			height_in_lines = 2,
		},

		f:static_text {
			title = hint,
			font = '<system/small>',
			width = THUMB_W * 2 + 24,
			height_in_lines = 2,
		},

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
			photoColumn(f, 'Without GPS  (will receive coordinates)', 'targetPhoto', 'targetStatus', 'targetName', 'targetMeta'),
			photoColumn(f, bind 'donorHeading', 'donorPhoto', 'donorStatus', 'donorName', 'donorMeta'),
		},

		f:static_text {
			title = bind 'deltaLabel',
			font = '<system/bold>',
			width = THUMB_W * 2 + 24,
			height_in_lines = 4,
		},

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
					if props.index > 1 then
						local target = props.index - 1
						LrTasks.startAsyncTask(function() showAt(target) end)
					end
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
					if props.index < matchCount then
						local target = props.index + 1
						LrTasks.startAsyncTask(function() showAt(target) end)
					end
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
					if props.index < matchCount then
						local target = props.index + 1
						LrTasks.startAsyncTask(function() showAt(target) end)
					end
				end,
			},
		},
	}

	-- This task blocks inside presentModalDialog. The preview task does not run
	-- until that call yields, so the catalog_photo views exist while the photos
	-- are bound. Setting them before the window is shown does not paint.
	LrTasks.startAsyncTask(function()
		LrTasks.sleep(0.05)
		showAt(1)
	end)

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
