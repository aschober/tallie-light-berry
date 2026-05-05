# Tallie Light Berry

Tallie Light is a [Tasmota](https://tasmota.github.io/) Berry app for ESP32 LED controllers. It watches live sports scores from the Tallie cloud and drives an LED strip to celebrate when a tracked team is winning — flashing or animating in the team's color. After the game ends, the light restores to its prior state once the user-selected timeout expires. Manually turning off the light also triggers a restore of light.

The device authenticates with the Tallie cloud using OAuth 2.0 Device Authorization Flow. Once authorized, the cloud provisions MQTT credentials and a set of topic subscriptions for each team the user has configured. Game updates arrive over MQTT and are processed entirely on-device.

## Hardware

Tallie Light runs on any ESP32 with a connected LED (WS2812 / SK6812) strip. It was developed against the [Adafruit Sparkle Motion Mini](https://www.adafruit.com/product/5987), a compact ESP32-S3 board with a built-in NeoPixel driver. The Tasmota template for this board is:

```
{"NAME":"Tallie Light","GPIO":[32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,640,0,0,608,0,0,0,0,0,0,0,0,0,1376,0,0,0,0,0,0,0],"FLAG":0,"BASE":1}
```

Any ESP32 running Tasmota with a NeoPixel-compatible LED strip should work with minor GPIO adjustments.

### Custom Tasmota firmware

Tallie Light requires a custom Tasmota build to include the Berry MQTT client. Standard Tasmota releases do not include all necessary features. Add the following to `user_config_override.h` before building:

```cpp
// Required: Berry MQTT client used for Tallie event subscriptions
#define USE_BERRY_MQTTCLIENT

// Required: TLS support for MQTT over port 443 (AWS IoT)
#define USE_MQTT_TLS
#define USE_MQTT_AWS_IOT_LIGHT

// Required: Berry animation engine for in-progress win effects
#define USE_BERRY_ANIMATION
```

## Installation

1. Flash Tasmota to your ESP32 and configure for your hardware. If using an [Adafruit Sparkle Motion Mini](https://www.adafruit.com/product/5987), you can apply the hardware template above.
2. Build the `.tapp` extension archive (see [Building](#building) below).
3. In the Tasmota web UI, go to **Firmware Upgrade → Upgrade by file upload** and upload `TallieLight-prod.tapp` with type set to **Tasmota App**.
4. The extension loads automatically on reboot. Open the Tasmota web UI and tap **Tallie Light** in the configuration menu to sign in and configure your teams.

## Building

The build script copies source files into a `build/` staging directory, minifies the HTML settings page, generates the environment module from config, strips comments and blank lines from Berry files to reduce on-device memory usage, then packages everything into a `.tapp` zip archive.

### Prerequisites

- [`minify`](https://github.com/tdewolff/minify) CLI — used to minify the HTML template:
  ```
  brew install tdewolff/tap/minify
  ```
- Python 3 — used by the web UI test harness build script (`tests/web/build_test_page.py`) which generates a test HTML file to see changes off device.

### Environment config

The build requires three environment values. You can provide them via a `.env` file or as shell environment variables (which take precedence over the file).

Copy the template and fill in your values:

```
cp env.template dev.env
```

`dev.env` / `prod.env`:
```
OAUTH_DOMAIN=https://your-tenant.us.kinde.com
OAUTH_CLIENT_ID=your_client_id
BACKEND_URL=https://your-api-id.execute-api.us-east-1.amazonaws.com/dev/v1
```

Alternatively, export the variables directly:
```
export OAUTH_DOMAIN=...
export OAUTH_CLIENT_ID=...
export BACKEND_URL=...
```

`.env` files are gitignored. Do not commit config.

### Running a build

```bash
./build_tapp.sh               # dev build, existing Berry extension version
./build_tapp.sh prod          # prod build, existing Berry extension version
./build_tapp.sh 1.2.0         # dev build, update version to 1.2.0
./build_tapp.sh 1.2.0 prod    # prod build, update version to 1.2.0
```

Output is written to `TallieLight-dev.tapp` or `TallieLight-prod.tapp` in the repo root. The `build/` directory is also left in place for inspection after a build.

## Development

### Running tests

Berry unit tests run off-device using the Tasmota Berry interpreter. The `berry` binary must be on your `$PATH`. Override with `BERRY_BIN=/path/to/berry` if needed.

```bash
bash tests/berry/run_tests.sh
```

### Web UI test harness

A self-contained HTML file for testing the settings page in any browser without a device:

```bash
bash tests/web/build_test_page.sh
open tests/web/tallielight_ui_test.html
```

Pass `--refresh-style` to re-fetch the Tasmota CSS when the firmware version changes.

### Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a full description of the state machine, event selection logic, class structure, and test scenarios.
