#
# OAuth Service — module wrapper
#
# Resolves OAuthService from solidified firmware globals when available,
# otherwise falls back to loading oa_service.be from the .tapp archive.
# Returns a singleton OAuthService instance.
#

var oauth_module = module("oauth_module")

oauth_module.init = def (m)
  import introspect
  import string
  
  def _log(msg) print("OAUTH: " + msg) end

  var use_tapp = false
  var solidified = introspect.get(global, 'OAuthService')
  if solidified == nil
    _log("no solidified classes, loading from .tapp")
    use_tapp = true
  else
    var tapp_ver = 0
    try
      var tallielight_env = introspect.module('tallielight_env', true)
      tapp_ver = tallielight_env.VERSION
    except .. as e, v
    end
    if tapp_ver == 0
      _log("tapp VERSION unavailable, using solidified")
    else
      var solid_ver = introspect.get(solidified, 'VERSION')
      if solid_ver == nil solid_ver = 0 end
      # major.minor.patch: bytes A.B.C of 0xAABBCCDD
      var tapp_major = tapp_ver >> 24
      var tapp_minor = (tapp_ver >> 16) & 0xFF
      var tapp_patch = (tapp_ver & 0xFFFF) >> 8
      var sol_major  = solid_ver >> 24
      var sol_minor  = (solid_ver >> 16) & 0xFF
      var sol_patch  = (solid_ver & 0xFFFF) >> 8
      if tapp_major > sol_major ||
         (tapp_major == sol_major && tapp_minor > sol_minor) ||
         (tapp_major == sol_major && tapp_minor == sol_minor && tapp_patch > sol_patch)
        use_tapp = true
      end
      _log(string.format("tapp: v%d.%d.%d, solidified: v%d.%d.%d - %s",
        tapp_major, tapp_minor, tapp_patch, sol_major, sol_minor, sol_patch,
        use_tapp ? "loading from .tapp" : "using solidified"))
    end
  end

  if use_tapp
    introspect.module('oa_service', true)
  end

  var OAuthService = introspect.get(global, 'OAuthService')
  return OAuthService()
end

return oauth_module
