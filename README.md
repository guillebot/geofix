# GeoFix — Lightroom Classic plug-in

Fills in GPS coordinates for photos that have none.

Select a root folder and GeoFix treats **that folder and every subfolder as one project**. A camera file in one subfolder can take its location from a phone photo in any other subfolder. Photos that already have coordinates are left as they are and can donate those coordinates to the others.

For each photo that still needs a location, GeoFix uses the best fix it can justify:

1. The same capture time as a geotagged photo: copy that point.
2. Geotagged photos before and after it, close enough in time, and a plausible travel speed between them: place it on the straight line between those two points.
3. Otherwise, a geotagged photo inside the nearest-photo time window: copy that point.
4. Otherwise leave it unchanged.

## Installation

1. Clone or download this repository.
2. In Lightroom Classic open **File > Plug-in Manager**.
3. Click **Add**, select the `GeoFix.lrplugin` folder and click **Done**.

The plug-in is loaded from where it sits, so keep the folder in place (or copy it
somewhere permanent, e.g. `~/Library/Application Support/Adobe/Lightroom/Modules/`).

After an update, use **File > Plug-in Manager > Reload Plug-in** (or restart Lightroom).

## Usage

1. In the Library module, click **one** folder in the Folders panel. That folder is the project root. Do not select several folders, a collection, or All Photographs.
2. Run **Library > Plug-in Extras > GeoFix: Fill missing GPS...**
3. Leave **Scope** on **Entire folder tree - one project (recommended)**.
4. Click **Analyze**.
5. Read the summary. It names the scope, the folder, how many photos were read, how many can donate coordinates, how many are missing GPS, and how many will be interpolated versus copied from the nearest photo.
6. Click **Apply**.

The menu stays available even when the root folder looks empty in the grid. A folder that only contains subfolders is a valid project root.

Turn on **Dry run** the first time you point it at a large library. Turn on **Save a CSV report** if you want a spreadsheet of every photo before anything is written. Turn on **Test mode** only for a small set: it opens matches one at a time.

Apply writes each location into the `.xmp` sidecar beside the photo (`IMG_0001.CR3` becomes `IMG_0001.xmp` in the same folder). The image file itself is not opened for writing, including JPEG, HEIC, DNG, TIFF, and RAW. An existing sidecar keeps its other metadata; only the GPS tags are added or replaced.

Lightroom's catalog is updated to the same coordinates. That is what makes the pin show on the map, and it stops a later "save metadata" from overwriting the sidecar with an empty location. **Edit > Undo** reverts the catalog only. It does not delete or restore the `.xmp` files.

### A large nested folder

For a root that holds on the order of 20,000 photos:

1. Click that root once in the Folders panel.
2. Keep the scope on **Entire folder tree - one project**.
3. Enable **Dry run** and **Save a CSV report**, then Analyze.
4. At 2,000 photos or more, GeoFix asks before it reads metadata. The dialog repeats the scope and the folder path. Cancel if the folder is wrong.
5. Metadata is read in batches of 1,000. The progress bar can be canceled between batches, and nothing has been written yet.
6. The summary is the preflight: donors, photos missing GPS, interpolated matches, nearest-photo matches, and anything skipped. The first 40 matches are listed; the CSV has every photo.
7. Run it again with Dry run off when the summary looks right.

Library filters and star ratings are not applied to the folder-tree or current-folder scopes. Every photo Lightroom has in that folder is included, including virtual copies.

## Project scope

This is the setting that decides which photos belong to the run. It applies to photos that need coordinates and to photos that can donate them. They are the same set.

| Scope | What is included |
|---|---|
| **Entire folder tree - one project (recommended)** | Every photo in the selected root folder and in every subfolder. Subfolder boundaries are ignored. Any geotagged photo in the tree can supply coordinates to any untagged photo in the tree. |
| Current folder only | Only photos stored directly in the selected folder. Photos in subfolders are left out. |
| Selected photos only | Only the current selection. If fewer than two photos are selected, Lightroom uses the whole filmstrip. Subfolders are included only when that filmstrip is already listing them. |

The default is the entire folder tree. **File > Plug-in Manager > GeoFix > Reset settings to defaults** returns to that default.

Select exactly one folder for the tree and current-folder scopes. If several folders are selected, GeoFix stops and asks for a single root. Collections and All Photographs are not folder trees; use **Selected photos only** for those.

## How coordinates are chosen

Capture time is `dateTimeOriginal`, then `dateTimeDigitized`, then the file date. The clock offset is added to the untagged photo before any of the steps below. Donor times are not shifted.

| Situation | Result |
|---|---|
| The photo already has GPS | Left unchanged. It can still donate its coordinates. `(0, 0)` counts as no GPS. A zero latitude or a zero longitude on its own is kept. |
| No capture time | Skipped. |
| A geotagged photo has the same adjusted capture time | That point is copied. |
| Geotagged photos exist both before and after, each is inside the interpolation gap, and the speed between them is within the limit | Latitude, longitude, and (when both have it) altitude are placed proportionally between the two points. Longitude takes the short way across the antimeridian. |
| The segment is too long or too fast, but a geotagged photo is inside the max time difference | The nearest geotagged photo is copied. |
| Nothing qualifies | The photo is left unchanged. |

The speed check uses the two known points, not the untagged photo. If those two points are 140 km apart and only 1,000 seconds apart, the implied speed is about 500 km/h, interpolation is refused at the default 250 km/h limit, and the nearest photo is used only if it falls inside the max time difference.

Interpolation may use a longer gap than the nearest-photo window. A picture 30 minutes from the nearest phone can still be placed between two phones taken two hours apart when the speed is plausible. The default gap is 2 hours. The default nearest-photo window is 10 minutes.

