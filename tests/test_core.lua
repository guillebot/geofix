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
	if lat ~= nil then r.gps = { latitude = lat, longitude = lon } end
	r.altitude = alt
	return r
end

local function near(a, b, tol, label)
	tol = tol or 1e-6
	local ok = type(a) == 'number' and type(b) == 'number' and math.abs(a - b) <= tol
	check(ok, string.format('%s (expected %s +/- %s, got %s)', label, tostring(b), tostring(tol), tostring(a)))
end

-- hasGps ----------------------------------------------------------------------
check(Core.hasGps(rec('a', 0, 40.4, -3.7)), 'valid gps is detected')
check(not Core.hasGps(rec('a', 0)), 'missing gps')
check(not Core.hasGps(rec('a', 0, 0, 0)), '(0,0) is treated as no gps')
check(Core.hasGps(rec('eq', 0, 0, 10)), 'equator with a real longitude is gps')
check(Core.hasGps(rec('pm', 0, 10, 0)), 'prime meridian with a real latitude is gps')
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
eq(p.matches[1].method, 'nearest', 'far cities fall back to nearest')
eq(p.matches[1].interpolationRejected, 'speed', 'far cities reject interpolation')
eq(p.matches[1].gps.latitude, 40, 'fallback copies nearest latitude')
eq(p.matches[1].gps.longitude, -3, 'fallback copies nearest longitude')
eq(p.matches[2].target.id, 'raw2.cr3', 'match 2 target')
eq(p.matches[2].donor.id, 'phone2.jpg', 'match 2 donor')
eq(p.matches[2].signedDelta, 100, 'match 2 signed delta (donor later)')
eq(p.matches[2].gps.latitude, 41, 'fallback copies second donor latitude')
eq(p.rejected.speed, 2, 'both city matches skipped interpolation')
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

-- distance and interpolation -------------------------------------------------
local degree = 2 * math.pi * 6371000 / 360
near(Core.haversineMeters(0, 0, 0, 0), 0, 1e-6, 'same point is 0 m')
near(Core.haversineMeters(0, 0, 0, 1), degree, 1, 'one degree at the equator')
near(Core.haversineMeters(0, 179, 0, -179), 2 * degree, 2, 'dateline uses the short arc')
near(Core.haversineMeters(10, 20, 11, 21), Core.haversineMeters(11, 21, 10, 20), 1e-6, 'distance is symmetric')

local wrapped = Core.interpolateCoordinate({ latitude = 0, longitude = 179 }, { latitude = 0, longitude = -179 }, 0.5)
near(math.abs(wrapped.longitude), 180, 1e-6, 'midpoint crosses the antimeridian')
near(wrapped.latitude, 0, 1e-9, 'dateline midpoint latitude')

