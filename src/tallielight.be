#
# TallieLight Service — module wrapper
#
# Resolves TallieLight classes from solidified firmware globals when available,
# otherwise falls back to loading each class file from the .tapp archive.
# Each tl_*.be file self-registers its class into global.* on load, so both
# paths leave the same globals populated before the module exports are built.
#

import strict
import introspect

if introspect.get(global, 'TallieLightService') == nil
  import tl_scoreboard_event
  import tl_config
  import tl_saved_light
  import tl_run_state
  import tl_light_controller
  import tl_service
end

var TallieLightService = introspect.get(global, 'TallieLightService')

var tallielight = module('tallielight')
tallielight.persist_conf   = TallieLightService.persist_conf
tallielight.run_from_conf  = TallieLightService.run_from_conf
tallielight.unload         = TallieLightService.unload
return tallielight
