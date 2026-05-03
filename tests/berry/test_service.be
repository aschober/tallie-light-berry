# TallieLightService tests
#
#   These tests cover the core logic of TallieLightService, including event
#   processing, mode selection, and pinning behavior. They use the harness to
#   verify MQTT interactions and timers, but they don't rely on any UI or
#   OAuth behavior (so they don't use the harness's stubs for those services).

import global
import harness
import json
import tallielight as sl

var passed = 0
var failed = 0
var failures = []
var current_test = ''

def expect(label, actual, expected)
  if actual == expected
    passed += 1
  else
    failed += 1
    failures.push(format("[%s] %s: expected %s, got %s", current_test, label, str(expected), str(actual)))
  end
end

def expect_true(label, cond) expect(label, cond, true) end
def expect_nil(label, val) expect(label, val == nil, true) end
def expect_not_nil(label, val) expect(label, val != nil, true) end

# ── Helpers ──────────────────────────────────────────────
def make_event(slug, abbr, state_str, score, opp_score, winner, last_updated)
  var winner_field = ''
  if winner != nil
    winner_field = format(',"winner":%s', winner ? 'true' : 'false')
  end
  var json_str = format(
    '{"competitor":{"abbreviation":"%s","slug":"%s","score":"%s"%s,"homeAway":"home"},'
    '"opponent":{"abbreviation":"OPP","score":"%s"},'
    '"competition":{"date":"2025-04-25T19:00Z","leagueShortDisplayName":"MLB",'
    '"status":{"type":{"shortDetail":"X","state":"%s"}}},'
    '"lastUpdated":%d}',
    abbr, slug, score, winner_field, opp_score, state_str, last_updated)
  return json_str
end

# Build a service with a simple two-team config
def make_service(turn_on_light)
  if turn_on_light == nil turn_on_light = true end
  harness.reset()
  harness.enqueue_topics_response(['sports-lamp/nyy', 'sports-lamp/bos'], nil, nil)
  var c = sl.TLConfig()
  c.team_configs = [
    {'teamSlug': 'nyy', 'selectedColor': '#002d72'},
    {'teamSlug': 'bos', 'selectedColor': '#bd3039'},
  ]
  c.turn_on_light = turn_on_light
  c.light_restore_mins = 60
  return sl.TallieLightService(c)
end

# Deliver an event JSON through the MQTT pathway
def deliver(svc, slug, abbr, state_str, score, opp_score, winner, last_updated)
  svc.mqtt._deliver(slug, make_event(slug, abbr, state_str, score, opp_score, winner, last_updated))
end

# Drain the 750ms light_change_rules_delay timer (fires HSB/Power rules)
def settle_change_detection()
  if harness.has_timer('light_change_rules_delay')
    harness.fire_timer('light_change_rules_delay')
  end
end

# ── 1: No events ─────────────────────────────────────────
def test_01_no_events()
  current_test = 'T1'
  var svc = make_service(true)
  expect("mode IDLE", svc.state.mode, sl.TL_IDLE)
  expect("no active event", svc.state.active_event, nil)
end

# ── 2: Scheduled-only event ──────────────────────────────
def test_02_scheduled_only()
  current_test = 'T2'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'pre', '0', '0', nil, 1700000000)
  expect("mode stays IDLE on pre", svc.state.mode, sl.TL_IDLE)
  expect_nil("no active event", svc.state.active_event)
end

# ── 3: In-progress losing ────────────────────────────────
def test_03_losing()
  current_test = 'T3'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '1', '3', nil, 1700000000)
  expect("mode IDLE", svc.state.mode, sl.TL_IDLE)
end

# ── 4: In-progress tied ──────────────────────────────────
def test_04_tied()
  current_test = 'T4'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '2', '2', nil, 1700000000)
  expect("mode IDLE (tied)", svc.state.mode, sl.TL_IDLE)
end

# ── 5: Final lost ────────────────────────────────────────
def test_05_final_lost()
  current_test = 'T5'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'post', '1', '5', false, 1700000000)
  expect("mode IDLE (lost)", svc.state.mode, sl.TL_IDLE)
end

