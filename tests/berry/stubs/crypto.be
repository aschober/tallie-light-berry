# Stub `crypto` module. On-device Tasmota provides crypto.SHA256() etc.;
# for tests we return a fixed deterministic digest so device IDs are stable.
var crypto = module('crypto')

class _SHA256
  def update(data) end
  def out()
    # Fixed 32-byte digest — deterministic for tests.
    return bytes('000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f')
  end
end

crypto.SHA256 = def () return _SHA256() end

return crypto
