--[[----------------------------------------------------------------------------
GeoFixMenuItem.lua

Library > Plug-in Extras > GeoFix: Copy GPS from nearest photo in time...

Flow:
  1. Settings dialog (time window, clock offset, options).
  2. Read metadata for the target photos and the donor pool.
  3. Compute the plan with GeoFixCore.
  4. Show a summary, or (in test mode) both photos side by side.
  5. On confirmation write the coordinates in one undoable step.

Targets:  the selected photos; if 0 or 1 photo is selected, every photo in the
          current filmstrip (i.e. the folder / collection being viewed).
Donors:   every photo in the active source(s) (folder, collection, ...), plus
          the targets themselves. Only photos with GPS and a capture time qualify.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local GeoFixCore = require 'GeoFixCore'
local GeoFixPrefs = require 'GeoFixPrefs'
local GeoFixReview = require 'GeoFixReview'
local logger = require 'GeoFixLogger'

local bind = LrView.bind

local UNIT_ITEMS = {
	{ title = 'seconds', value = 1 },
	{ title = 'minutes', value = 60 },
	{ title = 'hours', value = 3600 },
}

local META_KEYS = {
	'fileName', 'gps', 'gpsAltitude',
	'dateTimeOriginal', 'dateTimeDigitized', 'dateTime',
}

local MAX_DETAIL_LINES = 40

--------------------------------------------------------------------------------
-- Settings dialog
--------------------------------------------------------------------------------

local function showSettingsDialog(context)
	local props = LrBinding.makePropertyTable(context)
	GeoFixPrefs.applyTo(props)

	local f = LrView.osFactory()
	local labelWidth = LrView.share('geofix_label')

	local contents = f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),

		f:static_text {
			title = 'Photos without GPS coordinates will receive the coordinates of the geotagged photo '
				.. 'that is closest in capture time, as long as the difference is within the window below.',
			width_in_chars = 80,
			height_in_lines = 2,
		},

		f:spacer { height = 4 },

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Max time difference:', alignment = 'right', width = labelWidth },
			f:edit_field {
				value = bind 'maxDeltaValue',
				min = 0, max = 1000000, precision = 0,
				width_in_chars = 7,
				immediate = true,
			},
			f:popup_menu { value = bind 'maxDeltaUnit', items = UNIT_ITEMS },
		},

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Camera clock offset (s):', alignment = 'right', width = labelWidth },
			f:edit_field {
				value = bind 'clockOffsetSeconds',
				min = -604800, max = 604800, precision = 0,
				width_in_chars = 7,
				immediate = true,
			},
			f:static_text {
				title = 'Added to the untagged photo\'s time before matching. '
					.. 'E.g. the camera clock runs 90 s behind the phone: enter 90.',
				width_in_chars = 55,
				height_in_lines = 2,
			},
		},

		f:spacer { height = 4 },

		f:checkbox { title = 'Copy altitude too (when the donor has one)', value = bind 'copyAltitude' },
		f:checkbox { title = 'Look for donors in subfolders of the current folder', value = bind 'includeSubfolders' },
		f:checkbox { title = 'Select the updated photos when done', value = bind 'selectUpdated' },
		f:checkbox {
			title = 'Test mode: show both photos side by side and confirm each match',
			value = bind 'testMode',
		},
		f:checkbox { title = 'Dry run (analyze and report, do not change anything)', value = bind 'dryRun' },
	}

	local result = LrDialogs.presentModalDialog {
		title = 'GeoFix: Copy GPS from nearest photo in time',
		contents = contents,
		actionVerb = 'Analyze',
	}
	if result ~= 'ok' then return nil end

	GeoFixPrefs.saveFrom(props)

	local value = tonumber(props.maxDeltaValue) or 0
	local unit = tonumber(props.maxDeltaUnit) or 1
	return {
		maxDeltaSeconds = value * unit,
		clockOffsetSeconds = tonumber(props.clockOffsetSeconds) or 0,
		copyAltitude = props.copyAltitude and true or false,
		includeSubfolders = props.includeSubfolders and true or false,
		selectUpdated = props.selectUpdated and true or false,
		testMode = props.testMode and true or false,
		dryRun = props.dryRun and true or false,
	}
end

--------------------------------------------------------------------------------
-- Photo collection
--------------------------------------------------------------------------------