# ── 6: Event timed out ──────────────────────────────────
def test_06_timeout_filter()
  current_test = 'T6'
  var svc = make_service(true)
  # Event is winning but its last_updated + 60min < now
  harness.set_clock(1700000000 + 60 * 60 + 100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("mode IDLE (timed out)", svc.state.mode, sl.TL_IDLE)
end

# ── 7: Single in-progress winner ─────────────────────────
def test_07_single_inprogress_winner()
  current_test = 'T7'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("mode ANIM", svc.state.mode, sl.TL_ANIM)
  expect("active slug", svc.state.active_event.competitor_slug, 'nyy')
  expect_true("Color2 sent", harness.cmd_sent("Color2 002d72"))
  expect_not_nil("animation set", svc.state.animation)
end

# ── 8: Single final winner ───────────────────────────────
def test_08_single_final_winner()
  current_test = 'T8'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'post', '5', '3', true, 1700000000)
  expect("mode SOLID", svc.state.mode, sl.TL_SOLID)
  expect_true("Color2 sent", harness.cmd_sent("Color2 002d72"))
  expect_nil("no animation", svc.state.animation)
end

# ── 9: Two live winners — config order (NYY pos 0 wins over BOS pos 1) ──
def test_09_live_priority_config_order()
  current_test = 'T9'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  expect("BOS active first", svc.state.active_event.competitor_slug, 'bos')
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("NYY now active (lower index)", svc.state.active_event.competitor_slug, 'nyy')
end

# ── 10: Live beats final ─────────────────────────────────
def test_10_live_beats_final()
  current_test = 'T10'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'post', '5', '3', true, 1700000000)
  expect("NYY final active", svc.state.active_event.competitor_slug, 'nyy')
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  expect("BOS live takes over", svc.state.active_event.competitor_slug, 'bos')
  expect("now TL_ANIM", svc.state.mode, sl.TL_ANIM)
end

# ── 11: Final-only winners ranked by config order ────────
def test_11_final_priority_config_order()
  current_test = 'T11'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'bos', 'BOS', 'post', '5', '3', true, 1700000000)
  deliver(svc, 'nyy', 'NYY', 'post', '5', '3', true, 1700000000)
  expect("NYY (lower idx) wins", svc.state.active_event.competitor_slug, 'nyy')
end

# ── 12: Pinned beats higher-priority auto winner ────────
def test_12_pinned_overrides_priority()
  current_test = 'T12'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  # NYY (idx 0) is winning; pin BOS (idx 1)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  svc.activate_team_light('bos')
  expect("BOS pinned active", svc.state.active_event.competitor_slug, 'bos')
  expect("pin recorded", svc.state.pinned_slug, 'bos')
end

# ── 13: Pinned bypasses timeout filter ───────────────────
def test_13_pinned_bypasses_timeout()
  current_test = 'T13'
  var svc = make_service(true)
  # Old event but still winning
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  svc.activate_team_light('nyy')
  expect("NYY pinned and active", svc.state.active_event.competitor_slug, 'nyy')
  # Now advance clock past restore_mins
  harness.set_clock(1700000000 + 60 * 60 + 100)
  # Trigger re-selection by delivering another (non-winning) event
  deliver(svc, 'bos', 'BOS', 'in', '0', '5', nil, 1700000000 + 60 * 60 + 100)
  expect("NYY still pinned despite timeout", svc.state.active_event.competitor_slug, 'nyy')
end

# ── 14: Pinned team stops winning → fallthrough ─────────
def test_14_pinned_stops_winning()
  current_test = 'T14'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  svc.activate_team_light('nyy')
  expect("NYY pinned", svc.state.pinned_slug, 'nyy')
  # NYY now losing; BOS now winning
  deliver(svc, 'nyy', 'NYY', 'in', '1', '5', nil, 1700000050)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000050)
  expect("pin cleared", svc.state.pinned_slug, nil)
  expect("BOS now active", svc.state.active_event.competitor_slug, 'bos')
end

# ── 15: Pinned slug has no event ─────────────────────────
def test_15_pinned_no_event()
  current_test = 'T15'
  var svc = make_service(true)
  # Manually set a pin without delivering events; then trigger select via a non-winning delivery
  svc.state.pinned_slug = 'nyy'
  harness.set_clock(1700000100)
  deliver(svc, 'bos', 'BOS', 'in', '0', '5', nil, 1700000000)
  expect("pin cleared (no event)", svc.state.pinned_slug, nil)
  expect("mode IDLE", svc.state.mode, sl.TL_IDLE)
end

# ── 16: Pin set while another active → transition ───────
def test_16_pin_during_active()
  current_test = 'T16'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("NYY active first", svc.state.active_event.competitor_slug, 'nyy')
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  # NYY is still preferred (idx 0). Pin BOS
  svc.activate_team_light('bos')
  expect("BOS now active and pinned", svc.state.active_event.competitor_slug, 'bos')
end

