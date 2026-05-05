import strict
import string
import introspect
import tallielight_env

#
# TallieLight service
#
#   Watches MQTT scoreboard events and drives a light to celebrate when a 
#   tracked team is winning or won. Restores the prior light state when the
#   celebration ends.
#

# ─── TallieLight Mode enum ────────────────────────────────────────
# State of the light w.r.t. the active sports event.
var TL_IDLE  = 0   # no active event; light is user-controlled
var TL_SOLID = 1   # final win — solid team color, light on
var TL_ANIM  = 2   # in-progress win — animated team color, light on
var TL_MUTED = 3   # event is active but light is off

# Returns a human-readable name for a TL_* mode constant.
def tl_mode_name(m)
  if m == TL_IDLE  return 'TL_IDLE'  end
  if m == TL_SOLID return 'TL_SOLID' end
  if m == TL_ANIM  return 'TL_ANIM'  end
  if m == TL_MUTED return 'TL_MUTED' end
  return format('?%d', m)
end

############################################################
# ScoreboardEvent: parsed game update for one tracked team #
############################################################
class ScoreboardEvent
  var competitor_abbreviation
  var competitor_slug
  var competitor_winner
  var competitor_score
  var competitor_home_away
  var opponent_abbreviation
  var opponent_winner
  var opponent_score
  var competition_date
  var competition_status_short_detail
  var competition_status_state
  var league_short_display_name
  var last_updated

  def init(event)
    var competitor = event['competitor']
    self.competitor_abbreviation = competitor['abbreviation']
    self.competitor_slug = competitor['slug']
    self.competitor_winner = competitor.find('winner', nil)
    self.competitor_score = competitor['score']
    self.competitor_home_away = (competitor.find('homeAway', '') == 'home')

    var opponent = event['opponent']
    self.opponent_abbreviation = opponent['abbreviation']
    self.opponent_winner = opponent.find('winner', nil)
    self.opponent_score = opponent['score']

    var competition = event['competition']
    self.competition_date = tasmota.strptime(competition['date'], '%Y-%m-%dT%H:%MZ')

    var status_type = competition['status']['type']
    self.competition_status_short_detail = status_type['shortDetail']
    self.competition_status_state = status_type.find('state', nil)
    self.league_short_display_name = competition.find('leagueShortDisplayName', nil)

    self.last_updated = event.find('lastUpdated', tasmota.rtc()['utc'])
  end

  def is_scheduled()    return (self.competition_status_state == 'pre') end
  def is_final()        return (self.competition_status_state == 'post') end
  def is_in_progress()  return (self.competition_status_state == 'in') end
  def is_winner()
    return self.is_final() && self.competitor_winner == true
  end
  def is_winning()
    return self.is_winner() || (self.is_in_progress() && self.competitor_score > self.opponent_score)
  end

  def tostring()
    return format('ScoreboardEvent(%s vs %s, %s (%s), %s-%s, %d)',
      self.competitor_abbreviation, self.opponent_abbreviation,
      self.competition_status_short_detail, self.competition_status_state,
      self.competitor_score, self.opponent_score, self.last_updated)
  end
end

###########################################
# TLConfig: persisted user configuration. #
###########################################
class TLConfig
  var team_configs        # list of maps: [{teamSlug, selectedColor}, ...]
  var light_restore_mins  # int: minutes
  var turn_on_light       # bool
  var animation_type      # string: "breathe" | "comet" | "crenel"
  var saved_light         # TLSavedLight or nil

  def init()
    self.team_configs = []
    self.light_restore_mins = 60
    self.turn_on_light = true
    self.animation_type = 'crenel'
    self.saved_light = nil
  end

  # Serialize for the UI JS (which uses camelCase keys).
  def toJson()
    import json
    return json.dump({
      'teamConfigs': self.team_configs,
      'lightRestoreMins': self.light_restore_mins,
      'turnOnLight': self.turn_on_light,
      'animationType': self.animation_type,
    })
  end

  def tostring()
    import json
    return format('TLConfig(teams=%s restore_mins=%d turn_on=%s anim=%s saved_light=%s)',
      json.dump(self.team_configs), self.light_restore_mins, self.turn_on_light,
      self.animation_type, self.saved_light)
  end
end

###############################################################
# TLSavedLight: saved light state before a team change.       #
#  Restored when the active event clears.                     #
###############################################################
class TLSavedLight
  var rgb       # hex string "RRGGBB" (no leading #)
  var hue       # 0–360
  var sat       # 0–255
  var bri       # 0–255
  var power     # bool
  var end_time  # epoch seconds — when the active event will time out

  def init() end

  static def from_light(light_map, end_time)
    var s = TLSavedLight()
    s.rgb = light_map['rgb']
    s.hue = int(light_map['hue'])
    s.sat = int(light_map['sat'])
    s.bri = int(light_map['bri'])
    s.power = light_map['power']
    s.end_time = end_time
    return s
  end

  static def from_map(m)
    if m == nil return nil end
    var s = TLSavedLight()
    s.rgb = m['rgb']
    s.hue = int(m.find('hue', 0))
    s.sat = int(m.find('sat', 255))
    s.bri = int(m.find('bri', 128))
    s.power = m.find('power', true)
    s.end_time = int(m.find('end_time', 0))
    return s
  end

  def to_map()
    return {'rgb': self.rgb, 'hue': self.hue, 'sat': self.sat,
            'bri': self.bri, 'power': self.power, 'end_time': self.end_time}
  end

  def tostring()
    return format('TLSavedLight(rgb=%s hue=%d sat=%d bri=%d power=%s end_time=%d)',
      self.rgb, self.hue, self.sat, self.bri, self.power, self.end_time)
  end
