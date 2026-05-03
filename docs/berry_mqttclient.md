# Berry `mqttclient` Class

Independent MQTT client for Berry on ESP32. Allows Berry code to connect to a separate MQTT broker with its own credentials, completely independent from Tasmota's global MQTT connection. Supports TLS, LWT (Last Will and Testament), and automatic reconnection with exponential backoff.

## Requirements

- ESP32 platform
- `USE_BERRY` enabled in build
- `USE_TLS` enabled for TLS connections
- For AWS IoT, one of the following build flags (matching your auth method):
  - `USE_MQTT_AWS_IOT_LIGHT` — custom authorizer (user/password auth, no client certs)
  - `USE_MQTT_CLIENT_CERT` — client certificate auth (certs loaded from flash, user/password preserved)
  - `USE_MQTT_AWS_IOT` — full AWS IoT mutual TLS (implies `USE_MQTT_CLIENT_CERT`, clears user/password)

## Quick Start

```python
var m = mqttclient()

# Set callback for incoming messages
m.set_on_message(def (topic, idx, payload_s, payload_b)
  print("Received [" + topic + "]: " + payload_s)
end)

# Set reconnect callback — called after every successful (re)connect
m.set_on_connect(def ()
  m.subscribe("my/topic/#")
  m.publish("my/topic/status", "online")
  print("MQTT connected")
end)

# Connect to broker (auto-reconnect enabled by default)
m.connect("broker.example.com", 1883, "my-client-id", "user", "pass")

# Register loop - REQUIRED for messages and auto-reconnect
tasmota.add_fast_loop(def () m.loop() end)
```

## Constructor

### `mqttclient()`

Creates a new independent MQTT client instance. Multiple instances can coexist, each connected to a different broker.

```python
var m = mqttclient()
```

## Methods

### `connect(host, port, client_id [, user, pass, use_tls, lwt_topic, lwt_msg, lwt_qos, lwt_retain])`

Connects to an MQTT broker. Returns `true` on success, `false` on failure.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `host` | string | yes | | Broker hostname or IP address |
| `port` | int | yes | | Broker port (1883 plain, 8883 TLS, or 443 for AWS IoT) |
| `client_id` | string | yes | | Unique MQTT client identifier |
| `user` | string | no | `nil` | Username for authentication |
| `pass` | string | no | `nil` | Password for authentication |
| `use_tls` | bool | no | `false` | Enable TLS encryption |
| `lwt_topic` | string | no | `nil` | Last Will topic (requires `lwt_msg` too) |
| `lwt_msg` | string | no | `nil` | Last Will message |
| `lwt_qos` | int | no | `0` | Last Will QoS (0, 1, or 2) |
| `lwt_retain` | bool | no | `false` | Last Will retain flag |

```python
# Simple connection (no auth, no TLS)
m.connect("broker.example.com", 1883, "my-client")

# With authentication
m.connect("broker.example.com", 1883, "my-client", "user", "pass")

# With TLS (pass nil for user/pass if no auth needed)
m.connect("broker.example.com", 8883, "my-client", nil, nil, true)

# With authentication and TLS
m.connect("broker.example.com", 8883, "my-client", "user", "pass", true)

# AWS IoT Core on port 443 with custom authorizer (ALPN auto-configured)
m.connect("myendpoint.iot.us-east-1.amazonaws.com", 443, "my-thing", "user", "token", true)

# AWS IoT Core on port 443 with client cert (ALPN and cert auto-configured)
m.connect("myendpoint.iot.us-east-1.amazonaws.com", 443, "my-thing", nil, nil, true)

# Full example with LWT
m.connect("broker.example.com", 8883, "my-client",
          "user", "pass", true,
          "devices/my-client/status", "offline", 1, true)
```