# ── 16b: Re-pin to different team — HSB rule must not fire ───
def test_16b_repin_no_spurious_hsb()
  # Bug: switching pin from one active team to another triggered the HSB
  # change-detection rule (from the previous team), which incorrectly
  # interpreted the new team color as a manual user override → TL_IDLE.
  current_test = 'T16b'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  svc.activate_team_light('nyy')
  settle_change_detection()
  expect("NYY pinned and ANIM", svc.state.mode, sl.TL_ANIM)
  # Pin BOS (different color) — should switch to BOS without going through TL_IDLE
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  svc.activate_team_light('bos')
  expect("BOS now active", svc.state.active_event.competitor_slug, 'bos')
  expect("mode is ANIM not IDLE", svc.state.mode, sl.TL_ANIM)
end

# ── 16c: Unpin secondary pin — HSB rule must not fire ────
def test_16c_unpin_secondary_no_spurious_hsb()
  # Bug: unpinning a secondary team (different color from auto-winner) triggered
  # the HSB rule from the pinned team, clearing saved light and going TL_IDLE
  # before the unpin mute path completed.
  current_test = 'T16c'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  # NYY is auto-winner (idx 0), BOS is secondary
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  svc.activate_team_light('bos')
  settle_change_detection()
  expect("BOS pinned and ANIM", svc.state.mode, sl.TL_ANIM)
  expect("saved_light exists", svc.config.saved_light != nil, true)
  # Unpin — should go to TL_MUTED with NYY, color staged via light.set() (power off)
  svc.activate_team_light(nil)
  expect("mode is MUTED not IDLE", svc.state.mode, sl.TL_MUTED)
  expect("NYY is now active", svc.state.active_event.competitor_slug, 'nyy')
  expect("saved_light preserved", svc.config.saved_light != nil, true)
  expect("light power off after unpin", global.light._state['power'], false)
end

# ── 17: Unpin while pinned active ────────────────────────
def test_17_unpin_with_winner_still_active()
  # Unpin while event still active — enters TL_MUTED (staged, waiting for power-on).
  current_test = 'T17'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  svc.activate_team_light('bos')
  expect("BOS pinned", svc.state.pinned_slug, 'bos')
  svc.activate_team_light(nil)
  expect("pin cleared", svc.state.pinned_slug, nil)
  expect("mode TL_MUTED", svc.state.mode, sl.TL_MUTED)
  expect("BOS still active event", svc.state.active_event.competitor_slug, 'bos')
  # color staged via light.set() — light is off, BOS color is staged
  expect("light power off after unpin", global.light._state['power'], false)
  expect("BOS color staged", global.light._state['rgb'], 'bd3039')
end

def test_17c_unpin_muted_then_power_on_reactivates()
  # After pinning a secondary team then unpinning, power-on must animate with
  # the auto-winner's color. The unpin path stages the color via light.set() so
  # light.get()['rgb'] is already correct when set_animation runs on power-on.
  current_test = 'T17c'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  # NYY is auto-winner (lower index), BOS is pinned secondary
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)  # NYY winning → TL_ANIM
  deliver(svc, 'bos', 'BOS', 'post', '10', '5', true, 1700000000)  # BOS final winner
  svc.activate_team_light('bos')  # pin BOS → TL_SOLID (different color)
  svc.activate_team_light(nil)    # unpin → NYY still active → TL_MUTED
  settle_change_detection()
  expect("TL_MUTED before power-on", svc.state.mode, sl.TL_MUTED)
  expect("NYY color staged", svc.state.team_color_rgb, '002d72')  # NYY selectedColor
  harness.fire_rule("Power1#State", 1, nil)  # user powers light on
  settle_change_detection()
  expect("mode TL_ANIM after power-on", svc.state.mode, sl.TL_ANIM)
  expect("NYY active", svc.state.active_event.competitor_slug, 'nyy')
end

def test_17b_unpin_restores_when_no_winners()
  # Unpin while event no longer active — restores saved light and goes IDLE.
  current_test = 'T17b'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  svc.activate_team_light('bos')
  deliver(svc, 'bos', 'BOS', 'in', '1', '5', nil, 1700000050)  # BOS now losing
  svc.activate_team_light(nil)
  expect("pin cleared", svc.state.pinned_slug, nil)
  expect("mode IDLE", svc.state.mode, sl.TL_IDLE)
  expect("no active event", svc.state.active_event, nil)
end