end

######################################################
# TLRunState: volatile runtime state. Not persisted. #
######################################################
class TLRunState
  var mode             # TL_*
  var active_event     # ScoreboardEvent or nil
  var pinned_slug      # string or nil
  var team_color_rgb   # hex string "RRGGBB" (no #) — current team color, or nil
  var team_color_map   # map from light.get() reading after color was set, or nil
  var animation        # current animation object, or nil

  def init() self.clear() end

  def clear()
    self.mode = TL_IDLE
    self.active_event = nil
    self.pinned_slug = nil
    self.team_color_rgb = nil
    self.team_color_map = nil
    self.animation = nil
  end
end

######################################################
# Module-level Persistence Helpers                   #
#   Snake_case keys; flat map shape for saved_light. #
######################################################
def persist_read_conf()
  import persist
  var c = TLConfig()
  c.team_configs = persist.find('sl_teams', [])
  c.light_restore_mins = persist.find('sl_restore_mins', 60)
  c.turn_on_light = persist.find('sl_turn_on', true)
  c.animation_type = persist.find('sl_anim_type', 'crenel')
  c.saved_light = TLSavedLight.from_map(persist.find('sl_saved_light', nil))
  return c
end

def persist_conf(conf)
  import persist
  persist.sl_teams = conf.team_configs
  persist.sl_restore_mins = conf.light_restore_mins
  persist.sl_turn_on = conf.turn_on_light
  persist.sl_anim_type = conf.animation_type
  persist.sl_saved_light = (conf.saved_light != nil) ? conf.saved_light.to_map() : nil
  persist.save()
end

def persist_saved_light(saved_light)
  import persist
  print(format('TAL: persist_saved_light: saving light state: %s', saved_light))
  persist.sl_saved_light = (saved_light != nil) ? saved_light.to_map() : nil
  persist.save()
end

