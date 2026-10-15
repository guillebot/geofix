--[[----------------------------------------------------------------------------
GeoFix - Lightroom Classic plug-in

Fills missing GPS for a folder tree treated as one project. Coordinates are
interpolated between surrounding geotagged photos when the travel speed is
plausible, otherwise copied from the nearest geotagged photo in time.
------------------------------------------------------------------------------]]

return {
	LrSdkVersion = 6.0,
	LrSdkMinimumVersion = 4.0,

	LrToolkitIdentifier = 'com.guille.lightroom.geofix',
	LrPluginName = 'GeoFix',

	LrPluginInfoProvider = 'PluginInfoProvider.lua',

	LrLibraryMenuItems = {
		{
			-- Always available. A root that only contains subfolders can look
			-- empty in the filmstrip, and that is the folder the tree scope needs.
			title = 'GeoFix: Fill missing GPS...',
			file = 'GeoFixMenuItem.lua',
		},
	},

	VERSION = { major = 0, minor = 3, revision = 0, build = 4 },
}