**Notes:**
- The connect call is synchronous and blocks during TCP connect and TLS handshake (up to ~5 seconds for TLS).
- DNS resolution is performed internally.
- TLS uses Tasmota's built-in CA trust anchors for certificate validation.
- Calling `connect()` again on an already-connected client will clean up the previous connection first.
- **Auto-reconnect** is enabled by default after calling `connect()` (whether the initial connection succeeds or fails). If the connection is lost, `loop()` will automatically retry with exponential backoff. Use `set_auto_reconnect(false)` to disable.
- **AWS IoT auto-detection:** When the hostname contains `.iot.` and ends with `.amazonaws.com`, and the port is 443, the ALPN protocol is automatically set to `"mqtt"` (required by AWS IoT Core). Additional behavior depends on build flags:
  - `USE_MQTT_AWS_IOT_LIGHT`: ALPN only. User/password passed through for custom authorizer auth.
  - `USE_MQTT_CLIENT_CERT`: ALPN + client certs loaded from flash. User/password preserved.
  - `USE_MQTT_AWS_IOT`: ALPN + client certs loaded from flash. User/password cleared (cert-only auth).

### `disconnect()`

Disconnects from the broker, releases all resources (TCP/TLS transport and MQTT client), and **disables auto-reconnect**. Call `connect()` again to re-establish the connection and re-enable auto-reconnect.

```python
m.disconnect()
```

### `publish(topic, payload [, retain])`

Publishes a message. Returns `true` on success.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `topic` | string | yes | | Topic to publish to |
| `payload` | string or bytes | yes | | Message payload |
| `retain` | bool | no | `false` | Retain flag |

```python
# String payload
m.publish("my/topic", "hello world")

# With retain
m.publish("my/topic/status", "online", true)

# Bytes payload
var b = bytes("DEADBEEF")
m.publish("my/topic/binary", b)
```

### `subscribe(topic [, qos])`

Subscribes to a topic. Returns `true` on success.

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `topic` | string | yes | | Topic filter (supports MQTT wildcards `+` and `#`) |
| `qos` | int | no | `0` | QoS level (0, 1, or 2) |

```python
m.subscribe("my/topic")
m.subscribe("my/devices/+/status")
m.subscribe("my/topic/#", 1)
```

### `unsubscribe(topic)`

Unsubscribes from a topic. Returns `true` on success.

```python
m.unsubscribe("my/topic")
```

### `loop()`

Processes incoming MQTT messages, maintains the connection, and manages auto-reconnect. **Must be called regularly** — register it with `tasmota.add_fast_loop()`.

```python
tasmota.add_fast_loop(def () m.loop() end)
```

When messages arrive, `loop()` fires the callback set via `set_on_message()` synchronously. If auto-reconnect is enabled and the connection is lost, `loop()` will automatically attempt to reconnect with exponential backoff (10s, 20s, 30s, ... up to 120s). After a successful reconnect, the `on_connect` callback is fired.

### `connected()`

Returns `true` if currently connected to the broker.

```python
if m.connected()
  m.publish("status", "still alive")
end
```

### `state()`

Returns the PubSubClient connection state as an integer.

| Value | Constant | Description |
|-------|----------|-------------|
| `-4` | `MQTT_CONNECTION_TIMEOUT` | Connection timed out |
| `-3` | `MQTT_CONNECTION_LOST` | Connection lost after being established |
| `-2` | `MQTT_CONNECT_FAILED` | TCP/TLS connection failed |
| `-1` | `MQTT_DISCONNECTED` | Not connected (initial state) |
| `0` | `MQTT_CONNECTED` | Connected |
| `1` | `MQTT_CONNECT_BAD_PROTOCOL` | Bad protocol version |
| `2` | `MQTT_CONNECT_BAD_CLIENT_ID` | Client ID rejected |
| `3` | `MQTT_CONNECT_UNAVAILABLE` | Server unavailable |
| `4` | `MQTT_CONNECT_BAD_CREDENTIALS` | Bad username/password |
| `5` | `MQTT_CONNECT_UNAUTHORIZED` | Not authorized |

```python
print("State: " + str(m.state()))
```

### `set_on_message(closure)`

Sets the callback function for incoming messages. The callback receives 4 parameters:

