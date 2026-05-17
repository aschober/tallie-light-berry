#
# TallieLightService — core runtime service for TallieLight.
#
#   The module wrapper lives in tallielight.be.
#
#   - Registers the device with the backend and connects to MQTT on start.
#   - Subscribes to scoreboard events and drives light state (solid color,
#     animation, mute, idle) based on the active event and team priority.
#   - Persists configuration and saved light state across reboots.
#

#@ solidify:TallieLightService,weak
import introspect

# When loaded as a .tapp module (non-solidified path), pull sibling classes from global.
var TLScoreboardEvent   = introspect.get(global, 'TLScoreboardEvent')
var TLConfig            = introspect.get(global, 'TLConfig')
var TLSavedLight        = introspect.get(global, 'TLSavedLight')
var TLRunState          = introspect.get(global, 'TLRunState')
var TLLightController   = introspect.get(global, 'TLLightController')

class TallieLightService
  static VERSION = 0x01020700    # stamped by bump-version.sh or CI workflow

  var device_id                  # device id - UUID derived from MAC addr, stable across resets
  var config                     # TLConfig
  var state                      # TLRunState
  var last_events                # map: slug -> TLScoreboardEvent
  var lc                         # TLLightController
  var mqtt                       # mqttclient instance
  var _mqtt_loop                 # fast-loop callback (kept as field so we can remove it)
  var _allowed_topics            # list of full topic strings returned by backend
  var _mqtt_host                 # MQTT host returned by backend
  var _mqtt_port                 # MQTT port returned by backend
  var _mqtt_authorizer_name      # MQTT authorizer name returned by backend
  var _register_device_backoff   # ms, increases by 10s per retry, gives up after 120000

  # ── Lifecycle ─────────────────────────────────────────────
  def init(config)
    self.device_id = self._derive_device_id()
    self.config = config
    self.state = TLRunState()
    self.last_events = {}
    self.lc = TLLightController()
    self.mqtt = nil
    self._mqtt_loop = nil
    self._allowed_topics = []
    self._mqtt_host = nil
    self._mqtt_port = nil
    self._mqtt_authorizer_name = nil
    self._register_device_backoff = 10000

    self._log(format('init - device_id=%s, adding oauth_updated rule', self.device_id))
    tasmota.add_rule('OAuth=UPDATED', /->
      tasmota.set_timer(0, /-> self._oauth_updated(), 'oauth_updated')
    )
    self._start()
  end

  def _derive_device_id()
    # UUIDv8 deterministic UUID derived from WiFi MAC via SHA-256
    # Tallie Light namespace (random): 61069543-17a7-40c1-9433-b3085e97c0e6
    import crypto
    import string
    var ns = bytes('6106954317a740c19433b3085e97c0e6')
    var mac = string.replace(tasmota.wifi('mac'), ':', '')
    var name = bytes().fromstring(mac)
    var h = crypto.SHA256()
    h.update(ns)
    h.update(name)
    var d = h.out()
    d[6] = (d[6] & 0x0F) | 0x80   # version 8
    d[8] = (d[8] & 0x3F) | 0x80   # variant 10xx
    return string.tolower(d[0..3].tohex() + '-' + d[4..5].tohex() + '-' + d[6..7].tohex() + '-' + d[8..9].tohex() + '-' + d[10..15].tohex())
  end

  # ── Device registration ───────────────────────────────────
  def _webclient_put(url, payload, headers)
    tasmota.gc()
    var wc = webclient()
    wc.set_timeouts(4000, 3000)
    try
      wc.begin(url)
      for h : headers  wc.add_header(h[0], h[1])  end
      var http_code = wc.PUT(payload)
      var body = wc.get_string()
      wc.close()
      wc = nil
      return {"http_code": http_code, "response_body": body}
    except .. as e, msg
      try wc.close() except .. end
      wc = nil
      return {"http_code": -1, "response_body": ""}
    end
  end

  def _register_device()
    import json
    var tallielight_env = global._tallielight_env
    var token = global._oauth._get_valid_access_token()
    if token == nil  return {"success": false, "message": "No valid access token"}  end

    var team_slugs = []
    for tc : self.config.team_configs  team_slugs.push(tc['teamSlug'])  end

    var url = tallielight_env.BACKEND_URL + "/devices/" + self.device_id + "/register"
    var body = json.dump({"slugs": team_slugs})
    var headers = [["Content-Type", "application/json"],
                   ["Authorization", "Bearer " + token]]
    token = nil

    var resp = self._webclient_put(url, body, headers)
    var http_code = resp["http_code"]
    if http_code == 200
      var parsed = nil
      try parsed = json.load(resp["response_body"]) except .. end
      if parsed != nil && classname(parsed) == "map" && parsed.contains("password")
        self._allowed_topics = parsed["topics"]
        self._mqtt_host = parsed["mqtt_host"]
        self._mqtt_port = int(parsed["mqtt_port"])
        self._mqtt_authorizer_name = parsed["mqtt_authorizer_name"]
        self._log(format("_register_device: success, host=%s port=%d topics=%d",
                     self._mqtt_host, self._mqtt_port, self._allowed_topics.size()))
        return {"success": true, "password": parsed["password"]}
      end
    end

    var msg = format("HTTP %s", str(http_code))
    if http_code == -1  msg = "HTTP request failed"  end
    self._log(format("_register_device: failed — %s", msg))
    return {"success": false, "message": msg}
  end

  def _connect_mqtt()
    tasmota.remove_timer("register_device_retry")

    var result = self._register_device()
    if result["success"]
      self._register_device_backoff = 10000
      var client_id = self.device_id
      var mqtt_user = global._oauth.get_user_id() + '?x-amz-customauthorizer-name=' + self._mqtt_authorizer_name
      var mqtt_password = result["password"]
      self._log(format("_connect_mqtt: MQTT creds client_id=%s, pw len=%s", client_id, size(mqtt_password)))
      self._log(format('_connect_mqtt: Connecting to MQTT broker %s:%d…', self._mqtt_host, self._mqtt_port))
      var connected = self.mqtt.connect(self._mqtt_host, self._mqtt_port, client_id, mqtt_user, mqtt_password, true)
      if !connected
        self._log(format('_connect_mqtt: MQTT initial connection failed (state=%d). Auto-reconnect will retry.', self.mqtt.state()))
      end
    else
      if self._register_device_backoff > 120000
        self._log(format("_connect_mqtt: registration failed (%s), giving up after max retries.", result["message"]))
      else
        self._log(format("_connect_mqtt: registration failed (%s), retrying in %dms",
                     result["message"], self._register_device_backoff))
        tasmota.set_timer(self._register_device_backoff,
                          /-> self._connect_mqtt(), "register_device_retry")
        self._register_device_backoff += 10000
      end
    end
  end

  def _start()
    self._log('Starting TallieLightService…')

    var team_slugs = []
    for tc : self.config.team_configs  team_slugs.push(tc['teamSlug'])  end
    self._log(format('Configured for teams: %s', team_slugs))

    if !global._oauth.is_authorized(true)
      self._log('MQTT connect deferred as device is not authorized.')
      return
    end

    self.mqtt = global.mqttclient()
    self.mqtt.set_on_message(/ topic, idx, payload_s, payload_b -> self._process_event(topic, idx, payload_s))
    self.mqtt.set_on_connect(def ()
      self._log(format('MQTT connected. Subscribing to topics: %s', str(self._allowed_topics)))
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
    self._log('Stopping TallieLightService…')
    tasmota.remove_timer("register_device_retry")

    self._restore_light_state('stopping service')
    # self.lc.clear_animation()
    # self.lc.remove_event_timer()
    # self.lc.remove_light_change_rules()
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
    self._log('OAuth updated. Reconnecting MQTT…')
    if self.mqtt == nil
      self._start()
      return
    end
    if !global._oauth.is_authorized(false)
      self._log('OAuth updated but device not authorized. Skipping reconnect.')
      return
    end
    self._register_device_backoff = 10000
    self._connect_mqtt()
  end

  # Logging helper for debug print statements that is ignored by strip_berry in build-tapp.sh
  def _log(msg) print("TAL: " + msg) end

  # ── MQTT message handling ─────────────────────────────────
  def _process_event(topic, idx, json_data)
    import json
    var raw = json.load(json_data)
    if raw == nil
      print(format('TAL: _process_event: Invalid JSON: %s', json_data))
      return false
    end
    var event = TLScoreboardEvent(raw)
    self.last_events[event.competitor_slug] = event
    print(format('TAL: _process_event: MQTT event for %s', event.competitor_slug))
    self._apply_event_change(self._calculate_active_event(), false)
    return true
  end

  def _set_mode(new_mode, reason)
    if self.state.mode == new_mode
      print(format('TAL: _set_mode: %s (no change) — %s', TallieLightService.tl_mode_name(new_mode), reason))
    else
      print(format('TAL: _set_mode: %s → %s — %s', TallieLightService.tl_mode_name(self.state.mode), TallieLightService.tl_mode_name(new_mode), reason))
      self.state.mode = new_mode
    end
  end

  # ── Helpers ───────────────────────────────────────────────
  def _get_team_color(team_slug)
    import string
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
  def _calculate_active_event()
    if self.state.pinned_slug != nil
      var ev = self._event_for_slug(self.state.pinned_slug)
      if ev != nil && ev.is_winning()
        print(format('TAL: _calculate_active_event: %s (pinned)', self.state.pinned_slug))
        return ev
      end
      print(format('TAL: _calculate_active_event: %s (pinned) is no longer winning. Clearing pin.', self.state.pinned_slug))
      self.state.pinned_slug = nil
    end

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

    if self.state.mode == TallieLightService.TL_MUTED && !user_initiated
      print(format('TAL: _apply_event_change: muted and not user initiated, updating active event to %s but no light changes.', new_ev.competitor_slug))
      self.state.active_event = new_ev
      return
    end

    print(format('TAL: _apply_event_change: activating %s (user_initiated=%s)', new_ev.competitor_slug, user_initiated))
    self._set_active_event(new_ev, user_initiated)
  end

  def save_light_state(end_time_epoch)
    if self.config.saved_light == nil
      self.config.saved_light = TLSavedLight.from_light(light.get(), end_time_epoch)
      TallieLightService.persist_saved_light(self.config.saved_light)
      return
    end
    if self.config.saved_light.end_time == end_time_epoch return end
    self.config.saved_light.end_time = end_time_epoch
    TallieLightService.persist_saved_light(self.config.saved_light)
  end

  def _teardown_active_event()
    self.lc.clear_animation()
    self.config.saved_light = nil
    TallieLightService.persist_saved_light(self.config.saved_light)
    self.lc.remove_event_timer()
    self.lc.remove_light_change_rules()
  end

  def _restore_light_state(reason)
    self.lc.restore_light(self.config.saved_light)
    self._set_mode(TallieLightService.TL_IDLE, reason)
    self._teardown_active_event()
    self.state.clear()
  end

  def _set_active_event(new_ev, user_initiated)
    var rgb = self._get_team_color(new_ev.competitor_slug)
    if rgb == nil return end

    self.state.active_event = new_ev

    var now = tasmota.rtc()['utc']
    var end_time
    if self.state.pinned_slug != nil
      end_time = now + (self.config.light_restore_mins * 60)
    else
      end_time = new_ev.last_updated + (self.config.light_restore_mins * 60)
    end

    var _tl = end_time - now
    print(format('TAL: _set_active_event: %s end_time=%d time_left=%02d:%02d:%02d', new_ev.competitor_slug, end_time, _tl / 3600, (_tl % 3600) / 60, _tl % 60))

    self.lc.remove_light_change_rules()
    self.save_light_state(end_time)

    var light_off = !light.get()['power']
    var should_mute = light_off && !self.config.turn_on_light && !user_initiated

    if should_mute
      self.lc.clear_animation()
      var cur_bri = int(light.get()['bri'])
      light.set({'rgb': rgb, 'bri': cur_bri, 'power': false})
      self.state.team_color_rgb = rgb
      self.state.team_color_map = light.get()
      self._set_mode(TallieLightService.TL_MUTED, format('staged %s for %s, light off', rgb, new_ev.competitor_slug))
      var duration = end_time - now
      if duration < 1 duration = 1 end
      self.lc.set_event_timer(duration, /-> self._handle_event_timeout())
      self.lc.add_light_change_rules(
        / value, trigger, payload -> self._on_hsb_change(value, trigger, payload),
        / value, trigger, payload -> self._on_power_change(value, trigger, payload))
      return
    end

    var clear_result = self.lc.clear_animation()
    if clear_result self.state.animation = nil end
    var r = self.lc.set_solid(rgb, self.state.team_color_rgb, clear_result, user_initiated, self.config.turn_on_light)
    self.state.team_color_rgb = rgb
    self.state.team_color_map = r['team_color_map']

    if new_ev.is_winner()
      self.state.animation = nil
      self._set_mode(TallieLightService.TL_SOLID, format('%s won %s-%s', new_ev.competitor_abbreviation, new_ev.competitor_score, new_ev.opponent_score))
    else
      print(format('TAL: _set_active_event: set_animation rgb=%s', self.state.team_color_map['rgb']))
      self.state.animation = self.lc.set_animation(self.state.team_color_map, self.config.animation_type)
      self._set_mode(TallieLightService.TL_ANIM, format('%s winning %s-%s (%s)', new_ev.competitor_abbreviation, new_ev.competitor_score, new_ev.opponent_score, self.config.animation_type))
    end

    var duration = end_time - now
    if duration < 1 duration = 1 end
    self.lc.set_event_timer(duration, /-> self._handle_event_timeout())
    self.lc.add_light_change_rules(
      / value, trigger, payload -> self._on_hsb_change(value, trigger, payload),
      / value, trigger, payload -> self._on_power_change(value, trigger, payload))
  end

  # ── Power-on for deferred animation ──────────────────────
  def _on_power_on_for_anim()
    if self.config.saved_light != nil
      self.config.saved_light.power = true
      TallieLightService.persist_saved_light(self.config.saved_light)
    end
    self.state.active_event = nil
    self._apply_event_change(self._calculate_active_event(), true)
  end

  # ── Event timeout ─────────────────────────────────────────
  def _handle_event_timeout()
    print(format('TAL: _handle_event_timeout: %s', self.state.active_event ? self.state.active_event.competitor_slug : 'nil'))
    self.state.active_event = nil
    self.state.pinned_slug = nil
    self._apply_event_change(self._calculate_active_event(), false)
  end

  # ── Manual light change rules ────────────────────────────
  def _on_power_change(value, trigger, payload)
    print(format('TAL: _on_power_change: value=%s', value))
    if value == 0
      if self.config.saved_light != nil
        self.config.saved_light.power = false
        TallieLightService.persist_saved_light(self.config.saved_light)
      end
      if self.state.active_event != nil
        self.lc.clear_animation()
        self.state.animation = nil
        self._set_mode(TallieLightService.TL_MUTED, 'user turned light off during active event')
      else
        print('TAL: _on_power_change: light off, no active event — restoring saved light state if any.')
        self._restore_light_state('light off, no active event')
      end
    else
      if self.state.mode == TallieLightService.TL_MUTED
        print('TAL: _on_power_change: user powered light on while muted, recalculate active event.')
        if self.config.saved_light != nil
          self.config.saved_light.power = true
          TallieLightService.persist_saved_light(self.config.saved_light)
        end
        self.state.active_event = nil
        self._apply_event_change(self._calculate_active_event(), true)
      elif self.config.saved_light != nil && self.config.saved_light.power == false
        print('TAL: _on_power_change: light on while saved_light.power=false — updating saved light state.')
        self.config.saved_light.power = true
        TallieLightService.persist_saved_light(self.config.saved_light)
      end
    end
  end

  def _on_hsb_change(value, trigger, payload)
    import string
    print(format('TAL: _on_hsb_change: value=%s', value))
    if self.state.team_color_map == nil
      print('TAL: _on_hsb_change: no team_color_map, ignoring HSB change.')
      return
    end
    var parts = string.split(value, ',')
    var new_hue = int(parts[0])
    var new_sat = int(parts[1])
    var new_bri = int(parts[2])

    var team_bri = int(self.state.team_color_map['bri'])
    var team_hue = int(self.state.team_color_map['hue'])
    var team_sat = int(self.state.team_color_map['sat'])

    var new_sat_255 = int((new_sat * 255) / 100)
    var hue_unchanged = (new_hue >= team_hue - 1) && (new_hue <= team_hue + 1)
    var sat_unchanged = (new_sat_255 >= team_sat - 2) && (new_sat_255 <= team_sat + 2)

    if hue_unchanged && sat_unchanged
      var new_bri_255 = int((new_bri * 255) / 100)
      var new_rgb = light.get()['rgb']
      print(format('TAL: _on_hsb_change: brightness-only change (bri %d→%d) - update saved light state and animation', team_bri, new_bri_255))
      self.state.team_color_map['bri'] = new_bri_255
      self.state.team_color_map['rgb'] = new_rgb
      if self.config.saved_light != nil
        self.config.saved_light.bri = new_bri_255
        TallieLightService.persist_saved_light(self.config.saved_light)
      end
      if self.state.animation != nil
        self.lc.update_animation(self.state.animation, new_rgb, new_bri_255)
      end
      return
    end

    print(format('TAL: _on_hsb_change: hue/sat manually changed (hue %d→%d, sat %d→%d) — clearing saved light state.',
      team_hue, new_hue, team_sat, new_sat_255))
    self._set_mode(TallieLightService.TL_IDLE, 'manual color override')
    self._teardown_active_event()
    self.state.clear()
  end

  # ── Manual UI activation ─────────────────────────────────
  def activate_team_light(team_slug)
    if team_slug == nil || team_slug == ''
      self.state.pinned_slug = nil
      if self.state.mode == TallieLightService.TL_MUTED
        print('TAL: activate_team_light: unpin while muted, restoring light state.')
        self._restore_light_state('user deactivated while muted')
        return
      end
      var ev = self._calculate_active_event()
      if ev != nil
        print(format('TAL: activate_team_light: unpinned but %s still active, entering TL_MUTED.', ev.competitor_slug))
        var rgb = self._get_team_color(ev.competitor_slug)
        self.lc.remove_light_change_rules()
        self.lc.clear_animation()
        var cur_bri = int(light.get()['bri'])
        light.set({'rgb': rgb, 'bri': cur_bri, 'power': false})
        self.state.team_color_rgb = rgb
        self.state.team_color_map = light.get()
        if self.config.saved_light != nil
          self.config.saved_light.power = false
          TallieLightService.persist_saved_light(self.config.saved_light)
        end
        self.state.active_event = ev
        self._set_mode(TallieLightService.TL_MUTED, format('user unpinned, staged %s for %s, light off', rgb, ev.competitor_slug))
        self.lc.add_light_change_rules(
          / value, trigger, payload -> self._on_hsb_change(value, trigger, payload),
          / value, trigger, payload -> self._on_power_change(value, trigger, payload))
      else
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
    self.state.active_event = nil
    self._apply_event_change(self._calculate_active_event(), true)
  end

  # ── Manual UI mute ───────────────────────────────────────
  def mute_team_light()
    if self.state.mode == TallieLightService.TL_IDLE || self.state.active_event == nil
      print('TAL: mute_team_light: no active event — ignoring.')
      return
    end
    if self.state.mode == TallieLightService.TL_MUTED
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
      TallieLightService.persist_saved_light(self.config.saved_light)
    end
    self._set_mode(TallieLightService.TL_MUTED, 'user muted via UI')
    self.lc.add_light_change_rules(
      / value, trigger, payload -> self._on_hsb_change(value, trigger, payload),
      / value, trigger, payload -> self._on_power_change(value, trigger, payload))
  end

  # ── Static members ────────────────────────────────────────
  static TL_IDLE  = 0
  static TL_SOLID = 1
  static TL_ANIM  = 2
  static TL_MUTED = 3

  static def tl_mode_name(m)
    if m == 0  return 'TL_IDLE'  end
    if m == 1  return 'TL_SOLID' end
    if m == 2  return 'TL_ANIM'  end
    if m == 3  return 'TL_MUTED' end
    return format('?%d', m)
  end

  static def persist_read_conf()
    import persist
    var c = TLConfig()
    c.team_configs = persist.find('sl_teams', [])
    c.light_restore_mins = persist.find('sl_restore_mins', 60)
    c.turn_on_light = persist.find('sl_turn_on', true)
    c.animation_type = persist.find('sl_anim_type', 'crenel')
    c.saved_light = TLSavedLight.from_map(persist.find('sl_saved_light', nil))
    return c
  end

  static def persist_saved_light(saved_light)
    import persist
    print(format('TAL: persist_saved_light: saving light state: %s', saved_light))
    persist.sl_saved_light = (saved_light != nil) ? saved_light.to_map() : nil
    persist.save()
  end

  static def persist_conf(conf)
    import persist
    persist.sl_teams = conf.team_configs
    persist.sl_restore_mins = conf.light_restore_mins
    persist.sl_turn_on = conf.turn_on_light
    persist.sl_anim_type = conf.animation_type
    persist.sl_saved_light = (conf.saved_light != nil) ? conf.saved_light.to_map() : nil
    persist.save()
  end

end
global.TallieLightService = TallieLightService
