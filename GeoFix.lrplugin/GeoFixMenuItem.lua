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
  tree      the active folder and every nested subfolder, as one project. This
            is the default. Targets and donors are the same set of photos.
            getPhotos(true) is not trusted on its own: the plug-in also walks
            getChildren() and unions getPhotos(false) on every descendant.
  folder    photos directly in the active folder. Subfolders are left out.
  selection the current selection. Fewer than two selected photos means the
            whole filmstrip, which includes subfolders only when Lightroom is
            already listing them.

The folder scopes ignore Library filters. They use the folder itself.
------------------------------------------------------------------------------]]

local LrApplication = import 'LrApplication'
local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrFileUtils = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local LrView = import 'LrView'

local GeoFixCore = require 'GeoFixCore'
local GeoFixPrefs = require 'GeoFixPrefs'
local GeoFixReview = require 'GeoFixReview'
local logger = require 'GeoFixLogger'

local bind = LrView.bind

-- simple_list stores an array of selected item values. Compare each entry so
-- the project root is highlighted without another click.
local function listValueEquals(selected, itemValue)
	if type(selected) ~= 'table' then
		return selected == itemValue
	end
	local n = #selected
	if n > 0 then
		for i = 1, n do
			if selected[i] == itemValue then return true end
		end
		return false
	end
	for _, entry in pairs(selected) do
		if entry == itemValue then return true end
	end
	return false
end

local UNIT_ITEMS = {
	{ title = 'seconds', value = 1 },
	{ title = 'minutes', value = 60 },
	{ title = 'hours', value = 3600 },
}

-- catalog:batchGetRawMetadata accepts only some LrPhoto:getRawMetadata keys.
-- fileName is getFormattedMetadata, so the batch call throws
-- Unknown key: "fileName" and aborts. isVirtualCopy is a raw key that this
-- batch API also rejects (Adobe-confirmed). The display name comes from the
-- path leaf. An unknown virtual-copy flag is treated as false.
local META_KEYS = {
	'path', 'gps', 'gpsAltitude',
	'dateTimeOriginal', 'dateTimeDigitized', 'dateTime',
}

--------------------------------------------------------------------------------
-- Settings dialog
--------------------------------------------------------------------------------

local function showSettingsDialog(context, folderItems, folderNote, selectedFolder)
	local props = LrBinding.makePropertyTable(context)
	GeoFixPrefs.applyTo(props)
	props.scope = GeoFixCore.normalizeScope(props.scope)
	props.folderItems = folderItems or {}
	if selectedFolder and selectedFolder ~= 'none' then
		props.folderIndex = { selectedFolder }
	else
		props.folderIndex = {}
	end

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
				bind_to_object = props,
				value = bind {
					key = 'scope',
					bind_to_object = props,
				},
				items = scopeItems,
				value_equal = function(current, itemValue)
					return GeoFixCore.normalizeScope(current) == itemValue
				end,
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

		f:static_text { title = 'Project folder', font = '<system/bold>' },
		f:simple_list {
			bind_to_object = props,
			items = bind 'folderItems',
			value = bind 'folderIndex',
			width = 740,
			height = 180,
			value_equal = listValueEquals,
			enabled = bind {
				key = 'scope',
				bind_to_object = props,
				transform = function(value)
					return GeoFixCore.normalizeScope(value) ~= 'selection'
				end,
			},
		},
		f:static_text {
			title = folderNote or '',
			width_in_chars = 82,
			height_in_lines = 3,
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
		f:static_text {
			title = 'Coordinates are written to the .xmp sidecar beside each photo. The image file is not modified.',
			width_in_chars = 82,
			height_in_lines = 2,
		},
		},
	}

	local result = LrDialogs.presentModalDialog {
		title = 'GeoFix: Fill missing GPS',
		contents = contents,
		actionVerb = 'Analyze',
	}
	if result ~= 'ok' then return nil end

	-- Persist the canonical token. A menu title must not be stored as the scope.
	props.scope = GeoFixCore.normalizeScope(props.scope)
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
		folderIndex = type(props.folderIndex) == 'table' and props.folderIndex[1] or props.folderIndex,
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

