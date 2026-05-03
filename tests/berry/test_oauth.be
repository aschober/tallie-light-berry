# OAuth tests
#
#   These tests exercise oauth.be directly (not through the harness's
#   _OAuthService stub). They drive HTTP responses via harness.enqueue_http
#   and inspect persist + scheduled timers to verify behavior.
#

import global
import harness
import persist
import string
import json

# oauth.be returns a singleton OAuthService instance from its init function.
import introspect

var passed = 0
var failed = 0
var failures = []

def expect(label, actual, expected)
  if actual == expected
    passed += 1
  else
    failed += 1
    failures.push(format("%s: expected %s, got %s", label, str(expected), str(actual)))
  end
end

def expect_true(label, cond) expect(label, cond, true) end
def expect_false(label, cond) expect(label, cond, false) end
def expect_nil(label, v) expect(label, v, nil) end
def expect_not_nil(label, v)
  if v != nil passed += 1
  else
    failed += 1
    failures.push(format("%s: expected non-nil, got nil", label))
  end
end

# ── helpers ────────────────────────────────────────────────

# Build a JWT-shaped string with a base64url payload encoding the given map.
# Header and signature are placeholder strings; oauth_v2 only parses the payload.
def make_jwt(payload_map)
  var payload_json = json.dump(payload_map)
  var b64 = bytes().fromstring(payload_json).tob64()
  # Strip '=' padding and convert to base64url (- _ instead of + /)
  while size(b64) > 0 && b64[size(b64) - 1] == '='
    b64 = b64[0 .. size(b64) - 2]
  end
  b64 = string.replace(b64, "+", "-")
  b64 = string.replace(b64, "/", "_")
  return "hdr." + b64 + ".sig"
end

# Build a fresh OAuthService instance, resetting world state.
def setup()
  harness.reset()
  # Fix the clock to a known reference time used throughout the tests.
  harness.set_clock(1700000000)
  # `import oauth` returns a fresh singleton service instance (the module's
  # init() runs once per process; harness.reset() clears persist + tasmota
  # state so the singleton effectively starts clean each test).
  import oauth
  return oauth
end

# Build a successful token-endpoint response body.
def token_response_body(exp_at, sub, email, refresh_token)
  return json.dump({
    "access_token": make_jwt({"exp": exp_at, "sub": sub, "email": email}),
    "refresh_token": refresh_token
  })
end

# ── 1. is_authorized(false) ────────────────────────────────

def test_is_authorized_false_with_valid_token()
  var oa = setup()
  persist.oa_at = make_jwt({"exp": 1700000900, "sub": "u1", "email": "a@b"})
  persist.oa_ate = 1700000900     # 900s after current clock → valid
  expect_true("valid token → authorized", oa.is_authorized(false))
end

def test_is_authorized_false_with_no_token()
  var oa = setup()
  expect_false("missing token → unauthorized", oa.is_authorized(false))
end

def test_is_authorized_false_with_expired_token()
  var oa = setup()
  persist.oa_at = make_jwt({"exp": 1699999000, "sub": "u1", "email": "a@b"})
  persist.oa_ate = 1699999000     # before clock → expired
  expect_false("expired token, no refresh → unauthorized", oa.is_authorized(false))
end

# ── 2. is_authorized(true) schedules expiry timer ──────────

def test_is_authorized_true_schedules_timer_when_expiry_within_cron_window()
  var oa = setup()
  # Cron window is 15 min = 900s. Expiry in 300s → must schedule.
  persist.oa_at = make_jwt({"exp": 1700000300, "sub": "u1", "email": "a@b"})
  persist.oa_ate = 1700000300
  oa.is_authorized(true)
  expect_true("oauth_expiry_refresh timer scheduled",
              harness.has_timer("oauth_expiry_refresh"))
end

def test_is_authorized_true_no_timer_when_far_from_expiry()
  var oa = setup()
  # Expiry in 3600s (well beyond cron window) → no timer.
  persist.oa_at = make_jwt({"exp": 1700003600, "sub": "u1", "email": "a@b"})
  persist.oa_ate = 1700003600
  oa.is_authorized(true)
  expect_false("no oauth_expiry_refresh timer when token has plenty of life",
               harness.has_timer("oauth_expiry_refresh"))
end

# ── 3. _handle_token_response happy path ───────────────────

def test_handle_token_response_persists_all_fields()
  var oa = setup()
  # Pre-populate an error (in-memory pending) to verify it gets cleared.
  oa._device_flow_state["oa_err"] = "previous error"
  var body = token_response_body(1700005000, "user-abc", "x@y.com", "refresh-xyz")
  var r = oa._handle_token_response(200, body, "TEST")
  expect_true("success", r["success"])
  expect("oa_at persisted", persist.find("oa_at", nil),
         make_jwt({"exp": 1700005000, "sub": "user-abc", "email": "x@y.com"}))
  expect("oa_ate persisted", persist.find("oa_ate", nil), 1700005000)
  expect("oa_uid persisted", persist.find("oa_uid", nil), "user-abc")
  expect("oa_email persisted", persist.find("oa_email", nil), "x@y.com")
  expect("oa_rt persisted", persist.find("oa_rt", nil), "refresh-xyz")
  expect_nil("oa_err cleared", oa._get("oa_err"))
end

# ── 4. authorization_pending preserves state ───────────────