local function collectDonorPool(catalog, targets, includeSubfolders)
	local seen, pool = {}, {}
	local function add(photo)
		local id = photo.localIdentifier
		if not seen[id] then
			seen[id] = true
			pool[#pool + 1] = photo
		end
	end

	for _, photo in ipairs(targets) do add(photo) end

	local ok, sources = pcall(function() return catalog:getActiveSources() end)
	if ok and type(sources) == 'table' then
		for _, source in ipairs(sources) do
			-- LrFolder:getPhotos(includeChildren) / LrCollection:getPhotos().
			-- Special sources (strings such as "All Photographs") have no getPhotos; ignore them.
			local okPhotos, photos = pcall(function() return source:getPhotos(includeSubfolders) end)
			if okPhotos and type(photos) == 'table' then
				for _, photo in ipairs(photos) do add(photo) end
			end
		end
	end

	return pool
end

local function toRecords(catalog, photos)
	local meta = catalog:batchGetRawMetadata(photos, META_KEYS)
	local records = {}
	for _, photo in ipairs(photos) do
		local m = meta[photo] or {}
		records[#records + 1] = {
			id = photo.localIdentifier,
			photo = photo,
			name = m.fileName or ('#' .. tostring(photo.localIdentifier)),
			time = m.dateTimeOriginal or m.dateTimeDigitized or m.dateTime,
			gps = m.gps,
			altitude = m.gpsAltitude,
		}
	end
	return records
end

--------------------------------------------------------------------------------
-- Summary dialog
--------------------------------------------------------------------------------

local function buildDetails(plan)
	local lines = {}
	for i, m in ipairs(plan.matches) do
		if i > MAX_DETAIL_LINES then
			lines[#lines + 1] = string.format('... and %d more', #plan.matches - MAX_DETAIL_LINES)
			break
		end
		local sign = m.signedDelta < 0 and '-' or '+'
		lines[#lines + 1] = string.format('%s  <-  %s  (%s%s)',
			m.target.name, m.donor.name, sign, GeoFixCore.formatDuration(m.delta))
	end
	return table.concat(lines, '\n')
end

local function showSummaryDialog(plan, settings, targetCount)
	local f = LrView.osFactory()

	local summary = {}
	summary[#summary + 1] = string.format('%d photo(s) analyzed, %d geotagged donor(s) available.',
		targetCount, plan.donorCount)
	summary[#summary + 1] = string.format('%d photo(s) will receive coordinates.', #plan.matches)
	if plan.stats then
		summary[#summary + 1] = string.format('   time difference: avg %s, max %s',
			GeoFixCore.formatDuration(plan.stats.avgDelta), GeoFixCore.formatDuration(plan.stats.maxDelta))
	end
	summary[#summary + 1] = string.format('%d already had coordinates.', #plan.alreadyTagged)
	summary[#summary + 1] = string.format('%d had no geotagged photo within %s.',
		#plan.tooFar, GeoFixCore.formatDuration(settings.maxDeltaSeconds))
	if #plan.noTimestamp > 0 then
		summary[#summary + 1] = string.format('%d had no capture time and were skipped.', #plan.noTimestamp)
	end

	local rows = {
		spacing = f:control_spacing(),
		f:static_text {
			title = table.concat(summary, '\n'),
			width_in_chars = 80,
			height_in_lines = #summary,
		},
	}

	if #plan.matches > 0 then
		rows[#rows + 1] = f:separator { fill_horizontal = 1 }
		rows[#rows + 1] = f:static_text { title = 'target  <-  donor  (donor time relative to target)', font = '<system/small/bold>' }
		rows[#rows + 1] = f:scrolled_view {
			width = 640,
			height = 260,
			f:static_text {
				title = buildDetails(plan),
				width_in_chars = 100,
				height_in_lines = math.min(#plan.matches, MAX_DETAIL_LINES + 1),
				font = '<system/small>',
			},
		}
	end

	local canApply = (#plan.matches > 0) and not settings.dryRun
	local result = LrDialogs.presentModalDialog {
		title = settings.dryRun and 'GeoFix: Dry run result' or 'GeoFix: Review changes',
		contents = f:column(rows),
		actionVerb = canApply and string.format('Apply to %d photo(s)', #plan.matches) or 'Close',
		cancelVerb = canApply and 'Cancel' or '< exclude >',
	}
	return canApply and result == 'ok'
end

--------------------------------------------------------------------------------
-- Apply
--------------------------------------------------------------------------------

local function applyPlan(catalog, plan, settings, context)
	local progress = LrProgressScope {
		title = 'GeoFix: writing GPS coordinates',
		functionContext = context,
	}
	progress:setCancelable(true)

	local updated = {}
	local total = #plan.matches

	local status = catalog:withWriteAccessDo('GeoFix: copy GPS from nearest photo', function()
		for i, m in ipairs(plan.matches) do
			if progress:isCanceled() then break end
			local photo = m.target.photo
			photo:setRawMetadata('gps', {
				latitude = m.donor.gps.latitude,
				longitude = m.donor.gps.longitude,
			})
			if settings.copyAltitude and type(m.donor.altitude) == 'number' then
				photo:setRawMetadata('gpsAltitude', m.donor.altitude)
			end
			updated[#updated + 1] = photo
			progress:setPortionComplete(i, total)
			progress:setCaption(string.format('%d / %d', i, total))
		end
	end, { timeout = 60 })

	progress:done()

	if status ~= 'executed' then
		logger:warn('withWriteAccessDo returned ' .. tostring(status))
		LrDialogs.message('GeoFix',
			'Lightroom could not get write access to the catalog (' .. tostring(status) .. '). '
				.. 'No changes were made. Try again when no other operation is running.',
			'critical')
		return
	end

	logger:info(string.format('updated %d photo(s)', #updated))

	if settings.selectUpdated and #updated > 0 then
		pcall(function() catalog:setSelectedPhotos(updated[1], updated) end)
	end

	local msg = string.format('GPS coordinates were copied to %d photo(s).', #updated)
	if progress:isCanceled() then
		msg = msg .. ' (canceled before finishing)'
	end
	msg = msg .. '\n\nNote: the coordinates live in the catalog. Use Metadata > Save Metadata to File '
		.. 'if you want them written to the files / XMP sidecars.'
	LrDialogs.message('GeoFix', msg, 'info')
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local function main(context)
	local settings = showSettingsDialog(context)
	if not settings then return end

	local catalog = LrApplication.activeCatalog()

	local targets = catalog:getMultipleSelectedOrAllPhotos()
	if not targets or #targets == 0 then
		LrDialogs.message('GeoFix', 'There are no photos to analyze in the current view.', 'info')
		return
	end

	local progress = LrProgressScope {
		title = 'GeoFix: reading photo metadata',
		functionContext = context,
	}
	progress:setCancelable(true)

	progress:setCaption('Collecting photos...')
	local pool = collectDonorPool(catalog, targets, settings.includeSubfolders)
	logger:info(string.format('targets=%d pool=%d maxDelta=%ds offset=%ds',
		#targets, #pool, settings.maxDeltaSeconds, settings.clockOffsetSeconds))

	if progress:isCanceled() then progress:done() return end

	progress:setCaption(string.format('Reading metadata for %d photos...', #pool))
	local poolRecords = toRecords(catalog, pool)

	-- Targets are a subset of the pool; reuse the same record objects.
	local byId = {}
	for _, r in ipairs(poolRecords) do byId[r.id] = r end
	local targetRecords = {}
	for _, photo in ipairs(targets) do
		targetRecords[#targetRecords + 1] = byId[photo.localIdentifier]
	end

	progress:setCaption('Matching...')
	local plan = GeoFixCore.plan(targetRecords, poolRecords, {
		maxDeltaSeconds = settings.maxDeltaSeconds,
		clockOffsetSeconds = settings.clockOffsetSeconds,
	})
	progress:done()

	logger:info(string.format('plan: matches=%d tooFar=%d noTime=%d tagged=%d donors=%d',
		#plan.matches, #plan.tooFar, #plan.noTimestamp, #plan.alreadyTagged, plan.donorCount))

	if plan.donorCount == 0 then
		LrDialogs.message('GeoFix',
			'None of the photos in the current source has GPS coordinates, so there is nothing to copy from.\n\n'
				.. 'Make sure the geotagged photos (e.g. from your phone) are in the same folder or collection, '
				.. 'or enable "Look for donors in subfolders".',
			'info')
		return
	end

	local apply
	if settings.testMode and #plan.matches > 0 then
		apply = GeoFixReview.show(context, plan, settings)
	else
		apply = showSummaryDialog(plan, settings, #targetRecords)
	end
	if apply then
		applyPlan(catalog, plan, settings, context)
	end
end

LrTasks.startAsyncTask(function()
	LrFunctionContext.callWithContext('GeoFixMenuItem', function(context)
		context:addFailureHandler(function(_status, message)
			logger:error('failure: ' .. tostring(message))
			LrDialogs.message('GeoFix: error', tostring(message), 'critical')
		end)
		main(context)
	end)
end)
