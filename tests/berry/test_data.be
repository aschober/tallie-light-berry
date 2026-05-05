# Data tests: data classes, enums, persist helpers
#
#   These tests cover the data classes used throughout the codebase, including
#   TLConfig, TLSavedLight, TLRunState, and ScoreboardEvent. They also test the
#   persist_read_conf and persist_conf functions that load/save TLConfig to
#   persistent storage. These tests don't rely on any TallieLightService behavior
#   or MQTT interactions; they just verify the core logic of these data classes
#   and persistence functions.

import global
import harness     # installs tasmota/light/mqttclient/_oauth_service globals
import json
import tallielight as sl

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

def expect_true(label, cond)
  expect(label, cond, true)
end

def expect_nil(label, val)
  expect(label, val == nil, true)
end

# ── ScoreboardEvent ─────────────────────────────────────────
def test_scoreboard_event()
  var json_str = '{"competitor":{"abbreviation":"NYY","slug":"new-york-yankees","winner":true,"score":"5","homeAway":"home"},'
                 '"opponent":{"abbreviation":"BOS","winner":false,"score":"3"},'
                 '"competition":{"date":"2025-04-25T19:00Z","leagueShortDisplayName":"MLB","status":{"type":{"shortDetail":"Final","state":"post"}}},'
                 '"lastUpdated":1234567890}'
  var ev = sl.ScoreboardEvent(json.load(json_str))
  expect("competitor_slug", ev.competitor_slug, "new-york-yankees")
  expect("competitor_abbreviation", ev.competitor_abbreviation, "NYY")
  expect("competitor_winner", ev.competitor_winner, true)
  expect("competitor_score", ev.competitor_score, "5")
  expect("competitor_home_away (home)", ev.competitor_home_away, true)
  expect("opponent_abbreviation", ev.opponent_abbreviation, "BOS")
  expect("opponent_score", ev.opponent_score, "3")
  expect("league_short_display_name", ev.league_short_display_name, "MLB")
  expect("competition_status_state", ev.competition_status_state, "post")
  expect("last_updated", ev.last_updated, 1234567890)
  expect_true("is_final()", ev.is_final())
  expect_true("is_winner()", ev.is_winner())
  expect_true("is_winning() final", ev.is_winning())
  expect("is_in_progress()", ev.is_in_progress(), false)
  expect("is_scheduled()", ev.is_scheduled(), false)
end

def test_scoreboard_event_in_progress_winning()
  var ev = sl.ScoreboardEvent(json.load(
    '{"competitor":{"abbreviation":"NYY","slug":"nyy","score":"3"},'
    '"opponent":{"abbreviation":"BOS","score":"1"},'
    '"competition":{"date":"2025-04-25T19:00Z","status":{"type":{"shortDetail":"Top 7th","state":"in"}}},'
    '"lastUpdated":1700}'))
  expect_true("in-progress winning", ev.is_winning())
  expect("not winner (no final)", ev.is_winner(), false)
  expect_true("is_in_progress", ev.is_in_progress())
end

def test_scoreboard_event_tied_not_winning()
  var ev = sl.ScoreboardEvent(json.load(
    '{"competitor":{"abbreviation":"NYY","slug":"nyy","score":"2"},'
    '"opponent":{"abbreviation":"BOS","score":"2"},'
    '"competition":{"date":"2025-04-25T19:00Z","status":{"type":{"shortDetail":"Tied","state":"in"}}},'
    '"lastUpdated":1700}'))
  expect("tied is not winning", ev.is_winning(), false)
end

def test_scoreboard_event_final_lost()
  var ev = sl.ScoreboardEvent(json.load(
    '{"competitor":{"abbreviation":"NYY","slug":"nyy","winner":false,"score":"1"},'
    '"opponent":{"abbreviation":"BOS","winner":true,"score":"5"},'
    '"competition":{"date":"2025-04-25T19:00Z","status":{"type":{"shortDetail":"Final","state":"post"}}},'
    '"lastUpdated":1700}'))
  expect_true("is_final", ev.is_final())
  expect("is_winner false (lost)", ev.is_winner(), false)
  expect("is_winning false", ev.is_winning(), false)
end

def test_scoreboard_event_scheduled()
  var ev = sl.ScoreboardEvent(json.load(
    '{"competitor":{"abbreviation":"NYY","slug":"nyy","score":"0"},'
    '"opponent":{"abbreviation":"BOS","score":"0"},'
    '"competition":{"date":"2025-04-26T19:00Z","status":{"type":{"shortDetail":"Scheduled","state":"pre"}}},'
    '"lastUpdated":1700}'))
  expect_true("is_scheduled", ev.is_scheduled())
  expect("not winning", ev.is_winning(), false)
end

# ── TLConfig ───────────────────────────────────────────────
def test_slconfig_defaults()
  var c = sl.TLConfig()
  expect("team_configs default empty", size(c.team_configs), 0)
  expect("light_restore_mins default", c.light_restore_mins, 60)
  expect("turn_on_light default true", c.turn_on_light, true)
  expect("animation_type default crenel", c.animation_type, "crenel")
  expect_nil("saved_light default nil", c.saved_light)
end

