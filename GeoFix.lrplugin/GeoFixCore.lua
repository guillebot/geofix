--[[----------------------------------------------------------------------------
GeoFixCore.lua

Pure matching logic. No Lightroom SDK imports, so it can be exercised with a
plain Lua interpreter (see tests/test_core.lua). Must stay Lua 5.1 compatible
because that is what Lightroom Classic embeds.

A "record" is a plain table describing one photo:

  {
    id       = <anything unique>,
    name     = <string, for display>,
    path     = <string, optional file path>,
    time     = <number: capture time in seconds, any epoch> or nil,
    gps      = { latitude = <number>, longitude = <number> } or nil,
    altitude = <number> or nil,
  }

Times only need to be comparable with each other, so Lightroom's
"seconds since 2001-01-01" values can be used directly.

Coordinate choice, in order:
  1. Keep a photo that already has GPS.
  2. If a geotagged photo has the same capture time, copy it.
  3. If geotagged photos sit on both sides of the capture time, both are inside
     the interpolation gap, and the speed between them is plausible, place the
     photo on the straight line between them.
  4. Otherwise copy the nearest geotagged photo inside the time window.
  5. Otherwise leave the photo unchanged.
------------------------------------------------------------------------------]]

local GeoFixCore = {}

GeoFixCore.DEFAULT_MAX_DELTA_SECONDS = 600
GeoFixCore.DEFAULT_MAX_INTERPOLATE_SECONDS = 7200
GeoFixCore.DEFAULT_MAX_SPEED_KMH = 250
GeoFixCore.LARGE_PROJECT_COUNT = 2000
GeoFixCore.TEST_MODE_PAIR_LIMIT = 40
GeoFixCore.METADATA_CHUNK_SIZE = 1000
GeoFixCore.SUMMARY_DETAIL_LIMIT = 40
GeoFixCore.WRITE_TIMEOUT_BASE_SECONDS = 120
GeoFixCore.WRITE_TIMEOUT_CAP_SECONDS = 7200

local EARTH_RADIUS_M = 6371000

--- True when the record carries usable coordinates.
-- (0, 0) is treated as "no location": it is what some devices write when the
-- GPS fix was missing and it is never a real photo location in practice.
-- A zero latitude or a zero longitude on its own is valid.
function GeoFixCore.hasGps(record)
	local gps = record and record.gps
	if type(gps) ~= 'table' then return false end
	local lat, lon = gps.latitude, gps.longitude
	if type(lat) ~= 'number' or type(lon) ~= 'number' then return false end
	if lat == 0 and lon == 0 then return false end
	if lat < -90 or lat > 90 or lon < -180 or lon > 180 then return false end
	return true
end

local function byTime(a, b)
	if a.time == b.time then
		return tostring(a.id) < tostring(b.id)
	end
	return a.time < b.time
end

--- Filters a pool of records down to usable donors (have GPS and a timestamp),
-- sorted by capture time ascending. Equal times are ordered by id.
function GeoFixCore.sortedDonors(pool)
	local donors = {}
	for _, r in ipairs(pool) do
		if GeoFixCore.hasGps(r) and type(r.time) == 'number' then
			donors[#donors + 1] = r
		end
	end
	table.sort(donors, byTime)
	return donors
end

--- Finds the donor whose time is closest to t.
-- @param sortedDonors array sorted ascending by .time (see sortedDonors)
-- @param t            number
-- @return donor record (or nil when there are no donors), absolute delta in seconds
function GeoFixCore.findNearest(sortedDonors, t)
	local n = #sortedDonors
	if n == 0 then return nil, nil end

	-- Binary search for the first donor with time >= t.
	local lo, hi = 1, n
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if sortedDonors[mid].time < t then
			lo = mid + 1
		else
			hi = mid
		end
	end

	local best = sortedDonors[lo]
	local bestDelta = math.abs(best.time - t)

	if lo > 1 then
		local prev = sortedDonors[lo - 1]
		local prevDelta = math.abs(prev.time - t)
		-- On an exact tie prefer the earlier photo.
		if prevDelta <= bestDelta then
			best, bestDelta = prev, prevDelta
		end
	end

	return best, bestDelta
end

--- The geotagged photos immediately before and after t.
-- Either value is nil when that side does not exist.
function GeoFixCore.neighbors(sortedDonors, t)
	local n = #sortedDonors
	if n == 0 then return nil, nil end

	local lo, hi = 1, n
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if sortedDonors[mid].time < t then
			lo = mid + 1
		else
			hi = mid
		end
	end

	if sortedDonors[lo].time >= t then
		local pred = nil
		if lo > 1 then pred = sortedDonors[lo - 1] end
		return pred, sortedDonors[lo]
	end
	return sortedDonors[lo], nil
end

--- Great-circle distance in meters. Longitude wraps at the antimeridian.
function GeoFixCore.haversineMeters(lat1, lon1, lat2, lon2)
	local phi1 = math.rad(lat1)
	local phi2 = math.rad(lat2)
	local dphi = math.rad(lat2 - lat1)
	local dlambda = math.rad(lon2 - lon1)
	local sinDphi = math.sin(dphi / 2)
	local sinDlambda = math.sin(dlambda / 2)
	local a = sinDphi * sinDphi + math.cos(phi1) * math.cos(phi2) * sinDlambda * sinDlambda
	if a < 0 then a = 0 end
	if a > 1 then a = 1 end
	return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))
