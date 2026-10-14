# GeoFix — Lightroom Classic plug-in

Copies GPS coordinates onto photos that have none, taking them from the geotagged
photo that is closest in capture time.

Typical use: you shoot RAW with a camera that has no GPS (e.g. a Canon) and also take
a few photos with your phone during the day. Import both into the same folder, run
GeoFix, and every RAW gets the location of the phone photo shot closest to it, as
long as the two were taken within a time window you choose.

## Installation

1. Clone or download this repository.
2. In Lightroom Classic open **File > Plug-in Manager**.
3. Click **Add**, select the `GeoFix.lrplugin` folder and click **Done**.

The plug-in is loaded from where it sits, so keep the folder in place (or copy it
somewhere permanent, e.g. `~/Library/Application Support/Adobe/Lightroom/Modules/`).

## Usage

1. In the Library module, navigate to the folder (or collection) that contains both the
   untagged photos and the geotagged ones.
2. Optionally select the photos you want to fix. With one or no photo selected, every
   photo in the filmstrip is a candidate.
3. Run **Library > Plug-in Extras > GeoFix: Copy GPS from nearest photo in time...**
4. Set the options and click **Analyze**.
5. Review the summary and click **Apply**.

   Or turn on **Test mode**. Each match is then shown as two photos: the one that will
   receive coordinates on the left, and the geotagged donor on the right, with the time
   gap between them. **Previous** / **Next** walk the list. Uncheck **Apply this match**
   or click **Skip this match** to leave a photo unchanged, then click **Apply selected**.

The write happens in a single catalog step, so **Edit > Undo** reverts everything at once.

Coordinates are stored in the catalog, like any other metadata edit. If you want them
in the files or XMP sidecars, select the photos and use **Metadata > Save Metadata to
File** (Cmd/Ctrl+S).

### Options

| Option | Meaning |
|---|---|
| Max time difference | Only a geotagged photo taken within this window (before or after) is used. Default 10 minutes. |
| Camera clock offset (s) | Added to the untagged photo's capture time before matching. Use it when the camera clock is not synchronised with the phone: if the camera is 90 s behind, enter `90`; if ahead, `-90`. |
| Copy altitude too | Also copies the donor's GPS altitude when it has one. |
| Look for donors in subfolders | Also considers photos in subfolders of the current folder as donors. |
| Select the updated photos when done | Leaves the changed photos selected so you can inspect them on the map. |
| Test mode | After analysis, shows the untagged photo and its donor side by side so you can confirm or skip each pair before writing. |
| Dry run | Analyze and show the report without changing anything. Combine with Test mode to look at the pairs and write nothing. |

Settings are remembered between runs. **File > Plug-in Manager > GeoFix** has a button to reset them.

### What counts as what

- **Target**: a photo without coordinates. (0, 0) is treated as "no coordinates".
- **Donor**: a photo in the current source with coordinates and a capture time. The
  photos being analyzed are part of the donor pool too, so a previously tagged RAW can
  itself serve as a donor.
- **Capture time**: `dateTimeOriginal`, falling back to `dateTimeDigitized` and then to
  the file date. Photos with no time at all are skipped and reported.
- When two donors are at exactly the same distance, the earlier one wins.

### Finding the right clock offset

Photograph your phone's clock screen with the camera, then compare the capture time of
that RAW with the time displayed in the picture. Alternatively, Lightroom's
**Metadata > Edit Capture Time** can fix the camera photos permanently, after which no
offset is needed.

### Time zones

Lightroom compares capture times as written by the devices. If the camera and the phone
are set to different time zones (common when travelling), the difference shows up as a
constant offset of whole hours; either fix the times with **Edit Capture Time** or use
the clock offset option (e.g. `-3600` for one hour).

## Project layout

```
GeoFix.lrplugin/
  Info.lua                 plug-in manifest (menu entry, identifiers, version)
  GeoFixMenuItem.lua       UI + Lightroom glue: dialogs, metadata reads, catalog writes
  GeoFixReview.lua         test mode: side-by-side preview of each match
  placeholder.png          shown while a preview is loading
  GeoFixCore.lua           pure matching logic, no SDK dependencies
  GeoFixPrefs.lua          persisted settings and defaults
  GeoFixLogger.lua         log file setup (~/Documents/LrClassicLogs/GeoFix.log)
  PluginInfoProvider.lua   panel shown in the Plug-in Manager
tests/
  test_core.lua            unit tests for GeoFixCore (plain Lua, no Lightroom needed)
```

## Development

Lightroom Classic embeds Lua 5.1; keep the code compatible with it (no `goto`, no
integer division `//`, no bitwise operators, `unpack` instead of `table.unpack`).

Run the unit tests with any Lua interpreter (`brew install lua`):

```sh
lua tests/test_core.lua
```

After editing files, reload the plug-in from **File > Plug-in Manager > Reload Plug-in**
(or restart Lightroom). The plug-in log is written to `~/Documents/LrClassicLogs/GeoFix.log`.

SDK reference: [Lightroom Classic SDK](https://developer.adobe.com/lightroom-classic/).

## Limitations / ideas

- Matching is nearest-neighbour only. Interpolating between the donors before and after
  the target would give better results for long gaps.
- Donors are only looked up in the active source (plus subfolders if enabled), not in the
  entire catalog.
