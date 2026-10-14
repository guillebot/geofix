--[[----------------------------------------------------------------------------
PluginInfoProvider.lua

Section shown in File > Plug-in Manager when GeoFix is selected.
------------------------------------------------------------------------------]]

local LrView = import 'LrView'
local LrDialogs = import 'LrDialogs'

local GeoFixPrefs = require 'GeoFixPrefs'

return {
	sectionsForTopOfDialog = function(f, _propertyTable)
		return {
			{
				title = 'GeoFix',
				f:column {
					spacing = f:control_spacing(),
					fill_horizontal = 1,

					f:static_text {
						title = 'Copies GPS coordinates onto photos that have none, using the geotagged photo '
							.. 'that is closest in capture time (within a window you choose).\n\n'
							.. 'Typical use: tag camera RAW files with the location recorded by phone photos '
							.. 'taken at the same time.\n\n'
							.. 'Turn on Test mode to compare both photos before anything is written.\n\n'
							.. 'Run it from  Library > Plug-in Extras > GeoFix: Copy GPS from nearest photo in time...',
						fill_horizontal = 1,
						height_in_lines = 8,
					},

					f:row {
						f:push_button {
							title = 'Reset settings to defaults',
							action = function()
								GeoFixPrefs.reset()
								LrDialogs.message('GeoFix', 'Settings were reset to their defaults.', 'info')
							end,
						},
					},
				},
			},
		}
	end,
}