When two nearest photos are equally close in time, the earlier one is used. The same id order breaks exact time ties.

Altitude is copied from the donor, or blended when the coordinates are interpolated and both surrounding photos have an altitude. Turn **Copy altitude** off to leave altitude fields unchanged.

## Options

| Option | Meaning |
|---|---|
| Scope | Which photos are one project. Default: entire folder tree. |
| Max time difference | Window for copying the single nearest geotagged photo. Default 10 minutes. |
| Camera clock offset (s) | Added to the untagged photo's capture time before matching. If the camera is 90 s behind the phone, enter `90`. If it is ahead, enter `-90`. Allowed range is ±7 days. |
| Interpolate between the geotagged photos before and after | On by default. This is the best-coordinates path. |
| Interpolation gap | Both the photo before and the photo after must be at least this close to the untagged photo. Default 2 hours. |
| Max travel speed (km/h) | Largest speed GeoFix will accept between those two geotagged photos. Default 250. Use something near 900 for airline days. The field allows 0 through 2,000. |
| Copy altitude too | Writes altitude when the match has one. On by default. |
| Select the updated photos when done | Leaves the changed photos selected. |
| Test mode | Shows the untagged photo and the donor side by side. For an interpolated match the photo on the right is only the closer geotagged photo; the label states the coordinates that will actually be written. Above 40 matches, GeoFix offers the summary instead. |
| Dry run | Analyze and show the report without writing. |
| Save a CSV report | After analysis, asks where to save a UTF-8 CSV (with BOM, so Excel keeps accents). One row per photo: scope, source, id, path, name, status, method, coordinates, altitude, time gap, donor names, fraction, speed, and a note. |

Settings are remembered. The old "look for donors in subfolders" checkbox is gone; the scope menu replaces it.

### CSV report

The file is written only where you choose. GeoFix does not upload it. It contains filenames, paths, capture times, and coordinates, so treat it like the rest of the catalog export.

Names that start with `=`, `+`, `-`, `@`, a tab, or a carriage return are prefixed so a spreadsheet does not treat them as formulas. A negative longitude is still written as a number. Canceling the save dialog keeps the summary; the analysis is not discarded. If you also use Test mode, the CSV is the full analysis, including pairs you later skip.

### Finding the clock offset

Photograph the phone's clock with the camera, then compare the RAW's capture time with the time shown in the picture. **Metadata > Edit Capture Time** can correct the camera photos permanently, after which the offset can stay at 0.

### Time zones

Lightroom compares capture times as the devices wrote them. A camera and a phone set to different time zones look like a constant offset of whole hours. Fix the times with **Edit Capture Time**, or enter the offset here (`-3600` is one hour).

## What the summary is counting

Before Apply, the summary states:

- the scope, in the same words as the menu, including that subfolder boundaries are ignored when the tree is selected
- the folder path, or "Current selection / filmstrip"
- photos analyzed and geotagged donors
- photos that have no GPS
- how many will receive coordinates, split into interpolated, nearest, and exact time
- how many were already tagged, outside the window, or missing a capture time
- how many interpolation attempts were skipped because the speed was too high or the gap was too wide

Nothing is written until Apply. Dry run never writes.

The catalog update is allowed 120 seconds plus one second per match, and never more than 2 hours. Sidecar files are written after that, one at a time, and that step can be canceled. Canceling does not roll back sidecars already written.

## Project layout

```
GeoFix.lrplugin/
  Info.lua                 plug-in manifest (menu entry, identifiers, version)
  GeoFixMenuItem.lua       UI + Lightroom glue: scope, dialogs, metadata reads, catalog writes
  GeoFixReview.lua         test mode: side-by-side preview of each match
  placeholder.png          shown while a preview is loading
  GeoFixCore.lua           matching, scope text, summary, and CSV text; no SDK imports
  GeoFixPrefs.lua          persisted settings and defaults
  GeoFixLogger.lua         log file setup (~/Documents/LrClassicLogs/GeoFix.log)
  PluginInfoProvider.lua   panel shown in the Plug-in Manager
tests/
  test_core.lua            unit tests for GeoFixCore (plain Lua, no Lightroom needed)
```

The log records counts, the scope, and whether a CSV was written. It does not record coordinates or folder paths.

## Development

Lightroom Classic embeds Lua 5.1. Keep the code compatible with it: no `goto`, no integer division `//`, no bitwise operators, and no `table.unpack`.

The tests run on Lua 5.4 as well. From the repository root:

```sh
lua tests/test_core.lua
```

They cover nearest-photo matching, interpolation, the speed and gap fallbacks, the antimeridian, scope wording, CSV escaping, and a 20,000-photo library. They do not start Lightroom, so folder listing, thumbnail review, and catalog writes still need a pass in Lightroom Classic.

SDK reference: [Lightroom Classic SDK](https://developer.adobe.com/lightroom-classic/).

## Limitations

- The interpolated point is a straight line between two photos, not a road or a flight path.
- A segment faster than the speed limit is not interpolated. The nearest photo is copied only when it is inside the max time difference.
- Donors come from the selected project, not from the whole catalog.
- Several selected folders are rejected rather than merged.
- Folder scopes do not honor the Library filter bar.
- Test mode is practical for a few dozen pairs, not for thousands.
- The image file is never modified. JPEG, HEIC, DNG, and TIFF get a sibling `.xmp` as well; some apps read GPS from inside those formats and ignore the sidecar. Lightroom still shows the catalog coordinates.
- Undo does not revert sidecar files.
