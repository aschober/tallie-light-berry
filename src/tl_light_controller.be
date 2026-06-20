#@ solidify:TLLightController,weak
class TLLightController
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
    # Re-apply if the color changed or an animation was cleared. Animation
    # clear always requires re-application because the engine owns the physical
    # strip and leaves it dark after stop()/clear().
    var changed = (prev_team_rgb != new_rgb) || animation_was_cleared
    var lstate = light.get()
    if changed
      tasmota.cmd(format('Color2 %s', new_rgb))
      if !turn_on_light && user_initiated && lstate['power'] == false
        # SetOption20 suppresses auto power-on; send it explicitly for user actions.
        tasmota.cmd('Power ON')
      elif animation_was_cleared
        # Color2 alone doesn't flush the physical strip after the animation engine
        # releases it — follow with Dimmer to force Tasmota to re-render LEDs.
        var dimmer = tasmota.scale_uint(int(lstate['bri']), 0, 255, 0, 100)
        tasmota.cmd(format('Dimmer %d', dimmer))
      end
      lstate = light.get()
    end
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
      light.set({'hue': saved_light.hue, 'sat': saved_light.sat, 'bri': saved_light.bri, 'power': false})
    else
      var dimmer = tasmota.scale_uint(saved_light.bri, 0, 255, 0, 100)
      print(format('TAL: lc.restore_light: restoring saved_light with power on using Color2 and Dimmer commands.'))
      tasmota.cmd(format('Color2 %s', saved_light.rgb))
      tasmota.cmd(format('Dimmer %d', dimmer))
    end
  end

  # Set or update the animation.
  def set_animation(team_color_map, anim_type)
    import animation
    import string
    if self._anim_engine == nil
      self._anim_engine = animation.init_strip()
    end
    self._anim_engine.strip.set_bri(255)
    var anim_color = number(f'0xFF{string.toupper(team_color_map["rgb"])}')

    var anim
    if anim_type == 'comet'
      anim = animation.comet(self._anim_engine)
      anim.color = anim_color
      anim.tail_length = 3
      anim.fade_factor = 255
      anim.direction = -1
      anim.speed = 3000
      anim.wrap_around = 1
    elif anim_type == 'crenel'
      var num_pixels = self._anim_engine.get_strip().pixel_count()
      anim = animation.crenel(self._anim_engine)
      anim.color = anim_color
      anim.pulse_size = 1
      anim.low_size = 3
      anim.nb_pulse = -1
      var scroll = animation.sawtooth(self._anim_engine)
      scroll.min_value = 0
      scroll.max_value = num_pixels - 1
      scroll.duration = 2000
      anim.pos = scroll
    elif anim_type == 'breathe'
      var br = self._calc_breathe_brightness(int(team_color_map['bri']))
      anim = animation.breathe(self._anim_engine)
      anim.color = anim_color
      anim.min_brightness = br[0]
      anim.max_brightness = br[1]
      anim.curve_factor = 2
      anim.period = 3000
    elif anim_type == 'solid'
      return nil
    else
      var num_pixels = self._anim_engine.get_strip().pixel_count()
      anim = animation.crenel(self._anim_engine)
      anim.color = anim_color
      anim.pulse_size = 1
      anim.low_size = 3
      anim.nb_pulse = -1
      var scroll = animation.sawtooth(self._anim_engine)
      scroll.min_value = 0
      scroll.max_value = num_pixels - 1
      scroll.duration = 2000
      anim.pos = scroll
    end

    self._anim_engine.add(anim)
    self._anim_engine.run()
    return anim
  end

  def _calc_breathe_brightness(current_bri)
    var min_b = current_bri < 64 ? 0 : 64
    return [min_b, 255]
  end

  def update_animation(anim, new_rgb, new_bri_255)
    import animation
    import string
    anim.color = number(f'0xFF{string.toupper(new_rgb)}')
    if isinstance(anim, animation.breathe)
      var br = self._calc_breathe_brightness(new_bri_255)
      anim.min_brightness = br[0]
      anim.max_brightness = br[1]
    end
  end

  # Stop and clear any running animation.
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

  def set_event_timer(duration_secs, cb)
    tasmota.remove_timer('handle_event_timeout')
    tasmota.set_timer(duration_secs * 1000, cb, 'handle_event_timeout')
  end

  def remove_event_timer()
    tasmota.remove_timer('handle_event_timeout')
  end

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
global.TLLightController = TLLightController
