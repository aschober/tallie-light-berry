# LightController tests
#
#   These tests cover the LightController's core logic for handling light state,
#   animations, and timers/rules. They use the harness to verify commands sent
#   to the light and timers/rules registered with tasmota, but they don't rely
#   on any TallieLightService behavior (so they don't use the harness's
#   TallieLightService stub or its MQTT client stubs).

import global
import harness
import animation
import tallielight  # loads tl_*.be classes into global.*

var TLConfig           = global.TLConfig
var TLLightController  = global.TLLightController
var TallieLightService = global.TallieLightService

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

# Build a fresh LC and reset world.
def setup()
  harness.reset()
  return TLLightController()
end

# Build a minimal service for tests that need TallieLightService methods.
def setup_svc()
  harness.reset()
  var c = TLConfig()
  c.team_configs = [{'teamSlug': 'nyy', 'selectedColor': '#002d72'}]
  return TallieLightService(c)
end

# ── apply_set_option_20 ────────────────────────────────────
def test_setoption20_on()
  var lc = setup()
  lc.apply_set_option_20(true)
  expect("turn_on_light=true → SetOption20 0", harness.last_cmd(), "SetOption20 0")
end
def test_setoption20_off()
  var lc = setup()
  lc.apply_set_option_20(false)
  expect("turn_on_light=false → SetOption20 1", harness.last_cmd(), "SetOption20 1")
end


# ── set_solid ──────────────────────────────────────────────
def test_set_solid_sends_color2()
  var lc = setup()
  global.light._state['power'] = true
  var r = lc.set_solid('002d72', nil, false, false, true)
  expect_true("Color2 sent", harness.cmd_sent("Color2 002d72"))
  expect_true("changed=true", r['changed'])
end

def test_set_solid_skips_when_same_color_no_anim_clear()
  var lc = setup()
  var r = lc.set_solid('002d72', '002d72', false, false, true)
  expect("changed=false", r['changed'], false)
  expect("no Color2 cmd", harness.cmd_sent("Color2"), false)
end

def test_set_solid_resends_when_anim_was_cleared()
  var lc = setup()
  var r = lc.set_solid('002d72', '002d72', true, false, true)
  expect_true("changed=true after anim clear", r['changed'])
  expect_true("Color2 sent again", harness.cmd_sent("Color2 002d72"))
end

def test_set_solid_power_on_override_when_off_and_no_auto_on()
  var lc = setup()
  global.light._state = {'rgb': '000000', 'hue': 0, 'sat': 0, 'bri': 128, 'power': false}
  global._setoption20 = true   # so Color2 won't auto-turn-on
  var r = lc.set_solid('ff0000', nil, false, true, false)  # power_on_override=true, turn_on_light=false
  expect_true("Color2 sent", harness.cmd_sent("Color2 ff0000"))
  expect_true("Power ON sent", harness.cmd_sent("Power ON"))
end

def test_set_solid_no_power_on_when_already_on()
  var lc = setup()
  global.light._state['power'] = true
  var r = lc.set_solid('ff0000', nil, false, true, false)
  expect("no Power ON sent (already on)", harness.cmd_sent("Power ON"), false)
end

def test_set_solid_no_power_on_when_turn_on_light_true()
  var lc = setup()
  global.light._state = {'rgb': '000000', 'hue': 0, 'sat': 0, 'bri': 128, 'power': false}
  global._setoption20 = false   # turn_on_light=true means SetOption20=0
  var r = lc.set_solid('ff0000', nil, false, true, true)  # turn_on_light=true
  expect("no explicit Power ON (firmware auto-on)", harness.cmd_sent("Power ON"), false)
end

# ── set_animation ──────────────────────────────────────────
def test_set_animation_breathe()
  var lc = setup()
  var team_color_map = {'rgb': '002D72', 'hue': 220, 'sat': 255, 'bri': 100, 'power': true}
  var anim = lc.set_animation(team_color_map, 'breathe')
  expect_true("anim is breathe", isinstance(anim, animation.breathe))
  # Color = 0xFF002D72 → signed int representation
  expect("breathe color set", anim.color, number("0xFF002D72"))
  expect("breathe min_brightness", anim.min_brightness, 64)
  expect("breathe max_brightness", anim.max_brightness, 255)
  expect("breathe period", anim.period, 3000)