local before = rec('before', 0, 10, 20, 100)
local after = rec('after', 100, 10.002, 20, 300)
local between = rec('between', 25)
between.path = 'C:\\Photos\\a.jpg'
local blended = Core.plan({ between }, { before, after }, {
	maxDeltaSeconds = 5,
	maxInterpolateSeconds = 1000,
	maxSpeedKmh = 250,
})
eq(#blended.matches, 1, 'interpolation is used outside the nearest window')
eq(blended.matches[1].method, 'interpolated', 'slow segment is interpolated')
near(blended.matches[1].gps.latitude, 10.0005, 1e-9, 'latitude is one quarter of the way')
near(blended.matches[1].fraction, 0.25, 1e-9, 'time fraction')
near(blended.matches[1].altitude, 150, 1e-6, 'altitude is blended')
eq(blended.matches[1].donor.id, 'before', 'review donor is the closer photo')
check(Core.deltaLabel(blended.matches[1], 90):find('Will write 10.000500, 20.000000', 1, true) ~= nil, 'review label shows written coordinates')
check(Core.deltaLabel(blended.matches[1], 90):find('Clock offset +90 s', 1, true) ~= nil, 'review label shows the clock offset')

local noAlt = rec('noalt', 100, 10.002, 20)
local partial = Core.plan({ between }, { before, noAlt }, {
	maxDeltaSeconds = 5,
	maxInterpolateSeconds = 1000,
	maxSpeedKmh = 250,
})
check(partial.matches[1].altitude == nil, 'altitude is omitted unless both donors have it')

local meters = Core.haversineMeters(10, 10, 10.01, 10)
local gap = 100
local speed = (meters / gap) * 3.6
local west = rec('west', 0, 10, 10)
local east = rec('east', gap, 10.01, 10)
local mid = rec('mid', gap / 2)
local accepted = Core.plan({ mid }, { west, east }, {
	maxSpeedKmh = speed,
	maxInterpolateSeconds = 1000,
	maxDeltaSeconds = 1000,
})
local rejected = Core.plan({ mid }, { west, east }, {
	maxSpeedKmh = speed - 1,
	maxInterpolateSeconds = 1000,
	maxDeltaSeconds = 1000,
})
eq(accepted.matches[1].method, 'interpolated', 'speed limit is inclusive')
eq(rejected.matches[1].method, 'nearest', 'over-speed segment falls back to nearest')
eq(rejected.matches[1].interpolationRejected, 'speed', 'fallback records the speed rejection')
eq(rejected.matches[1].donor.id, 'west', 'tie prefers the earlier donor')
eq(rejected.rejected.speed, 1, 'speed rejection is counted')

local tooQuick = Core.plan({ mid }, { west, east }, {
	maxSpeedKmh = speed - 1,
	maxInterpolateSeconds = 1000,
	maxDeltaSeconds = 10,
})
eq(#tooQuick.matches, 0, 'impossible segment outside the nearest window is left unchanged')
eq(tooQuick.tooFar[1].reason, 'speed', 'unchanged photo records the speed reason')

local early = rec('early', 0, 1, 1)
local late = rec('late', 10000, 1.001, 1)
local soon = rec('soon', 30)
local gapped = Core.plan({ soon }, { early, late }, {
	maxInterpolateSeconds = 100,
	maxDeltaSeconds = 600,
	maxSpeedKmh = 250,
})
eq(gapped.matches[1].method, 'nearest', 'a far neighbor disables interpolation')
eq(gapped.matches[1].interpolationRejected, 'gap', 'gap rejection is recorded')
eq(gapped.matches[1].donor.id, 'early', 'gap fallback uses the near donor')

local stamp = rec('stamp', 1000, 5, 6, 42)
local same = rec('same', 1000)
local exact = Core.plan({ same }, { stamp, late }, { maxDeltaSeconds = 1, maxInterpolateSeconds = 1 })
eq(exact.matches[1].method, 'exact', 'equal capture time is copied exactly')
eq(exact.matches[1].delta, 0, 'exact delta')
eq(exact.matches[1].gps.longitude, 6, 'exact longitude')
eq(exact.counts.exact, 1, 'exact count')

local crossed = rec('crossed', 5000)
local dateline = Core.plan({ crossed }, {
	rec('westedge', 0, 0, 179, 0),
	rec('eastedge', 10000, 0, -179, 100),
}, { maxDeltaSeconds = 10, maxInterpolateSeconds = 20000, maxSpeedKmh = 250 })
eq(dateline.matches[1].method, 'interpolated', 'dateline segment can be interpolated')
near(math.abs(dateline.matches[1].gps.longitude), 180, 1e-4, 'dateline result sits on the antimeridian')
near(dateline.matches[1].altitude, 50, 1e-6, 'dateline altitude midpoint')

-- scope, summary, report ------------------------------------------------------
eq(Core.normalizeScope('nope'), 'tree', 'unknown scope becomes the whole tree')
eq(Core.scopeChoices()[1].value, 'tree', 'recommended scope is listed first')
check(Core.scopeChoices()[1].title:find('one project', 1, true) ~= nil, 'scope menu says one project')
eq(Core.scopeTitle('tree'), 'Entire folder tree - one project', 'tree title')
check(Core.scopeDetail('tree'):find('Subfolder boundaries are ignored', 1, true) ~= nil, 'tree scope ignores subfolders')
check(Core.scopeDetail('folder'):find('left out', 1, true) ~= nil, 'folder scope excludes subfolders')
check(Core.scopeDetail('selection'):find('filmstrip', 1, true) ~= nil, 'selection scope explains the filmstrip')
local parentAndChildren = Core.classifyFolders({
	{ id = 'root', parentId = nil },
	{ id = 'a', parentId = 'root' },
	{ id = 'b', parentId = 'root' },
	{ id = 'c', parentId = 'root' },
	{ id = 'd', parentId = 'root' },
})
eq(parentAndChildren.kind, 'ancestor', 'parent plus subfolders is one project')
eq(parentAndChildren.id, 'root', 'project root is the parent folder')

local onlyChildren = Core.classifyFolders({
	{ id = 'a', parentId = 'parent' },
	{ id = 'b', parentId = 'parent' },
	{ id = 'c', parentId = 'parent' },
	{ id = 'd', parentId = 'parent' },
})
eq(onlyChildren.kind, 'siblings', 'subfolders reported without the parent share that parent')
eq(onlyChildren.parentId, 'parent', 'shared parent is kept')
eq(Core.classifyFolders({}).kind, 'none', 'no folders')
eq(Core.classifyFolders({ { id = 'only', parentId = 'higher' } }).kind, 'one', 'one selected folder stays that folder')
eq(Core.classifyFolders({
	{ id = 'a', parentId = 'p1' },
	{ id = 'b', parentId = 'p2' },
}).kind, 'ambiguous', 'unrelated folders are rejected')

check(Core.singleRootError(0, 'selection') == nil, 'selection does not need a folder')
check(Core.singleRootError(3, 'selection') == nil, 'selection ignores extra folders')
check(Core.singleRootError(1, 'tree') == nil, 'one folder is a valid project')
check(Core.singleRootError(0, 'tree'):find('single folder', 1, true) ~= nil, 'missing folder explains what to select')
check(Core.singleRootError(2, 'folder'):find('single root folder', 1, true) ~= nil, 'two folders are rejected')

eq(Core.writeTimeoutSeconds(0), 120, 'write timeout base')
eq(Core.writeTimeoutSeconds(100), 220, 'write timeout grows with matches')
eq(Core.writeTimeoutSeconds(100000), 7200, 'write timeout cap')
eq(Core.writeTimeoutSeconds(-5), 120, 'negative match count uses the base timeout')
eq(Core.METADATA_CHUNK_SIZE, 1000, 'metadata is read in batches of 1000')
eq(Core.LARGE_PROJECT_COUNT, 2000, 'large-project confirmation threshold')
eq(Core.TEST_MODE_PAIR_LIMIT, 40, 'test mode warns above 40 pairs')

local summary = table.concat(Core.summaryLines(blended, {
	scope = 'tree',
	source = 'D:\\Trip',
	photoCount = 4,
	interpolate = true,
	maxInterpolateSeconds = 7200,
	maxSpeedKmh = 250,
	maxDeltaSeconds = 600,
	copyAltitude = true,
	reportPath = 'C:\\Temp\\geofix.csv',
}), '\n')
check(summary:find('Scope: Entire folder tree - one project', 1, true) ~= nil, 'summary names the project scope')
check(summary:find('Subfolder boundaries are ignored', 1, true) ~= nil, 'summary repeats the tree rule')
check(summary:find('D:\\Trip', 1, true) ~= nil, 'summary names the source')
check(summary:find('CSV report: C:\\Temp\\geofix.csv', 1, true) ~= nil, 'summary names the report')

local speedSummary = table.concat(Core.summaryLines(rejected, {
	scope = 'folder',
	source = 'A',
	interpolate = true,
	maxInterpolateSeconds = 1000,
	maxSpeedKmh = 1,
	maxDeltaSeconds = 1000,
}), '\n')
check(speedSummary:find('Current folder only', 1, true) ~= nil, 'summary names folder scope')
check(speedSummary:find('implied travel speed was too high', 1, true) ~= nil, 'summary explains skipped interpolation')

local many = {}
local only = rec('donor', 0, 1, 1)
for i = 1, 41 do
	many[i] = rec('t' .. i, i)
end
local listed = Core.detailText(Core.plan(many, { only }, { interpolate = false, maxDeltaSeconds = 600 }))
check(listed:find('... and 1 more', 1, true) ~= nil, 'detail list keeps the first 40 matches')

local formula = rec('=2+2', 0)
formula.name = 'a,b.jpg'
formula.path = 'C:\\Photos\\a.jpg'
local nearDonor = rec('donor.jpg', 5, 10, -3.7, 12)
local reported = Core.plan({ formula, nearDonor }, { formula, nearDonor }, { maxDeltaSeconds = 60, interpolate = false })
local csv = Core.buildReport(reported, { scope = 'tree', source = '=hidden', copyAltitude = false })
eq(csv:match('^[^\n]+'), 'scope,source,id,path,target,status,method,latitude,longitude,altitude,delta_seconds,donor,before,after,fraction,speed_kmh,note', 'csv header')
check(csv:find("'=2+2", 1, true) ~= nil, 'formula-like id is prefixed')
check(csv:find(',=2+2', 1, true) == nil, 'formula-like id is not a raw field')
check(csv:find("'=hidden", 1, true) ~= nil, 'formula-like source is prefixed')
check(csv:find('"a,b.jpg"', 1, true) ~= nil, 'comma in a filename is quoted')
check(csv:find('-3.700000', 1, true) ~= nil, 'negative longitude is preserved')
check(csv:find("'-3.700000", 1, true) == nil, 'negative longitude is not prefixed')
local matchRow = csv:match('[^\n]*"a,b.jpg"[^\n]*')
check(matchRow ~= nil and matchRow:find('-3.700000,,', 1, true) ~= nil, 'match altitude column is empty when copy is off')
check(csv:find('already_tagged', 1, true) ~= nil, 'csv includes photos that already had gps')

local full = Core.buildReport(blended, { scope = 'selection', source = 'Trip', copyAltitude = true })
check(full:find('10.000500', 1, true) ~= nil, 'csv writes the interpolated latitude')
check(full:find('150.000', 1, true) ~= nil, 'csv writes the blended altitude')
check(full:find('selection', 1, true) ~= nil, 'csv records the scope')

-- 20k library: every 20th photo is geotagged, everything else is filled in. --
local library = {}
for i = 1, 20000 do
	if i % 20 == 0 then
		library[i] = rec('phone' .. i, i * 30, 10 + i * 0.0000001, 20, 100)
	else
		library[i] = rec('cam' .. i, i * 30 + 5)
	end
end
local started = os.clock()
local big = Core.plan(library, library)
local elapsed = os.clock() - started
eq(big.donorCount, 1000, '20k donor count')
eq(#big.alreadyTagged, 1000, '20k already tagged')
eq(#big.matches, 19000, '20k matches')
eq(#big.tooFar, 0, '20k none too far')
eq(#big.noTimestamp, 0, '20k timestamps present')
eq(big.counts.interpolated, 18981, '20k interpolated')
eq(big.counts.nearest, 19, '20k nearest before the first donor')
eq(big.counts.exact, 0, '20k exact')
check(elapsed < 10, string.format('20k plan finished in %.2fs', elapsed))
local reportStarted = os.clock()
local bigCsv = Core.buildReport(big, { scope = 'tree', source = 'Trip', copyAltitude = true })
local _, newlines = bigCsv:gsub('\n', '\n')
eq(newlines, 20001, 'csv has a header plus every photo')
check(os.clock() - reportStarted < 10, '20k csv finished')
-- sidecar path and XMP merge ------------------------------------------------
eq(Core.sidecarPath('C:\\Photos\\Trip\\IMG_0001.CR3'), 'C:\\Photos\\Trip\\IMG_0001.xmp', 'windows raw gets a sibling xmp')
eq(Core.sidecarPath('/Users/a/b.raw/IMG.NEF'), '/Users/a/b.raw/IMG.xmp', 'dots in a directory stay put')
eq(Core.sidecarPath('C:\\Photos\\Trip\\photo'), 'C:\\Photos\\Trip\\photo.xmp', 'no extension still gets xmp')
check(Core.sidecarPath('C:\\Photos\\Trip\\IMG_0001.CR3') ~= 'C:\\Photos\\Trip\\IMG_0001.CR3', 'sidecar is not the image')
check(Core.sidecarPath('..') == nil, 'parent segment is not a sidecar target')
local latText, latRef = Core.formatExifCoord(-33.5, true)
local lonText, lonRef = Core.formatExifCoord(-70.25, false)
eq(latText, '33,30.000000S', 'south latitude')
eq(latRef, 'S', 'south ref')
eq(lonText, '70,15.000000W', 'west longitude')
eq(lonRef, 'W', 'west ref')

local created = Core.upsertGpsXmp(nil, 41.40338, 2.17403, 12.5)
check(created:find('exif:GPSLatitude="41,24.202800N"', 1, true) ~= nil, 'new sidecar latitude')
check(created:find('exif:GPSLongitude="2,10.441800E"', 1, true) ~= nil, 'new sidecar longitude')
check(created:find('exif:GPSAltitude="1250/100"', 1, true) ~= nil, 'new sidecar altitude')
check(created:find('IMG_', 1, true) == nil, 'new sidecar has no filename')
local again = Core.upsertGpsXmp(created, 41.40338, 2.17403, 12.5)
local _, latCount = again:gsub('exif:GPSLatitude="', '')
eq(latCount, 1, 'updating a sidecar does not duplicate latitude')

local existing = '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
	.. '<rdf:Description rdf:about="" crs:HasSettings="True" exif:GPSLatitude="1,0.000000N" exif:GPSLongitude="2,0.000000E" exif:GPSAltitude="10/1">'
	.. '</rdf:Description></rdf:RDF></x:xmpmeta>'
local merged = Core.upsertGpsXmp(existing, 10, 20, nil)
check(merged:find('crs:HasSettings="True"', 1, true) ~= nil, 'existing sidecar metadata is kept')
check(merged:find('exif:GPSLatitude="10,0.000000N"', 1, true) ~= nil, 'existing latitude is replaced')
check(merged:find('exif:GPSAltitude="10/1"', 1, true) ~= nil, 'altitude is left unchanged when it is not copied')
check(merged:find('1,0.000000N', 1, true) == nil, 'old latitude is gone')

local elements = '<rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/">'
	.. '<exif:GPSLatitude>1,0.000000N</exif:GPSLatitude><exif:GPSLongitude>2,0.000000E</exif:GPSLongitude></rdf:Description>'
local elemMerged = Core.upsertGpsXmp(elements, 5, 6, nil)
check(elemMerged:find('<exif:GPSLatitude>5,0.000000N</exif:GPSLatitude>', 1, true) ~= nil, 'element latitude is replaced')
local _, elemCount = elemMerged:gsub('<exif:GPSLatitude>', '')
eq(elemCount, 1, 'element latitude is not duplicated')

local bare = '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" crs:Version="15.0"/></rdf:RDF></x:xmpmeta>'
local inserted = Core.upsertGpsXmp(bare, 1, 2, nil)
check(inserted:find('crs:Version="15.0"', 1, true) ~= nil, 'version survives insertion')
check(inserted:find('exif:GPSLongitude="2,0.000000E"', 1, true) ~= nil, 'longitude is inserted')
check(Core.upsertGpsXmp('this is not xmp', 1, 2, nil) == nil, 'non-xmp sidecar is refused')

print(string.format('large plan: %.2fs', elapsed))

print(string.format('%d passed, %d failed', passes, failures))
if failures > 0 then os.exit(1) end
