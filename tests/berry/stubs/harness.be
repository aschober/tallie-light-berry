# Test harness for tallielight.be.
#   Installs fakes for the Tasmota globals (tasmota, light, mqttclient,
#   global._oauth, global._tallielight_env) and exposes helpers to drive scenarios.
#
#   Usage:
#     import harness
#     harness.reset()           # clean slate before each test
#     harness.set_clock(now)    # set tasmota.rtc()['utc']
#     harness.fire_rule(trigger, value, payload)  # invoke a registered rule
#     harness.fire_timer(name)  # invoke a registered timer
#     harness.run_loop()        # run mqtt.loop() (drives queued on_message)
#

import global
import string
import tallielight_env  # sets global._tallielight_env for src/ code that reads it

var harness = module('harness')

# ============================================================
# tasmota global
# ============================================================
class _Tasmota
  var _clock_utc
  var _cmds
  var _rules            # map: trigger -> list of {cb, name}
  var _timers           # map: name -> {ms, cb}
  var _crons            # map: name -> {spec, cb}
  var _fast_loops       # list of cb
  var _gc_count
  var wd

  def init()
    self.wd = '/tests/'
    self._reset()
  end

  def _reset()
    self._clock_utc = 1700000000  # arbitrary epoch
    self._cmds = []
    self._rules = {}
    self._timers = {}
    self._crons = {}
    self._fast_loops = []
    self._gc_count = 0
  end

  def rtc()
    return {'utc': self._clock_utc, 'local': self._clock_utc}
  end

  def cmd(s)
    self._cmds.push(s)
    # Mirror selected commands into the light stub for realism
    var l = global.light
    if l != nil
      var upper = string.toupper(s)
      if string.find(upper, "COLOR2 ") == 0
        var hex = s[7..]
        l._apply_color2(hex)
      elif string.find(upper, "POWER ON") == 0
        l._state['power'] = true
      elif string.find(upper, "POWER OFF") == 0
        l._state['power'] = false
      elif string.find(upper, "BACKLOG0 ") == 0
        # Recursively apply each ;-separated subcommand
        var rest = s[9..]
        var parts = string.split(rest, ';')
        for p : parts
          var trimmed = string.tr(p, " ", "")
          if size(trimmed) > 0 self.cmd(string.tr(p, "", "")) end  # no-op trim; just recurse with original
        end
        # Simpler: split & dispatch raw
        for p : string.split(rest, ';')
          # strip leading spaces
          var q = p
          while size(q) > 0 && q[0] == ' ' q = q[1..] end
          if size(q) > 0 self.cmd(q) end
        end
      elif string.find(upper, "DIMMER ") == 0
        var n = int(s[7..])
        l._state['bri'] = int((n * 255) / 100)
      end
    end
  end

  def add_rule(trigger, cb, name)
    if !self._rules.contains(trigger) self._rules[trigger] = [] end
    # Remove any existing rule with the same name first (matches Tasmota behavior)
    if name != nil
      var filtered = []
      for r : self._rules[trigger]
        if r['name'] != name filtered.push(r) end
      end
      self._rules[trigger] = filtered
    end
    self._rules[trigger].push({'cb': cb, 'name': name})
  end

  def add_rule_once(trigger, cb, name)
    self.add_rule(trigger, cb, name)
  end

  def remove_rule(trigger, name)
    if !self._rules.contains(trigger) return end
    if name == nil
      self._rules.remove(trigger)
      return
    end
    var filtered = []
    for r : self._rules[trigger]
      if r['name'] != name filtered.push(r) end
    end
    if size(filtered) == 0
      self._rules.remove(trigger)
    else
      self._rules[trigger] = filtered
    end
  end

  def set_timer(ms, cb, name)
    if name != nil
      self._timers[name] = {'ms': ms, 'cb': cb}
    else
      var anon = format("_anon_%d", size(self._timers))
      self._timers[anon] = {'ms': ms, 'cb': cb}
    end
  end

  def remove_timer(name)
    if self._timers.contains(name) self._timers.remove(name) end
  end

  def add_cron(spec, cb, name)
    self._crons[name] = {'spec': spec, 'cb': cb}
  end

  def remove_cron(name)
    if self._crons.contains(name) self._crons.remove(name) end
  end

  def add_fast_loop(cb) self._fast_loops.push(cb) end
  def remove_fast_loop(cb)
    var filtered = []
    for f : self._fast_loops
      if f != cb filtered.push(f) end
    end
    self._fast_loops = filtered
  end

  def gc() self._gc_count = self._gc_count + 1 end

  def memory() return {'heap_free': 100000} end

  def millis() return 12345 end

  def wifi(key)
    if key == 'mac' return 'AA:BB:CC:DD:EE:FF' end
    return nil
  end

  def publish_result(payload, topic)
    if !self._cmds.contains('publish_result') end
    self._cmds.push(format("publish_result %s %s", topic, payload))
  end

  def defer(cb) cb() end

  def strptime(s, fmt) return 0 end  # unused in tests

  def scale_uint(value, from_lo, from_hi, to_lo, to_hi)
    if from_hi == from_lo return to_lo end
    return int(to_lo + ((value - from_lo) * (to_hi - to_lo)) / (from_hi - from_lo))
  end