end

def test_set_animation_max_brightness_high_bri()
  var lc = setup()
  var anim = lc.set_animation({'rgb': '00FF00', 'hue': 120, 'sat': 255, 'bri': 250, 'power': true}, 'breathe')
  expect("max_brightness is 255", anim.max_brightness, 255)
  expect("min_brightness high bri", anim.min_brightness, 64)
end

def test_set_animation_comet()
  var lc = setup()
  var anim = lc.set_animation({'rgb': 'FF0000', 'hue': 0, 'sat': 255, 'bri': 200, 'power': true}, 'comet')
  expect_true("anim is comet", isinstance(anim, animation.comet))
  expect("comet tail_length", anim.tail_length, 3)
  expect("comet direction", anim.direction, -1)
  expect("comet speed", anim.speed, 3000)
end

def test_set_animation_crenel()
  var lc = setup()
  var anim = lc.set_animation({'rgb': 'FF0000', 'hue': 0, 'sat': 255, 'bri': 200, 'power': true}, 'crenel')
  expect_true("anim is crenel", isinstance(anim, animation.crenel))
  expect("crenel pulse_size", anim.pulse_size, 1)
  expect("crenel low_size", anim.low_size, 3)
end

def test_set_animation_engine_kept_alive()
  var lc = setup()
  var first_anim = lc.set_animation({'rgb': 'FF0000', 'hue': 0, 'sat': 255, 'bri': 200, 'power': true}, 'breathe')
  var first_engine = lc._anim_engine
  lc.clear_animation()
  var second_anim = lc.set_animation({'rgb': '00FF00', 'hue': 120, 'sat': 255, 'bri': 200, 'power': true}, 'breathe')
  expect_true("animation engine reused (not re-created)", lc._anim_engine == first_engine)
end

# ── clear_animation ────────────────────────────────────────
def test_clear_animation_when_running()
  var lc = setup()
  lc.set_animation({'rgb': 'FF0000', 'hue': 0, 'sat': 255, 'bri': 200, 'power': true}, 'breathe')
  expect("returns true when cleared", lc.clear_animation(), true)
  expect("engine stopped", lc._anim_engine.is_running, false)
end

def test_clear_animation_when_idle()
  var lc = setup()
  expect("returns false when nothing to clear", lc.clear_animation(), false)
end

def test_clear_animation_removes_power_on_rule()
  var lc = setup()
  lc.register_power_on_for_anim(def () end)
  expect_true("rule registered", harness.has_rule("Power1#State", "on_power_on_for_anim"))
  lc.clear_animation()
  expect("rule removed", harness.has_rule("Power1#State", "on_power_on_for_anim"), false)
end

# ── update_animation ──────────────────────────────────────
def test_update_breathe_brightness()
  var lc = setup()
  var anim = lc.set_animation({'rgb': 'FF0000', 'hue': 0, 'sat': 255, 'bri': 100, 'power': true}, 'breathe')
  lc.update_animation(anim, 'FF0000', 200)
  expect("min_brightness updated (200 >= 64)", anim.min_brightness, 64)
  expect("max_brightness updated", anim.max_brightness, 255)
end

def test_update_breathe_low_bri()
  var lc = setup()
  var anim = lc.set_animation({'rgb': 'FF0000', 'hue': 0, 'sat': 255, 'bri': 30, 'power': true}, 'breathe')
  lc.update_animation(anim, 'FF0000', 30)
  expect("min_brightness updated (30 < 64)", anim.min_brightness, 0)
  expect("max_brightness updated", anim.max_brightness, 255)
end

def test_update_breathe_ignores_non_breathe()
  var lc = setup()
  var anim = lc.set_animation({'rgb': 'FF0000', 'hue': 0, 'sat': 255, 'bri': 100, 'power': true}, 'comet')
  lc.update_animation(anim, '00FF00', 200)
  expect("comet tail_length untouched", anim.tail_length, 3)
  expect("comet color updated", anim.color, number("0xFF00FF00"))
end

