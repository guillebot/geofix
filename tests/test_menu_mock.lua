-- Run from the repository root:  lua tests/test_menu_mock.lua
-- Drives GeoFixMenuItem.lua end to end against a fake Lightroom SDK.
-- Catalog calls fail like Lightroom does when they wait inside a plain pcall
-- or inside withWriteAccessDo.
package.path = './GeoFix.lrplugin/?.lua;' .. package.path

local unpack = table.unpack or unpack
local rawPcall = pcall
local plainPcallDepth = 0
local inWrite = false

local function pack(...)
	return { n = select('#', ...), ... }
end

pcall = function(fn, ...)
	plainPcallDepth = plainPcallDepth + 1
	local result = pack(rawPcall(fn, ...))
	plainPcallDepth = plainPcallDepth - 1
	return unpack(result, 1, result.n)
end

local function wait()
	if plainPcallDepth > 0 then error('We can only wait from within a task', 2) end
	if inWrite then error('waited inside withWriteAccessDo', 2) end
end

local failures, passes = 0, 0
local function check(cond, label)
	if cond then
		passes = passes + 1
	else
		failures = failures + 1
		io.stderr:write('FAIL: ' .. label .. '\n')
	end
end

local tmpRoot = (os.getenv('TEMP') or os.getenv('TMPDIR') or '/tmp')
local sep = package.config:sub(1, 1)
local workDir = tmpRoot .. sep .. 'geofix_mock_' .. tostring(os.time())
local state = {}
local prefsStore = {}
os.execute('mkdir "' .. workDir .. '"')

--------------------------------------------------------------------------------
-- Fake catalog
--------------------------------------------------------------------------------

local Folder = {}
Folder.__index = Folder