def test_handle_token_response_authorization_pending()
  var oa = setup()
  var prior_err = "an earlier error"
  persist.oa_err = prior_err
  var body = json.dump({"error": "authorization_pending", "error_description": "User has not yet authorized"})
  var r = oa._handle_token_response(400, body, "TEST")
  expect_false("success=false", r["success"])
  expect_true("authorization_pending=true", r.find("authorization_pending", false))
  # Must NOT overwrite oa_err — current poll attempt isn't an error to surface.
  expect("oa_err untouched", persist.find("oa_err", nil), prior_err)
end

# ── 5. refresh_access_token wipes auth on 4xx ──────────────

def test_refresh_access_token_4xx_wipes_all_auth()
  var oa = setup()
  # Seed full prior auth state.
  persist.oa_at = "old-jwt"
  persist.oa_ate = 1700000900
  persist.oa_rt = "old-refresh"
  persist.oa_uid = "u1"
  persist.oa_email = "x@y.com"
  persist.oa_mp = "mqtt-pass"

  # OAuth returns 401 → refresh token invalid.
  harness.enqueue_http(401, json.dump({"error": "invalid_grant"}))
  var r = oa.refresh_access_token_flow()
  expect_false("success=false", r["success"])
  expect_nil("oa_at wiped", persist.find("oa_at", nil))
  expect_nil("oa_rt wiped", persist.find("oa_rt", nil))
  expect_nil("oa_ate wiped", persist.find("oa_ate", nil))
  expect_nil("oa_uid wiped", persist.find("oa_uid", nil))
  expect_nil("oa_email wiped", persist.find("oa_email", nil))
  expect_nil("oa_mp wiped", persist.find("oa_mp", nil))
end

# ── 6. clear_pending_oauth_data scope ──────────────────────

def test_clear_pending_preserves_persistent_auth()
  var oa = setup()
  # Persistent auth.
  persist.oa_at = "jwt"
  persist.oa_ate = 1700000900
  persist.oa_rt = "refresh"
  persist.oa_uid = "u1"
  persist.oa_email = "x@y.com"
  persist.oa_mp = "mqtt-pass"
  # Pending fields (from device-flow init) — held in-memory, not persist.
  oa._device_flow_state["oa_dc"]  = "device-code"
  oa._device_flow_state["oa_dce"] = 1700000500
  oa._device_flow_state["oa_uc"]  = "ABCD-1234"
  oa._device_flow_state["oa_vuc"] = "https://kinde/verify?code=ABCD-1234"
  oa._device_flow_state["oa_pi"]  = 5
  oa._device_flow_state["oa_err"] = "stale error"

  oa.clear_pending_oauth_data()

  # Pending wiped (in-memory only — persist never held these):
  expect_nil("oa_dc wiped", oa._get("oa_dc"))
  expect_nil("oa_dce wiped", oa._get("oa_dce"))
  expect_nil("oa_uc wiped", oa._get("oa_uc"))
  expect_nil("oa_vuc wiped", oa._get("oa_vuc"))
  expect_nil("oa_pi wiped", oa._get("oa_pi"))
  expect_nil("oa_err wiped", oa._get("oa_err"))
  # Persistent auth preserved:
  expect("oa_at preserved", persist.find("oa_at", nil), "jwt")
  expect("oa_ate preserved", persist.find("oa_ate", nil), 1700000900)
  expect("oa_rt preserved", persist.find("oa_rt", nil), "refresh")
  expect("oa_uid preserved", persist.find("oa_uid", nil), "u1")
  expect("oa_email preserved", persist.find("oa_email", nil), "x@y.com")
  expect("oa_mp preserved", persist.find("oa_mp", nil), "mqtt-pass")
end

# ── 7. read_all_oauth_data freshness ───────────────────────

def test_read_all_oauth_data_returns_fresh_map()
  var oa = setup()
  persist.oa_email = "first@x.com"
  var m1 = oa.read_all_oauth_data()
  expect("first read sees first email", m1["oa_email"], "first@x.com")

  # Mutate persist between reads. A fresh map should reflect the new state.
  persist.oa_email = "second@x.com"
  var m2 = oa.read_all_oauth_data()
  expect("second read sees updated email", m2["oa_email"], "second@x.com")

  # First map must be its own copy — mutating it must not poison subsequent reads.
  m2["oa_email"] = "tampered@x.com"
  var m3 = oa.read_all_oauth_data()
  expect("third read still reads from persist, not a shared map",
         m3["oa_email"], "second@x.com")
end

# ── Run ────────────────────────────────────────────────────
def run_all()
  test_is_authorized_false_with_valid_token()
  test_is_authorized_false_with_no_token()
  test_is_authorized_false_with_expired_token()
  test_is_authorized_true_schedules_timer_when_expiry_within_cron_window()
  test_is_authorized_true_no_timer_when_far_from_expiry()
  test_handle_token_response_persists_all_fields()
  test_handle_token_response_authorization_pending()
  test_refresh_access_token_4xx_wipes_all_auth()
  test_clear_pending_preserves_persistent_auth()
  test_read_all_oauth_data_returns_fresh_map()

  print(format("Batch 4: %d passed, %d failed", passed, failed))
  if failed > 0
    print("Failures:")
    for f : failures
      print("  -", f)
    end
    return 1
  end
  return 0
end

run_all()