# ── timers and rules ───────────────────────────────────────
def test_set_event_timer()
  var lc = setup()
  var fired = []
  lc.set_event_timer(60, def () fired.push(1) end)
  expect_true("timer registered", harness.has_timer("handle_event_timeout"))
  harness.fire_timer("handle_event_timeout")
  expect("callback fired", size(fired), 1)
end

def test_set_event_timer_replaces()
  var lc = setup()
  var fired = []
  lc.set_event_timer(60, def () fired.push(1) end)
  lc.set_event_timer(120, def () fired.push(2) end)
  harness.fire_timer("handle_event_timeout")
  expect("only second callback fires (first was replaced)", fired, [2])
end

def test_remove_event_timer()
  var lc = setup()
  lc.set_event_timer(60, def () end)
  lc.remove_event_timer()
  expect("timer removed", harness.has_timer("handle_event_timeout"), false)
end

def test_add_light_change_rules_uses_delay()
  var lc = setup()
  var hsb_fired = []
  lc.add_light_change_rules(
    def (v, t, p) hsb_fired.push(['h', v]) end,
    def (v, t, p) hsb_fired.push(['p', v]) end)
  # Rules NOT registered yet (waiting for 500ms timer)
  expect("hsb rule not yet registered", harness.has_rule("HSBColor", "on_hsb_change"), false)
  expect_true("delay timer registered", harness.has_timer("light_change_rules_delay"))
  harness.fire_timer("light_change_rules_delay")
  expect_true("hsb rule registered after timer", harness.has_rule("HSBColor", "on_hsb_change"))
  expect_true("power rule registered after timer", harness.has_rule("Power1#State", "on_power_change"))
  # Verify callbacks fire
  harness.fire_rule("HSBColor", "120,50,80", nil)
  harness.fire_rule("Power1#State", 1, nil)
  expect("hsb callback fired", hsb_fired[0], ['h', "120,50,80"])
  expect("power callback fired", hsb_fired[1], ['p', 1])
end

def test_remove_light_change_rules()
  var lc = setup()
  lc.add_light_change_rules(def () end, def () end)
  harness.fire_timer("light_change_rules_delay")
  lc.remove_light_change_rules()
  expect("hsb rule removed", harness.has_rule("HSBColor", "on_hsb_change"), false)
  expect("power rule removed", harness.has_rule("Power1#State", "on_power_change"), false)
end

def test_register_power_on_for_anim_only_fires_on_value_1()
  var lc = setup()
  var fired = []
  lc.register_power_on_for_anim(def () fired.push(1) end)
  harness.fire_rule("Power1#State", 0, nil)
  expect("does not fire on power off", size(fired), 0)
  harness.fire_rule("Power1#State", 1, nil)
  expect("fires on power on", size(fired), 1)
  # Rule removes itself after firing
  expect("rule removed after firing", harness.has_rule("Power1#State", "on_power_on_for_anim"), false)
end

# ── Run ────────────────────────────────────────────────────
def run_all()
  test_setoption20_on()
  test_setoption20_off()
  test_set_solid_sends_color2()
  test_set_solid_skips_when_same_color_no_anim_clear()
  test_set_solid_resends_when_anim_was_cleared()
  test_set_solid_power_on_override_when_off_and_no_auto_on()
  test_set_solid_no_power_on_when_already_on()
  test_set_solid_no_power_on_when_turn_on_light_true()
  test_set_animation_breathe()
  test_set_animation_max_brightness_high_bri()
  test_set_animation_comet()
  test_set_animation_crenel()
  test_set_animation_engine_kept_alive()
  test_clear_animation_when_running()
  test_clear_animation_when_idle()
  test_clear_animation_removes_power_on_rule()
  test_update_breathe_brightness()
  test_update_breathe_low_bri()
  test_update_breathe_ignores_non_breathe()
  test_set_event_timer()
  test_set_event_timer_replaces()
  test_remove_event_timer()
  test_add_light_change_rules_uses_delay()
  test_remove_light_change_rules()
  test_register_power_on_for_anim_only_fires_on_value_1()

  print(format("test_lightcontroller: %d passed, %d failed", passed, failed))
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