end

--- Point at `fraction` (0 = from, 1 = to) along the short longitude arc.
function GeoFixCore.interpolateCoordinate(fromGps, toGps, fraction)
	if fraction < 0 then fraction = 0 end
	if fraction > 1 then fraction = 1 end
	local lat = fromGps.latitude + (toGps.latitude - fromGps.latitude) * fraction
	local dlon = toGps.longitude - fromGps.longitude
	if dlon > 180 then
		dlon = dlon - 360
	elseif dlon < -180 then
		dlon = dlon + 360
	end
	local lon = fromGps.longitude + dlon * fraction
	if lon > 180 then
		lon = lon - 360
	elseif lon <= -180 then
		lon = lon + 360
	end
	return { latitude = lat, longitude = lon }
end

--- Best donor placement for one adjusted capture time.
-- Returns a match table with .method ('exact' or 'interpolated'),
-- a rejection table with .reason ('speed' or 'gap'), or nil when the caller
-- should use the nearest donor.
function GeoFixCore.locate(sortedDonors, t, opts)
	opts = opts or {}
	local interpolate = opts.interpolate
	if interpolate == nil then interpolate = true end
	local maxInterp = tonumber(opts.maxInterpolateSeconds) or GeoFixCore.DEFAULT_MAX_INTERPOLATE_SECONDS
	local maxSpeed = tonumber(opts.maxSpeedKmh) or GeoFixCore.DEFAULT_MAX_SPEED_KMH
	if maxInterp < 0 then maxInterp = 0 end
	if maxSpeed < 0 then maxSpeed = 0 end

	local pred, succ = GeoFixCore.neighbors(sortedDonors, t)
	if succ and succ.time == t then
		return {
			method = 'exact',
			donor = succ,
			gps = { latitude = succ.gps.latitude, longitude = succ.gps.longitude },
			altitude = succ.altitude,
			delta = 0,
			signedDelta = 0,
		}
	end

	if interpolate and pred and succ then
		local beforeDelta = t - pred.time
		local afterDelta = succ.time - t
		local gap = succ.time - pred.time
		if gap > 0 and beforeDelta >= 0 and afterDelta >= 0
			and beforeDelta <= maxInterp and afterDelta <= maxInterp then
			local meters = GeoFixCore.haversineMeters(
				pred.gps.latitude, pred.gps.longitude,
				succ.gps.latitude, succ.gps.longitude)
			local speedKmh = (meters / gap) * 3.6
			if speedKmh <= maxSpeed then
				local fraction = beforeDelta / gap
				if fraction < 0 then fraction = 0 end
				if fraction > 1 then fraction = 1 end
				local closer = pred
				local closerDelta = beforeDelta
				if afterDelta < beforeDelta then
					closer = succ
					closerDelta = afterDelta
				end
				local altitude = nil
				if type(pred.altitude) == 'number' and type(succ.altitude) == 'number' then
					altitude = pred.altitude + (succ.altitude - pred.altitude) * fraction
				end
				return {
					method = 'interpolated',
					donor = closer,
					before = pred,
					after = succ,
					gps = GeoFixCore.interpolateCoordinate(pred.gps, succ.gps, fraction),
					altitude = altitude,
					delta = closerDelta,
					signedDelta = closer.time - t,
					fraction = fraction,
					speedKmh = speedKmh,
					gap = gap,
				}
			end
			return { reason = 'speed', speedKmh = speedKmh, maxSpeedKmh = maxSpeed }
		end
		if gap > 0 then
			return { reason = 'gap' }
		end
	end

	return nil
end

local function nearestNote(rejected)
	if rejected and rejected.reason == 'speed' then
		return string.format(
			'Nearest photo; interpolation skipped (%.0f km/h exceeds %.0f km/h)',
			rejected.speedKmh or 0, rejected.maxSpeedKmh or 0)
	elseif rejected and rejected.reason == 'gap' then
		return 'Nearest photo; surrounding geotagged photos are outside the interpolation gap'
	end
	return 'Copied from the nearest geotagged photo'
end

