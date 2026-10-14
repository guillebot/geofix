--[[----------------------------------------------------------------------------
GeoFixLogger.lua

Writes to Lightroom's plug-in log file:
  macOS:   ~/Documents/LrClassicLogs/GeoFix.log
  Windows: %USERPROFILE%\Documents\LrClassicLogs\GeoFix.log
------------------------------------------------------------------------------]]

local LrLogger = import 'LrLogger'

local logger = LrLogger('GeoFix')
logger:enable('logfile')

return logger
