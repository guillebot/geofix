--[[----------------------------------------------------------------------------
GeoFix - Lightroom Classic plug-in

Copies GPS coordinates onto photos that have none, taking them from the
geotagged photo that is closest in capture time (within a configurable window).
Typical use: tag camera RAW files using phone photos shot at the same time.
------------------------------------------------------------------------------]]

return {
	LrSdkVersion = 6.0,
	LrSdkMinimumVersion = 4.0,

	LrToolkitIdentifier = 'com.guille.lightroom.geofix',
	LrPluginName = 'GeoFix',

	LrPluginInfoProvider = 'PluginInfoProvider.lua',

	LrLibraryMenuItems = {
		{
			title = 'GeoFix: Copy GPS from nearest photo in time...',
			file = 'GeoFixMenuItem.lua',
			enabledWhen = 'photosAvailable',
		},
	},

	VERSION = { major = 0, minor = 2, revision = 0, build = 2 },
}