| Parameter | Type | Description |
|-----------|------|-------------|
| `topic` | string | The topic the message was received on |
| `idx` | int | Always 0 (reserved) |
| `payload_s` | string | Payload as a string |
| `payload_b` | bytes | Payload as raw bytes |

```python
m.set_on_message(def (topic, idx, payload_s, payload_b)
  print("Topic: " + topic)
  print("Payload: " + payload_s)
  # Use payload_b for binary data
end)
```

### `set_on_connect(closure)`

Sets a callback function that is called after every successful connection or reconnection. This is the recommended place to subscribe to topics and publish initial status, since subscriptions are not preserved across reconnects.

The callback receives no parameters.

```python
m.set_on_connect(def ()
  m.subscribe("my/topic/#")
  m.publish("my/status", "online", true)
  print("MQTT connected/reconnected")
end)
```

### `set_auto_reconnect(enabled)`

Enables or disables automatic reconnection. Auto-reconnect is **enabled by default** after calling `connect()`. When enabled, `loop()` will automatically retry the connection with exponential backoff if the connection is lost.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `enabled` | bool | yes | `true` to enable, `false` to disable |

```python
# Disable auto-reconnect
m.set_auto_reconnect(false)

# Re-enable auto-reconnect (resets backoff timer)
m.set_auto_reconnect(true)
```