def test_17d_activate_then_mute()
  # □→■→▣: activate a team then mute via UI — pin preserved, color staged, light off.
  current_test = 'T17d'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  svc.activate_team_light('bos')          # □→■
  settle_change_detection()
  expect("TL_ANIM after pin", svc.state.mode, sl.TL_ANIM)
  svc.mute_team_light()                   # ■→▣
  expect("TL_MUTED after mute", svc.state.mode, sl.TL_MUTED)
  expect("pin preserved", svc.state.pinned_slug, 'bos')
  expect("active event preserved", svc.state.active_event.competitor_slug, 'bos')
  expect("light off", global.light._state['power'], false)
  expect("BOS color staged", global.light._state['rgb'], 'bd3039')
  expect("saved_light.power false after mute", svc.config.saved_light.power, false)
end

def test_17e_mute_unpinned_auto_winner()
  # ■→▣ on an unpinned auto-selected event — mute_team_light works without a pin.
  current_test = 'T17e'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)  # auto-selected, no pin
  expect("TL_ANIM no pin", svc.state.mode, sl.TL_ANIM)
  expect("no pin", svc.state.pinned_slug, nil)
  settle_change_detection()
  svc.mute_team_light()                   # ■→▣
  expect("TL_MUTED", svc.state.mode, sl.TL_MUTED)
  expect("still no pin", svc.state.pinned_slug, nil)
  expect("BOS still active", svc.state.active_event.competitor_slug, 'bos')
  expect("light off", global.light._state['power'], false)
  expect("saved_light.power false after mute", svc.config.saved_light.power, false)
end

def test_17f_unpin_while_muted_restores()
  # ▣→□: activate_team_light(nil) while muted restores light and goes IDLE.
  current_test = 'T17f'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  svc.activate_team_light('bos')          # □→■
  svc.mute_team_light()                   # ■→▣
  expect("TL_MUTED", svc.state.mode, sl.TL_MUTED)
  svc.activate_team_light(nil)            # ▣→□
  expect("TL_IDLE", svc.state.mode, sl.TL_IDLE)
  expect("pin cleared", svc.state.pinned_slug, nil)
  expect("no active event", svc.state.active_event, nil)
end

def test_17g_power_off_muted_then_unpin_restores()
  # ▣→□ when TL_MUTED was entered via power-off (not mute_team_light).
  current_test = 'T17g'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  settle_change_detection()
  global.light._state['power'] = false
  harness.fire_rule("Power1#State", 0, nil)   # power-off → TL_MUTED
  expect("TL_MUTED via power-off", svc.state.mode, sl.TL_MUTED)
  svc.activate_team_light(nil)                # ▣→□
  expect("TL_IDLE", svc.state.mode, sl.TL_IDLE)
  expect("no active event", svc.state.active_event, nil)
end

# ── 18: Power off during TL_ANIM → TL_MUTED ──────────────
def test_18_power_off_during_anim()
  current_test = 'T18'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("TL_ANIM", svc.state.mode, sl.TL_ANIM)
  settle_change_detection()
  # User turns light off
  global.light._state['power'] = false
  harness.fire_rule("Power1#State", 0, nil)
  expect("TL_MUTED", svc.state.mode, sl.TL_MUTED)
  expect_not_nil("event preserved", svc.state.active_event)
  expect("saved_light.power false after power-off", svc.config.saved_light.power, false)
end

# ── 19: Power off during TL_SOLID → TL_MUTED ─────────────
def test_19_power_off_during_solid()
  current_test = 'T19'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'post', '5', '3', true, 1700000000)
  expect("TL_SOLID", svc.state.mode, sl.TL_SOLID)
  settle_change_detection()
  global.light._state['power'] = false
  harness.fire_rule("Power1#State", 0, nil)
  expect("TL_MUTED", svc.state.mode, sl.TL_MUTED)
  expect("saved_light.power false after power-off", svc.config.saved_light.power, false)
end

# ── 20: New in-progress event with light off + turn_on_light=false → TL_MUTED ──
def test_20_inprogress_light_off_no_auto_on()
  current_test = 'T20'
  var svc = make_service(false)
  global.light._state['power'] = false
  global._setoption20 = true
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("TL_MUTED", svc.state.mode, sl.TL_MUTED)
  expect("NYY color staged via light.set", global.light._state['rgb'], '002d72')
  expect("light still off", global.light._state['power'], false)
  expect("saved_light.power false (light was already off)", svc.config.saved_light.power, false)
end

# ── 21: New final event with light off + turn_on_light=false → TL_MUTED ──
def test_21_final_light_off_no_auto_on()
  current_test = 'T21'
  var svc = make_service(false)
  global.light._state['power'] = false
  global._setoption20 = true
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'post', '5', '3', true, 1700000000)
  expect("TL_MUTED (final)", svc.state.mode, sl.TL_MUTED)
  expect("NYY color staged via light.set", global.light._state['rgb'], '002d72')
  expect("light still off", global.light._state['power'], false)
  expect("saved_light.power false (light was already off)", svc.config.saved_light.power, false)