end

# ============================================================
# light global
# ============================================================
class _Light
  var _state
  def init() self._reset() end
  def _reset()
    self._state = {'rgb': '000000', 'hue': 0, 'sat': 255, 'bri': 128, 'power': true}
  end
  def get() return self._state end
  def set(m)
    # Real `light.set()` updates fields without forcing power on
    for k : m.keys() self._state[k] = m[k] end
  end
  def _apply_color2(hex)
    # Strip leading # if present, uppercase, store
    var h = hex
    while size(h) > 0 && h[0] == ' ' h = h[1..] end
    if size(h) > 0 && h[0] == '#' h = h[1..] end
    self._state['rgb'] = h
    # Real Tasmota would also derive hue/sat from rgb. For tests, we just record.
    # SetOption20=1 keeps power off; SetOption20=0 powers on.
    if !global._setoption20 self._state['power'] = true end
  end
end

# ============================================================
# mqttclient global (class)
# ============================================================
class _MqttClient
  var _on_msg
  var _on_conn
  var _connected
  var _subs
  var _last_creds
  def init()
    self._on_msg = nil
    self._on_conn = nil
    self._connected = false
    self._subs = []
  end
  def set_on_message(cb) self._on_msg = cb end
  def set_on_connect(cb) self._on_conn = cb end
  def connect(host, port, client_id, user, password, clean)
    self._last_creds = {'host': host, 'port': port, 'user': user, 'password': password}
    self._connected = true
    if self._on_conn != nil self._on_conn() end
    return true
  end
  def disconnect() self._connected = false end
  def subscribe(topic) self._subs.push(topic) end
  def loop() end
  def state() return self._connected ? 1 : 0 end
  def connected() return self._connected end
  # Test driver helper:
  def _deliver(topic, payload)
    if self._on_msg != nil self._on_msg(topic, 0, payload, nil) end
  end
end

# ============================================================
# webclient global (used by oauth_v2)
#   - _wc_responses: queue of {http_code, response_body} the next POSTs return
#   - _wc_requests: list of {url, payload, headers} actually sent
# ============================================================
var _wc_state = {'responses': [], 'requests': []}