**Backoff timing** (matches Tasmota's global MQTT client, base delay configurable via `MqttRetry` command, default 10s):

| Attempt | Delay (default) |
|---------|-----------------|
| 1st retry | 10s |
| 2nd retry | 20s |
| 3rd retry | 30s |
| ... | ... |
| 12th+ retry | 120s (max) |

## Complete Examples

### Basic Pub/Sub

```python
var m = mqttclient()

m.set_on_message(def (topic, idx, payload_s, payload_b)
  print("[" + topic + "]: " + payload_s)
end)

m.set_on_connect(def ()
  m.subscribe("berry/test/#")
  m.publish("berry/test/hello", "world")
  print("MQTT connected")
end)

m.connect("broker.hivemq.com", 1883, "berry-" + str(tasmota.millis()))
tasmota.add_fast_loop(def () m.loop() end)
```

### TLS Connection with Authentication

```python
var m = mqttclient()

m.set_on_message(def (topic, idx, payload_s, payload_b)
  print("[" + topic + "]: " + payload_s)
end)

m.set_on_connect(def ()
  m.subscribe("devices/my-device/commands/#")
  m.publish("devices/my-device/status", "online", true)
  print("MQTT connected")
end)

m.connect("my-broker.example.com", 8883, "my-device", "username", "password", true)
tasmota.add_fast_loop(def () m.loop() end)
```

### LWT (Last Will and Testament)

```python
var m = mqttclient()

m.set_on_message(def (topic, idx, payload_s, payload_b)
  print("[" + topic + "]: " + payload_s)
end)

m.set_on_connect(def ()
  m.publish("devices/my-device/availability", "online", true)
  m.subscribe("devices/my-device/commands/#")
  print("MQTT connected")
end)

# Connect with LWT - broker publishes "offline" if we disconnect unexpectedly
m.connect("broker.example.com", 1883, "my-device",
          "user", "pass", false,
          "devices/my-device/availability", "offline", 1, true)
tasmota.add_fast_loop(def () m.loop() end)
```

### Auto-Reconnect with on_connect Callback

Auto-reconnect is built in. Use `set_on_connect()` to re-subscribe after each reconnection.

```python
var m = mqttclient()

m.set_on_message(def (topic, idx, payload_s, payload_b)
  print("[" + topic + "]: " + payload_s)
end)

# This callback fires after every successful connect or reconnect
m.set_on_connect(def ()
  m.subscribe("my/topic/#")
  m.publish("my/status", "online", true)
  print("MQTT connected")
end)

# Connect — auto-reconnect enabled by default
m.connect("broker.example.com", 1883, "my-device", "user", "pass")

# Register loop — handles messages AND auto-reconnect with exponential backoff
tasmota.add_fast_loop(def () m.loop() end)
```

### AWS IoT Core — Custom Authorizer

Using a custom authorizer with username/password authentication. Requires `USE_TLS` and `USE_MQTT_AWS_IOT_LIGHT` in the build. No client certificates needed.

```python
var m = mqttclient()

m.set_on_message(def (topic, idx, payload_s, payload_b)
  print("[" + topic + "]: " + payload_s)
end)

m.set_on_connect(def ()
  m.subscribe("my/app/commands/#")
  m.publish("my/app/status", '{"state":"online"}')
  print("AWS IoT connected")
end)

var endpoint = "abcdefg1234567-ats.iot.us-east-1.amazonaws.com"
m.connect(endpoint, 443, "my-thing-name", "my-username", "my-auth-token", true)
tasmota.add_fast_loop(def () m.loop() end)
```

### AWS IoT Core — Mutual TLS (Client Certificate)

Using device certificate authentication. Requires `USE_TLS` and `USE_MQTT_CLIENT_CERT` (or `USE_MQTT_AWS_IOT`) in the build. Upload your device certificate and private key to Tasmota using the `TLSKey` command.

```python
var m = mqttclient()

m.set_on_message(def (topic, idx, payload_s, payload_b)
  print("[" + topic + "]: " + payload_s)

  # Handle commands
  import json
  var msg = json.load(payload_s)
  if msg != nil
    # process message
  end
end)

m.set_on_connect(def ()
  # Subscribe to device shadow and custom topics
  m.subscribe("$aws/things/my-thing-name/shadow/update/delta")
  m.subscribe("my/app/commands/#")
  m.publish("my/app/status", '{"state":"online"}')
  print("AWS IoT connected")
end)

# AWS IoT endpoint - ALPN and client cert are auto-configured
var endpoint = "abcdefg1234567-ats.iot.us-east-1.amazonaws.com"
m.connect(endpoint, 443, "my-thing-name", nil, nil, true)
tasmota.add_fast_loop(def () m.loop() end)
```

**Note:** AWS IoT does not support retained messages. Do not use `retain=true` when publishing.

### Multiple Independent Connections

```python
var m1 = mqttclient()
var m2 = mqttclient()

m1.set_on_message(def (topic, idx, payload_s, payload_b)
  print("Broker1 [" + topic + "]: " + payload_s)
end)

m2.set_on_message(def (topic, idx, payload_s, payload_b)
  print("Broker2 [" + topic + "]: " + payload_s)
end)

m1.set_on_connect(def ()
  m1.subscribe("broker1/topics/#")
  print("Broker1 connected")
end)

m2.set_on_connect(def ()
  m2.subscribe("broker2/topics/#")
  print("Broker2 connected")
end)

m1.connect("broker1.example.com", 1883, "device-conn1")
m2.connect("broker2.example.com", 8883, "device-conn2", "user", "pass", true)

tasmota.add_fast_loop(def () m1.loop() m2.loop() end)
```

## Memory Usage

Each `mqttclient` instance uses approximately:
- ~1200 bytes for the MQTT packet buffer
- ~100 bytes for WiFiClient (plain TCP)
- ~4 KB additional for TLS buffers (only when `use_tls=true`)

## Differences from Tasmota's Built-in MQTT

| Feature | Built-in `mqtt` module | `mqttclient` class |
|---------|----------------------|-------------------|
| Broker | Uses Tasmota settings | Any broker, specified at runtime |
| Instances | Single global connection | Multiple independent instances |
| Configuration | Tasmota web UI / commands | Berry code parameters |
| Auto-reconnect | Built-in with exponential backoff | Built-in with exponential backoff (matching timing) |
| Reconnect callback | N/A | `set_on_connect()` for re-subscribing |
| Topic prefix | Automatic Tasmota prefix | No prefix, fully user-controlled |
| TLS | Via Tasmota settings | Per-connection `use_tls` parameter |
| LWT | Via Tasmota settings | Per-connection LWT parameters |
| AWS IoT (port 443) | Via Tasmota settings | Auto-detected from hostname |
| Client certificates | Via `TLSKey` command | Reuses same flash-stored certs |