end

# ── 22: Power on while muted (in-progress) → TL_ANIM ─────
def test_22_power_on_muted_inprogress()
  current_test = 'T22'
  var svc = make_service(false)
  global.light._state['power'] = false
  global._setoption20 = true
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("TL_MUTED", svc.state.mode, sl.TL_MUTED)
  settle_change_detection()  # register light_change_rules via deferred timer
  # User powers on
  global.light._state['power'] = true
  harness.fire_rule("Power1#State", 1, nil)
  expect("TL_ANIM", svc.state.mode, sl.TL_ANIM)
end

# ── 22b: Power on while muted updates saved_light.power → true ───
def test_22b_power_on_muted_updates_saved_light()
  # Entering TL_MUTED sets saved_light.power=false. When user manually powers on,
  # saved_light.power must be updated to true so a future timeout restores light on.
  current_test = 'T22b'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  settle_change_detection()
  global.light._state['power'] = false
  harness.fire_rule("Power1#State", 0, nil)
  expect("TL_MUTED", svc.state.mode, sl.TL_MUTED)
  expect("saved_light.power false after power-off", svc.config.saved_light.power, false)
  # User manually powers light back on
  global.light._state['power'] = true
  harness.fire_rule("Power1#State", 1, nil)
  expect("TL_ANIM after power-on", svc.state.mode, sl.TL_ANIM)
  expect("saved_light.power true after power-on", svc.config.saved_light.power, true)
end

# ── 23: Power on while muted (final) → TL_SOLID ─────────
def test_23_power_on_muted_final()
  current_test = 'T23'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'post', '5', '3', true, 1700000000)
  settle_change_detection()
  # Power off → muted
  global.light._state['power'] = false
  harness.fire_rule("Power1#State", 0, nil)
  expect("muted", svc.state.mode, sl.TL_MUTED)
  # Power on → re-activate
  global.light._state['power'] = true
  harness.fire_rule("Power1#State", 1, nil)
  expect("TL_SOLID", svc.state.mode, sl.TL_SOLID)
end

# ── 24: Manual pin overrides muted ───────────────────────
def test_24_pin_overrides_muted()
  current_test = 'T24'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  settle_change_detection()
  global.light._state['power'] = false
  harness.fire_rule("Power1#State", 0, nil)
  expect("muted", svc.state.mode, sl.TL_MUTED)
  # User pins BOS (also winning)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000000)
  global.light._state['power'] = true  # simulate pin power-on
  svc.activate_team_light('bos')
  expect("TL_ANIM with BOS", svc.state.mode, sl.TL_ANIM)
  expect("BOS active", svc.state.active_event.competitor_slug, 'bos')
end

# ── 25: Event timeout while muted → TL_IDLE ──────────────
def test_25_timeout_while_muted()
  current_test = 'T25'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  settle_change_detection()
  global.light._state['power'] = false
  harness.fire_rule("Power1#State", 0, nil)
  expect("muted", svc.state.mode, sl.TL_MUTED)
  # Advance clock and fire the timeout
  harness.set_clock(1700000000 + 60 * 60 + 100)
  # Update event so it's now timed out
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)  # same lastUpdated
  # Fire the timeout timer
  harness.fire_timer("handle_event_timeout")
  expect("TL_IDLE after timeout", svc.state.mode, sl.TL_IDLE)
end

# ── 26: New MQTT update while muted → stays muted, restages color ──
def test_26_update_while_muted()
  current_test = 'T26'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  settle_change_detection()
  global.light._state['power'] = false
  harness.fire_rule("Power1#State", 0, nil)
  expect("muted with NYY", svc.state.active_event.competitor_slug, 'nyy')
  global.tasmota._cmds = []
  # NYY gets a newer update — active_event should update, light unchanged
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000050)
  expect("still muted", svc.state.mode, sl.TL_MUTED)
  expect("active_event updated", svc.state.active_event.last_updated, 1700000050)
  expect("no light commands sent", size(harness.cmds()), 0)
end

# ── 27: Duplicate event (same slug+timestamp) ───────────
def test_27_duplicate_event()
  current_test = 'T27'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  var color2_count_before = 0
  for c : harness.cmds() if c == "Color2 002d72" color2_count_before += 1 end end
  # Re-deliver identical event
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  var color2_count_after = 0
  for c : harness.cmds() if c == "Color2 002d72" color2_count_after += 1 end end
  expect("no second Color2 sent", color2_count_after, color2_count_before)