########################################################################
# LightController: all hardware/animation calls.                       #
#   Owns the animation engine and is the single place that issues      #
#   `tasmota.cmd`, `light.get/set`, and `animation.*` calls.           #
#   Stateless w.r.t. the event state machine — the service holds that. #
########################################################################
class LightController
  var _anim_engine     # animation engine (kept alive across team changes)

  def init() self._anim_engine = nil end

  # Apply SetOption20 based on turn_on_light. SetOption20=1 means
  #   Color/Dimmer/CT updates do not auto-power-on the light.
  def apply_set_option_20(turn_on_light)
    var v = turn_on_light ? '0' : '1'
    tasmota.cmd('SetOption20 ' + v)
  end

  # Set the light to a solid team color. Returns the team color map after
  #   application (light.get() reading) so the caller can compare future
  #   manual changes against it.
  #
  #   `prev_team_rgb`  — last applied team color, or nil
  #   `user_initiated` — if true and light is off and turn_on_light=false,
  #                        send Power ON
  #   `turn_on_light` — config flag (controls whether SetOption20 power-on
  #                     is enabled at the firmware level)
  #
  #   Returns: {'team_color_map': map, 'changed': bool}
  def set_solid(new_rgb, prev_team_rgb, animation_was_cleared, user_initiated, turn_on_light)
    var changed = (prev_team_rgb != new_rgb) || animation_was_cleared
    if changed
      if !turn_on_light && user_initiated && light.get()['power'] == false
        # If turn_on_light=false and user initiated and will be turning on, send
        # a Color2 and then a Power ON command to ensure the light turns on.
        tasmota.cmd(format('Color2 %s', new_rgb))
        tasmota.cmd('Power ON')
      else
        # If turn_on_light=true, or not user-initiated, or light is already on, then
        # rely on Color2 command to change color and turn on the light if needed
        tasmota.cmd(format('Color2 %s', new_rgb))
      end
    end
    var lstate = light.get()
    print(format('TAL: lc.set_solid: new_rgb=%s prev=%s changed=%s light.rgb=%s', new_rgb, prev_team_rgb, changed, lstate['rgb']))
    return {'team_color_map': lstate, 'changed': changed}
  end

  # Restore the light to a saved state.
  def restore_light(saved_light)
    if (saved_light == nil)
      print('TAL: lc.restore_light: no saved_light, nothing to restore.')
      return
    end
    if saved_light.power == false
      print(format('TAL: lc.restore_light: restoring saved_light with power off using light.set().'))
      # If saved_light was off, restore the state with light.set with power=false so it stays off.
      light.set({'hue': saved_light.hue, 'sat': saved_light.sat, 'bri': saved_light.bri, 'power': false})
    else
      # If saved_light was on, use two separate commands tasmota.cmds for Color and Dimmer. Hopefully this is synchronous.
      var dimmer = tasmota.scale_uint(saved_light.bri, 0, 255, 0, 100)
      print(format('TAL: lc.restore_light: restoring saved_light with power on using Color2 and Dimmer commands.'))
      tasmota.cmd(format('Color2 %s', saved_light.rgb))
      tasmota.cmd(format('Dimmer %d', dimmer))
    end
  end

  # Set or update the animation. Returns the animation object so the caller
  #   can store it in run_state.
  #
  #   `team_color_map` — the light.get() reading from set_solid (used for
  #                        gamma-corrected color and current brightness for breathe)
  #   `anim_type`      — "breathe" | "comet" | "crenel"
  def set_animation(team_color_map, anim_type)
    import animation
    if self._anim_engine == nil
      self._anim_engine = animation.init_strip()
    end
    # Animation engine applies its own bri scaling, so set strip bri to max
    # so the animation has full dynamic range.
    self._anim_engine.strip.set_bri(255)

    var team_color_upper = string.toupper(team_color_map['rgb'])
    var team_color_hex = number(f'0xFF{team_color_upper}')

    var anim
    if anim_type == 'comet'
      anim = animation.comet(self._anim_engine)
      anim.color = team_color_hex
      anim.tail_length = 3
      anim.fade_factor = 255
      anim.direction = -1
      anim.speed = 3000
      anim.wrap_around = 1
    elif anim_type == 'crenel'
      var num_pixels = self._anim_engine.get_strip().pixel_count()
      anim = animation.crenel(self._anim_engine)
      anim.color = team_color_hex
      anim.pulse_size = 1
      anim.low_size = 3
      anim.nb_pulse = -1
      var scroll = animation.sawtooth(self._anim_engine)
      scroll.min_value = 0
      scroll.max_value = num_pixels - 1
      scroll.duration = 2000
      anim.pos = scroll
    elif anim_type == 'breathe'
      var current_bri = int(team_color_map['bri'])
      var bri_range = self._calc_breathe_brightness(current_bri)
      anim = animation.breathe(self._anim_engine)
      anim.color = team_color_hex
      anim.min_brightness = bri_range[0]
      anim.max_brightness = bri_range[1]
      anim.curve_factor = 2
      anim.period = 3000
    else
      print(format('TAL: set_animation — unknown anim_type "%s", falling back to breathe.', anim_type))
      var current_bri = int(team_color_map['bri'])
      var bri_range = self._calc_breathe_brightness(current_bri)
      anim = animation.breathe(self._anim_engine)
      anim.color = team_color_hex
      anim.min_brightness = bri_range[0]
      anim.max_brightness = bri_range[1]
      anim.curve_factor = 2
      anim.period = 3000
    end

    self._anim_engine.add(anim)
    self._anim_engine.run()
    return anim
  end

  # Calculate min/max brightness for an animation based on the current
  #   brightness in 0–255. Returns [min, max].
  def _calc_breathe_brightness(current_bri)
    var max_b = int(current_bri) + 32
    if max_b > 255 max_b = 255 end
    return [0, max_b]
  end

  # Update only the brightness range of an existing breathe animation. Used
  #   when the user changes brightness without changing hue/sat.
  def update_breathe_brightness(anim, new_bri_255)
    import animation
    if anim != nil && isinstance(anim, animation.breathe)
      var br = self._calc_breathe_brightness(new_bri_255)
      anim.min_brightness = br[0]
      anim.max_brightness = br[1]
    end
  end

  # Stop and clear any running animation. Returns true if an animation was
  #   cleared (so callers can decide to force a color reset).
  def clear_animation()
    tasmota.remove_rule('Power1#State', 'on_power_on_for_anim')
    var has_anim = (self._anim_engine != nil && self._anim_engine.is_running)
    if has_anim
      self._anim_engine.stop()
      self._anim_engine.clear()
      return true
    end
    return false
  end

  # Schedule the event-timeout timer.
  def set_event_timer(duration_secs, cb)
    tasmota.remove_timer('handle_event_timeout')
    tasmota.set_timer(duration_secs * 1000, cb, 'handle_event_timeout')
  end

  def remove_event_timer()
    tasmota.remove_timer('handle_event_timeout')
  end

  # Register HSB and Power1#State rules with the given callbacks.
  #   Done after a 500ms delay so any immediate light changes settle first.
  def add_light_change_rules(on_hsb_cb, on_power_cb)
    tasmota.set_timer(500, def ()
      tasmota.remove_rule('HSBColor', 'on_hsb_change')
      tasmota.remove_rule('Power1#State', 'on_power_change')
      tasmota.add_rule('HSBColor', on_hsb_cb, 'on_hsb_change')
      tasmota.add_rule('Power1#State', on_power_cb, 'on_power_change')
    end, 'light_change_rules_delay')
  end

  def remove_light_change_rules()
    tasmota.remove_timer('light_change_rules_delay')
    tasmota.remove_rule('HSBColor', 'on_hsb_change')
    tasmota.remove_rule('Power1#State', 'on_power_change')
    tasmota.remove_rule('Power1#State', 'on_power_on_for_anim')
  end

  # Register a rule that fires when the user manually powers on the light,
  #   used when an in-progress event arrives while the light is off and
  #   turn_on_light=false. The callback will start the animation.
  def register_power_on_for_anim(cb)
    tasmota.remove_rule('Power1#State', 'on_power_on_for_anim')
    tasmota.add_rule('Power1#State', def (value, trigger, payload)
      if value == 1
        tasmota.remove_rule('Power1#State', 'on_power_on_for_anim')
        cb()
      end
    end, 'on_power_on_for_anim')
  end
end

