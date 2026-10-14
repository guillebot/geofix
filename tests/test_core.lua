-- Run from the repository root:  lua tests/test_core.lua
package.path = './GeoFix.lrplugin/?.lua;' .. package.path

local Core = require 'GeoFixCore'

local failures, passes = 0, 0

local function check(cond, label)
	if cond then
		passes = passes + 1
	else
		failures = failures + 1
		io.stderr:write('FAIL: ' .. label .. '\n')
	end
end

local function eq(a, b, label)
	check(a == b, string.format('%s (expected %s, got %s)', label, tostring(b), tostring(a)))
end

local function rec(id, time, lat, lon, alt)
	local r = { id = id, name = id, time = time }
	if lat then r.gps = { latitude = lat, longitude = lon } end
	r.altitude = alt
	return r
end

-- hasGps ----------------------------------------------------------------------
check(Core.hasGps(rec('a', 0, 40.4, -3.7)), 'valid gps is detected')
check(not Core.hasGps(rec('a', 0)), 'missing gps')
check(not Core.hasGps(rec('a', 0, 0, 0)), '(0,0) is treated as no gps')
check(not Core.hasGps({ gps = { latitude = 'x', longitude = 1 } }), 'non numeric gps')
check(not Core.hasGps({ gps = { latitude = 95, longitude = 1 } }), 'out of range latitude')
check(not Core.hasGps(nil), 'nil record')