end

# ── 28: Same team, newer timestamp ──────────────────────
def test_28_newer_timestamp()
  current_test = 'T28'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("TL_ANIM", svc.state.mode, sl.TL_ANIM)
  # Same team, newer timestamp, same status — should refresh timer but not change light
  deliver(svc, 'nyy', 'NYY', 'in', '6', '1', nil, 1700000050)
  expect("still TL_ANIM", svc.state.mode, sl.TL_ANIM)
  expect("active event timestamp updated", svc.state.active_event.last_updated, 1700000050)
end

# ── 29: In-progress → final transition ───────────────────
def test_29_inprogress_to_final()
  current_test = 'T29'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("TL_ANIM first", svc.state.mode, sl.TL_ANIM)
  expect_not_nil("animation active", svc.state.animation)
  deliver(svc, 'nyy', 'NYY', 'post', '5', '3', true, 1700000050)
  expect("TL_SOLID after final", svc.state.mode, sl.TL_SOLID)
  expect_nil("animation cleared", svc.state.animation)
end

# ── 30: User changes hue manually → TL_IDLE ─────────────
def test_30_hue_change()
  current_test = 'T30'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'post', '5', '3', true, 1700000000)
  settle_change_detection()
  # Capture team color hue/sat as recorded; simulate big hue shift
  var team_hue = int(svc.state.team_color_map['hue'])
  var new_hue = (team_hue + 100) % 360
  harness.fire_rule("HSBColor", format("%d,50,80", new_hue), nil)
  expect("TL_IDLE after hue change", svc.state.mode, sl.TL_IDLE)
  expect("saved_light cleared", svc.config.saved_light, nil)
end

# ── 31: User changes saturation manually → TL_IDLE ──────
def test_31_sat_change()
  current_test = 'T31'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  settle_change_detection()
  # Send same hue with sat=10 (very different)
  var team_hue = int(svc.state.team_color_map['hue'])
  harness.fire_rule("HSBColor", format("%d,10,80", team_hue), nil)
  expect("TL_IDLE after sat change", svc.state.mode, sl.TL_IDLE)
end

# ── 32: Brightness-only change in TL_ANIM ────────────────
def test_32_bri_only_anim()
  current_test = 'T32'
  harness.reset()
  harness.enqueue_topics_response(['sports-lamp/nyy', 'sports-lamp/bos'], nil, nil)
  var c = sl.TLConfig()
  c.team_configs = [{'teamSlug': 'nyy', 'selectedColor': '#002d72'}, {'teamSlug': 'bos', 'selectedColor': '#bd3039'}]
  c.turn_on_light = true
  c.light_restore_mins = 60
  c.animation_type = 'breathe'
  var svc = sl.TallieLightService(c)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  settle_change_detection()
  var team_hue = int(svc.state.team_color_map['hue'])
  var team_sat = int(svc.state.team_color_map['sat'])
  var team_sat_100 = int((team_sat * 100) / 255)
  # Change only brightness
  harness.fire_rule("HSBColor", format("%d,%d,30", team_hue, team_sat_100), nil)
  expect("still TL_ANIM", svc.state.mode, sl.TL_ANIM)
  # bri 30/100 → 76/255; max_brightness = 76 + 32 = 108
  expect("anim max_brightness updated", svc.state.animation.max_brightness, 108)
end

# ── 33: Brightness-only change in TL_SOLID ───────────────
def test_33_bri_only_solid()
  current_test = 'T33'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'post', '5', '3', true, 1700000000)
  settle_change_detection()
  var team_hue = int(svc.state.team_color_map['hue'])
  var team_sat = int(svc.state.team_color_map['sat'])
  var team_sat_100 = int((team_sat * 100) / 255)
  harness.fire_rule("HSBColor", format("%d,%d,40", team_hue, team_sat_100), nil)
  expect("still TL_SOLID", svc.state.mode, sl.TL_SOLID)
  # bri 40/100 → 102/255
  expect("saved_light bri updated", svc.config.saved_light.bri, 102)
end

# ── 34: Timeout, other team still winning → switch ───────
def test_34_timeout_switches_team()
  current_test = 'T34'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  # NYY winning final
  deliver(svc, 'nyy', 'NYY', 'post', '5', '3', true, 1700000000)
  expect("TL_SOLID with NYY", svc.state.active_event.competitor_slug, 'nyy')
  # BOS now winning live (newer event)
  deliver(svc, 'bos', 'BOS', 'in', '5', '1', nil, 1700000100)
  # BOS (live) takes over from NYY (final)
  expect("BOS now active", svc.state.active_event.competitor_slug, 'bos')
  expect("TL_ANIM", svc.state.mode, sl.TL_ANIM)
