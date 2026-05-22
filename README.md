# Tallie Light Berry

Tallie Light is a [Tasmota](https://tasmota.github.io/) Berry app for ESP32 LED controllers. It watches live sports scores from the Tallie Cloud and drives an LED strip to celebrate when a favorite team is winning or has won — animating LEDs in the team's color during the game and solid color when the game ends. After the celebration is over (based on a user-selected timer), the light restores to its prior state. Tallie Light can be configured to automatically turn on when winning or can be configured to be your team's color the next time it is manually turned on.

The device authenticates with the Tallie Cloud using OAuth 2.0 Device Authorization Flow. Once authorized, the Tallie Cloud provisions MQTT credentials and a set of topic subscriptions for each team the user has configured. Game updates arrive over MQTT and are processed entirely on-device.

## How it works

```
Team is winning (live game)                 →  LED animates in team color
Team wins (game final)                      →  LED solid in team color
Timer expires, team not playing, team lost  →  LED restores to prior state
Light turned off while wininng or won       →  Event silently tracked; color applied on next power-on
```

### Scoreboard

<img width="440" alt="scoreboard" src="https://github.com/user-attachments/assets/f19cea10-29c2-4bd6-b9be-67316d04d708" />

The Tasmota main page shows a live scoreboard widget for all tracked teams. Each team row shows a live indicator you can click to activate, mute, or deactivate the celebration:

| Indicator | Meaning |
|---|---|
| ■ filled square | Active: Team is winning or has won and light is on in team color — click to Mute |
| ▣ square with fill | Muted: tracking team silently, light is off — click to Deactivate |
| □ outline square | Deactivate: Team is winning or has won, but light is not the team color — click to Activate |

### Settings
The settings page (served from the device's Tasmota web UI) lets you:
- Sign in with your Tallie account
- Search for and add teams
- Choose which team color to display (primary, alternate, or custom)
- Set a celebration timer (how long the light stays in team color after an event ends)
- Control whether the light turns on automatically when a team starts winning

<img width="470" alt="settings" src="https://github.com/user-attachments/assets/11e7b34f-fcbf-421c-8bf0-ea81905f5bea" />

## Hardware

### Option 1: Purchase a pre-built Tallie Light (Coming Soon)

A ready-to-use Tallie Light device with firmware pre-installed. No assembly or flashing required.

### Option 2: Build your own

Tallie Light runs on any ESP32 with a connected LED (WS2812 / SK6812) strip -- commonly known as WLED-compatible or Tasmota-compatible controllers. Tallie Light was developed using an [Adafruit Sparkle Motion Mini](https://www.adafruit.com/product/6160), a compact ESP32 board with built-in fuse and 5V level shifter, an [Adafruit I2C Stemma QT Rotary Encoder](https://www.adafruit.com/product/4991), and a Ring of 16x RGBW 5050 LEDs. Any ESP32 running Tasmota with a NeoPixel-compatible LED strip should work with minor GPIO adjustments.


1. The [Tasmota Template](https://tasmota.github.io/docs/Templates/) for the Adafruit Sparkle Motion Mini, I2C rotary encoder, and RGBW LEDs is:
```json
{"NAME":"Tallie Light","GPIO":[32,0,0,0,0,0,0,0,0,0,0,0,0,0,0,640,0,0,608,0,0,0,0,0,0,0,0,0,1376,0,0,0,0,0,0,0],"FLAG":0,"BASE":1}
```
2. Run the following command after boot to configure LED and rotary encoder settings.
```bash
> Backlog0 SetOption43 50; SetOption105 1; PixelType 9
```
3. Configure [Tasmota Timezone](https://tasmota.github.io/docs/Commands/#timestd) (see `TimeStd`, `TimeDst` commands) so Tallie Light relies on accurate day and time.
```bash
# Below is for America/New_York
> Backlog0 Timezone 99; TimeStd 0,1,11,1,2,-300; TimeDst 0,2,3,1,2,-240
```

#### Custom Tasmota firmware

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

There are two ways to install Tallie Light, depending on whether you use the custom Tasmota firmware from this repo or a standard Tasmota build.

### Option A: Custom firmware (recommended, ~30 KB heap)

The custom build pre-compiles Tallie Light Berry classes into the firmware, reducing heap usage by roughly 20 KB compared to the `.tapp` approach.

1. Download `tl-tasmota32.factory.bin` from the [latest release](https://github.com/aschober/sports-lamp-berry/releases/latest).
2. **First flash:** Use the [Tasmota Web Installer](https://tasmota.github.io/install/) for browser-based flashing via USB — no tools required. Click **Connect**, select your device's serial port, choose **Upload factory bin**, and select `tl-tasmota32.factory.bin`.  
   **OTA upgrade (already running Tasmota):** In the Tasmota web UI, go to **Firmware Upgrade → Upgrade by file upload** and upload `tl-tasmota32.bin`. The firmware `OtaUrl` is pre-configured to `https://ota.tallielight.com/tl-tasmota32.bin` so future OTA upgrades can be triggered directly from the Tasmota UI without specifying a URL.
3. Connect to the `tasmota-XXXXXX` Wi-Fi hotspot, join your network, then apply the hardware template for your board (see [Hardware](#hardware)).
4. Open the Tasmota web UI and tap **Tallie Light** in the configuration menu to sign in and select your teams.
5. In **Tools → Extension Manager**, set the extension repo to `https://ota.tallielight.com/extensions/` to receive future Tallie Light `.tapp` updates via the Extension Manager.

### Option B: Standard Tasmota + `.tapp` extension (~50 KB heap)

If you already have Tasmota running, you can install Tallie Light as a Berry app extension without reflashing. This uses more heap because Berry classes are loaded at runtime rather than compiled into the firmware.

1. Ensure your Tasmota build includes `USE_BERRY_MQTTCLIENT`, `USE_MQTT_TLS`, `USE_MQTT_AWS_IOT_LIGHT`, and `USE_BERRY_ANIMATION` (see [Custom Tasmota firmware](#custom-tasmota-firmware)).
2. Download `TallieLight.tapp` from the [latest release](https://github.com/aschober/sports-lamp-berry/releases/latest).
3. In the Tasmota web UI, go to **Firmware Upgrade → Upgrade by file upload**, upload `TallieLight.tapp` with type set to **Tasmota App**, and reboot.
4. Open the Tasmota web UI and tap **Tallie Light** in the configuration menu to sign in and select your teams.

## Building

The build script copies source files into a `build/` staging directory, minifies the HTML settings page, generates the environment module from config, strips comments and blank lines from Berry files to reduce on-device memory usage, then packages everything into a `.tapp` zip archive.

### Prerequisites

- [`minify`](https://github.com/tdewolff/minify) CLI — used to minify the HTML template:
  ```
  brew install tdewolff/tap/minify
  ```
- Python3 — used by the web UI test harness build script (`tests/web/build_test_page.py`) which generates a test HTML file to see changes off device.

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
./build-tapp.sh               # dev build using existing version from manifest.json
./build-tapp.sh prod          # prod build using existing version from manifest.json
```

Output is written to `TallieLight-dev.tapp` or `TallieLight-prod.tapp` in the repo root. The `build/` directory is left in place for inspection after a build.

## Development

### Running tests

Berry unit tests run off-device using the Tasmota Berry interpreter. The `berry` binary must be on your `$PATH`. Override with `BERRY_BIN=/path/to/berry` if needed.

```bash
bash tests/berry/run-tests.sh
```

### Web UI test harness

A self-contained HTML file for testing the settings page in any browser without a device:

```bash
bash tests/web/build-test-page.sh
open tests/web/tallielight_ui_test.html
```

Pass `--refresh-style` to re-fetch the Tasmota CSS when the firmware version changes.

### Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for a full description of the state machine, event selection logic, class structure, and test scenarios.

## Releases

Releases are triggered manually from the GitHub Actions UI via the **Build Release** workflow (`workflow_dispatch`). Select a `bump` component (`major`, `minor`, or `patch`) or provide an explicit `version` string (e.g. `1.3.0`). The workflow:

1. Bumps the version, builds all artifacts, and deploys the extension index and OTA binaries to `https://ota.tallielight.com` via the `gh-pages` branch.
2. Commits the version bump to `main`, creates a `vA.B.C.0` git tag, and publishes a GitHub Release with all artifacts attached.

Every push to `main` also triggers the **Build App** workflow, which produces snapshot `.tapp` artifacts (versioned `vA.B.C.<commit-count>`) available as GitHub Actions artifacts for testing without cutting a full release.

### Release artifacts

| Artifact | Description |
|---|---|
| `TallieLight.tapp` | Production `.tapp` extension archive |
| `TallieLight-dev.tapp` | Dev `.tapp` extension archive |
| `tl-tasmota32.bin` | Production custom Tasmota firmware — OTA upgrade |
| `tl-dev-tasmota32.bin` | Dev custom Tasmota firmware — OTA upgrade |
| `tl-tasmota32.factory.bin` | Production factory image — first flash via esptool at `0x0` |
| `tl-dev-tasmota32.factory.bin` | Dev factory image — first flash via esptool at `0x0` |

### OTA delivery

Released firmware and `.tapp` files are served from `https://ota.tallielight.com` (GitHub Pages, `gh-pages` branch):

| URL | Content |
|---|---|
| `/tl-tasmota32.bin` | Production firmware OTA binary |
| `/tl-dev-tasmota32.bin` | Dev firmware OTA binary |
| `/extensions/extensions.jsonl` | Production Extension Manager index |
| `/extensions/tapp/TallieLight.tapp` | Production `.tapp` |
| `/extensions/dev/extensions.jsonl` | Dev Extension Manager index |
| `/extensions/dev/tapp/TallieLight-dev.tapp` | Dev `.tapp` |

Each build variant pulls secrets from its matching GitHub Environment (`dev` or `prod`).
