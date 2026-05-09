import strict
import introspect

#
# TallieLight Service — module wrapper
#
# Resolves TallieLight classes from solidified firmware globals when available,
# otherwise falls back to loading each class file from the .tapp archive.
# Each tl_*.be file self-registers its class into global.* on load, so both
# paths leave the same globals populated before the module exports are built.
#

var _cls = introspect.get(global, 'TallieLightService')
if _cls == nil
  introspect.module("tl_scoreboard_event", true)
  introspect.module("tl_config", true)
  introspect.module("tl_saved_light", true)
  introspect.module("tl_run_state", true)
  introspect.module("tl_light_controller", true)
  introspect.module("tl_service", true)
end
_cls = nil

var TallieLightService = introspect.get(global, 'TallieLightService')

var tallielight = module('tallielight')
tallielight.persist_conf   = TallieLightService.persist_conf
tallielight.run_from_conf  = TallieLightService.run_from_conf
tallielight.unload         = TallieLightService.unload
return tallielight