end

# ── 35: Timeout, no winners remaining → TL_IDLE ──────────
def test_35_timeout_no_winners()
  current_test = 'T35'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  # Save snapshot first (light has a state)
  global.light._state = {'rgb': 'aabbcc', 'hue': 100, 'sat': 200, 'bri': 200, 'power': true}
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("TL_ANIM", svc.state.mode, sl.TL_ANIM)
  expect_not_nil("saved_light created", svc.config.saved_light)
  # Advance time beyond the event's timeout window
  harness.set_clock(1700000000 + 60 * 60 + 100)
  # Re-deliver same (now-timed-out) event to trigger re-selection
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  # Hmm — duplicate event check would skip. Let's fire the timer instead.
  harness.fire_timer("handle_event_timeout")
  expect("TL_IDLE", svc.state.mode, sl.TL_IDLE)
  expect_nil("saved_light cleared", svc.config.saved_light)
end

# ── 36: save_light_state first call saves state ──────────────
def test_36_save_light_state_first_call()
  current_test = 'T36'
  var svc = make_service(true)
  global.light._state = {'rgb': '112233', 'hue': 100, 'sat': 200, 'bri': 150, 'power': true}
  svc.save_light_state(12345)
  expect_not_nil("saved_light created", svc.config.saved_light)
  expect("saved rgb", svc.config.saved_light.rgb, "112233")
  expect("saved end_time", svc.config.saved_light.end_time, 12345)
  import persist
  expect("persisted once", persist._save_count, 1)
end

# ── 37: save_light_state idempotent on same end_time ─────────
def test_37_save_light_state_idempotent_same_endtime()
  current_test = 'T37'
  var svc = make_service(true)
  global.light._state = {'rgb': 'aabbcc', 'hue': 0, 'sat': 0, 'bri': 0, 'power': true}
  svc.save_light_state(9000)
  import persist
  var first = persist._save_count
  svc.save_light_state(9000)
  expect("no extra persist on same end_time", persist._save_count, first)
end

# ── 38: save_light_state updates end_time if different ─────────
def test_38_save_light_state_updates_endtime()
  current_test = 'T38'
  var svc = make_service(true)
  global.light._state = {'rgb': 'aabbcc', 'hue': 0, 'sat': 0, 'bri': 0, 'power': true}
  svc.save_light_state(9000)
  svc.save_light_state(9999)
  expect("end_time updated", svc.config.saved_light.end_time, 9999)
end

# ── 39: restore light with power on → Color2 + Dimmer cmds ─────────
def test_39_restore_light_power_on()
  current_test = 'T39'
  var svc = make_service(true)
  svc.config.saved_light = sl.TLSavedLight.from_light({'rgb': '00ff00', 'hue': 120, 'sat': 255, 'bri': 200, 'power': true}, 0)
  svc.lc.restore_light(svc.config.saved_light)
  svc._teardown_active_event()
  expect_true("Color2 cmd sent", harness.cmd_sent("Color2 00ff00"))
  expect_true("Dimmer cmd sent", harness.cmd_sent("Dimmer "))
  expect("saved_light cleared", svc.config.saved_light, nil)
end

# ── 40: restore light with power off → direct state set ─────────
def test_40_restore_light_power_off_uses_lightset()
  current_test = 'T40'
  var svc = make_service(true)
  svc.config.saved_light = sl.TLSavedLight.from_light({'rgb': '0000ff', 'hue': 240, 'sat': 255, 'bri': 100, 'power': false}, 0)
  global.light._state = {'rgb': 'ffffff', 'hue': 0, 'sat': 0, 'bri': 255, 'power': true}
  svc.lc.restore_light(svc.config.saved_light)
  svc._teardown_active_event()
  expect("hue restored", global.light._state['hue'], 240)
  expect("sat restored", global.light._state['sat'], 255)
  expect("bri restored", global.light._state['bri'], 100)
  expect("power restored to off", global.light._state['power'], false)
  expect("saved_light cleared", svc.config.saved_light, nil)
end

# ── 41: restore light with no saved_light → no cmd ─────────
def test_41_restore_light_no_saved_light()
  current_test = 'T41'
  var svc = make_service(true)
  svc._teardown_active_event()
  expect("no Backlog cmd", harness.cmd_sent("Backlog"), false)
