# Stub `uuid` module. On-device Tasmota provides uuid.uuid4(); for tests we
#   return a fixed value so device IDs are deterministic.
var uuid = module('uuid')
uuid.uuid4 = def () return '00000000-0000-4000-8000-000000000000' end
return uuid
