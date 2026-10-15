--[[----------------------------------------------------------------------------
GeoFixMenuItem.lua

Library > Plug-in Extras > GeoFix: Fill missing GPS...

Flow:
  1. Settings dialog. Project scope is the first choice.
  2. Read metadata in batches. A large folder tree asks for confirmation first.
  3. Estimate coordinates with GeoFixCore.
  4. Optionally write a CSV report.
  5. Show a summary, or (in test mode) both photos side by side.
  6. On confirmation write the coordinates in one undoable step.

Scope:
  tree      the active folder and every subfolder, as one project. This is the
            default. Targets and donors are the same set of photos.
  folder    photos directly in the active folder. Subfolders are left out.
  selection the current selection. Fewer than two selected photos means the
            whole filmstrip, which includes subfolders only when Lightroom is
            already listing them.

The folder scopes ignore Library filters. They use the folder itself.
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
	'fileName', 'path', 'gps', 'gpsAltitude',
	'dateTimeOriginal', 'dateTimeDigitized', 'dateTime',
}

--------------------------------------------------------------------------------
-- Settings dialog
--------------------------------------------------------------------------------

local function showSettingsDialog(context)
	local props = LrBinding.makePropertyTable(context)
	GeoFixPrefs.applyTo(props)

	local scopeItems = {}
	for _, choice in ipairs(GeoFixCore.scopeChoices()) do
		scopeItems[#scopeItems + 1] = { title = choice.title, value = choice.value }
	end

	local f = LrView.osFactory()
	local labelWidth = LrView.share('geofix_label')

	local contents = f:scrolled_view {
		width = 780,
		height = 520,
		f:column {
		bind_to_object = props,
		spacing = f:control_spacing(),

		f:static_text {
			title = 'Choose the project scope first. Entire folder tree treats the selected root and every subfolder as one project, then fills in the best coordinates available.',
			width_in_chars = 82,
			height_in_lines = 3,
		},

		f:spacer { height = 4 },
		f:static_text { title = 'Project scope', font = '<system/bold>' },

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Scope:', alignment = 'right', width = labelWidth },
			f:popup_menu {
				value = bind 'scope',
				items = scopeItems,
				width_in_chars = 52,
			},
		},

		f:static_text {
			title = bind {
				key = 'scope',
				transform = function(value)
					return GeoFixCore.scopeDetail(value)
				end,
			},
			width_in_chars = 82,
			height_in_lines = 4,
		},

		f:separator { fill_horizontal = 1 },
		f:static_text { title = 'Coordinates', font = '<system/bold>' },

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

		f:checkbox {
			title = 'Interpolate between the geotagged photos before and after (best coordinates)',
			value = bind 'interpolate',
		},

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Interpolation gap:', alignment = 'right', width = labelWidth },
			f:edit_field {
				value = bind 'maxInterpValue',
				min = 0, max = 1000000, precision = 0,
				width_in_chars = 7,
				immediate = true,
				enabled = bind 'interpolate',
			},
			f:popup_menu {
				value = bind 'maxInterpUnit',
				items = UNIT_ITEMS,
				enabled = bind 'interpolate',
			},
		},

		f:row {
			spacing = f:label_spacing(),
			f:static_text { title = 'Max travel speed (km/h):', alignment = 'right', width = labelWidth },
			f:edit_field {
				value = bind 'maxSpeedKmh',
				min = 0, max = 2000, precision = 0,
				width_in_chars = 7,
				immediate = true,
				enabled = bind 'interpolate',
			},
			f:static_text {
				title = 'Both surrounding photos must be inside this gap. '
					.. 'Faster travel falls back to the nearest photo. Raise the speed for trains or flights.',
				width_in_chars = 62,
				height_in_lines = 2,
			},
		},

		f:spacer { height = 4 },

		f:checkbox { title = 'Copy altitude too (when it can be estimated)', value = bind 'copyAltitude' },
		f:checkbox { title = 'Select the updated photos when done', value = bind 'selectUpdated' },
		f:checkbox {
			title = 'Test mode: show both photos side by side and confirm each match',
			value = bind 'testMode',
		},
		f:checkbox { title = 'Dry run (analyze and report, do not change anything)', value = bind 'dryRun' },
		f:checkbox {
			title = 'Save a CSV report (filenames, capture times, and coordinates)',
			value = bind 'writeReport',
		},
		},
	}

	local result = LrDialogs.presentModalDialog {
		title = 'GeoFix: Fill missing GPS',
		contents = contents,
		actionVerb = 'Analyze',
	}
	if result ~= 'ok' then return nil end

	GeoFixPrefs.saveFrom(props)

	local value = tonumber(props.maxDeltaValue) or 0
	local unit = tonumber(props.maxDeltaUnit) or 1
	local interpValue = tonumber(props.maxInterpValue) or 0
	local interpUnit = tonumber(props.maxInterpUnit) or 1
	return {
		maxDeltaSeconds = value * unit,
		clockOffsetSeconds = tonumber(props.clockOffsetSeconds) or 0,
		copyAltitude = props.copyAltitude and true or false,
		scope = GeoFixCore.normalizeScope(props.scope),
		interpolate = props.interpolate and true or false,
		maxInterpolateSeconds = interpValue * interpUnit,
		maxSpeedKmh = tonumber(props.maxSpeedKmh) or GeoFixCore.DEFAULT_MAX_SPEED_KMH,
		writeReport = props.writeReport and true or false,
		selectUpdated = props.selectUpdated and true or false,
		testMode = props.testMode and true or false,
		dryRun = props.dryRun and true or false,
	}
