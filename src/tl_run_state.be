#@ solidify:TLRunState,weak
class TLRunState
  var mode             # TL_* (0=IDLE, 1=SOLID, 2=ANIM, 3=MUTED)
  var active_event     # TLScoreboardEvent or nil
  var pinned_slug      # string or nil
  var team_color_rgb   # hex string "RRGGBB" (no #) — current team color, or nil
  var team_color_map   # map from light.get() reading after color was set, or nil
  var animation        # current animation object, or nil

  def init() self.clear() end

  def clear()
    self.mode = 0  # TL_IDLE
    self.active_event = nil
    self.pinned_slug = nil
    self.team_color_rgb = nil
    self.team_color_map = nil
    self.animation = nil
  end
end
global.TLRunState = TLRunState