# ── TLSavedLight ───────────────────────────────────────────
def test_slsavedlight_from_light()
  var lm = {'rgb': '002d72', 'hue': 220, 'sat': 200, 'bri': 100, 'power': true}
  var s = sl.TLSavedLight.from_light(lm, 9999)
  expect("rgb", s.rgb, "002d72")
  expect("hue", s.hue, 220)
  expect("sat", s.sat, 200)
  expect("bri", s.bri, 100)
  expect("power", s.power, true)
  expect("end_time", s.end_time, 9999)
end

def test_slsavedlight_to_map_roundtrip()
  var orig = sl.TLSavedLight.from_light({'rgb': 'aabbcc', 'hue': 10, 'sat': 50, 'bri': 200, 'power': false}, 4242)
  var m = orig.to_map()
  var back = sl.TLSavedLight.from_map(m)
  expect("rt rgb", back.rgb, "aabbcc")
  expect("rt hue", back.hue, 10)
  expect("rt power", back.power, false)
  expect("rt end_time", back.end_time, 4242)
end

def test_slsavedlight_from_nil()
  expect_nil("from_map(nil)", sl.TLSavedLight.from_map(nil))
end

# ── TLRunState ─────────────────────────────────────────────
def test_slrunstate_clear()
  var s = sl.TLRunState()
  s.mode = sl.TL_ANIM
  s.active_event = "fake"
  s.pinned_slug = "team-a"
  s.team_color_rgb = "ff0000"
  s.animation = "anim"
  s.clear()
  expect("mode", s.mode, sl.TL_IDLE)
  expect_nil("active_event", s.active_event)
  expect_nil("pinned_slug", s.pinned_slug)
  expect_nil("team_color_rgb", s.team_color_rgb)
  expect_nil("animation", s.animation)
end

# ── persist_read_conf / persist_conf ────────────────────────────
def test_persist_defaults()
  harness.reset()
  var c = sl.persist_read_conf()
  expect("default team_configs", size(c.team_configs), 0)
  expect("default light_restore_mins", c.light_restore_mins, 60)
  expect("default turn_on_light", c.turn_on_light, true)
  expect("default animation_type crenel", c.animation_type, "crenel")
  expect_nil("default saved_light", c.saved_light)
end

def test_persist_roundtrip()
  harness.reset()
  var c = sl.TLConfig()
  c.team_configs = [{'teamSlug': 'nyy', 'selectedColor': '#002d72'}]
  c.light_restore_mins = 90
  c.turn_on_light = false
  c.animation_type = 'comet'
  c.saved_light = sl.TLSavedLight.from_light({'rgb': 'ff0000', 'hue': 0, 'sat': 255, 'bri': 200, 'power': true}, 1234)
  sl.persist_conf(c)

  var c2 = sl.persist_read_conf()
  expect("rt team_configs size", size(c2.team_configs), 1)
  expect("rt team_configs slug", c2.team_configs[0]['teamSlug'], 'nyy')
  expect("rt light_restore_mins", c2.light_restore_mins, 90)
  expect("rt turn_on_light", c2.turn_on_light, false)
  expect("rt animation_type", c2.animation_type, 'comet')
  expect_true("rt saved_light", c2.saved_light != nil)
  expect("rt saved_light rgb", c2.saved_light.rgb, 'ff0000')
  expect("rt saved_light end_time", c2.saved_light.end_time, 1234)
end

def test_persist_saved_light_only_updates_saved_light()
  harness.reset()
  var c = sl.TLConfig()
  c.light_restore_mins = 120
  c.turn_on_light = false
  c.animation_type = 'comet'
  sl.persist_conf(c)

  # Now update only saved_light — other keys must be untouched
  var sl_obj = sl.TLSavedLight.from_light({'rgb': '00ff00', 'hue': 120, 'sat': 255, 'bri': 100, 'power': true}, 9999)
  sl.persist_saved_light(sl_obj)

  var c2 = sl.persist_read_conf()
  expect("light_restore_mins unchanged", c2.light_restore_mins, 120)
  expect("turn_on_light unchanged", c2.turn_on_light, false)
  expect("animation_type unchanged", c2.animation_type, 'comet')
  expect_true("saved_light updated", c2.saved_light != nil)
  expect("saved_light rgb updated", c2.saved_light.rgb, '00ff00')
  expect("saved_light end_time updated", c2.saved_light.end_time, 9999)
end

def test_persist_saved_light_nil_clears()
  harness.reset()
  var c = sl.TLConfig()
  c.light_restore_mins = 60
  c.saved_light = sl.TLSavedLight.from_light({'rgb': 'ff0000', 'hue': 0, 'sat': 255, 'bri': 200, 'power': true}, 1234)
  sl.persist_conf(c)

  sl.persist_saved_light(nil)

  var c2 = sl.persist_read_conf()
  expect("light_restore_mins unchanged after nil save", c2.light_restore_mins, 60)
  expect_nil("saved_light cleared", c2.saved_light)
end

# ── Run ────────────────────────────────────────────────────
def run_all()
  test_scoreboard_event()
  test_scoreboard_event_in_progress_winning()
  test_scoreboard_event_tied_not_winning()
  test_scoreboard_event_final_lost()
  test_scoreboard_event_scheduled()
  test_slconfig_defaults()
  test_slsavedlight_from_light()
  test_slsavedlight_to_map_roundtrip()
  test_slsavedlight_from_nil()
  test_slrunstate_clear()
  test_persist_defaults()
  test_persist_roundtrip()
  test_persist_saved_light_only_updates_saved_light()
  test_persist_saved_light_nil_clears()

  print(format("test_data: %d passed, %d failed", passed, failed))
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