local function successNote(found)
	if found.method == 'exact' then
		return 'Copied from a geotagged photo with the same capture time'
	elseif found.method == 'interpolated' then
		return 'Interpolated between the geotagged photos before and after'
	end
	return nearestNote(found)
end

local function tooFarNote(item, donor)
	if item.reason == 'speed' then
		return string.format(
			'Implied travel %.0f km/h exceeds %.0f km/h, and no geotagged photo is inside the nearest-photo window',
			item.speedKmh or 0, item.maxSpeedKmh or 0)
	elseif item.reason == 'gap' then
		return 'Surrounding geotagged photos are outside the interpolation gap, and no geotagged photo is inside the nearest-photo window'
	elseif not donor then
		return 'No geotagged photo with a capture time'
	end
	return 'Nearest geotagged photo is outside the time window'
end

--- Builds the plan of GPS copies to perform.
--
-- @param targets array of records that may receive coordinates
-- @param pool    array of records that may donate coordinates (may overlap targets)
-- @param opts    {
--                  maxDeltaSeconds       = number (default 600), nearest-copy window
--                  clockOffsetSeconds    = number added to every target time (default 0)
--                  interpolate           = boolean (default true)
--                  maxInterpolateSeconds = number (default 7200); both neighbors
--                                          must be at least this close to the target
--                  maxSpeedKmh           = number (default 250)
--                }
-- @return {
--   matches       = { { target=, donor=, method=, gps=, delta=, ... }, ... },
--   tooFar        = { { target=, nearestDelta=, reason=, note= }, ... },
--   noTimestamp   = { record, ... },
--   alreadyTagged = { record, ... },
--   donorCount    = number,
--   counts        = { exact=, nearest=, interpolated= },
--   rejected      = { speed=, gap= },
--   stats         = { maxDelta=, avgDelta= } or nil,
-- }
function GeoFixCore.plan(targets, pool, opts)
	opts = opts or {}
	local maxDelta = tonumber(opts.maxDeltaSeconds) or GeoFixCore.DEFAULT_MAX_DELTA_SECONDS
	local offset = tonumber(opts.clockOffsetSeconds) or 0
	local interpolate = opts.interpolate
	if interpolate == nil then interpolate = true end
	local maxInterp = tonumber(opts.maxInterpolateSeconds) or GeoFixCore.DEFAULT_MAX_INTERPOLATE_SECONDS
	local maxSpeed = tonumber(opts.maxSpeedKmh) or GeoFixCore.DEFAULT_MAX_SPEED_KMH

	local donors = GeoFixCore.sortedDonors(pool)
	local locateOpts = {
		interpolate = interpolate,
		maxInterpolateSeconds = maxInterp,
		maxSpeedKmh = maxSpeed,
	}

	local result = {
		matches = {},
		tooFar = {},
		noTimestamp = {},
		alreadyTagged = {},
		donorCount = #donors,
		counts = { exact = 0, nearest = 0, interpolated = 0 },
		rejected = { speed = 0, gap = 0 },
		stats = nil,
	}

	local sum, worst = 0, 0

	for _, target in ipairs(targets) do
		if GeoFixCore.hasGps(target) then
			result.alreadyTagged[#result.alreadyTagged + 1] = target
		elseif type(target.time) ~= 'number' then
			result.noTimestamp[#result.noTimestamp + 1] = target
		else
			local t = target.time + offset
			local found = GeoFixCore.locate(donors, t, locateOpts)
			if found and found.method then
				found.target = target
				found.note = successNote(found)
				result.matches[#result.matches + 1] = found
				result.counts[found.method] = (result.counts[found.method] or 0) + 1
				sum = sum + found.delta
				if found.delta > worst then worst = found.delta end
			else
				local donor, delta = GeoFixCore.findNearest(donors, t)
				if donor and delta <= maxDelta then
					local match = {
						target = target,
						method = 'nearest',
						donor = donor,
						gps = { latitude = donor.gps.latitude, longitude = donor.gps.longitude },
						altitude = donor.altitude,
						delta = delta,
						signedDelta = donor.time - t,
					}
					if found and found.reason and result.rejected[found.reason] ~= nil then
						match.interpolationRejected = found.reason
						match.rejectedSpeedKmh = found.speedKmh
						match.maxSpeedKmh = found.maxSpeedKmh
						result.rejected[found.reason] = result.rejected[found.reason] + 1
					end
					match.note = nearestNote(found)
					result.matches[#result.matches + 1] = match
					result.counts.nearest = result.counts.nearest + 1
					sum = sum + delta
					if delta > worst then worst = delta end
				else
					local item = {
						target = target,
						nearestDelta = delta,
						reason = donor and 'window' or 'none',
					}
					if found and found.reason and result.rejected[found.reason] ~= nil then
						item.reason = found.reason
						item.speedKmh = found.speedKmh
						item.maxSpeedKmh = found.maxSpeedKmh
						result.rejected[found.reason] = result.rejected[found.reason] + 1
					end
					item.note = tooFarNote(item, donor)
					result.tooFar[#result.tooFar + 1] = item
				end
			end
		end
	end

	if #result.matches > 0 then
		result.stats = { maxDelta = worst, avgDelta = sum / #result.matches }
	end

	return result
end

--- Human readable duration, e.g. "42s", "3m 05s", "2h 10m".
function GeoFixCore.formatDuration(seconds)
	seconds = math.abs(tonumber(seconds) or 0)
	local whole = math.floor(seconds + 0.5)
	if whole < 60 then
		return string.format('%ds', whole)
	elseif whole < 3600 then
		return string.format('%dm %02ds', math.floor(whole / 60), whole % 60)
	else
		local hours = math.floor(whole / 3600)
		local mins = math.floor((whole % 3600) / 60)
		return string.format('%dh %02dm', hours, mins)
	end
end

function GeoFixCore.normalizeScope(scope)
	if scope == 'tree' or scope == 'folder' or scope == 'selection' then
		return scope
	end
	return 'tree'
end

function GeoFixCore.scopeChoices()
	return {
		{ value = 'tree', title = 'Entire folder tree - one project (recommended)' },
		{ value = 'folder', title = 'Current folder only' },
		{ value = 'selection', title = 'Selected photos only' },
	}
end

function GeoFixCore.scopeTitle(scope)
	scope = GeoFixCore.normalizeScope(scope)
	if scope == 'folder' then return 'Current folder only' end
	if scope == 'selection' then return 'Selected photos only' end
	return 'Entire folder tree - one project'
end

function GeoFixCore.scopeDetail(scope)
	scope = GeoFixCore.normalizeScope(scope)
	if scope == 'folder' then
		return 'Only photos directly in the selected folder are analyzed. Photos in subfolders are left out.'
	elseif scope == 'selection' then
		return 'Only the current selection is analyzed. If fewer than two photos are selected, Lightroom uses every photo in the filmstrip. Subfolders are included only when that filmstrip already lists them.'
	end
	return 'All photos in the selected root folder and every subfolder are analyzed together as one project. Subfolder boundaries are ignored. Any geotagged photo in the tree can supply coordinates to any untagged photo in the tree.'
end

--- Pick one project folder from the folders Lightroom reported.
-- Each record is { id = comparable, parentId = comparable or nil }.
-- parentId may point at another record in the list, or at a parent outside it.
-- @return { kind = 'one'|'ancestor'|'siblings'|'none'|'ambiguous', id = , parentId = }
function GeoFixCore.classifyFolders(records)
	records = records or {}
	if #records == 0 then return { kind = 'none' } end
	if #records == 1 then return { kind = 'one', id = records[1].id } end

	local inSet = {}
	for _, record in ipairs(records) do
		inSet[record.id] = true
	end

	local function parentOf(id)
		for _, record in ipairs(records) do
			if record.id == id then return record.parentId end
		end
		return nil
	end

	local function reaches(id, target, guard)
		if id == target then return true end
		guard = (guard or 0) + 1
		if guard > 64 then return false end
		local parentId = parentOf(id)
		if parentId == nil or not inSet[parentId] then return false end
		return reaches(parentId, target, guard)
	end

	local tops = {}
	for _, record in ipairs(records) do
		if record.parentId == nil or not inSet[record.parentId] then
			tops[#tops + 1] = record
		end
	end

	if #tops == 1 then
		local topId = tops[1].id
		for _, record in ipairs(records) do
			if not reaches(record.id, topId) then
				return { kind = 'ambiguous' }
			end
		end
		return { kind = 'ancestor', id = topId }
	end

	local shared = tops[1] and tops[1].parentId or nil
	if shared == nil then return { kind = 'ambiguous' } end
	for i = 2, #tops do
		if tops[i].parentId ~= shared then
			return { kind = 'ambiguous' }
		end
	end
	return { kind = 'siblings', parentId = shared }
end

--- Nil when the scope can run. Otherwise a message naming what to select.
function GeoFixCore.singleRootError(folderCount, scope)
	if scope == 'selection' then return nil end
	folderCount = tonumber(folderCount) or 0
	if folderCount == 1 then return nil end
	if folderCount < 1 then
		return 'Select a single folder in the Folders panel. '
			.. 'A folder that only contains subfolders is valid. '
			.. 'The entire-tree and current-folder scopes use that folder as the project. '
			.. 'Collections and All Photographs are not folder trees. '
			.. 'To analyze a selection or filmstrip instead, choose Selected photos only.'
	end
	return 'More than one folder is selected. Click a single root folder so every subfolder is treated as the same project.'
end

--- Catalog write timeout. 120 seconds plus one second per match, capped at 2 hours.
function GeoFixCore.writeTimeoutSeconds(matchCount)
	local n = tonumber(matchCount) or 0
	if n < 0 then n = 0 end
	n = math.floor(n)
	local seconds = GeoFixCore.WRITE_TIMEOUT_BASE_SECONDS + n
	if seconds > GeoFixCore.WRITE_TIMEOUT_CAP_SECONDS then
		seconds = GeoFixCore.WRITE_TIMEOUT_CAP_SECONDS
	end
	return seconds
end

function GeoFixCore.summaryLines(plan, info)
	info = info or {}
	plan = plan or {}
	local counts = plan.counts or { interpolated = 0, nearest = 0, exact = 0 }
	local rejected = plan.rejected or { speed = 0, gap = 0 }
	local scope = GeoFixCore.normalizeScope(info.scope)
	local matches = plan.matches or {}
	local tooFar = plan.tooFar or {}
	local noTimestamp = plan.noTimestamp or {}
	local alreadyTagged = plan.alreadyTagged or {}
	local analyzed = info.photoCount
	if type(analyzed) ~= 'number' then
		analyzed = #matches + #tooFar + #noTimestamp + #alreadyTagged
	end

	local lines = {
		'Scope: ' .. GeoFixCore.scopeTitle(scope),
		GeoFixCore.scopeDetail(scope),
		'Source: ' .. ((type(info.source) == 'string' and info.source ~= '') and info.source or '(none)'),
		string.format('%d photo(s) analyzed, %d geotagged donor(s).', analyzed, plan.donorCount or 0),
		string.format('%d photo(s) have no GPS.', analyzed - #alreadyTagged),
		string.format('%d photo(s) will receive coordinates: %d interpolated, %d nearest, %d exact time.',
			#matches, counts.interpolated or 0, counts.nearest or 0, counts.exact or 0),
	}

	if plan.stats then
		lines[#lines + 1] = string.format('Time to the closer geotagged photo: avg %s, max %s.',
			GeoFixCore.formatDuration(plan.stats.avgDelta),
			GeoFixCore.formatDuration(plan.stats.maxDelta))
	end
	lines[#lines + 1] = string.format('%d already had coordinates.', #alreadyTagged)
	lines[#lines + 1] = string.format('%d had no geotagged photo within %s.',
		#tooFar, GeoFixCore.formatDuration(info.maxDeltaSeconds or GeoFixCore.DEFAULT_MAX_DELTA_SECONDS))
	if #noTimestamp > 0 then
		lines[#lines + 1] = string.format('%d had no capture time and were skipped.', #noTimestamp)
	end
	if (rejected.speed or 0) > 0 then
		lines[#lines + 1] = string.format(
			'%d photo(s) were not interpolated because the implied travel speed was too high.',
			rejected.speed)
	end
	if (rejected.gap or 0) > 0 then
		lines[#lines + 1] = string.format(
			'%d photo(s) were not interpolated because the surrounding geotagged photos are outside the interpolation gap.',
			rejected.gap)
	end

	local interpolate = info.interpolate
	if interpolate == nil then interpolate = true end
	if interpolate then
		lines[#lines + 1] = string.format(
			'Interpolation: on, gap %s, max speed %d km/h. Nearest-photo window %s.',
			GeoFixCore.formatDuration(info.maxInterpolateSeconds or GeoFixCore.DEFAULT_MAX_INTERPOLATE_SECONDS),
			math.floor((tonumber(info.maxSpeedKmh) or GeoFixCore.DEFAULT_MAX_SPEED_KMH) + 0.5),
			GeoFixCore.formatDuration(info.maxDeltaSeconds or GeoFixCore.DEFAULT_MAX_DELTA_SECONDS))
	else
		lines[#lines + 1] = string.format(
			'Interpolation: off. Only the nearest geotagged photo inside %s is used.',
			GeoFixCore.formatDuration(info.maxDeltaSeconds or GeoFixCore.DEFAULT_MAX_DELTA_SECONDS))
	end

	if info.copyAltitude == false then
		lines[#lines + 1] = 'Altitude: left unchanged.'
	else
		lines[#lines + 1] = 'Altitude: copied from the donor, or blended when both surrounding photos have it.'
	end

	local offset = tonumber(info.clockOffsetSeconds) or 0
	if offset ~= 0 then
		lines[#lines + 1] = string.format(
			'Camera clock offset: %+d s, applied to untagged photos before matching.', offset)
	end
	if type(info.reportPath) == 'string' and info.reportPath ~= '' then
		lines[#lines + 1] = 'CSV report: ' .. info.reportPath
	elseif info.reportSkipped then
		lines[#lines + 1] = 'CSV report was not saved.'
	end

	return lines
end

function GeoFixCore.matchLine(match)
	local gps = match.gps or {}
	local lat = type(gps.latitude) == 'number' and gps.latitude or 0
	local lon = type(gps.longitude) == 'number' and gps.longitude or 0
	local targetName = tostring(match.target and match.target.name or '')
	if match.method == 'interpolated' then
		return string.format('%s  <-  %.6f, %.6f  (interpolated between %s and %s, %.0f km/h)',
			targetName, lat, lon,
			tostring(match.before and match.before.name or ''),
			tostring(match.after and match.after.name or ''),
			tonumber(match.speedKmh) or 0)
	end
	local signed = tonumber(match.signedDelta) or 0
	local sign = signed < 0 and '-' or '+'
	local how = match.method == 'exact' and 'exact time' or 'nearest'
	return string.format('%s  <-  %s  (%s, %s%s)',
		targetName,
		tostring(match.donor and match.donor.name or ''),
		how, sign, GeoFixCore.formatDuration(match.delta))
end

function GeoFixCore.detailText(plan, maxLines)
	if maxLines == nil then maxLines = GeoFixCore.SUMMARY_DETAIL_LIMIT end
	local lines = {}
	local matches = (plan and plan.matches) or {}
	for i, match in ipairs(matches) do
		if i > maxLines then
			lines[#lines + 1] = string.format('... and %d more', #matches - maxLines)
			break
		end
		lines[#lines + 1] = GeoFixCore.matchLine(match)
	end
	return table.concat(lines, '\n')
end

function GeoFixCore.deltaLabel(match, offset)
	local gps = match.gps or {}
	local lat = type(gps.latitude) == 'number' and gps.latitude or 0
	local lon = type(gps.longitude) == 'number' and gps.longitude or 0
	local text
	if match.method == 'interpolated' then
		text = string.format(
			'Interpolated %d%% of the way from %s to %s, %s apart, about %.0f km/h. Will write %.6f, %.6f.',
			math.floor(((tonumber(match.fraction) or 0) * 100) + 0.5),
			tostring(match.before and match.before.name or ''),
			tostring(match.after and match.after.name or ''),
			GeoFixCore.formatDuration(match.gap),
			tonumber(match.speedKmh) or 0,
			lat, lon)
		if type(match.altitude) == 'number' then
			text = text .. string.format(' Altitude %.0f m.', match.altitude)
		end
	elseif match.method == 'exact' then
		text = string.format('Same capture time as %s. Will write %.6f, %.6f.',
			tostring(match.donor and match.donor.name or ''), lat, lon)
	else
		local signed = tonumber(match.signedDelta) or 0
		local relation
		if signed < 0 then
			relation = 'Donor is ' .. GeoFixCore.formatDuration(match.delta) .. ' earlier'
		elseif (tonumber(match.delta) or 0) == 0 then
			relation = 'Same capture time'
		else
			relation = 'Donor is ' .. GeoFixCore.formatDuration(match.delta) .. ' later'
		end
		text = string.format('%s. Will write %.6f, %.6f. %s',
			relation, lat, lon, tostring(match.note or ''))
	end
	offset = tonumber(offset) or 0
	if offset ~= 0 then
		text = string.format('%s Clock offset %+d s was applied to the untagged photo.', text, offset)
	end
	return text
end

local function csvField(value)
	if value == nil then return '' end
	local s = tostring(value)
	-- Plain numbers stay numeric so a negative longitude is not treated as a formula.
	if not s:match('^%-?%d+%.?%d*$') then
		if s:match('^[=+@]') or s:match('^%-') or s:match('^\t') or s:match('^\r') then
			s = "'" .. s
		end
	end
	if s:find('[",\r\n]') then
		return '"' .. s:gsub('"', '""') .. '"'
	end
	return s
end

local function fmtNum(value, pattern)
	if type(value) ~= 'number' then return '' end
	return string.format(pattern, value)
end

local function csvSpeed(extra)
	local speed = extra.speedKmh
	if type(speed) ~= 'number' then speed = extra.rejectedSpeedKmh end
	return fmtNum(speed, '%.1f')
end

--- CSV text for every analyzed photo. UTF-8, no BOM (the plug-in adds a BOM on write).
-- Filenames that spreadsheets would treat as formulas are prefixed.
function GeoFixCore.buildReport(plan, meta)
	plan = plan or {}
	meta = meta or {}
	local copyAltitude = meta.copyAltitude ~= false
	local scope = GeoFixCore.normalizeScope(meta.scope)
	local source = meta.source
	local lines = {
		'scope,source,id,path,target,status,method,latitude,longitude,altitude,delta_seconds,donor,before,after,fraction,speed_kmh,note',
	}

	local function add(status, target, extra)
		extra = extra or {}
		target = target or {}
		local gps = extra.gps
		local altitude = extra.altitude
		if status == 'already_tagged' then
			gps = target.gps
			altitude = target.altitude
		end
		if status == 'match' and not copyAltitude then
			altitude = nil
		end
		local lat, lon
		if type(gps) == 'table' then
			lat = gps.latitude
			lon = gps.longitude
		end
		local fields = {
			csvField(scope),
			csvField(source),
			csvField(target.id),
			csvField(target.path),
			csvField(target.name),
			csvField(status),
			csvField(extra.method),
			csvField(fmtNum(lat, '%.6f')),
			csvField(fmtNum(lon, '%.6f')),
			csvField(fmtNum(altitude, '%.3f')),
			csvField(fmtNum(extra.delta, '%.3f')),
			csvField(extra.donor and extra.donor.name),
			csvField(extra.before and extra.before.name),
			csvField(extra.after and extra.after.name),
			csvField(fmtNum(extra.fraction, '%.4f')),
			csvField(csvSpeed(extra)),
			csvField(extra.note),
		}
		lines[#lines + 1] = table.concat(fields, ',')
	end

	for _, match in ipairs(plan.matches or {}) do
		add('match', match.target, match)
	end
	for _, item in ipairs(plan.tooFar or {}) do
		add('too_far', item.target, {
			delta = item.nearestDelta,
			note = item.note,
			speedKmh = item.speedKmh,
		})
	end
	for _, target in ipairs(plan.noTimestamp or {}) do
		add('no_timestamp', target, { note = 'No capture time' })
	end
	for _, target in ipairs(plan.alreadyTagged or {}) do
		add('already_tagged', target, { note = 'Already had GPS coordinates' })
	end

	return table.concat(lines, '\n') .. '\n'
end

--- XMP sidecar next to a photo. `IMG_0001.CR3` -> `IMG_0001.xmp` in the same directory.
-- The image path itself is never returned.
function GeoFixCore.sidecarPath(photoPath)
	if type(photoPath) ~= 'string' or photoPath == '' then return nil end
	local slash = photoPath:match('^.*()[/\\]')
	local dir, leaf
	if slash then
		dir = photoPath:sub(1, slash)
		leaf = photoPath:sub(slash + 1)
	else
		dir = ''
		leaf = photoPath
	end
	if leaf == '' or leaf == '.' or leaf == '..' then return nil end
	if leaf:find('[/\\]', 1, false) then return nil end
	local base = leaf:match('^(.*)%.[^%.\\/]+$')
	if not base or base == '' then base = leaf end
	if base == '' or base == '.' or base == '..' then return nil end
	return dir .. base .. '.xmp'
end

--- EXIF GPS text used by Lightroom sidecars, e.g. "41,24.202800N".
-- @return text, ref ("N"/"S" or "E"/"W")
function GeoFixCore.formatExifCoord(degrees, isLatitude)
	local negative = degrees < 0
	local ref
	if isLatitude then
		ref = negative and 'S' or 'N'
	else
		ref = negative and 'W' or 'E'
	end
	local absv = math.abs(degrees)
	local deg = math.floor(absv)
	local minutes = (absv - deg) * 60
	if minutes >= 59.9999995 then
		minutes = 0
		deg = deg + 1
	end
	return string.format('%d,%.6f%s', deg, minutes, ref), ref
end

local function patternQuote(text)
	return (text:gsub('(%W)', '%%%1'))
end

local function exifPrefix(xml)
	local prefix = xml:match('xmlns:([%w_%-]+)="http://ns%.adobe%.com/exif/1%.0/"')
	if prefix and prefix ~= '' then return prefix end
	return 'exif'
end

local function hasExifTag(xml, prefix, tag)
	if xml:find(prefix .. ':' .. tag .. '="', 1, true) then return true end
	if xml:find(prefix .. ':' .. tag .. "='", 1, true) then return true end
	if xml:find('<' .. prefix .. ':' .. tag .. '>', 1, true) then return true end
	return false
end

local function replaceExifTag(xml, prefix, tag, value)
	local quoted = patternQuote(prefix)
	local found = false
	local attr = prefix .. ':' .. tag .. '="'
	if xml:find(attr, 1, true) then
		xml = xml:gsub('(' .. quoted .. ':' .. tag .. '=")[^"]*(")', function(open, close)
			return open .. value .. close
		end)
		found = true
	end
	local attrSingle = prefix .. ':' .. tag .. "='"
	if xml:find(attrSingle, 1, true) then
		xml = xml:gsub('(' .. quoted .. ':' .. tag .. "=')[^']*(')", function(open, close)
			return open .. value .. close
		end)
		found = true
	end
	local openElem = '<' .. prefix .. ':' .. tag .. '>'
	if xml:find(openElem, 1, true) then
		xml = xml:gsub('(<' .. quoted .. ':' .. tag .. '>%s*)[^<]*(%s*</' .. quoted .. ':' .. tag .. '>)', function(open, close)
			return open .. value .. close
		end)
		found = true
	end
	return xml, found
end

local function looksLikeXmp(xml)
	return xml:find('x:xmpmeta', 1, true)
		or xml:find('rdf:RDF', 1, true)
		or xml:find('<rdf:Description', 1, true)
end

local function insertExifAttrs(xml, prefix, attrs)
	local startAt = xml:find('<rdf:Description', 1, true)
	if not startAt then return nil end
	local closeAt = xml:find('>', startAt, true)
	if not closeAt then return nil end
	local insertAt = closeAt
	if xml:sub(closeAt - 1, closeAt - 1) == '/' then
		insertAt = closeAt - 1
	end
	local addition = ' ' .. attrs
	local xmlns = 'xmlns:' .. prefix .. '='
	if not xml:find(xmlns, 1, true) then
		addition = ' xmlns:' .. prefix .. '="http://ns.adobe.com/exif/1.0/"' .. addition
	end
	return xml:sub(1, insertAt - 1) .. addition .. xml:sub(insertAt)
end

local function minimalXmp(latText, lonText, altText, altRef)
	local altitude = ''
	if altText then
		altitude = '\n    exif:GPSAltitude="' .. altText .. '"\n    exif:GPSAltitudeRef="' .. altRef .. '"'
	end
	return '<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
		.. '<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="GeoFix">\n'
		.. ' <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
		.. '  <rdf:Description rdf:about=""\n'
		.. '    xmlns:exif="http://ns.adobe.com/exif/1.0/"\n'
		.. '    exif:GPSLatitude="' .. latText .. '"\n'
		.. '    exif:GPSLongitude="' .. lonText .. '"' .. altitude .. '>\n'
		.. '  </rdf:Description>\n'
		.. ' </rdf:RDF>\n'
		.. '</x:xmpmeta>\n'
		.. '<?xpacket end="w"?>\n'
end

--- Merge GPS into an XMP sidecar. Other tags are left in place.
-- A nil or blank document becomes a new sidecar. A non-XMP document is refused.
-- A nil altitude leaves any existing altitude tags unchanged.
-- @return xml, error
function GeoFixCore.upsertGpsXmp(existing, latitude, longitude, altitude)
	if type(latitude) ~= 'number' or type(longitude) ~= 'number' then
		return nil, 'missing coordinates'
	end
	local latText, latRef = GeoFixCore.formatExifCoord(latitude, true)
	local lonText, lonRef = GeoFixCore.formatExifCoord(longitude, false)
	local altText, altRef
	if type(altitude) == 'number' then
		local hundredths = math.floor(math.abs(altitude) * 100 + 0.5)
		altText = string.format('%d/100', hundredths)
		altRef = altitude < 0 and '1' or '0'
	end

	if existing == nil or existing:match('^%s*$') then
		return minimalXmp(latText, lonText, altText, altRef), nil
	end
	if not looksLikeXmp(existing) then
		return nil, 'sidecar is not XMP'
	end

	local xml = existing
	local prefix = exifPrefix(xml)
	xml = replaceExifTag(xml, prefix, 'GPSLatitude', latText)
	xml = replaceExifTag(xml, prefix, 'GPSLongitude', lonText)
	xml = replaceExifTag(xml, prefix, 'GPSLatitudeRef', latRef)
	xml = replaceExifTag(xml, prefix, 'GPSLongitudeRef', lonRef)
	if altText then
		xml = replaceExifTag(xml, prefix, 'GPSAltitude', altText)
		xml = replaceExifTag(xml, prefix, 'GPSAltitudeRef', altRef)
	end

	local missing = {}
	if not hasExifTag(xml, prefix, 'GPSLatitude') then
		missing[#missing + 1] = prefix .. ':GPSLatitude="' .. latText .. '"'
	end
	if not hasExifTag(xml, prefix, 'GPSLongitude') then
		missing[#missing + 1] = prefix .. ':GPSLongitude="' .. lonText .. '"'
	end
	if altText and not hasExifTag(xml, prefix, 'GPSAltitude') then
		missing[#missing + 1] = prefix .. ':GPSAltitude="' .. altText .. '"'
	end
	if altText and not hasExifTag(xml, prefix, 'GPSAltitudeRef') then
		missing[#missing + 1] = prefix .. ':GPSAltitudeRef="' .. altRef .. '"'
	end
	if #missing > 0 then
		xml = insertExifAttrs(xml, prefix, table.concat(missing, ' '))
		if not xml then return nil, 'could not find an XMP description' end
	end
	return xml, nil
end

return GeoFixCore
