# Stub `persist` module. Real Tasmota `persist` allows both `persist.foo = v`
#   and `persist.member("foo")` / `persist.find("foo", default)` against the
#   same store. Berry modules don't honor user-defined setmember/member, so
#   this stub uses `introspect.get/set` to read attributes set via assignment.
#

import introspect

var persist = module('persist')

# Reserved keys that aren't user persist data
var _reserved = {'has': true, 'find': true, 'member': true, 'save': true,
                 'setmember': true, 'remove': true,
                 '_reset': true, '_dump': true, '_save_count': true,
                 '_reserved': true}

persist._save_count = 0

persist._reset = def ()
  persist._save_count = 0
  for k : introspect.members(persist)
    if !_reserved.contains(k)
      introspect.set(persist, k, nil)
    end
  end
end

persist._dump = def ()
  var out = {}
  for k : introspect.members(persist)
    if !_reserved.contains(k)
      out[k] = introspect.get(persist, k)
    end
  end
  return out
end

persist.has = def (k)
  for m : introspect.members(persist)
    if m == k return true end
  end
  return false
end

persist.find = def (k, default)
  for m : introspect.members(persist)
    if m == k return introspect.get(persist, k) end
  end
  return default
end

persist.member = def (k)
  if introspect.contains(persist, k) return introspect.get(persist, k) end
  import undefined
  return undefined
end

persist.save = def () persist._save_count = persist._save_count + 1 end

persist.setmember = def (k, v) introspect.set(persist, k, v) end

persist.remove = def (k) introspect.set(persist, k, nil) end

return persist
