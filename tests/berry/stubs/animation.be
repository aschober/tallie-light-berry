# Stub `animation` module for off-device tests.
#   Records what was created/started/stopped without rendering anything.
#

var animation = module('animation')

class _FakeStrip
  var _bri
  var _pixel_count
  def init()
    self._bri = 255
    self._pixel_count = 30
  end
  def set_bri(b) self._bri = b end
  def pixel_count() return self._pixel_count end
end

class _FakeEngine
  var strip
  var is_running
  var _added
  def init()
    self.strip = _FakeStrip()
    self.is_running = false
    self._added = []
  end
  def get_strip() return self.strip end
  def add(a) self._added.push(a) end
  def run() self.is_running = true end
  def stop() self.is_running = false end
  def clear() self._added = [] end
end

class _FakeAnim
  var color
  var _kind
  def init(kind) self._kind = kind end
end

class breathe : _FakeAnim
  var min_brightness, max_brightness, curve_factor, period
  def init(engine) super(self).init("breathe") end
end

class comet : _FakeAnim
  var tail_length, fade_factor, direction, speed, wrap_around
  def init(engine) super(self).init("comet") end
end

class crenel : _FakeAnim
  var pulse_size, low_size, nb_pulse, pos
  def init(engine) super(self).init("crenel") end
end

class sawtooth
  var min_value, max_value, duration
  def init(engine) end
end

animation.init_strip = def () return _FakeEngine() end
animation.breathe = breathe
animation.comet = comet
animation.crenel = crenel
animation.sawtooth = sawtooth

return animation
