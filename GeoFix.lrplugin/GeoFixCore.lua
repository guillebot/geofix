--[[----------------------------------------------------------------------------
GeoFixCore.lua

Pure matching logic. No Lightroom SDK imports, so it can be exercised with a
plain Lua interpreter (see tests/test_core.lua). Must stay Lua 5.1 compatible
because that is what Lightroom Classic embeds.

A "record" is a plain table describing one photo:

  {
    id       = <anything unique>,
    name     = <string, for display>,
    time     = <number: capture time in seconds, any epoch> or nil,
    gps      = { latitude = <number>, longitude = <number> } or nil,
    altitude = <number> or nil,
  }

Times only need to be comparable with each other, so Lightroom's
"seconds since 2001-01-01" values can be used directly.
------------------------------------------------------------------------------]]

local GeoFixCore = {}

--- True when the record carries usable coordinates.
-- (0, 0) is treated as "no location": it is what some devices write when the
-- GPS fix was missing and it is never a real photo location in practice.
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
	return a.time < b.time
end

--- Filters a pool of records down to usable donors (have GPS and a timestamp),
-- sorted by capture time ascending.
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

--- Builds the plan of GPS copies to perform.
--
-- @param targets array of records that may receive coordinates
-- @param pool    array of records that may donate coordinates (may overlap targets)
-- @param opts    {
--                  maxDeltaSeconds    = number (default 600),
--                  clockOffsetSeconds = number added to every target's time before
--                                       matching (default 0). Use it when the camera
--                                       clock is not aligned with the donor device.
--                }
-- @return {
--   matches       = { { target=, donor=, delta=, signedDelta= }, ... },
--   tooFar        = { { target=, nearestDelta= }, ... },   -- no donor inside the window
--   noTimestamp   = { record, ... },                        -- target without capture time
--   alreadyTagged = { record, ... },                        -- target already had GPS
--   donorCount    = number,
--   stats         = { maxDelta=, avgDelta= } or nil,
-- }
function GeoFixCore.plan(targets, pool, opts)
	opts = opts or {}
	local maxDelta = tonumber(opts.maxDeltaSeconds) or 600
	local offset = tonumber(opts.clockOffsetSeconds) or 0

	local donors = GeoFixCore.sortedDonors(pool)

	local result = {
		matches = {},
		tooFar = {},
		noTimestamp = {},
		alreadyTagged = {},
		donorCount = #donors,
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
			local donor, delta = GeoFixCore.findNearest(donors, t)
			if donor and delta <= maxDelta then
				result.matches[#result.matches + 1] = {
					target = target,
					donor = donor,
					delta = delta,
					signedDelta = donor.time - t,
				}
				sum = sum + delta
				if delta > worst then worst = delta end
			else
				result.tooFar[#result.tooFar + 1] = { target = target, nearestDelta = delta }
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

return GeoFixCore
