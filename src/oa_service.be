#
# OAuthService — OAuth Device Authorization Flow for TallieLight.
#
#   - OAuth Device Flow (RFC 8628): initiate → user logs in via verification
#     URL → poll → tokens → announce OAuth=UPDATED (tallielight.be handles
#     backend registration).
#   - All OAuth state lives in `persist` (Tasmota's flash store). Long strings
#     (access token JWT, refresh token, device code, verification URI) only
#     enter the heap when actually needed.
#   - Two fields are cached on the instance: user id and token expiry.
#

#@ solidify:OAuthService,weak
class OAuthService
  static VERSION = 0x01020600  # stamped by bump-version.sh or CI workflow
  
  var device_id              # cached device id — never changes after first boot
  var _cached_uid            # cached user id — used on every MQTT (re)connect
  var _cached_token_expiry   # cached token expiry — used on every is_authorized cron tick
  var _device_flow_state     # transient device-flow state (oa_uc/oa_vuc/oa_dc/oa_dce/oa_pi/oa_err) — in-memory only

  # Map of OAuth field names to the persist keys used to store them.
  # USER_CODE: "oa_uc",
  # VERIFICATION_URI_COMPLETE: "oa_vuc",
  # DEVICE_CODE: "oa_dc",
  # DEVICE_CODE_EXPIRY: "oa_dce",
  # POLLING_INTERVAL: "oa_pi",
  # LAST_ERROR: "oa_err",
  # ACCESS_TOKEN: "oa_at",
  # ACCESS_TOKEN_EXPIRY: "oa_ate",
  # USER_ID: "oa_uid",
  # USER_EMAIL: "oa_email",
  # REFRESH_TOKEN: "oa_rt"

  # All keys that get persisted. read_all_oauth_data() iterates this list to
  # build a fresh map for the UI (pending keys are merged separately).
  static _PERSIST_KEYS = ["oa_at", "oa_ate", "oa_uid", "oa_email", "oa_rt"]

  # Pending device-flow keys held in _device_flow_state map (not persisted).
  static _DEVICE_FLOW_KEYS = ["oa_uc", "oa_vuc", "oa_dc", "oa_dce", "oa_pi", "oa_err"]

  static OAUTH_REFRESH_WINDOW_MINUTES = 15

  def init()
    import persist
    import math
    math.srand(tasmota.millis())

    # First-boot device id is generated once and pinned.
    var did = persist.find("oa_did", nil)
    if did == nil
      import uuid
      did = uuid.uuid4()
      persist.oa_did = did
      persist.save()
      self._log(format("init - generated new device_id %s", did))
    end
    self.device_id = did

    # Prime the in-memory oauth cache from persist
    self._cached_uid            = persist.find("oa_uid", nil)
    self._cached_token_expiry   = persist.find("oa_ate", nil)
    self._device_flow_state     = {}

    # Spread refresh-check cron across 15-min window to avoid thundering herd
    var interval = OAuthService.OAUTH_REFRESH_WINDOW_MINUTES
    var offset = math.rand() % interval
    var minutes = []
    var mm = offset
    while mm < 60
      minutes.push(str(mm))
      mm = mm + interval
    end
    tasmota.remove_cron("oauth_refresh")
    tasmota.add_cron(format("0 %s * * * *", minutes.concat(",")),
                     /-> self._cron_refresh_check(), "oauth_refresh")
    self._log(format("init - device_id=%s, refresh cron at minutes %s",
                     did, minutes.concat(",")))
  end

  def unload()
    tasmota.remove_cron("oauth_refresh")
    tasmota.remove_timer("oauth_expiry_refresh")
    tasmota.remove_timer("oauth_register")
    self._log("unloaded")
  end

  def _log(msg) print("OAUTH: " + msg) end

  def _cron_refresh_check() self.is_authorized(true) end

  # ── Storage layer ────────────────────────────────────────────────

  # Read a single key — device-flow keys come from the in-memory map.
  def _get(key)
    if self._device_flow_state.contains(key) return self._device_flow_state[key] end
    import persist
    return persist.find(key, nil)
  end

  # Write a map of key→value. Device-flow keys go to _device_flow_state; persist keys
  # go to flash in one batch (single .save()). nil values delete the key.
  def _set_many(data)
    if data == nil || data.size() == 0 return end
    var needs_save = false
    import persist
    for k : data.keys()
      var v = data[k]
      if OAuthService._DEVICE_FLOW_KEYS.find(k) != nil
        if v != nil self._device_flow_state[k] = v
        else        self._device_flow_state.remove(k)
        end
      else
        if v != nil
          persist.setmember(k, v)
        else
          persist.remove(k)
        end
        needs_save = true
        # Update the small in-memory cache for hot persist fields.
        if   k == "oa_uid" self._cached_uid          = v
        elif k == "oa_ate" self._cached_token_expiry = v
        end
      end
    end
    if needs_save persist.save() end
  end

  # Build a fresh map of all OAuth fields for the UI. Caller-owned: the
  # returned map is not retained by the service.
  def read_all_oauth_data()
    import persist
    var out = {}
    for k : OAuthService._PERSIST_KEYS
      out[k] = persist.find(k, nil)
    end
    # Merge in-memory device-flow fields (nil values are excluded).
    for k : OAuthService._DEVICE_FLOW_KEYS
      var v = self._device_flow_state.find(k, nil)
      if v != nil out[k] = v end
    end
    return out
  end

  def clear_pending_oauth_data()
    self._device_flow_state = {}
    self._log("cleared pending OAuth data")
  end

  def delete_all_oauth_data()
    self._device_flow_state = {}
    import persist
    for k : OAuthService._PERSIST_KEYS persist.remove(k) end
    persist.save()
    self._cached_uid          = nil
    self._cached_token_expiry = nil
    self._log("cleared all OAuth data")
  end

  # Save an error to LAST_ERROR and return a failure result map.
  def _save_error(msg)
    self._device_flow_state["oa_err"] = msg
    return {"success": false, "message": msg}
  end

  # ── HTTP layer ───────────────────────────────────────────────────

  # POST helper that owns the full webclient lifecycle and GCs around
  # the request. headers: optional list of [name, value]; defaults to
  # form-urlencoded.
  def _webclient_post(url, payload, log_header, headers)
    do var m = tasmota.memory() self._log(format("%s _webclient_post pre-start-gc heap_free: %s, frag: %s", log_header, m.find("heap_free", "?"), m.find("frag", "?"))) end
    tasmota.gc()
    do var m = tasmota.memory() self._log(format("%s _webclient_post post-start-gc heap_free: %s, frag: %s", log_header, m.find("heap_free", "?"), m.find("frag", "?"))) end
    var wc = webclient()
    try
      wc.begin(url)
      if headers != nil
        for h : headers wc.add_header(h[0], h[1]) end
      else
        wc.add_header("Content-Type", "application/x-www-form-urlencoded")
      end
      var http_code = wc.POST(payload)
      var body = wc.get_string()
      wc.close()
      wc = nil
      do var m = tasmota.memory() self._log(format("%s _webclient_post pre-end-gc heap_free: %s, frag: %s", log_header, m.find("heap_free", "?"), m.find("frag", "?"))) end
      tasmota.gc()
      do var m = tasmota.memory() self._log(format("%s _webclient_post post-end-gc heap_free: %s, frag: %s", log_header, m.find("heap_free", "?"), m.find("frag", "?"))) end
      return {"http_code": http_code, "response_body": body}
    except .. as e, msg
      self._log(format("%s HTTP request failed - %s: %s", log_header, e, msg))
      try wc.close() except .. end
      wc = nil
      do var m = tasmota.memory() self._log(format("%s _webclient_post pre-end-gc heap_free: %s, frag: %s", log_header, m.find("heap_free", "?"), m.find("frag", "?"))) end
      tasmota.gc()
      do var m = tasmota.memory() self._log(format("%s _webclient_post post-end-gc heap_free: %s, frag: %s", log_header, m.find("heap_free", "?"), m.find("frag", "?"))) end
      return {"http_code": -1, "response_body": ""}
    end
  end

  # ── JWT layer ────────────────────────────────────────────────────

  # Decode the payload segment of a JWT. Header + signature are ignored.
  # Returns a map (the decoded JSON) or nil on any error.
  def _parse_jwt_payload(token, log_header)
    import string
    import json
    if token == nil return nil end

    var dot1 = string.find(token, ".")
    var dot2 = string.find(token, ".", dot1 + 1)
    if dot1 < 0 || dot2 < 0
      self._log(format("%s invalid JWT format", log_header))
      return nil
    end

    var b64 = token[dot1 + 1 .. dot2 - 1]
    if b64 == nil || size(b64) == 0
      self._log(format("%s empty JWT payload", log_header))
      return nil
    end

    # base64url → base64 + repad
    b64 = string.replace(b64, "-", "+")
    b64 = string.replace(b64, "_", "/")
    var mod = size(b64) % 4
    if mod == 2      b64 = b64 + "=="
    elif mod == 3    b64 = b64 + "="
    elif mod == 1
      self._log(format("%s invalid JWT base64 length", log_header))
      return nil
    end

    try
      var payload = json.load(bytes().fromb64(b64).asstring())
      if payload == nil || classname(payload) != "map"
        self._log(format("%s JWT payload is not a JSON object", log_header))
        return nil
      end
      return payload
    except .. as e, msg
      self._log(format("%s JWT decode error: %s - %s", log_header, e, msg))
      return nil
    end
  end

  # ── Token response handler ───────────────────────────────────────

  # Parse a /oauth2/token response and persist the resulting tokens.
  # Returns {"success": true, ...} on success, or a failure result map.
  # On HTTP non-200 with `error: authorization_pending`, returns
  # {"success": false, "authorization_pending": true} WITHOUT touching
  # oa_err — pending isn't a user-visible error, it's a poll-again signal.
  def _handle_token_response(http_code, body, log_header)
    import json

    if http_code == 200
      var parsed = nil
      try
        parsed = json.load(body)
      except .. as e, msg
        self._log(format("%s token JSON parse error: %s - %s", log_header, e, msg))
        return self._save_error("Token has invalid JSON")
      end
      if parsed == nil || classname(parsed) != "map" ||
          !parsed.contains("access_token") || !parsed.contains("refresh_token")
        return self._save_error("HTTP OK but response missing access_token or refresh_token")
      end

      var jwt_payload = self._parse_jwt_payload(parsed["access_token"], log_header)
      if jwt_payload == nil
        return self._save_error(format("%s failed to parse JWT payload", log_header))
      end
      if !jwt_payload.contains("exp") || !jwt_payload.contains("sub") || !jwt_payload.contains("email")
        return self._save_error(format("%s JWT missing required claims (exp, sub, email)", log_header))
      end

      var new_exp = int(jwt_payload["exp"])
      self._set_many({
        "oa_at":       parsed["access_token"],
        "oa_ate":      new_exp,
        "oa_uid":      jwt_payload["sub"],
        "oa_email":    jwt_payload["email"],
        "oa_rt":       parsed["refresh_token"],
        "oa_err":   nil
      })
      var ttl = new_exp - tasmota.rtc()["utc"]
      self._log(format("%s token persisted, valid for %ds", log_header, ttl))
      return {"success": true, "message": "HTTP OK"}
    end

    # Non-200: distinguish authorization_pending (expected) from real errors.
    try
      var parsed = json.load(body)
      if parsed != nil && classname(parsed) == "map" &&
          parsed.find("error", nil) == "authorization_pending"
        return {"success": false, "authorization_pending": true}
      end
    except .. end

    var msg = format("HTTP %s: %s", str(http_code), str(body))
    self._log(format("%s %s", log_header, msg))
    return self._save_error(msg)
  end

  # ── Flow methods ─────────────────────────────────────────────────

  def initiate_authorization_flow()
    import json
    var tallielight_env = global._tallielight_env
    self._log("initiating Device Authorization Flow")
    self.clear_pending_oauth_data()

    var log_header = "POST /oauth2/device/auth"
    var url = tallielight_env.OAUTH_DOMAIN + "/oauth2/device/auth"
    var resp = self._webclient_post(url, "scope=offline", log_header, nil)
    var http_code = resp["http_code"]
    var body = resp["response_body"]

    if http_code != 200
      return self._save_error(format("%s - HTTP %s, body: %s",
                                     log_header, str(http_code), str(body)))
    end

    var parsed = nil
    try parsed = json.load(body)
    except .. as e, msg
      return self._save_error(format("%s JSON parse error: %s - %s", log_header, e, msg))
    end

    if parsed == nil || classname(parsed) != "map" ||
        !parsed.contains("device_code") || !parsed.contains("user_code") ||
        !parsed.contains("verification_uri_complete") || !parsed.contains("expires_in")
      return self._save_error(format("%s HTTP OK but response missing required fields", log_header))
    end

    var now = tasmota.rtc()["utc"]
    self._set_many({
      "oa_dc":  parsed["device_code"],
      "oa_uc":  parsed["user_code"],
      "oa_vuc": parsed["verification_uri_complete"],
      "oa_dce": now + int(parsed["expires_in"]),
      "oa_pi":  parsed.contains("interval") ? int(parsed["interval"]) : 5,
      "oa_err": nil
    })
    return {"success": true, "message": format("%s HTTP OK", log_header)}
  end

  def complete_authorization_flow()
    import json
    var tallielight_env = global._tallielight_env
    self._log("polling /oauth2/token for completed authorization")

    var log_header = "POST /oauth2/token"
    var device_code = self._get("oa_dc")
    var dc_expiry   = self._get("oa_dce")

    if device_code == nil
      return self._save_error(format("%s - missing device_code", log_header))
    end
    var now = tasmota.rtc()["utc"]
    if dc_expiry != nil && now >= int(dc_expiry)
      self.clear_pending_oauth_data()
      return self._save_error(format("%s - device code expired", log_header))
    end

    var url = tallielight_env.OAUTH_DOMAIN + "/oauth2/token"
    var payload = "grant_type=urn:ietf:params:oauth:grant-type:device_code" +
                  "&client_id=" + tallielight_env.OAUTH_CLIENT_ID +
                  "&device_code=" + device_code
    var resp = self._webclient_post(url, payload, log_header, nil)
    var result = self._handle_token_response(resp["http_code"], resp["response_body"], log_header)

    if !result["success"]
      # authorization_pending → user hasn't logged in yet, keep pending state
      if result.find("authorization_pending", false)
        return result
      end
      # 5xx → transient, keep pending state for retry
      var hc = resp["http_code"]
      if hc >= 500 && hc < 600
        self._log(format("transient HTTP %d, keeping pending data for retry", hc))
        return result
      end
      # Other failures → wipe pending state, user will need to restart flow
      self.clear_pending_oauth_data()
      return result
    end

    # Tokens persisted. Defer device registration (~2s round-trip to the
    # backend) so the polling HTTP handler can return immediately — otherwise
    # the browser hits its chunked-response timeout before we send the body.
    # The deferred path still emits OAuth=UPDATED on success, which fires
    # the MQTT reconnect rule.
    self.clear_pending_oauth_data()
    tasmota.set_timer(0, /-> self._register_and_announce(), "oauth_register")
    return result
  end

  # Announce token update so the MQTT reconnect rule fires.
  def _register_and_announce()
    import json
    tasmota.publish_result(json.dump({'OAuth': 'UPDATED'}), 'RESULT')
  end

  def refresh_access_token_flow()
    import json
    var tallielight_env = global._tallielight_env
    self._log("refreshing access token")
    var log_header = "POST /oauth2/token refresh"

    var rt = self._get("oa_rt")
    if rt == nil
      return self._save_error(format("%s - missing refresh_token", log_header))
    end

    var url = tallielight_env.OAUTH_DOMAIN + "/oauth2/token"
    var payload = "grant_type=refresh_token" +
                  "&client_id=" + tallielight_env.OAUTH_CLIENT_ID +
                  "&refresh_token=" + rt
    rt = nil   # let the long string become collectable while the POST is in flight

    var resp = self._webclient_post(url, payload, log_header, nil)
    var http_code = resp["http_code"]

    # OAuth refresh errors (400/401/403) mean refresh token is invalid →
    # nuke all auth data so the UI prompts a fresh login.
    if http_code == 400 || http_code == 401 || http_code == 403
      self._log(format("refresh failed with HTTP %d - clearing all auth data", http_code))
      self.delete_all_oauth_data()
      return {"success": false,
              "message": format("Refresh token invalid (HTTP %d). Re-authentication required.", http_code)}
    end

    var result = self._handle_token_response(http_code, resp["response_body"], log_header)
    if !result["success"]
      self._log("refresh failed - cron will retry on next interval")
      return result
    end

    # If the new token expires before the next cron tick, schedule a one-shot
    # timer to refresh just after expiry so we ride out with a full TTL.
    self._maybe_schedule_expiry_timer()

    # Defer registration so callers (cron, manual refresh from UI) aren't
    # blocked on a backend round-trip. _register_and_announce emits
    # OAuth=UPDATED on success, which triggers the MQTT reconnect rule.
    tasmota.set_timer(0, /-> self._register_and_announce(), "oauth_register")
    return result
  end

  # ── Status accessors ─────────────────────────────────────────────

  # Schedule a one-shot timer to refresh just after the access token expires,
  # but only when expiry is sooner than the next cron tick (else cron handles it).
  def _maybe_schedule_expiry_timer()
    var ate = self._cached_token_expiry != nil ? self._cached_token_expiry : self._get("oa_ate")
    if ate == nil return end
    var secs = ate - tasmota.rtc()["utc"]
    var window = OAuthService.OAUTH_REFRESH_WINDOW_MINUTES * 60
    if secs <= 0 || secs >= window return end
    tasmota.remove_timer("oauth_expiry_refresh")
    tasmota.set_timer((secs + 1) * 1000, /-> self._cron_refresh_check(), "oauth_expiry_refresh")
    self._log(format("token expires in %ds, scheduled one-shot refresh", secs))
  end

  # is_authorized(should_refresh)
  #   should_refresh=false → pure check of "do we have a non-expired token?"
  #   should_refresh=true  → also schedule expiry timer when close, and
  #                          attempt a refresh when already expired.
  # Returns bool.
  def is_authorized(should_refresh)
    var now = tasmota.rtc()["utc"]
    var ate = self._cached_token_expiry != nil ? self._cached_token_expiry : self._get("oa_ate")
    var has_at = self._get("oa_at") != nil
    var token_valid = (has_at && ate != nil && now < ate)

    if token_valid
      if should_refresh self._maybe_schedule_expiry_timer() end
      return true
    end

    if !should_refresh return false end

    # Token expired or missing — try refresh if we have a refresh_token.
    if self._get("oa_rt") == nil
      self._log("no refresh_token available")
      return false
    end

    var refresh_result = self.refresh_access_token_flow()
    if refresh_result["success"] return true end
    self._log("refresh failed")
    return token_valid   # fall back to the (still expired) old answer
  end

  def _get_valid_access_token()
    if self.is_authorized(false) return self._get("oa_at") end
    return nil
  end

  def get_mqtt_username()  return self._cached_uid end
  def get_mqtt_client_id() return self.device_id end

end

global.OAuthService = OAuthService