local function newFolder(name, parent)
	local folder = setmetatable({ name = name, parent = parent, children = {}, photos = {} }, Folder)
	if parent then
		parent.children[#parent.children + 1] = folder
		folder.path = parent.path .. sep .. name
	else
		folder.path = workDir .. sep .. name
	end
	if sep == '\\' then
		os.execute('mkdir "' .. folder.path .. '" >nul 2>&1')
	else
		os.execute('mkdir -p "' .. folder.path .. '" >/dev/null 2>&1')
	end
	return folder
end

function Folder:type() wait() return 'LrFolder' end
function Folder:getName() wait() return self.name end
function Folder:getPath() wait() return self.path end
function Folder:getParent() wait() return self.parent end
function Folder:getChildren() wait() return self.children end
function Folder:getPhotos(includeChildren)
	wait()
	-- Some Lightroom builds ignore includeChildren and return only this folder.
	if state.directPhotosOnly then includeChildren = false end
	local out = {}
	local function collect(folder)
		for _, photo in ipairs(folder.photos) do out[#out + 1] = photo end
		if includeChildren then
			for _, child in ipairs(folder.children) do collect(child) end
		end
	end
	collect(self)
	return out
end

local Photo = {}
Photo.__index = Photo
local nextId = 1

local function newPhoto(folder, fileName, time, gps)
	local photo = setmetatable({
		localIdentifier = nextId,
		meta = {
			fileName = fileName,
			path = folder.path .. sep .. fileName,
			dateTimeOriginal = time,
			gps = gps,
			isVirtualCopy = false,
		},
	}, Photo)
	nextId = nextId + 1
	photo.thumbToken = 'preview:' .. fileName
	folder.photos[#folder.photos + 1] = photo
	return photo
end

function Photo:getRawMetadata(key) wait() return self.meta[key] end
function Photo:setRawMetadata(key, value)
	if not inWrite then error('setRawMetadata outside withWriteAccessDo') end
	self.meta[key] = value
end
function Photo:requestJpegThumbnail(_w, _h, callback)
	state.pendingThumbs = state.pendingThumbs or {}
	state.thumbRequests = (state.thumbRequests or 0) + 1
	local token = self.thumbToken
	-- Delivered from LrTasks.sleep, same as Lightroom calling back on a later turn.
	state.pendingThumbs[#state.pendingThumbs + 1] = function()
		state.thumbDelivered = (state.thumbDelivered or 0) + 1
		if state.failThumbs then
			callback(nil, 'C:/secret/photo.jpg')
		else
			callback(token, nil)
		end
	end
end

local function newCatalog(activeSources, roots)
	local catalog = { kAllPhotos = 'kAllPhotos', selected = nil }
	function catalog:getActiveSources() wait() return activeSources end
	function catalog:getFolders() wait() return roots end
	function catalog:getMultipleSelectedOrAllPhotos() wait() return {} end
	function catalog:setSelectedPhotos(active, photos) wait() self.selected = photos end
	-- LrCatalog:batchGetRawMetadata keys are a subset of LrPhoto:getRawMetadata.
	-- fileName is getFormattedMetadata only. isVirtualCopy (and the other keys
	-- below the allowlist) are raw keys that the batch call rejects with
	-- Unknown key: "...", which aborts the whole request.
	local batchRawKeys = {
		path = true, uuid = true, fileSize = true, rating = true,
		dimensions = true, croppedDimensions = true,
		shutterSpeed = true, aperture = true, exposureBias = true, flash = true,
		isoSpeedRating = true, focalLength = true, focalLength35mm = true,
		dateTimeOriginal = true, dateTimeDigitized = true, dateTime = true,
		dateTimeOriginalISO8601 = true, dateTimeDigitizedISO8601 = true, dateTimeISO8601 = true,
		gps = true, gpsAltitude = true, gpsImgDirection = true,
		colorNameForLabel = true, pickStatus = true,
		fileFormat = true, width = true, height = true, aspectRatio = true, isCropped = true,
		bitDepth = true, lastEditTime = true, editCount = true, copyrightState = true,
		isVideo = true, customMetadata = true,
		trimmedDurationInSeconds = true, durationRatio = true, trimmedDurationRatio = true,
		locationIsPrivate = true, smartPreviewInfo = true,
		altTextAccessibility = true, extDescrAccessibility = true, isExported = true,
	}
	function catalog:batchGetRawMetadata(photos, keys)
		wait()
		state.batched = state.batched or {}
		for _, photo in ipairs(photos) do
			state.batched[#state.batched + 1] = photo
		end
		local out = {}
		for _, photo in ipairs(photos) do
			local row = {}
			for _, key in ipairs(keys or {}) do
				if not batchRawKeys[key] then
					error('Unknown key: "' .. key .. '"')
				end
				row[key] = photo.meta[key]
			end
			out[photo] = row
		end
		return out
	end
	function catalog:withWriteAccessDo(_name, fn, _opts)
		wait()
		inWrite = true
		local ok, err = rawPcall(fn)
		inWrite = false
		if not ok then error(err) end
		return 'executed'
	end
	return catalog
end

--------------------------------------------------------------------------------
-- Fake SDK modules
-- Lightroom Classic's os table does not provide rename or remove. Calling
-- either one fails the scenario the way the plug-in crashed in Lightroom.
--------------------------------------------------------------------------------

local hostRename = os.rename
local hostRemove = os.remove
os.rename = nil
os.remove = nil


local function propertyTable()
	local props = {}
	function props:addObserver() end
	return props
end

local factory = setmetatable({}, {
	__index = function()
		return function(_self, args)
			if args == nil then return 8 end
			return args
		end
	end,
})

local pendingTasks = {}
local taskDepth = 0

local function drainTasks()
	local guard = 0
	while pendingTasks[1] ~= nil and guard < 20 do
		guard = guard + 1
		local fn = table.remove(pendingTasks, 1)
		taskDepth = taskDepth + 1
		fn()
		taskDepth = taskDepth - 1
	end
end

local function eachView(node, fn)
	if type(node) ~= 'table' then return end
	fn(node)
	for i = 1, #node do
		eachView(node[i], fn)
	end
end

local function findButton(node, title)
	local found
	eachView(node, function(item)
		if item.title == title and type(item.action) == 'function' then
			found = item
		end
	end)
	return found
end

local function boundPhotoKeys(node)
	local keys = {}
	eachView(node, function(item)
		if item.photo == 'targetPhoto' or item.photo == 'donorPhoto' then
			keys[item.photo] = true
		end
	end)
	return keys
end

local function snapPreview(props)
	if type(props) ~= 'table' then return {} end
	return {
		target = props.targetPhoto,
		donor = props.donorPhoto,
		targetStatus = props.targetStatus,
		donorStatus = props.donorStatus,
		index = props.index,
	}
end

local function previewTimedOut(snap)
	if type(snap) ~= 'table' then return false end
	return snap.targetStatus == 'Preview timed out' or snap.donorStatus == 'Preview timed out'
end

local modules = {
	LrApplication = { activeCatalog = function() return state.catalog end },
	LrBinding = { makePropertyTable = function() return propertyTable() end },
	LrDialogs = {
		presentModalDialog = function(args)
			state.dialogs[#state.dialogs + 1] = args.title
			local title = args.title or ''
			if title:find('Verify matches', 1, true) then
				local props = args.contents and args.contents.bind_to_object
				local review = {
					atOpen = snapPreview(props),
					bound = boundPhotoKeys(args.contents),
				}
				-- The dialog is on screen. Preview work queued before this call
				-- runs now, and the thumbnail callback lands in the bound path.
				drainTasks()
				review.afterLoad = snapPreview(props)
				if state.driveReview and type(props) == 'table' then
					local nextButton = findButton(args.contents, 'Next')
					review.clickedNext = nextButton ~= nil
					if nextButton then nextButton.action() end
					drainTasks()
					review.afterNext = snapPreview(props)
					local previous = findButton(args.contents, 'Previous')
					review.clickedPrevious = previous ~= nil
					if previous then previous.action() end
					drainTasks()
					review.afterPrev = snapPreview(props)
					local skip = findButton(args.contents, 'Skip this match')
					review.clickedSkip = skip ~= nil
					if skip then skip.action() end
					drainTasks()
					review.afterSkip = snapPreview(props)
					review.selectedAfterSkip = props.selectedLabel
				end
				state.review = review
			end
			return 'ok'
		end,
		message = function(title, text)
			state.messages[#state.messages + 1] = text or title
		end,
		confirm = function() return 'ok' end,
		runSavePanel = function() return state.reportPath end,
	},
	LrFileUtils = {
		exists = function(path)
			local file = io.open(path, 'rb')
			if file then file:close() return 'file' end
			return false
		end,
		-- Some Lightroom versions refuse to overwrite an existing destination.
		move = function(srcPath, destPath)
			local dest = io.open(destPath, 'rb')
			if dest then
				dest:close()
				return false
			end
			return hostRename(srcPath, destPath) and true or false
		end,
		delete = function(path)
			return hostRemove(path) and true or false
		end,
	},
	LrFunctionContext = {
		callWithContext = function(_name, fn)
			local context = { addFailureHandler = function(self, handler) self.handler = handler end }
			local ok, err = rawPcall(fn, context)
			if not ok then
				state.failure = tostring(err)
				if context.handler then context.handler(false, err) end
			end
		end,
	},
	LrProgressScope = function()
		return {
			setCancelable = function() end,
			isCanceled = function() return false end,
			setPortionComplete = function() end,
			setCaption = function() end,
			done = function() end,
		}
	end,
	LrTasks = {
		pcall = rawPcall,
		yield = function() wait() end,
		sleep = function()
			wait()
			local pending = state.pendingThumbs
			if type(pending) ~= 'table' or pending[1] == nil then return end
			state.pendingThumbs = {}
			for i = 1, #pending do
				pending[i]()
			end
		end,
		-- Nested tasks wait until the modal dialog drains them, so a photo
		-- bound from that task is applied while the catalog_photo view exists.
		startAsyncTask = function(fn)
			if taskDepth > 0 then
				pendingTasks[#pendingTasks + 1] = fn
			else
				taskDepth = taskDepth + 1
				fn()
				taskDepth = taskDepth - 1
			end
		end,
	},
	LrView = {
		osFactory = function() return factory end,
		bind = function(value) return value end,
		share = function(name) return name end,
	},
	LrPrefs = { prefsForPlugin = function() return prefsStore end },
	LrDate = { timeToUserFormat = function(t) return tostring(t) end },
	LrPathUtils = { child = function(a, b) return a .. sep .. b end },
	LrLogger = function()
		return {
			enable = function() end,
			info = function() end,
			warn = function(_, message)
				if type(state.warnings) ~= 'table' then state.warnings = {} end
				state.warnings[#state.warnings + 1] = tostring(message)
			end,
			error = function() end,
		}
	end,
}

import = function(name)
	local module = modules[name]
	if not module then error('mock has no module ' .. tostring(name)) end
	return module
end
_PLUGIN = { path = './GeoFix.lrplugin' }

--------------------------------------------------------------------------------
-- batchGetRawMetadata rejects keys Lightroom itself rejects
--------------------------------------------------------------------------------

do
	local catalog = newCatalog({}, {})
	local photo = { meta = { path = 'C:/photos/IMG_0001.CR3', gps = { latitude = 1, longitude = 2 } } }
	local function rejects(key)
		local ok, err = rawPcall(function()
			catalog:batchGetRawMetadata({ photo }, { key })
		end)
		check(not ok and tostring(err):find('Unknown key: "' .. key .. '"', 1, true) ~= nil,
			'batch rejects ' .. key .. ' (' .. tostring(err) .. ')')
	end
	rejects('fileName')
	rejects('isVirtualCopy')
	local ok, err = rawPcall(function()
		catalog:batchGetRawMetadata({ photo }, {
			'path', 'gps', 'gpsAltitude',
			'dateTimeOriginal', 'dateTimeDigitized', 'dateTime',
		})
	end)
	check(ok, 'batch accepts the keys GeoFix requests (' .. tostring(err) .. ')')
end

--------------------------------------------------------------------------------
-- Scenarios
--------------------------------------------------------------------------------

local function buildTree()
	local root = newFolder('Photos', nil)
	local trip = newFolder('Trip', root)
	local subs = {}
	for i, name in ipairs({ 'A', 'B', 'C', 'D' }) do
		subs[i] = newFolder(name, trip)
	end
	local photos = {
		newPhoto(subs[1], 'IMG_0001.CR3', 1000, { latitude = 40, longitude = -3 }),
		newPhoto(subs[2], 'IMG_0002.CR3', 1060, nil),
		newPhoto(subs[3], 'IMG_0003.CR3', 1120, { latitude = 40.01, longitude = -3.01 }),
		newPhoto(subs[4], 'IMG_0004.CR3', 1150, nil),
	}
	return root, trip, subs, photos
end

local function readFile(path)
	local file = io.open(path, 'rb')
	if not file then return nil end
	local data = file:read('*a')
	file:close()
	return data
end

local function cleanup(photos)
	for _, photo in ipairs(photos) do
		local sidecar = photo.meta.path:gsub('%.[^.]+$', '') .. '.xmp'
		hostRemove(sidecar)
		hostRemove(sidecar .. '.geofix.tmp')
		hostRemove(sidecar .. '.geofix.bak')
	end
end

local function clearPrefs()
	for key in pairs(prefsStore) do
		prefsStore[key] = nil
	end
end

local function run(label, activeSourcesFor, opts)
	opts = opts or {}
	local root, trip, subs, photos = buildTree()
	if opts.deeper then
		local nested = newFolder('Nested', subs[1])
		photos[#photos + 1] = newPhoto(nested, 'IMG_0005.CR3', nil, nil)
	end
	clearPrefs()
	for key, value in pairs(opts.prefs or {}) do
		prefsStore[key] = value
	end
	while pendingTasks[1] ~= nil do
		table.remove(pendingTasks, 1)
	end
	taskDepth = 0
	state = {
		catalog = newCatalog(activeSourcesFor(root, trip, subs), { root }),
		dialogs = {},
		messages = {},
		warnings = {},
		batched = {},
		pendingThumbs = {},
		thumbRequests = 0,
		thumbDelivered = 0,
		directPhotosOnly = opts.directPhotosOnly and true or false,
		reportPath = opts.reportPath,
		driveReview = opts.driveReview and true or false,
		failThumbs = opts.failThumbs and true or false,
	}
	if opts.prepare then opts.prepare(photos) end
	local chunk = assert(loadfile(os.getenv('GEOFIX_MENU_FILE') or 'GeoFix.lrplugin/GeoFixMenuItem.lua'))
	chunk()
	return photos, state, trip
end

local function expectAnalyzed(label, photos, result)
	local seen = {}
	for _, photo in ipairs(result.batched or {}) do
		seen[photo] = true
	end
	for i, photo in ipairs(photos) do
		check(seen[photo] == true, label .. ': analyzed photo ' .. tostring(i) .. ' from its subfolder')
	end
end

local function expectWritten(label, photos, result)
	check(result.failure == nil, label .. ': no failure (' .. tostring(result.failure) .. ')')
	local last = result.messages[#result.messages] or ''
	check(last:find('GPS was saved for 2 photo', 1, true) ~= nil, label .. ': two photos updated (' .. last .. ')')
	check(type(photos[2].meta.gps) == 'table', label .. ': subfolder B photo received GPS')
	check(type(photos[4].meta.gps) == 'table', label .. ': subfolder D photo received GPS')
	local xmpPath = photos[2].meta.path:gsub('%.[^.]+$', '') .. '.xmp'
	local xmp = readFile(xmpPath) or ''
	check(xmp:find('GPSLatitude', 1, true) ~= nil, label .. ': sidecar written for IMG_0002')
	check(photos[2].meta.path:find(sep .. 'B' .. sep .. 'IMG_0002.CR3', 1, true) ~= nil,
		label .. ': subfolder B keeps its own path')
	check(readFile(photos[2].meta.path) == nil, label .. ': image file never created or touched')
	cleanup(photos)
end

do
	local photos, result, trip = run('parent selected', function(_root, trip) return { trip } end)
	check(#trip.photos == 0, 'parent selected: parent has no direct photos')
	expectAnalyzed('parent selected', photos, result)
	expectWritten('parent selected', photos, result)
end

do
	local marker = 'GeoFixKeepLabel'
	local photos, result = run('existing sidecar', function(_root, trip) return { trip } end, {
		prepare = function(list)
			local xmpPath = list[2].meta.path:gsub('%.[^.]+$', '') .. '.xmp'
			local file = assert(io.open(xmpPath, 'wb'))
			file:write('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" dc:title="'
				.. marker .. '"/></rdf:RDF></x:xmpmeta>')
			file:close()
		end,
	})
	local xmpPath = photos[2].meta.path:gsub('%.[^.]+$', '') .. '.xmp'
	local xmp = readFile(xmpPath) or ''
	check(xmp:find(marker, 1, true) ~= nil, 'existing sidecar: previous metadata kept')
	check(readFile(xmpPath .. '.geofix.bak') == nil, 'existing sidecar: backup not left behind')
	check(readFile(xmpPath .. '.geofix.tmp') == nil, 'existing sidecar: temp not left behind')
	expectWritten('existing sidecar', photos, result)
end

do
	local photos, result = run('four subfolders selected', function(_root, _trip, subs) return subs end)
	expectAnalyzed('four subfolders selected', photos, result)
	expectWritten('four subfolders selected', photos, result)
end

do
	local photos, result = run('parent and subfolders selected', function(_root, trip, subs)
		return { trip, subs[1], subs[2], subs[3], subs[4] }
	end)
	expectAnalyzed('parent and subfolders selected', photos, result)
	expectWritten('parent and subfolders selected', photos, result)
end

do
	local reportPath = workDir .. sep .. 'geofix-tree.csv'
	local photos, result, trip = run('getPhotos ignores children', function(_root, trip) return { trip } end, {
		directPhotosOnly = true,
		deeper = true,
		reportPath = reportPath,
		prefs = { scope = 'tree', writeReport = true },
	})
	check(#trip.photos == 0, 'getPhotos ignores children: parent has no direct photos')
	expectAnalyzed('getPhotos ignores children', photos, result)
	expectWritten('getPhotos ignores children', photos, result)
	local csv = readFile(reportPath) or ''
	check(csv:find('\ntree,', 1, true) ~= nil, 'csv scope stays tree when descendants are walked')
	check(csv:find(sep .. 'B' .. sep .. 'IMG_0002.CR3', 1, true) ~= nil, 'csv keeps subfolder B path')
	check(csv:find(sep .. 'Nested' .. sep .. 'IMG_0005.CR3', 1, true) ~= nil, 'csv keeps a nested subfolder path')
	check(csv:find('no_timestamp', 1, true) ~= nil, 'csv includes the nested photo that has no capture time')
	check(csv:find(sep .. 'Trip' .. sep .. 'IMG_0002.CR3', 1, true) == nil, 'csv does not rewrite a subfolder photo onto the parent')
	hostRemove(reportPath)
end

do
	local photos, result = run('menu title is the whole tree', function(_root, trip) return { trip } end, {
		prefs = { scope = 'Entire folder tree - one project (recommended)' },
	})
	expectAnalyzed('menu title is the whole tree', photos, result)
	expectWritten('menu title is the whole tree', photos, result)
end

do
	local photos, result = run('current folder only', function(_root, trip) return { trip } end, {
		prefs = { scope = 'folder' },
		directPhotosOnly = true,
	})
	check(result.failure == nil, 'current folder only: no failure (' .. tostring(result.failure) .. ')')
	local last = result.messages[#result.messages] or ''
	check(last:find('no photos', 1, true) ~= nil, 'current folder only: does not pull in subfolders (' .. last .. ')')
	check(#(result.batched or {}) == 0, 'current folder only: subfolder photos were not read')
	check(photos[2].meta.gps == nil, 'current folder only: no photo changed')
	cleanup(photos)
end

do
	local photos, result = run('folder menu title', function(_root, trip) return { trip } end, {
		prefs = { scope = 'Current folder only' },
	})
	check(result.failure == nil, 'folder menu title: no failure (' .. tostring(result.failure) .. ')')
	local last = result.messages[#result.messages] or ''
	check(last:find('no photos', 1, true) ~= nil, 'folder menu title stays on the current folder (' .. last .. ')')
	check(#(result.batched or {}) == 0, 'folder menu title: subfolder photos were not read')
	cleanup(photos)
end

do
	local photos, result = run('test mode previews', function(_root, trip) return { trip } end, {
		prefs = { testMode = true, dryRun = true },
		driveReview = true,
	})
	check(result.failure == nil, 'test mode previews: no failure (' .. tostring(result.failure) .. ')')
	local titles = table.concat(result.dialogs, ' | ')
	check(titles:find('Verify matches', 1, true) ~= nil, 'test mode previews: review dialog opened (' .. titles .. ')')
	local review = result.review or {}
	local open = review.atOpen or {}
	local loaded = review.afterLoad or {}
	local nxt = review.afterNext or {}
	local prev = review.afterPrev or {}
	local skipped = review.afterSkip or {}
	check(review.bound and review.bound.targetPhoto == true, 'test mode previews: target catalog_photo is bound to targetPhoto')
	check(review.bound and review.bound.donorPhoto == true, 'test mode previews: donor catalog_photo is bound to donorPhoto')
	check(open.target == nil and open.donor == nil,
		'test mode previews: dialog opens before either photo is bound')
	check(loaded.target == photos[2] and loaded.donor == photos[1],
		'test mode previews: first pair binds the untagged and geotagged LrPhotos')
	check(not previewTimedOut(loaded), 'test mode previews: first pair does not time out')
	check((result.thumbRequests or 0) == 0, 'test mode previews: does not wait on a jpeg callback')
	check(review.clickedNext == true, 'test mode previews: Next button exists')
	check(nxt.target == photos[4] and nxt.donor == photos[3],
		'test mode previews: Next updates both LrPhotos')
	check(not previewTimedOut(nxt), 'test mode previews: Next does not time out')
	check(review.clickedPrevious == true, 'test mode previews: Previous button exists')
	check(prev.target == photos[2] and prev.donor == photos[1],
		'test mode previews: Previous restores both LrPhotos')
	check(review.clickedSkip == true, 'test mode previews: Skip button exists')
	check(skipped.target == photos[4] and skipped.donor == photos[3],
		'test mode previews: Skip updates both LrPhotos')
	check(not previewTimedOut(skipped), 'test mode previews: Skip does not time out')
	check(review.selectedAfterSkip == '1 of 2 selected',
		'test mode previews: Skip drops the current match (' .. tostring(review.selectedAfterSkip) .. ')')
	local leaked = false
	for _, message in ipairs(result.warnings or {}) do
		if message:find('preview:', 1, true) or message:find('secret', 1, true)
			or message:find('thumbnail failed', 1, true) or message:find('timed out', 1, true) then
			leaked = true
		end
	end
	check(not leaked, 'test mode previews: a loaded thumbnail is not logged')
	check(photos[2].meta.gps == nil, 'test mode previews: dry run leaves GPS unset')
	cleanup(photos)
end

do
	local photos, result = run('test mode ignores jpeg callback', function(_root, trip) return { trip } end, {
		prefs = { testMode = true, dryRun = true },
		failThumbs = true,
		driveReview = true,
	})
	check(result.failure == nil, 'test mode ignores jpeg callback: no failure (' .. tostring(result.failure) .. ')')
	local review = result.review or {}
	local loaded = review.afterLoad or {}
	local nxt = review.afterNext or {}
	check(review.bound and review.bound.targetPhoto == true and review.bound.donorPhoto == true,
		'test mode ignores jpeg callback: dialog still binds both photos')
	check(loaded.target == photos[2] and loaded.donor == photos[1],
		'test mode ignores jpeg callback: photos show without the jpeg callback')
	check(nxt.target == photos[4] and nxt.donor == photos[3],
		'test mode ignores jpeg callback: Next still updates both photos')
	check(not previewTimedOut(loaded) and not previewTimedOut(nxt),
		'test mode ignores jpeg callback: status is not Preview timed out')
	check((result.thumbRequests or 0) == 0,
		'test mode ignores jpeg callback: requestJpegThumbnail was not called')
	local warnings = result.warnings or {}
	local quiet = true
	for _, message in ipairs(warnings) do
		if message:find('thumbnail', 1, true) or message:find('secret', 1, true) or message:find('timed out', 1, true) then
			quiet = false
		end
	end
	check(quiet, 'test mode ignores jpeg callback: no thumbnail warning')
	check(photos[2].meta.gps == nil, 'test mode ignores jpeg callback: nothing was written')
	cleanup(photos)
end

do
	local photos, result = run('nothing selected', function() return {} end)
	check(result.failure == nil, 'nothing selected: no failure')
	local last = result.messages[#result.messages] or ''
	check(last:find('Choose the project folder', 1, true) ~= nil, 'nothing selected: asks for a folder (' .. last .. ')')
	check(photos[2].meta.gps == nil, 'nothing selected: no photo changed')
	cleanup(photos)
end

if sep == '\\' then
	os.execute('rmdir /s /q "' .. workDir .. '"')
else
	os.execute('rm -rf "' .. workDir .. '"')
end

print(string.format('%d passed, %d failed', passes, failures))
if failures > 0 then os.exit(1) end
