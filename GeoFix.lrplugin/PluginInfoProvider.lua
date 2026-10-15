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
						title = 'Fills in missing GPS for a whole folder tree, or for one folder, or for the current selection. '
							.. 'With Entire folder tree selected, every subfolder is the same project.\n\n'
							.. 'Coordinates are interpolated between the geotagged photos before and after each picture '
							.. 'when the implied travel speed is plausible. Otherwise GeoFix copies the nearest geotagged photo inside the time window.\n\n'
							.. 'Run it from Library > Plug-in Extras > GeoFix: Fill missing GPS...',
						fill_horizontal = 1,
						height_in_lines = 9,
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
