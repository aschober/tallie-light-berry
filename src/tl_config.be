#@ solidify:TLConfig,weak
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
global.TLConfig = TLConfig
