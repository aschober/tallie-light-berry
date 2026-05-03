# TallieLight Extension Entry Point

do
  import introspect
  import sys

  # Push .tapp archive path so introspect.module can resolve files within it
  var wd = tasmota.wd
  if size(wd) sys.path().push(wd) end

  var tallielight_ui_mod = introspect.module("tallielight_ui", true)
  tasmota.add_extension(tallielight_ui_mod.get_driver())

  if size(wd) sys.path().pop() end
end
