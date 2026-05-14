#
# TallieLight Service — module wrapper
#
# Resolves TallieLight classes from solidified firmware globals when available,
# otherwise falls back to loading each class file from the .tapp archive.
# Each tl_*.be file self-registers its class into global.* on load, so both
# paths leave the same globals populated before the module exports are built.
#

var tallielight_module = module('tallielight_module')

tallielight_module.init = def (m)
  import strict
  import introspect
  import string

  def _log(msg) print("TAL: " + msg) end

  var use_tapp = false
  if introspect.get(global, 'TallieLightService') == nil
    _log("no solidified classes, loading from .tapp")
    use_tapp = true
  else
    var tapp_ver = 0
    try
      var tallielight_env = introspect.module('tallielight_env', true)
      tapp_ver = tallielight_env.VERSION
    except .. as e, v
    end
    if tapp_ver != 0
      var solid_ver = introspect.get(introspect.get(global, 'TallieLightService'), 'VERSION')
      if solid_ver == nil solid_ver = 0 end
      # major.minor.patch: bytes A.B.C of 0xAABBCCDD
      var tapp_major = tapp_ver >> 24
      var tapp_minor = (tapp_ver >> 16) & 0xFF
      var tapp_patch = (tapp_ver & 0xFFFF) >> 8
      var sol_major  = solid_ver >> 24
      var sol_minor  = (solid_ver >> 16) & 0xFF
      var sol_patch  = (solid_ver & 0xFFFF) >> 8
      _log(string.format("tapp: v%d.%d.%d, solidified: v%d.%d.%d",
        tapp_major, tapp_minor, tapp_patch, sol_major, sol_minor, sol_patch))
      if tapp_major > sol_major || (tapp_major == sol_major && tapp_minor > sol_minor)
        use_tapp = true
      end
    else
      _log("tapp VERSION unavailable, using solidified")
    end
  end

  if use_tapp
    # Load each class file from .tapp without caching so can unload later
    introspect.module('tl_scoreboard_event', true)
    introspect.module('tl_config', true)
    introspect.module('tl_saved_light', true)
    introspect.module('tl_run_state', true)
    introspect.module('tl_light_controller', true)
    introspect.module('tl_service', true)
    _log("loaded from .tapp")
  else
    _log("using solidified")
  end

  var TallieLightService = introspect.get(global, 'TallieLightService')

  # Berry closes upvalues when the enclosing scope (init) exits, making
  # bare var reassignment invisible across sibling closures. A map is a
  # heap object the closures hold by reference, so key writes are visible
  # to all of them after init returns.
  var svc = {'instance': nil}

  var tallielight = module('tallielight')
  tallielight.persist_conf  = TallieLightService.persist_conf
  tallielight.get           = def () return svc['instance'] end
  tallielight.run_from_conf = def ()
    import introspect
    var c = TallieLightService.persist_read_conf()
    var cls = introspect.get(global, 'TallieLightService')
    svc['instance'] = (cls != nil ? cls : TallieLightService)(c)
  end
  tallielight.unload = def ()
    var s = svc['instance']
    if type(s) == 'instance'
      s._stop()
      tasmota.remove_rule('OAuth=UPDATED')
      tasmota.remove_timer('oauth_updated')
      svc['instance'] = nil
    end
    _log("unloaded")
    tasmota.gc()
  end
  return tallielight
end

return tallielight_module