class _WebClient
  var _url
  var _headers
  def init() self._headers = [] end
  def begin(url) self._url = url end
  def add_header(name, value) self._headers.push([name, value]) end
  def _send(method, payload)
    var req = {'method': method, 'url': self._url, 'payload': payload, 'headers': self._headers}
    _wc_state['requests'].push(req)
    if size(_wc_state['responses']) == 0
      return -1   # tests forgot to enqueue → simulate transport failure
    end
    var r = _wc_state['responses'][0]
    _wc_state['responses'].remove(0)
    self._last_body = r['response_body']
    return r['http_code']
  end
  def POST(payload) return self._send('POST', payload) end
  def PUT(payload)  return self._send('PUT',  payload) end
  var _last_body
  def get_string() return self._last_body != nil ? self._last_body : "" end
  def set_timeouts(conn_ms, read_ms) end
  def close() end
end

# Tasmota exposes `webclient` as a callable that returns a new client.
def _webclient_factory() return _WebClient() end

# ============================================================
# OAuth service stub
# ============================================================
class _OAuthService
  def is_authorized(refresh) return true end
  def get_access_token() return 'test_access_token' end
  def get_user_id() return 'test_user_id' end
  def unload() end
end

# ============================================================
# Install globals
# ============================================================
global.tasmota = _Tasmota()
global.light = _Light()
global.mqttclient = _MqttClient
global._oauth = _OAuthService()

global._setoption20 = false  # tracks SetOption20 state for color application
global.webclient = _webclient_factory

# ============================================================
# Test helpers
# ============================================================
harness.reset = def ()
  global.tasmota._reset()
  global.light._reset()
  global._setoption20 = false
  import persist
  persist._reset()
  global._tallielight = nil
  _wc_state['responses'] = []
  _wc_state['requests'] = []
end

# Queue a canned HTTP response for the next webclient.POST/PUT
harness.enqueue_http = def (http_code, response_body)
  _wc_state['responses'].push({'http_code': http_code, 'response_body': response_body})
end

# Queue a successful PUT /devices/register response
harness.enqueue_topics_response = def (topics, host, port)
  import json
  if host == nil  host = 'test-mqtt.iot.amazonaws.com'  end
  if port == nil  port = 443  end
  _wc_state['responses'].push({'http_code': 200, 'response_body': json.dump({'topics': topics, 'mqtt_host': host, 'mqtt_port': port, 'mqtt_authorizer_name': 'test-authorizer', 'password': 'test_password'})})
end

# Inspect actual requests made through webclient
harness.http_requests = def () return _wc_state['requests'] end
harness.last_http_request = def ()
  var r = _wc_state['requests']
  if size(r) == 0 return nil end
  return r[size(r) - 1]
end

harness.set_clock = def (utc) global.tasmota._clock_utc = utc end
harness.advance_clock = def (secs) global.tasmota._clock_utc = global.tasmota._clock_utc + secs end

harness.fire_rule = def (trigger, value, payload)
  if !global.tasmota._rules.contains(trigger) return false end
  var rules = global.tasmota._rules[trigger]
  for r : rules
    r['cb'](value, trigger, payload)
  end
  return true
end

harness.fire_timer = def (name)
  if !global.tasmota._timers.contains(name) return false end
  var t = global.tasmota._timers[name]
  global.tasmota._timers.remove(name)
  t['cb']()
  return true
end

harness.has_timer = def (name) return global.tasmota._timers.contains(name) end
harness.has_rule = def (trigger, name)
  if !global.tasmota._rules.contains(trigger) return false end
  for r : global.tasmota._rules[trigger]
    if r['name'] == name return true end
  end
  return false
end

harness.cmds = def () return global.tasmota._cmds end
harness.last_cmd = def ()
  var c = global.tasmota._cmds
  if size(c) == 0 return nil end
  return c[size(c) - 1]
end

# Find a cmd matching a prefix
harness.cmd_sent = def (prefix)
  for c : global.tasmota._cmds
    if string.find(c, prefix) == 0 return true end
  end
  return false
end

# Track SetOption20 from cmd stream
harness.apply_setoption20 = def ()
  for c : global.tasmota._cmds
    if c == "SetOption20 1" global._setoption20 = true
    elif c == "SetOption20 0" global._setoption20 = false
    end
  end
end

return harness