end

# ── 42: Save snapshot idempotent on same end_time ───────
def test_42_save_idempotent()
  current_test = 'T42'
  var svc = make_service(true)
  harness.set_clock(1700000100)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  import persist
  var saves_before = persist._save_count
  # Re-deliver same event (same last_updated → same end_time)
  deliver(svc, 'nyy', 'NYY', 'in', '5', '1', nil, 1700000000)
  expect("no extra persist on duplicate", persist._save_count, saves_before)
end

# ── 43: OAuth updated → MQTT reconnect ──────────────────
def test_43_oauth_reconnect()
  current_test = 'T43'
  var svc = make_service(true)
  var first_creds = svc.mqtt._last_creds
  # Fire OAuth=UPDATED rule
  harness.enqueue_topics_response(['sports-lamp/nyy', 'sports-lamp/bos'], nil, nil)
  harness.fire_rule("OAuth=UPDATED", nil, nil)
  # The rule schedules a 0ms timer
  harness.fire_timer("oauth_updated")
  expect_not_nil("creds re-applied", svc.mqtt._last_creds)
  expect("connected", svc.mqtt.connected(), true)
end

# ── 44: Boot with persisted saved_light ─────────────────
def test_44_boot_with_saved_light()
  current_test = 'T44'
  harness.reset()
  # Pre-populate persist
  import persist
  persist.sl_teams = [{'teamSlug': 'nyy', 'selectedColor': '#002d72'}]
  persist.sl_restore_mins = 60
  persist.sl_turn_on = true
  persist.sl_anim_type = 'breathe'
  persist.sl_saved_light = {'rgb': 'aabbcc', 'hue': 50, 'sat': 100, 'bri': 200, 'power': true, 'end_time': 1234}
  # Boot
  harness.enqueue_topics_response(['sports-lamp/nyy'], nil, nil)
  sl.TallieLightService.run_from_conf()
  expect_not_nil("service started", global._tallielight)
  expect("mode IDLE", global._tallielight.state.mode, sl.TL_IDLE)
  expect_not_nil("saved_light loaded", global._tallielight.config.saved_light)
  expect("saved rgb loaded", global._tallielight.config.saved_light.rgb, 'aabbcc')
end

# ── Run all ──────────────────────────────────────────────
def run_all()
  test_01_no_events()
  test_02_scheduled_only()
  test_03_losing()
  test_04_tied()
  test_05_final_lost()
  test_06_timeout_filter()
  test_07_single_inprogress_winner()
  test_08_single_final_winner()
  test_09_live_priority_config_order()
  test_10_live_beats_final()
  test_11_final_priority_config_order()
  test_12_pinned_overrides_priority()
  test_13_pinned_bypasses_timeout()
  test_14_pinned_stops_winning()
  test_15_pinned_no_event()
  test_16_pin_during_active()
  test_16b_repin_no_spurious_hsb()
  test_16c_unpin_secondary_no_spurious_hsb()
  test_17_unpin_with_winner_still_active()
  test_17c_unpin_muted_then_power_on_reactivates()
  test_17d_activate_then_mute()
  test_17e_mute_unpinned_auto_winner()
  test_17f_unpin_while_muted_restores()
  test_17g_power_off_muted_then_unpin_restores()
  test_17b_unpin_restores_when_no_winners()
  test_18_power_off_during_anim()
  test_19_power_off_during_solid()
  test_20_inprogress_light_off_no_auto_on()
  test_21_final_light_off_no_auto_on()
  test_22_power_on_muted_inprogress()
  test_22b_power_on_muted_updates_saved_light()
  test_23_power_on_muted_final()
  test_24_pin_overrides_muted()
  test_25_timeout_while_muted()
  test_26_update_while_muted()
  test_27_duplicate_event()
  test_28_newer_timestamp()
  test_29_inprogress_to_final()
  test_30_hue_change()
  test_31_sat_change()
  test_32_bri_only_anim()
  test_33_bri_only_solid()
  test_34_timeout_switches_team()
  test_35_timeout_no_winners()
  test_36_save_light_state_first_call()
  test_37_save_light_state_idempotent_same_endtime()
  test_38_save_light_state_updates_endtime()
  test_39_restore_light_power_on()
  test_40_restore_light_power_off_uses_lightset()
  test_41_restore_light_no_saved_light()
  test_42_save_idempotent()
  test_43_oauth_reconnect()
  test_44_boot_with_saved_light()

  print(format("Batch 3: %d passed, %d failed", passed, failed))
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
