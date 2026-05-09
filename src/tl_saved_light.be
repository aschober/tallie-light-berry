#@ solidify:TLSavedLight,weak
class TLSavedLight
  var rgb       # hex string "RRGGBB" (no leading #)
  var hue       # 0-360
  var sat       # 0-255
  var bri       # 0-255
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
global.TLSavedLight = TLSavedLight