#########################################################################
# TallieLightService: orchestrator. Owns config, run state, MQTT client,  #
#   and delegates hardware operations to LightController.               #
#########################################################################
class TallieLightService
  var config            # TLConfig
  var state             # TLRunState
  var last_events       # map: slug -> ScoreboardEvent
  var lc                # LightController
  var mqtt              # mqttclient instance
  var _mqtt_loop        # fast-loop callback (kept as field so we can remove it)
  var _allowed_topics   # list of full topic strings returned by backend
  var _mqtt_host              # MQTT host returned by backend
  var _mqtt_port              # MQTT port returned by backend
  var _mqtt_authorizer_name   # MQTT authorizer name returned by backend
  var _register_device_backoff   # ms, increases by 10s per retry, gives up after 120000

  # ── Lifecycle ─────────────────────────────────────────────
  def init(config)
    self.config = config
    self.state = TLRunState()
    self.last_events = {}
    self.lc = LightController()
    self.mqtt = nil
    self._mqtt_loop = nil
    self._allowed_topics = []
    self._mqtt_host = nil
    self._mqtt_port = nil
    self._mqtt_authorizer_name = nil
    self._register_device_backoff = 10000

    print('TAL: Add rule for OAuth Updated.')
    tasmota.add_rule('OAuth=UPDATED', /->
      tasmota.set_timer(0, /-> self._oauth_updated(), 'oauth_updated')
    )
    self._start()
  end

  # ── Device registration ───────────────────────────────────
  def _webclient_put(url, payload, log_header, headers)
    tasmota.gc()
    var wc = webclient()
    try
      wc.begin(url)
      for h : headers  wc.add_header(h[0], h[1])  end
      var http_code = wc.PUT(payload)
      var body = wc.get_string()
      wc.close()
      wc = nil
      tasmota.gc()
      return {"http_code": http_code, "response_body": body}
    except .. as e, msg
      try wc.close() except .. end
      wc = nil
      tasmota.gc()
      return {"http_code": -1, "response_body": ""}
    end
  end

  # Call PUT /devices/{clientId}/register with current team slugs.
  # Returns {"success": true, "password": ..., "topics": ..., ...} on success.
  def _register_device()
    import json
    var oauth = global._oauth_service
    var token = oauth._get_valid_access_token()
    if token == nil  return {"success": false, "message": "No valid access token"}  end

    var team_slugs = []
    for tc : self.config.team_configs  team_slugs.push(tc['teamSlug'])  end

    var url = tallielight_env.BACKEND_URL + "/devices/" + oauth.device_id + "/register"
    var body = json.dump({"slugs": team_slugs})
    var headers = [["Content-Type", "application/json"],
                   ["Authorization", "Bearer " + token]]
    token = nil   # collectable once request is in flight

    var resp = self._webclient_put(url, body, "PUT /devices/register", headers)
    var http_code = resp["http_code"]
    if http_code == 200
      var parsed = nil
      try parsed = json.load(resp["response_body"]) except .. end
      if parsed != nil && classname(parsed) == "map" && parsed.contains("password")
        self._allowed_topics = parsed["topics"]
        self._mqtt_host = parsed["mqtt_host"]
        self._mqtt_port = int(parsed["mqtt_port"])
        self._mqtt_authorizer_name = parsed["mqtt_authorizer_name"]
        print(format("TAL: _register_device: success, host=%s port=%d topics=%s",
                     self._mqtt_host, self._mqtt_port, str(self._allowed_topics)))
        return {"success": true, "password": parsed["password"]}
      end
    end

    var msg = format("HTTP %s", str(http_code))
    if http_code == -1  msg = "HTTP request failed"  end
    print(format("TAL: _register_device: failed — %s", msg))
    return {"success": false, "message": msg}
  end

  def _connect_mqtt()
    tasmota.remove_timer("register_device_retry")

    var result = self._register_device()
    if result["success"]
      self._register_device_backoff = 10000
      var oauth = global._oauth_service
      var client_id = oauth.get_mqtt_client_id()
      var mqtt_user = oauth.get_mqtt_username() + '?x-amz-customauthorizer-name=' + self._mqtt_authorizer_name
      var mqtt_password = result["password"]
      print(format("TAL: _connect_mqtt: MQTT creds client_id=%s, pw len=%s", client_id, size(mqtt_password)))
      print(format('TAL: _connect_mqtt: Connecting to MQTT broker %s:%d…', self._mqtt_host, self._mqtt_port))
      var connected = self.mqtt.connect(self._mqtt_host, self._mqtt_port, client_id, mqtt_user, mqtt_password, true)
      if !connected
        print(format('TAL: _connect_mqtt: MQTT initial connection failed (state=%d). Auto-reconnect will retry.', self.mqtt.state()))
      end
    else
      if self._register_device_backoff > 120000
        print(format("TAL: _connect_mqtt: registration failed (%s), giving up after max retries.", result["message"]))
      else
        print(format("TAL: _connect_mqtt: registration failed (%s), retrying in %dms",
                     result["message"], self._register_device_backoff))
        tasmota.set_timer(self._register_device_backoff,
                          /-> self._connect_mqtt(), "register_device_retry")
        self._register_device_backoff += 10000
      end
    end
  end

  def _start()
    var oauth = global._oauth_service

    var team_slugs = []
    for tc : self.config.team_configs  team_slugs.push(tc['teamSlug'])  end
    print(format('TAL: _start: Configured for teams: %s', team_slugs))

    if !oauth.is_authorized(true)
      print('TAL: _start: MQTT connect deferred as device is not authorized.')
      return
    end

    self.mqtt = mqttclient()
    self.mqtt.set_on_message(/ topic, idx, payload_s, payload_b -> self._process_event(topic, idx, payload_s))
    self.mqtt.set_on_connect(def ()
      print(format('TAL: _start: MQTT connected. Subscribing to allowed topics: %s', str(self._allowed_topics)))
      for topic : self._allowed_topics
        self.mqtt.subscribe(topic)
      end
    end)

    self._connect_mqtt()

    self._mqtt_loop = def ()
      if self.mqtt != nil self.mqtt.loop() end
    end
    tasmota.add_fast_loop(self._mqtt_loop)

    self.lc.apply_set_option_20(self.config.turn_on_light)
  end

  def _stop()
    print('TAL: _stop: Stopping TallieLightService...')
    tasmota.remove_timer("register_device_retry")
    # Note: do not clear the saved_light on stop so that if restarted while an
    # event is active, it can restore the light after boot when no event active.
    # self.lc.restore_light(self.config.saved_light)
    # self._teardown_active_event()
    # self.state.clear()
    self.lc.clear_animation()
    self.lc.remove_event_timer()
    self.lc.remove_light_change_rules()
    self.last_events = {}
    if self._mqtt_loop != nil
      tasmota.remove_fast_loop(self._mqtt_loop)
      self._mqtt_loop = nil
    end
    if self.mqtt != nil
      self.mqtt.disconnect()
      self.mqtt = nil
    end
  end

  def _oauth_updated()
    print('TAL: _oauth_updated: OAuth updated. Reconnecting MQTT…')
    if self.mqtt == nil
      self._start()
      return
    end
    var oauth = global._oauth_service
    if !oauth.is_authorized(false)
      print('TAL: _oauth_updated: OAuth updated but device not authorized. Skipping reconnect.')
      return
    end
    self._register_device_backoff = 10000
    self._connect_mqtt()
  end

  # ── MQTT message handling ─────────────────────────────────
  def _process_event(topic, idx, json_data)
    import json
    var raw = json.load(json_data)
    if raw == nil
      print(format('TAL: _process_event: Invalid JSON: %s', json_data))
      return false
    end
    var event = ScoreboardEvent(raw)
    self.last_events[event.competitor_slug] = event
    print(format('TAL: _process_event: MQTT event for %s', event.competitor_slug))
    self._apply_event_change(self._calculate_active_event(), false)
    return true
  end

  # Log a mode transition. If the mode is unchanged, log the no-op too so the
  # trace explains why nothing happened.
  def _set_mode(new_mode, reason)
    if self.state.mode == new_mode
      print(format('TAL: _set_mode: %s (no change) — %s', tl_mode_name(new_mode), reason))
    else
      print(format('TAL: _set_mode: %s → %s — %s', tl_mode_name(self.state.mode), tl_mode_name(new_mode), reason))
      self.state.mode = new_mode
    end
  end

  # ── Helpers ───────────────────────────────────────────────
  def _get_team_color(team_slug)
    for tc : self.config.team_configs
      if tc['teamSlug'] == team_slug
        var color = tc['selectedColor']
        var hex = string.tr(color, '#', '')
        if size(hex) != 6
          print(format("TAL: _get_team_color: Invalid color format '%s' for %s.", color, team_slug))
          return nil
        end
        return hex
      end
    end
    print(format('TAL: _get_team_color: No team color found for %s.', team_slug))
    return nil
  end

  def _team_priority(slug)
    var n = size(self.config.team_configs)
    var i = 0
    while i < n
      if self.config.team_configs[i]['teamSlug'] == slug return i end
      i += 1
    end
    return 999
  end

  def _best_by_priority(events)
    var best = events[0]
    var best_p = self._team_priority(best.competitor_slug)
    for ev : events
      var p = self._team_priority(ev.competitor_slug)
      if p < best_p
        best = ev
        best_p = p
      end
    end
    return best
  end

  def _event_for_slug(slug)
    if slug == nil return nil end
    if self.last_events.contains(slug) return self.last_events[slug] end
    return nil
  end

  # ── Pure event selection ──────────────────────────────────
  # Returns the best winning ScoreboardEvent given current last_events,
  # pinned slug, and config. Pure w.r.t. hardware (only side effect: clears
  # a stale pin if the pinned team is no longer winning).
  def _calculate_active_event()
    # 1. Pinned team takes priority (no timeout gate)
    if self.state.pinned_slug != nil
      var ev = self._event_for_slug(self.state.pinned_slug)
      if ev != nil && ev.is_winning()
        print(format('TAL: _calculate_active_event: %s (pinned)', self.state.pinned_slug))
        return ev
      end
      # Pin stale — clear it and fall through
      print(format('TAL: _calculate_active_event: %s (pinned) is no longer winning. Clearing pin.', self.state.pinned_slug))
      self.state.pinned_slug = nil
    end

    # 2. Auto-select winning events, filtered by timeout
    var in_progress_winners = []
    var final_winners = []
    var now = tasmota.rtc()['utc']
    var restore_secs = self.config.light_restore_mins * 60
    for slug : self.last_events.keys()
      var ev = self.last_events[slug]
      if !ev.is_winning() continue end
      if (ev.last_updated + restore_secs) - now <= 0
        var hours = (-restore_secs + now - ev.last_updated) / 3600
        var mins = ((-restore_secs + now - ev.last_updated) % 3600) / 60
        var secs = (-restore_secs + now - ev.last_updated) % 60
        print(format('TAL: _calculate_active_event: %s is stale (timed out=%02d:%02d:%02d), skipping.', ev.competitor_slug, hours, mins, secs))
        continue
      end
      if ev.is_winner()
        final_winners.push(ev)
      else
        in_progress_winners.push(ev)
      end
    end

    var summary = format('(total=%d, in-progress-winners=%d, final-winners=%d)', size(self.last_events), size(in_progress_winners), size(final_winners))
    if size(in_progress_winners) > 0
      var best = self._best_by_priority(in_progress_winners)
      print(format('TAL: _calculate_active_event: %s (in-progress) %s', best.competitor_slug, summary))
      return best
    end
    if size(final_winners) > 0
      var best = self._best_by_priority(final_winners)
      print(format('TAL: _calculate_active_event: %s (final) %s', best.competitor_slug, summary))
      return best
    end
    print(format('TAL: _calculate_active_event: none %s', summary))
    return nil
  end

  def _event_unchanged(new_ev)
    return self.state.active_event != nil && new_ev != nil &&
           self.state.active_event.competitor_slug == new_ev.competitor_slug &&
           self.state.active_event.last_updated == new_ev.last_updated
  end

  # ── Transition logic ──────────────────────────────────────
  # Apply an event-selection result to the current state.
  # `user_initiated` — set when a manual user action (pin, unpin)
  # should force activation/restore even from TL_MUTED.
  def _apply_event_change(new_ev, user_initiated)
    if self._event_unchanged(new_ev)
      print(format('TAL: _apply_event_change: event unchanged for %s, no changes.', new_ev.competitor_slug))
      return
    end

    if new_ev == nil
      print('TAL: _apply_event_change: no active event provided, restoring light state.')
      self._restore_light_state('no active event')
      return
    end

    if self.state.mode == TL_MUTED && !user_initiated
      print(format('TAL: _apply_event_change: muted and not user initiated, updating active event to %s but no light changes.', new_ev.competitor_slug))
      self.state.active_event = new_ev
      return
    end

    print(format('TAL: _apply_event_change: activating %s (user_initiated=%s)', new_ev.competitor_slug, user_initiated))
    self._set_active_event(new_ev, user_initiated)
  end

  # Capture the current light state into config.saved_light.
  # Persists if newly written or if end_time changed. Idempotent for the
  # same end_time.
  def save_light_state(end_time_epoch)
    if self.config.saved_light == nil
      self.config.saved_light = TLSavedLight.from_light(light.get(), end_time_epoch)
      persist_saved_light(self.config.saved_light)
      return
    end
    if self.config.saved_light.end_time == end_time_epoch return end
    self.config.saved_light.end_time = end_time_epoch
    persist_saved_light(self.config.saved_light)
  end

  # Clear animation, clear saved_light, remove rules and timers. Called on restore and before
  # re-activating a new event.
  def _teardown_active_event()
    self.lc.clear_animation()
    self.config.saved_light = nil
    persist_saved_light(self.config.saved_light)
    self.lc.remove_event_timer()
    self.lc.remove_light_change_rules()
  end

  def _restore_light_state(reason)
    self.lc.restore_light(self.config.saved_light)
    self._set_mode(TL_IDLE, reason)
    self._teardown_active_event()
    self.state.clear()
  end

  def _set_active_event(new_ev, user_initiated)
    var rgb = self._get_team_color(new_ev.competitor_slug)
    if rgb == nil return end

    self.state.active_event = new_ev

    # Compute end_time. Pinned events use a fresh timer; auto events use
    # last_updated-based timer.
    var now = tasmota.rtc()['utc']
    var end_time
    if self.state.pinned_slug != nil
      end_time = now + (self.config.light_restore_mins * 60)
    else
      end_time = new_ev.last_updated + (self.config.light_restore_mins * 60)
    end

    var _tl = end_time - now
    print(format('TAL: _set_active_event: %s end_time=%d time_left=%02d:%02d:%02d', new_ev.competitor_slug, end_time, _tl / 3600, (_tl % 3600) / 60, _tl % 60))

    # Remove existing light-change rules before issuing color commands, so the
    # HSB rule from the previous event doesn't fire on our own color change.
    self.lc.remove_light_change_rules()

    # Snapshot current light before any changes
    self.save_light_state(end_time)

    # Decide entry mode based on light state and turn_on_light config
    var light_off = !light.get()['power']
    var should_mute = light_off && !self.config.turn_on_light && !user_initiated

    if should_mute
      # Light is off and turn_on_light=false — stage color silently and enter TL_MUTED.
      self.lc.clear_animation()
      var cur_bri = int(light.get()['bri'])
      light.set({'rgb': rgb, 'bri': cur_bri, 'power': false})  # stage color, preserve brightness, keep light off
      self.state.team_color_rgb = rgb
      self.state.team_color_map = light.get()
      self._set_mode(TL_MUTED, format('staged %s for %s, light off', rgb, new_ev.competitor_slug))
      var duration = end_time - now
      if duration < 1 duration = 1 end
      self.lc.set_event_timer(duration, /-> self._handle_event_timeout())
      self.lc.add_light_change_rules(
        / value, trigger, payload -> self._on_hsb_change(value, trigger, payload),
        / value, trigger, payload -> self._on_power_change(value, trigger, payload))
      return
    end

    # Light should be on (or already is). Apply solid color first.
    var clear_result = self.lc.clear_animation()
    if clear_result self.state.animation = nil end
    var r = self.lc.set_solid(rgb, self.state.team_color_rgb, clear_result, user_initiated, self.config.turn_on_light)
    self.state.team_color_rgb = rgb
    self.state.team_color_map = r['team_color_map']

    if new_ev.is_winner()
      # Final win → solid only
      self.state.animation = nil
      self._set_mode(TL_SOLID, format('%s won %s-%s', new_ev.competitor_abbreviation, new_ev.competitor_score, new_ev.opponent_score))
    else
      # In-progress → add animation on top
      print(format('TAL: _set_active_event: set_animation team_color_map=%s', self.state.team_color_map))
      self.state.animation = self.lc.set_animation(self.state.team_color_map, self.config.animation_type)
      self._set_mode(TL_ANIM, format('%s leading %s-%s (animation_type: %s)', new_ev.competitor_abbreviation, new_ev.competitor_score, new_ev.opponent_score, self.config.animation_type))
    end

    # Schedule timeout and register HSB/Power change rules
    var duration = end_time - now
    if duration < 1 duration = 1 end
    self.lc.set_event_timer(duration, /-> self._handle_event_timeout())
    self.lc.add_light_change_rules(
      / value, trigger, payload -> self._on_hsb_change(value, trigger, payload),
      / value, trigger, payload -> self._on_power_change(value, trigger, payload))
  end

  # ── Power-on for deferred animation ──────────────────────
  def _on_power_on_for_anim()
    # User powered on the light while TL_MUTED with an in-progress event.
    # Force re-activation as if user_initiated=true.
    if self.config.saved_light != nil
      self.config.saved_light.power = true
      persist_saved_light(self.config.saved_light)
    end
    self.state.active_event = nil  # force re-evaluation
    self._apply_event_change(self._calculate_active_event(), true)
  end

  # ── Event timeout ─────────────────────────────────────────
  def _handle_event_timeout()
    print(format('TAL: _handle_event_timeout: %s', self.state.active_event ? self.state.active_event.competitor_slug : 'nil'))
    self.state.active_event = nil
    self.state.pinned_slug = nil
    # Don't change mode here; let _apply_event_change decide based on new selection
    self._apply_event_change(self._calculate_active_event(), false)
  end

  # ── Manual light change rules ────────────────────────────
  def _on_power_change(value, trigger, payload)
    print(format('TAL: _on_power_change: value=%s', value))
    if value == 0 
      # ---- Light turned OFF ----
      if self.config.saved_light != nil
        self.config.saved_light.power = false
        persist_saved_light(self.config.saved_light)
      end
      if self.state.active_event != nil
        # Mute (preserve event, stop animation)
        self.lc.clear_animation()
        self.state.animation = nil
        self._set_mode(TL_MUTED, 'user turned light off during active event')
      else
        # No active event — user is just turning light off
        print('TAL: _on_power_change: light off, no active event — restoring saved light state if any.')
        self._restore_light_state('light off, no active event')
      end
    else 
      # ---- Light turned ON ----
      if self.state.mode == TL_MUTED
        print('TAL: _on_power_change: user powered light on while muted, recalculate active event.')
        if self.config.saved_light != nil
          self.config.saved_light.power = true
          persist_saved_light(self.config.saved_light)
        end
        self.state.active_event = nil
        self._apply_event_change(self._calculate_active_event(), true)
      elif self.config.saved_light != nil && self.config.saved_light.power == false
        # Update snapshot to reflect new power state
        print('TAL: _on_power_change: light on while saved_light.power=false — updating saved light state.')
        self.config.saved_light.power = true
        persist_saved_light(self.config.saved_light)
      end
    end
  end

  def _on_hsb_change(value, trigger, payload)
    print(format('TAL: _on_hsb_change: value=%s', value))
    if self.state.team_color_map == nil
      print('TAL: _on_hsb_change: no team_color_map, ignoring HSB change.')
      return
    end
    var parts = string.split(value, ',')
    var new_hue = int(parts[0])           # 0–360
    var new_sat = int(parts[1])           # 0–100
    var new_bri = int(parts[2])           # 0–100

    var team_bri = int(self.state.team_color_map['bri'])
    var team_hue = int(self.state.team_color_map['hue'])
    var team_sat = int(self.state.team_color_map['sat'])

    var new_sat_255 = int((new_sat * 255) / 100)
    var hue_unchanged = (new_hue >= team_hue - 1) && (new_hue <= team_hue + 1)
    var sat_unchanged = (new_sat_255 >= team_sat - 2) && (new_sat_255 <= team_sat + 2)

    if hue_unchanged && sat_unchanged
      # Brightness-only change — keep state
      var new_bri_255 = int((new_bri * 255) / 100)
      print(format('TAL: _on_hsb_change: brightness-only change (bri %d→%d) - update saved light state', team_bri, new_bri_255))
      self.state.team_color_map['bri'] = new_bri_255
      if self.config.saved_light != nil
        self.config.saved_light.bri = new_bri_255
        persist_saved_light(self.config.saved_light)
      end
      self.lc.update_breathe_brightness(self.state.animation, new_bri_255)
      return
    end

    # Hue/sat changed → user overrode the team color. Clear saved light state
    # and go to IDLE (don't restore, since the light is now what user wants).
    print(format('TAL: _on_hsb_change: hue/sat manually changed (hue %d→%d, sat %d→%d) — clearing saved light state.',
      team_hue, new_hue, team_sat, new_sat_255))
    self._set_mode(TL_IDLE, 'manual color override')
    self._teardown_active_event()
    self.state.clear()
  end

  # ── Manual UI activation ─────────────────────────────────
  def activate_team_light(team_slug)
    if team_slug == nil || team_slug == ''
      self.state.pinned_slug = nil
      # If already muted, user is explicitly asking to deactivate — restore light.
      if self.state.mode == TL_MUTED
        print('TAL: activate_team_light: unpin while muted, restoring light state.')
        self._restore_light_state('user deactivated from muted')
        return
      end
      var ev = self._calculate_active_event()
      if ev != nil
        # Event still active without pin — mute (stage color, wait for power-on).
        print(format('TAL: activate_team_light: unpinned but %s still active, entering TL_MUTED.', ev.competitor_slug))
        var rgb = self._get_team_color(ev.competitor_slug)
        self.lc.remove_light_change_rules()
        self.lc.clear_animation()
        var cur_bri = int(light.get()['bri'])
        light.set({'rgb': rgb, 'bri': cur_bri, 'power': false})  # stage color, preserve brightness, turn light off
        self.state.team_color_rgb = rgb
        self.state.team_color_map = light.get()
        if self.config.saved_light != nil
          self.config.saved_light.power = false
          persist_saved_light(self.config.saved_light)
        end
        self.state.active_event = ev
        self._set_mode(TL_MUTED, format('user unpinned, staged %s for %s, light off', rgb, ev.competitor_slug))
        self.lc.add_light_change_rules(
          / value, trigger, payload -> self._on_hsb_change(value, trigger, payload),
          / value, trigger, payload -> self._on_power_change(value, trigger, payload))
      else
        # No active event without pin — restore.
        print('TAL: activate_team_light: unpin with no active event, restoring light state.')
        self._restore_light_state('user unpinned with no active event')
      end
      return
    end
    var ev = self._event_for_slug(team_slug)
    if ev == nil
      print(format('TAL: activate_team_light: %s — no event known. Skipping.', team_slug))
      return
    end
    if !ev.is_winning()
      print(format('TAL: activate_team_light: %s — not winning. Skipping.', team_slug))
      return
    end
    print(format('TAL: activate_team_light: %s — pinning.', team_slug))
    self.state.pinned_slug = team_slug
    self.state.active_event = nil  # force re-eval
    self._apply_event_change(self._calculate_active_event(), true)
  end

  # ── Manual UI mute ───────────────────────────────────────
  def mute_team_light()
    if self.state.mode == TL_IDLE || self.state.active_event == nil
      print('TAL: mute_team_light: no active event — ignoring.')
      return
    end
    if self.state.mode == TL_MUTED
      print('TAL: mute_team_light: already muted — ignoring.')
      return
    end
    print(format('TAL: mute_team_light: muting %s.', self.state.active_event.competitor_slug))
    var rgb = self.state.team_color_rgb
    self.lc.remove_light_change_rules()
    self.lc.clear_animation()
    var cur_bri = int(light.get()['bri'])
    light.set({'rgb': rgb, 'bri': cur_bri, 'power': false})
    self.state.team_color_map = light.get()
    if self.config.saved_light != nil
      self.config.saved_light.power = false
      persist_saved_light(self.config.saved_light)
    end
    self._set_mode(TL_MUTED, 'user muted via UI')
    self.lc.add_light_change_rules(
      / value, trigger, payload -> self._on_hsb_change(value, trigger, payload),
      / value, trigger, payload -> self._on_power_change(value, trigger, payload))
  end

  # ── service static lifecycle helpers ──────────────────────
  static def run_from_conf()
    var c = persist_read_conf()
    var cls = introspect.get(global, 'TallieLightService')
    global._tallielight = (cls != nil ? cls : TallieLightService)(c)
  end

  static def unload()
    var s = global._tallielight
    if type(s) == 'instance'
      s._stop()
      tasmota.remove_rule('OAuth=UPDATED')
      tasmota.remove_timer('oauth_updated')
      global._tallielight = nil
      tasmota.gc()
    end
  end
end

################################
# Module export                #
################################
var tallielight = module('tallielight')
# Exported for tests.
tallielight.TL_IDLE = TL_IDLE
tallielight.TL_SOLID = TL_SOLID
tallielight.TL_ANIM = TL_ANIM
tallielight.TL_MUTED = TL_MUTED
tallielight.ScoreboardEvent = ScoreboardEvent
tallielight.TLConfig = TLConfig
tallielight.TLSavedLight = TLSavedLight
tallielight.TLRunState = TLRunState
tallielight.LightController = LightController
tallielight.TallieLightService = TallieLightService
tallielight.persist_read_conf = persist_read_conf
tallielight.persist_conf = persist_conf
tallielight.persist_saved_light = persist_saved_light
tallielight.run_from_conf = TallieLightService.run_from_conf
tallielight.unload = TallieLightService.unload
return tallielight
