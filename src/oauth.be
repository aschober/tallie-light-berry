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
  var OAuthService = introspect.get(global, 'OAuthService')
  if OAuthService == nil
    import oa_service
    OAuthService = introspect.get(global, 'OAuthService')
  end
  return OAuthService()
end

return oauth_module