-- sortedDonors / findNearest --------------------------------------------------
local pool = {
	rec('p3', 300, 1, 1),
	rec('p1', 100, 2, 2),
	rec('noTime', nil, 3, 3),
	rec('noGps', 150),
	rec('p2', 200, 4, 4),
}
local donors = Core.sortedDonors(pool)
eq(#donors, 3, 'only timestamped geotagged records are donors')
eq(donors[1].id, 'p1', 'donors sorted asc 1')
eq(donors[2].id, 'p2', 'donors sorted asc 2')
eq(donors[3].id, 'p3', 'donors sorted asc 3')

local d, delta = Core.findNearest(donors, 190)
eq(d.id, 'p2', 'nearest below')
eq(delta, 10, 'nearest below delta')

d, delta = Core.findNearest(donors, 240)
eq(d.id, 'p2', 'nearest above')
eq(delta, 40, 'nearest above delta')

d, delta = Core.findNearest(donors, 150)
eq(d.id, 'p1', 'exact tie prefers earlier')

d, delta = Core.findNearest(donors, -1000)
eq(d.id, 'p1', 'before first donor')
eq(delta, 1100, 'before first donor delta')

d, delta = Core.findNearest(donors, 10000)
eq(d.id, 'p3', 'after last donor')
eq(delta, 9700, 'after last donor delta')

d, delta = Core.findNearest({}, 10)
check(d == nil and delta == nil, 'no donors returns nil')

d = Core.findNearest({ rec('only', 5, 1, 1) }, 999)
eq(d.id, 'only', 'single donor')

-- plan ------------------------------------------------------------------------
local phone1 = rec('phone1.jpg', 1000, 40.0, -3.0, 650)
local phone2 = rec('phone2.jpg', 2000, 41.0, -4.0)
local raw1 = rec('raw1.cr3', 1030)      -- 30 s after phone1
local raw2 = rec('raw2.cr3', 1900)      -- 100 s before phone2
local raw3 = rec('raw3.cr3', 5000)      -- 3000 s after phone2, too far
local raw4 = rec('raw4.cr3', nil)       -- no time
local raw5 = rec('raw5.cr3', 1500, 10, 10) -- already tagged

local targets = { raw1, raw2, raw3, raw4, raw5 }
local p = Core.plan(targets, { phone1, phone2, raw1, raw2, raw3, raw4, raw5 }, { maxDeltaSeconds = 600 })

eq(p.donorCount, 3, 'donor count includes already tagged target')
eq(#p.matches, 2, 'two matches')
eq(p.matches[1].target.id, 'raw1.cr3', 'match 1 target')
eq(p.matches[1].donor.id, 'phone1.jpg', 'match 1 donor')
eq(p.matches[1].delta, 30, 'match 1 delta')
eq(p.matches[1].signedDelta, -30, 'match 1 signed delta (donor earlier)')
eq(p.matches[2].target.id, 'raw2.cr3', 'match 2 target')
eq(p.matches[2].donor.id, 'phone2.jpg', 'match 2 donor')
eq(p.matches[2].signedDelta, 100, 'match 2 signed delta (donor later)')
eq(#p.tooFar, 1, 'one too far')
eq(p.tooFar[1].target.id, 'raw3.cr3', 'too far target')
eq(p.tooFar[1].nearestDelta, 3000, 'too far nearest delta')
eq(#p.noTimestamp, 1, 'one without timestamp')
eq(#p.alreadyTagged, 1, 'one already tagged')
eq(p.stats.maxDelta, 100, 'stats max')
eq(p.stats.avgDelta, 65, 'stats avg')

-- window boundary is inclusive
p = Core.plan({ raw2 }, { phone2 }, { maxDeltaSeconds = 100 })
eq(#p.matches, 1, 'delta == max is accepted')
p = Core.plan({ raw2 }, { phone2 }, { maxDeltaSeconds = 99 })
eq(#p.matches, 0, 'delta > max is rejected')

-- clock offset: camera 100 s behind the phone -> raw2 (1900) + 100 == phone2 (2000)
p = Core.plan({ raw2 }, { phone2 }, { maxDeltaSeconds = 10, clockOffsetSeconds = 100 })
eq(#p.matches, 1, 'clock offset aligns camera to donor')
eq(p.matches[1].delta, 0, 'clock offset delta')

-- offset in the wrong direction pushes it out of the window
p = Core.plan({ raw2 }, { phone2 }, { maxDeltaSeconds = 150, clockOffsetSeconds = -100 })
eq(#p.matches, 0, 'wrong offset direction misses')

-- no donors at all
p = Core.plan({ raw1 }, { raw1 }, { maxDeltaSeconds = 600 })
eq(p.donorCount, 0, 'no donors')
eq(#p.tooFar, 1, 'target reported as too far when no donors')
check(p.tooFar[1].nearestDelta == nil, 'nearestDelta nil when no donors')
check(p.stats == nil, 'no stats without matches')

-- defaults
p = Core.plan({ raw1 }, { phone1 })
eq(#p.matches, 1, 'default window (600 s) applies')

-- formatDuration --------------------------------------------------------------
eq(Core.formatDuration(0), '0s', 'fmt 0')
eq(Core.formatDuration(42.4), '42s', 'fmt seconds')
eq(Core.formatDuration(-42), '42s', 'fmt negative uses abs')
eq(Core.formatDuration(185), '3m 05s', 'fmt minutes')
eq(Core.formatDuration(3600), '1h 00m', 'fmt hour')
eq(Core.formatDuration(7800), '2h 10m', 'fmt hours+minutes')

-- larger randomized consistency check: binary search == linear scan ----------
math.randomseed(42)
local big = {}
for i = 1, 500 do
	big[#big + 1] = rec('d' .. i, math.random(0, 100000), 1, 1)
end
local sorted = Core.sortedDonors(big)
for _ = 1, 500 do
	local t = math.random(-1000, 101000)
	local got, gotDelta = Core.findNearest(sorted, t)
	local bestDelta = math.huge
	for _, r in ipairs(sorted) do
		local dd = math.abs(r.time - t)
		if dd < bestDelta then bestDelta = dd end
	end
	if gotDelta ~= bestDelta then
		check(false, string.format('binary search mismatch at t=%d (%s vs %s)', t, tostring(gotDelta), tostring(bestDelta)))
	else
		passes = passes + 1
	end
	check(got ~= nil, 'randomized result non-nil')
end

print(string.format('%d passed, %d failed', passes, failures))
if failures > 0 then os.exit(1) end