end

--------------------------------------------------------------------------------
-- Photo collection
--------------------------------------------------------------------------------

local function dedupe(photos)
	local seen, out = {}, {}
	for _, photo in ipairs(photos or {}) do
		local id = photo.localIdentifier
		if id == nil then id = photo end
		if not seen[id] then
			seen[id] = true
			out[#out + 1] = photo
		end
	end
	return out
end

local function folderEntries(catalog)
	local entries, seen = {}, {}
	local ok, sources = pcall(function() return catalog:getActiveSources() end)
	if not ok or type(sources) ~= 'table' then return entries end
	for _, source in ipairs(sources) do
		if type(source) ~= 'string' then
			local pathOk, path = pcall(function() return source:getPath() end)
			if pathOk and type(path) == 'string' and path ~= '' and not seen[path] then
				seen[path] = true
				entries[#entries + 1] = { source = source, path = path }
			end
		end
	end
	return entries
end

local function collectProject(catalog, settings)
	if settings.scope == 'selection' then
		local photos = catalog:getMultipleSelectedOrAllPhotos() or {}
		return dedupe(photos), 'Current selection / filmstrip', nil
	end

	local folders = folderEntries(catalog)
	local err = GeoFixCore.singleRootError(#folders, settings.scope)
	if err then return nil, nil, err end

	local folder = folders[1]
	local includeChildren = settings.scope == 'tree'
	local okPhotos, photos = pcall(function()
		return folder.source:getPhotos(includeChildren)
	end)
	if not okPhotos or type(photos) ~= 'table' then
		return nil, nil, 'Lightroom could not list the photos in the selected folder.\n\n' .. tostring(photos)
	end
	return dedupe(photos), folder.path, nil
end

local function toRecords(catalog, photos, progress)
	local records = {}
	local total = #photos
	local chunkSize = GeoFixCore.METADATA_CHUNK_SIZE
	local startAt = 1
	while startAt <= total do
		if progress:isCanceled() then return nil end
		local stopAt = math.min(startAt + chunkSize - 1, total)
		local chunk = {}
		for i = startAt, stopAt do
			chunk[#chunk + 1] = photos[i]
		end
		progress:setPortionComplete(stopAt, total)
		progress:setCaption(string.format('Reading metadata %d / %d', stopAt, total))
		local meta = catalog:batchGetRawMetadata(chunk, META_KEYS)
		if type(meta) ~= 'table' then meta = {} end
		for _, photo in ipairs(chunk) do
			local m = meta[photo] or {}
			records[#records + 1] = {
				id = photo.localIdentifier,
				photo = photo,
				name = m.fileName or ('#' .. tostring(photo.localIdentifier)),
				path = m.path,
				time = m.dateTimeOriginal or m.dateTimeDigitized or m.dateTime,
				gps = m.gps,
				altitude = m.gpsAltitude,
			}
		end
		startAt = stopAt + 1
		if LrTasks.yield then LrTasks.yield() end
		if progress:isCanceled() then return nil end
	end
	return records
end

--------------------------------------------------------------------------------
-- Summary dialog
--------------------------------------------------------------------------------

local function showSummaryDialog(plan, settings, info)
	local f = LrView.osFactory()
	local lines = GeoFixCore.summaryLines(plan, {
		scope = settings.scope,
		source = info.source,
		photoCount = info.photoCount,
		interpolate = settings.interpolate,
		maxInterpolateSeconds = settings.maxInterpolateSeconds,
		maxSpeedKmh = settings.maxSpeedKmh,
		maxDeltaSeconds = settings.maxDeltaSeconds,
		clockOffsetSeconds = settings.clockOffsetSeconds,
		copyAltitude = settings.copyAltitude,
		reportPath = info.reportPath,
		reportSkipped = info.reportSkipped,
	})
	local details = GeoFixCore.detailText(plan)

	local rows = {
		spacing = f:control_spacing(),
		f:scrolled_view {
			width = 720,
			height = 220,
			f:static_text {
				title = table.concat(lines, '\n'),
				width_in_chars = 90,
				height_in_lines = #lines + 6,
			},
		},
	}

	if #plan.matches > 0 then
		local shown = math.min(#plan.matches, GeoFixCore.SUMMARY_DETAIL_LIMIT)
		if #plan.matches > GeoFixCore.SUMMARY_DETAIL_LIMIT then
			shown = shown + 1
		end
		rows[#rows + 1] = f:separator { fill_horizontal = 1 }
		rows[#rows + 1] = f:static_text {
			title = 'target  <-  coordinates or donor',
			font = '<system/small/bold>',
		}
		rows[#rows + 1] = f:scrolled_view {
			width = 720,
			height = 260,
			f:static_text {
				title = details,
				width_in_chars = 110,
				height_in_lines = shown,
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
-- Report and apply
--------------------------------------------------------------------------------

local function saveReport(plan, settings, sourceLabel)
	if not settings.writeReport then return nil, false end
	local selected = LrDialogs.runSavePanel {
		title = 'Save GeoFix CSV report',
		prompt = 'Save report',
		requiredFileType = 'csv',
		canCreateDirectories = true,
	}
	if type(selected) ~= 'string' or selected == '' then
		return nil, true
	end
	local path = selected
	if not path:lower():match('%.csv$') then
		path = path .. '.csv'
	end
	local csv = GeoFixCore.buildReport(plan, {
		scope = settings.scope,
		source = sourceLabel,
		copyAltitude = settings.copyAltitude,
	})
	local ok, err = pcall(function()
		local file, openErr = io.open(path, 'wb')
		if not file then error(openErr or 'could not open file') end
		file:write('\239\187\191', csv)
		file:close()
	end)
	if not ok then
		logger:warn('csv report failed')
		LrDialogs.message('GeoFix',
			'The CSV report could not be written. The analysis is still available.\n\n' .. tostring(err),
			'info')
		return nil, true
	end
	logger:info('csv report written')
	return path, false
end

local function wantTestMode(settings, matchCount)
	if not settings.testMode or matchCount <= 0 then return false end
	if matchCount <= GeoFixCore.TEST_MODE_PAIR_LIMIT then return true end
	local answer = LrDialogs.confirm(
		'Test mode is one photo at a time',
		string.format(
			'%d matches would open one by one. The summary lists them without loading previews.',
			matchCount),
		'Use the summary',
		'Review one by one')
	return answer == 'cancel'
end

local function applyPlan(catalog, plan, settings, context)
	local progress = LrProgressScope {
		title = 'GeoFix: writing GPS coordinates',
		functionContext = context,
	}
	progress:setCancelable(true)

	local updated = {}
	local total = #plan.matches
	local timeout = GeoFixCore.writeTimeoutSeconds(total)
	logger:info(string.format('writing %d photo(s), timeout %ds', total, timeout))

	local status = catalog:withWriteAccessDo('GeoFix: fill missing GPS', function()
		for i, m in ipairs(plan.matches) do
			if progress:isCanceled() then break end
			local photo = m.target.photo
			local gps = m.gps
			if photo and type(gps) == 'table'
				and type(gps.latitude) == 'number' and type(gps.longitude) == 'number' then
				photo:setRawMetadata('gps', {
					latitude = gps.latitude,
					longitude = gps.longitude,
				})
				if settings.copyAltitude and type(m.altitude) == 'number' then
					photo:setRawMetadata('gpsAltitude', m.altitude)
				end
				updated[#updated + 1] = photo
			end
			progress:setPortionComplete(i, total)
			progress:setCaption(string.format('%d / %d', i, total))
		end
	end, { timeout = timeout })

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
	local photos, sourceLabel, err = collectProject(catalog, settings)
	if err then
		LrDialogs.message('GeoFix', err, 'info')
		return
	end
	if not photos or #photos == 0 then
		LrDialogs.message('GeoFix',
			'There are no photos in this project.\n\n' .. GeoFixCore.scopeDetail(settings.scope),
			'info')
		return
	end

	logger:info(string.format(
		'scope=%s photos=%d maxDelta=%ds interp=%s interpGap=%ds speed=%d offset=%ds',
		settings.scope, #photos, settings.maxDeltaSeconds, tostring(settings.interpolate),
		settings.maxInterpolateSeconds, settings.maxSpeedKmh, settings.clockOffsetSeconds))

	if #photos >= GeoFixCore.LARGE_PROJECT_COUNT then
		local answer = LrDialogs.confirm(
			'Read a large project?',
			string.format(
				'%s\n\n%d photos\n%s\n\nDonor and missing-GPS counts are shown after the read, before anything is written. You can cancel during the read.',
				GeoFixCore.scopeDetail(settings.scope),
				#photos,
				sourceLabel),
			'Continue',
			'Cancel')
		if answer ~= 'ok' then
			logger:info('canceled before metadata read')
			return
		end
	end

	local progress = LrProgressScope {
		title = 'GeoFix: reading photo metadata',
		functionContext = context,
	}
	progress:setCancelable(true)

	local records = toRecords(catalog, photos, progress)
	if not records then
		progress:done()
		logger:info('canceled during metadata read')
		return
	end

	progress:setCaption('Matching...')
	local plan = GeoFixCore.plan(records, records, {
		maxDeltaSeconds = settings.maxDeltaSeconds,
		clockOffsetSeconds = settings.clockOffsetSeconds,
		interpolate = settings.interpolate,
		maxInterpolateSeconds = settings.maxInterpolateSeconds,
		maxSpeedKmh = settings.maxSpeedKmh,
	})
	progress:done()

	logger:info(string.format(
		'plan: matches=%d interpolated=%d nearest=%d exact=%d tooFar=%d noTime=%d tagged=%d donors=%d',
		#plan.matches, plan.counts.interpolated, plan.counts.nearest, plan.counts.exact,
		#plan.tooFar, #plan.noTimestamp, #plan.alreadyTagged, plan.donorCount))

	local reportPath, reportSkipped = saveReport(plan, settings, sourceLabel)

	if plan.donorCount == 0 then
		local text = 'None of the photos in this project has GPS coordinates, so there is nothing to copy from.\n\n'
			.. 'Select the root folder in the Folders panel and keep the scope on "Entire folder tree - one project". '
			.. 'The geotagged photos have to be inside that folder or one of its subfolders.'
		if reportPath then
			text = text .. '\n\nCSV report:\n' .. reportPath
		end
		LrDialogs.message('GeoFix', text, 'info')
		return
	end

	local info = {
		source = sourceLabel,
		photoCount = #records,
		reportPath = reportPath,
		reportSkipped = reportSkipped,
	}

	local apply
	if wantTestMode(settings, #plan.matches) then
		apply = GeoFixReview.show(context, plan, settings)
	else
		apply = showSummaryDialog(plan, settings, info)
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