local function iterArray(sources)
	local list = {}
	if type(sources) ~= 'table' then return list end
	local n = #sources
	if n > 0 then
		for i = 1, n do
			if sources[i] ~= nil then list[#list + 1] = sources[i] end
		end
		return list
	end
	local numeric = {}
	for key, source in pairs(sources) do
		if source ~= nil and type(key) == 'number' then
			numeric[#numeric + 1] = { key = key, source = source }
		end
	end
	table.sort(numeric, function(a, b) return a.key < b.key end)
	for _, item in ipairs(numeric) do
		list[#list + 1] = item.source
	end
	if #list == 0 then
		for _, source in pairs(sources) do
			if source ~= nil then list[#list + 1] = source end
		end
	end
	return list
end

-- Catalog calls wait on the catalog. Lightroom's Lua cannot wait inside a plain
-- pcall; it fails with "We can only wait from within a task". LrTasks.pcall can.
local function try(fn)
	local ok, value = LrTasks.pcall(fn)
	if ok then return value end
	return nil
end

local function nonEmpty(value)
	if type(value) == 'string' and value ~= '' then return value end
	return nil
end

local function isFolder(source)
	if source == nil or type(source) == 'string' then return false end
	return try(function() return source:type() end) == 'LrFolder'
end

local function folderPathAndName(source)
	local path = nonEmpty(try(function() return source:getPath() end))
	local name = nonEmpty(try(function() return source:getName() end))
	if not name and path then
		name = path:match('([^\\/]+)[\\/]*$')
	end
	return path, name
end

local function folderLabel(path, name)
	return nonEmpty(path) or nonEmpty(name) or 'Selected folder'
end

-- Last path segment. Lightroom paths use \ on Windows and / on Mac.
local function pathLeaf(path)
	if type(path) ~= 'string' or path == '' then return nil end
	local leaf = path:match('([^\\/]+)[\\/]*$')
	if leaf == nil or leaf == '' or leaf == '.' or leaf == '..' then return nil end
	return leaf
end

local function entriesFromSources(sources)
	local entries, seen = {}, {}
	for _, source in ipairs(sources) do
		if isFolder(source) and not seen[source] then
			local path, name = folderPathAndName(source)
			if not (path and seen[path]) then
				seen[source] = true
				if path then seen[path] = true end
				local parent = try(function() return source:getParent() end)
				if not isFolder(parent) then parent = nil end
				entries[#entries + 1] = {
					source = source,
					path = path,
					name = name,
					parent = parent,
				}
			end
		end
	end
	return entries
end

local function listCatalogFolders(catalog, progress)
	local folders, seen = {}, {}
	local function add(folder, depth)
		if progress:isCanceled() then return end
		if folder == nil or depth > 64 or #folders >= 5000 or seen[folder] then return end
		seen[folder] = true
		local path, name = folderPathAndName(folder)
		local title
		if depth == 0 then
			title = folderLabel(path, name)
		else
			title = string.rep('> ', depth) .. (name or 'Folder')
		end
		folders[#folders + 1] = { source = folder, path = path, name = name, title = title }
		if #folders % 25 == 0 then
			progress:setCaption(string.format('Reading folders (%d)', #folders))
			LrTasks.yield()
		end
		local children = try(function() return folder:getChildren() end)
		for _, child in ipairs(iterArray(children)) do
			add(child, depth + 1)
		end
	end
	local roots = try(function() return catalog:getFolders() end)
	for _, root in ipairs(iterArray(roots)) do
		add(root, 0)
	end
	return folders
end

local function loadFolderContext(catalog, progress)
	local sources = iterArray(try(function() return catalog:getActiveSources() end))
	local entries = entriesFromSources(sources)
	progress:setCaption('Reading folders...')
	local catalogFolders = listCatalogFolders(catalog, progress)
	logger:info(string.format('active sources=%d folders=%d catalogFolders=%d',
		#sources, #entries, #catalogFolders))
	return { sources = sources, entries = entries, catalogFolders = catalogFolders }
end

local function sameFolder(a, b)
	if a == nil or b == nil then return false end
	if a.source == b.source then return true end
	return a.path ~= nil and a.path == b.path
end

local function folderMenu(catalogFolders, detected)
	if detected then
		local listed = false
		for _, entry in ipairs(catalogFolders) do
			if sameFolder(entry, detected) then
				listed = true
				break
			end
		end
		if not listed then
			catalogFolders[#catalogFolders + 1] = {
				source = detected.source,
				path = detected.path,
				name = detected.name,
				title = folderLabel(detected.path, detected.name),
			}
		end
	end
	local items, selected = {}, 'none'
	for i, entry in ipairs(catalogFolders) do
		local value = 'f' .. tostring(i)
		items[#items + 1] = { title = entry.title, value = value }
		if selected == 'none' and sameFolder(entry, detected) then
			selected = value
		end
	end
	if #items == 0 then
		items[1] = { title = 'No folders found in this catalog', value = 'none' }
	end
	return items, selected
end

local function chooseFolder(entries)
	local records = {}
	local indexOf = {}
	for i, entry in ipairs(entries) do
		indexOf[entry.source] = i
	end
	for i, entry in ipairs(entries) do
		local parentId = nil
		if entry.parent then
			parentId = indexOf[entry.parent] or entry.parent
		end
		records[i] = { id = i, parentId = parentId }
	end

	local class = GeoFixCore.classifyFolders(records)
	if class.kind == 'none' then return nil, 'none' end
	if class.kind == 'ambiguous' then return nil, 'ambiguous' end
	if class.kind == 'one' or class.kind == 'ancestor' then
		return entries[class.id], nil
	end

	local parent = class.parentId
	if type(parent) == 'number' then parent = entries[parent] and entries[parent].source end
	if not isFolder(parent) then return nil, 'ambiguous' end
	local path, name = folderPathAndName(parent)
	return { source = parent, path = path, name = name }, nil
end

-- Photos in one folder. Tree scope also walks every descendant.
-- getPhotos(true) is documented to include subfolders, but some Lightroom
-- builds ignore the flag and return only the photos stored in that folder.
-- Each catalog call goes through LrTasks.pcall (see try). These calls must
-- stay outside withWriteAccessDo.
local function collectFolderPhotos(folder, includeChildren)
	local photos = {}
	local seen = {}
	local listed = false

	local function addListed(batch)
		if type(batch) ~= 'table' then return end
		listed = true
		for _, photo in ipairs(iterArray(batch)) do
			photos[#photos + 1] = photo
		end
	end

	local function walk(node, depth)
		if node == nil or depth > 64 or seen[node] then return end
		seen[node] = true
		local nodePath = nonEmpty(try(function() return node:getPath() end))
		if nodePath then
			if seen[nodePath] then return end
			seen[nodePath] = true
		end
		addListed(try(function() return node:getPhotos(false) end))
		if not includeChildren then return end
		local children = try(function() return node:getChildren() end)
		for _, child in ipairs(iterArray(children)) do
			walk(child, depth + 1)
		end
		if LrTasks.yield then LrTasks.yield() end
	end

	walk(folder, 0)
	if includeChildren then
		addListed(try(function() return folder:getPhotos(true) end))
	end
	if not listed then return nil end
	return dedupe(photos)
end

local function collectProject(catalog, settings)
	if settings.scope == 'selection' then
		local photos = catalog:getMultipleSelectedOrAllPhotos()
		if type(photos) ~= 'table' then photos = {} end
		return dedupe(iterArray(photos)), 'Current selection / filmstrip', nil
	end

	local folder = settings.projectFolder
	if not folder or not folder.source then
		return nil, nil, 'Choose the project folder in the list. A folder that only contains subfolders is listed there too.'
	end

	local includeChildren = settings.scope == 'tree'
	local photos = collectFolderPhotos(folder.source, includeChildren)
	if not photos then
		return nil, nil, 'Lightroom could not list the photos in the selected folder.'
	end
	local path, name = folder.path, folder.name
	if not path and not name then
		path, name = folderPathAndName(folder.source)
	end
	return photos, folderLabel(path, name), nil
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
				name = pathLeaf(m.path) or ('#' .. tostring(photo.localIdentifier)),
				path = m.path,
				time = m.dateTimeOriginal or m.dateTimeDigitized or m.dateTime,
				gps = m.gps,
				altitude = m.gpsAltitude,
				virtual = false,
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

local MAX_SIDECAR_BYTES = 5 * 1024 * 1024

local function readSidecar(path)
	if not LrFileUtils.exists(path) then return nil, nil end
	local file, err = io.open(path, 'rb')
	if not file then return nil, 'could not read sidecar' end
	local size = file:seek('end')
	if type(size) == 'number' and size > MAX_SIDECAR_BYTES then
		file:close()
		return nil, 'sidecar is too large to update safely'
	end
	file:seek('set')
	local data = file:read('*a')
	file:close()
	if not data then return nil, err or 'could not read sidecar' end
	return data, nil
end

-- Lightroom Classic's Lua leaves os.rename and os.remove nil.
-- LrFileUtils.move does not overwrite an existing destination, so an existing
-- sidecar is moved aside and put back if the new file cannot take its place.
local function replaceSidecar(path, contents)
	local tmp = path .. '.geofix.tmp'
	local file, err = io.open(tmp, 'wb')
	if not file then return false, err or 'could not create sidecar' end
	local okWrite, writeErr = pcall(function() file:write(contents) end)
	file:close()
	if not okWrite then
		LrFileUtils.delete(tmp)
		return false, writeErr or 'could not write sidecar'
	end

	local backup = path .. '.geofix.bak'
	if not LrFileUtils.exists(path) then
		if LrFileUtils.move(tmp, path) then return true end
		LrFileUtils.delete(tmp)
		return false, 'could not replace sidecar'
	end

	if LrFileUtils.exists(backup) then
		LrFileUtils.delete(backup)
	end
	if not LrFileUtils.move(path, backup) then
		LrFileUtils.delete(tmp)
		return false, 'could not replace sidecar'
	end
	if not LrFileUtils.move(tmp, path) then
		LrFileUtils.move(backup, path)
		LrFileUtils.delete(tmp)
		return false, 'could not replace sidecar'
	end
	LrFileUtils.delete(backup)
	return true
end

local function writeSidecars(jobs, context)
	local progress = LrProgressScope {
		title = 'GeoFix: writing XMP sidecars',
		functionContext = context,
	}
	progress:setCancelable(true)

	local written, failed = 0, 0
	local failedNames = {}
	local total = #jobs
	for i, job in ipairs(jobs) do
		if progress:isCanceled() then break end
		progress:setPortionComplete(i, total)
		progress:setCaption(string.format('%d / %d', i, total))
		local existing, readErr = readSidecar(job.sidecar)
		local xml, mergeErr
		if readErr then
			xml, mergeErr = nil, readErr
		else
			xml, mergeErr = GeoFixCore.upsertGpsXmp(existing, job.latitude, job.longitude, job.altitude)
		end
		if not xml then
			failed = failed + 1
			if #failedNames < 8 then failedNames[#failedNames + 1] = job.name end
			logger:warn('sidecar skipped: ' .. tostring(mergeErr))
		else
			local ok = replaceSidecar(job.sidecar, xml)
			if ok then
				written = written + 1
			else
				failed = failed + 1
				if #failedNames < 8 then failedNames[#failedNames + 1] = job.name end
				logger:warn('sidecar write failed')
			end
		end
		if LrTasks.yield then LrTasks.yield() end
	end
	local canceled = progress:isCanceled()
	progress:done()
	return written, failed, failedNames, canceled
end

local function sidecarJobs(updates)
	local byPath, order = {}, {}
	for _, item in ipairs(updates) do
		local sidecar = GeoFixCore.sidecarPath(item.path)
		if sidecar then
			local existing = byPath[sidecar]
			if not existing then
				order[#order + 1] = sidecar
				byPath[sidecar] = {
					sidecar = sidecar,
					name = item.name,
					latitude = item.latitude,
					longitude = item.longitude,
					altitude = item.altitude,
					virtual = item.virtual,
				}
			elseif existing.virtual and not item.virtual then
				byPath[sidecar] = {
					sidecar = sidecar,
					name = item.name,
					latitude = item.latitude,
					longitude = item.longitude,
					altitude = item.altitude,
					virtual = false,
				}
			end
		end
	end
	local jobs = {}
	for _, sidecar in ipairs(order) do
		jobs[#jobs + 1] = byPath[sidecar]
	end
	local missing = 0
	for _, item in ipairs(updates) do
		if not GeoFixCore.sidecarPath(item.path) then missing = missing + 1 end
	end
	return jobs, missing
end

local function applyPlan(catalog, plan, settings, context)
	local progress = LrProgressScope {
		title = 'GeoFix: writing GPS coordinates',
		functionContext = context,
	}
	progress:setCancelable(true)

	local updated = {}
	local sidecarUpdates = {}
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
				local altitude = nil
				if settings.copyAltitude and type(m.altitude) == 'number' then
					photo:setRawMetadata('gpsAltitude', m.altitude)
					altitude = m.altitude
				end
				updated[#updated + 1] = photo
				sidecarUpdates[#sidecarUpdates + 1] = {
					path = m.target.path,
					name = m.target.name,
					latitude = gps.latitude,
					longitude = gps.longitude,
					altitude = altitude,
					virtual = m.target.virtual,
				}
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

	local jobs, missingPaths = sidecarJobs(sidecarUpdates)
	local sidecarsWritten, sidecarsFailed, failedNames, sidecarsCanceled = writeSidecars(jobs, context)
	sidecarsFailed = sidecarsFailed + missingPaths
	logger:info(string.format('updated %d photo(s), sidecars=%d failed=%d', #updated, sidecarsWritten, sidecarsFailed))

	if settings.selectUpdated and #updated > 0 then
		LrTasks.pcall(function() catalog:setSelectedPhotos(updated[1], updated) end)
	end

	local msg = string.format(
		'GPS was saved for %d photo(s) and written to %d XMP sidecar(s). The image files were not modified.',
		#updated, sidecarsWritten)
	if progress:isCanceled() or sidecarsCanceled then
		msg = msg .. ' (canceled before finishing)'
	end
	if sidecarsFailed > 0 then
		msg = msg .. string.format('\n\n%d sidecar(s) could not be written.', sidecarsFailed)
		if #failedNames > 0 then
			msg = msg .. '\n' .. table.concat(failedNames, '\n')
		end
	end
	msg = msg .. '\n\nThe catalog has the same coordinates, so the location shows in Lightroom and a later metadata save will not wipe the sidecar. Edit > Undo reverts the catalog only, not the .xmp files.'
	LrDialogs.message('GeoFix', msg, 'info')
end

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

local function folderByMenuValue(catalogFolders, value)
	local index = tostring(value or ''):match('^f(%d+)$')
	index = tonumber(index)
	if not index then return nil end
	return catalogFolders[index]
end

local function main(context)
	-- Read the Folders-panel selection before the modal settings dialog opens.
	local catalog = LrApplication.activeCatalog()
	local folderProgress = LrProgressScope {
		title = 'GeoFix: listing folders',
		functionContext = context,
	}
	folderProgress:setCancelable(true)
	local info = loadFolderContext(catalog, folderProgress)
	local listCanceled = folderProgress:isCanceled()
	folderProgress:done()
	if listCanceled then return end

	local detected, choice = chooseFolder(info.entries)
	local items, selectedFolder = folderMenu(info.catalogFolders, detected)
	local note
	if detected then
		note = 'Selected in the Folders panel: ' .. folderLabel(detected.path, detected.name)
			.. '. Pick another row to change the project root.'
	elseif choice == 'ambiguous' then
		note = 'Several unrelated folders are selected in the Folders panel. Pick the project root below.'
	else
		note = 'No folder is selected in the Folders panel. Pick the project root below.'
	end
	local settings = showSettingsDialog(context, items, note, selectedFolder)
	if not settings then return end
	if settings.scope ~= 'selection' then
		settings.projectFolder = folderByMenuValue(info.catalogFolders, settings.folderIndex)
	end

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
