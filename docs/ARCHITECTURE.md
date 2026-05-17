# Tallie Light Architecture

Tallie Light is a [Tasmota](https://tasmota.github.io/) Berry application that runs on an ESP32 with an attached RGB LED light strip (WS2812B / SK6812). It subscribes to live scoreboard events from the Tallie backend over MQTT and drives an LED strip to celebrate when a tracked team is winning — showing the team color as a solid or animated light. When the event ends or the light is turned off, it restores the light to its prior state.

The extension is packaged as a `.tapp` archive (a zip of Berry source files and an HTML settings page) and loaded via Tasmota's extension manager. It uses OAuth 2.0 Device Authorization Flow to authenticate the device with the Tallie backend, which provisions MQTT credentials and a set of allowed topic subscriptions.

## Core Concepts

| Concept | Description |
|---|---|
| **ScoreboardEvent** | A parsed game update for one tracked team, containing scores, game status, and timestamps |
| **Active Event** | The single event currently driving the light display |
| **Saved Light State** | A snapshot of the light's color/brightness/power taken before any team change, used for restoration |
| **Pinned Team** | A user-selected team that takes priority over all automatic event selection |
| **TL_MUTED** | Mode when an event is active but the light is off — entered when the user turns the light off, clicks ■ to mute, unpins a team with another winner still active, or when a new winning event arrives with `turn_on_light=false` and the light is already off |

---

## Light Mode Enum

```berry
var TL_IDLE  = 0   # no active event; light is user-controlled
var TL_SOLID = 1   # final win — solid team color, light on
var TL_ANIM  = 2   # in-progress win — animated team color, light on
var TL_MUTED = 3   # event is active but light is off
```

`TL_MUTED` unifies all "event active, light off" entry paths:
- User manually turned the light off during an active event
- New winning event arrived with `turn_on_light=false` and light already off
- User clicked ■ in the Web UI to mute the active event
- User unpinned a team while another winning event was active

In all cases the team color is staged via `light.set()` (preserving brightness, keeping light off), `saved_light.power` is set to `false` (so a future timeout restore keeps the light off), and the system waits for power-on. On power-on, `saved_light.power` is updated to `true` and `_set_active_event()` re-runs and enters `TL_SOLID` or `TL_ANIM`.

---

## State Machine

```
TL_IDLE ──── winning event, light on ────────────────────────► TL_ANIM
   ▲                                                              │
   │                                                    game ends, still winning
   │                                                              │
   │                                                              ▼
   │                                                           TL_SOLID
   │                                                              │
   │◄──── timeout / no longer winning ────────────────────────────┤
   │                                                              │
   │              user turns off / clicks ■ / unpin ──────────► TL_MUTED ◄──────┐
   │                                                              │             │
   │◄──── timeout while muted ─────────────────────────────────── │             │
   │                                                              │             │
   │◄──── user clicks ▣ (deactivate) ──────────────────────────── │             │
   │                                                              │             │
   ▲◄──── user turns light on ──── re-enters TL_ANIM/TL_SOLID ────┘             │
                                                                                │
TL_IDLE ──── winning event, light off + turn_on_light=false ───────────────────►┘
```

### State Descriptions

**TL_IDLE** — No active event. Light is user-controlled. MQTT events are evaluated on arrival.

**TL_ANIM** — A tracked team is winning an in-progress game. Light shows team color + animation (breathe, comet, or crenel). A timeout timer runs for `light_restore_mins` from `last_updated`.

**TL_SOLID** — A tracked team has won a completed game. Light shows solid team color. Same timeout applies.

**TL_MUTED** — Event is active, team color is set, but light is off. Timeout still applies.

---

## Event Selection Logic

When multiple tracked teams have game updates, `_calculate_active_event()` picks one using this priority order:

1. **Pinned team** — always wins; no timeout gate applied.
2. **In-progress winning events** — game is live and `competitor_score > opponent_score` (strict; ties do not count).
3. **Final winning events** — completed game where competitor won.
4. Within each tier, teams are ranked by their order in `config.team_configs`.
5. **Timeout filter** — any event whose `last_updated + light_restore_mins` has passed is excluded from tiers 2 and 3 (but not pinned).

---

## Winning Condition

A `ScoreboardEvent` is considered winning if either:
- Game is **final** (`state == "post"`) AND `competitor_winner == true`, **OR**
- Game is **in-progress** (`state == "in"`) AND `competitor_score > opponent_score`

Scheduled games (`state == "pre"`) never trigger light changes.

---

## Triggers and Transitions

### MQTT Message Received
1. Parse JSON into a `ScoreboardEvent` and store in `last_events[topic]`
2. Call `_apply_event_change(_calculate_active_event(), false)`
3. If unchanged (`_event_unchanged()`) → no-op
4. If new event is nil → `_restore_light_state()`
5. If mode is `TL_MUTED` and not user-initiated → update `active_event` in memory only, no light change
6. Otherwise → `_set_active_event(new_ev, user_initiated)`

### `_set_active_event()` Decision Tree

```
Compute end_time (pinned: now + restore_mins; auto: last_updated + restore_mins)
        │
        ▼
  save_light_state(end_time)   ← idempotent; skips if end_time unchanged
        │
        ▼
  Light off AND turn_on_light=false AND NOT user_initiated?
        │ yes → light.set() stages color silently → TL_MUTED
        │ no
        ▼
  event.is_winner() (final)?
        │ yes → set_solid() → TL_SOLID
        │ no  → set_animation() → TL_ANIM
        │
        ▼
  Set event timer for end_time
  Register HSB + Power change rules (500ms delay)
```

### Event Timeout Fires
1. Clear `active_event` and `pinned_slug`
2. Re-evaluate via `_calculate_active_event()`
3. If another winner exists → `_set_active_event()`; otherwise → `_restore_light_state()`

### User Turns Light OFF
- If `state.mode` is `TL_ANIM` or `TL_SOLID` → `TL_MUTED` (animation stopped, event and timer preserved)
- If `TL_IDLE` → `_restore_light_state()` if a saved state exists

### User Turns Light ON (while TL_MUTED)
- Updates `saved_light.power = true` (so a subsequent timeout restore leaves the light on)
- Clears `active_event` to force re-evaluation, then calls `_apply_event_change(_calculate_active_event(), true)` — re-enters `TL_ANIM` or `TL_SOLID`

### User Changes Color or Saturation Manually
- Detected via Tasmota HSB rule (registered 500ms after team light is set)
- If hue or saturation differs from team color: clear `saved_light` (no restore), exit to `TL_IDLE`
- If only brightness changes: update `saved_light.bri`; no mode change

### User Pins a Team (□→■)
- `state.pinned_slug` set; `_apply_event_change()` called with `user_initiated=true`
- Pinned team's event used as long as `is_winning()` returns true

### User Mutes a Team (■→▣)
- `mute_team_light()` — preserves `pinned_slug` and `active_event`
- Stages team color via `light.set()` (preserving brightness, keeping light off) → `TL_MUTED`
- On power-on, re-enters `TL_ANIM` or `TL_SOLID`

### User Deactivates (▣→□)
- `activate_team_light(nil)` while already `TL_MUTED` → `_restore_light_state()` → `TL_IDLE`
- Clears pin, active event, and saved light

### User Unpins from Active State (■→▣ or ■→□)
- `activate_team_light(nil)` while `TL_ANIM` or `TL_SOLID`:
  - If another winning event exists → `TL_MUTED` with that event staged (not the pinned team)
  - If no other winners → `_restore_light_state()` → `TL_IDLE`

---

## Light Change Details

### set_solid() (final win)
- Sends `Color2 <rgb>`. If `user_initiated=true` and light is off and `turn_on_light=false`, also sends `Power ON`.
- Skips the command if color is unchanged and no animation was just cleared.

### set_animation() (in-progress win)
- Applies team color then overlays configured animation (`breathe`, `comet`, or `crenel`).
- For `breathe`, min/max brightness is calculated relative to current brightness, capped at 255.

### _restore_light_state()
- Sets mode to `TL_IDLE`, then calls `lc.restore_light()` and `_teardown_active_event()`.
- `restore_light()`: if `saved_light.power == false` uses `light.set()` (hue/sat/bri, power off); if `saved_light.power == true` uses `Backlog0 Color2 <rgb>; Dimmer <bri>`.
- `_teardown_active_event()`: clears animation, clears and persists `saved_light=nil`, removes event timer and light change rules, then calls `state.clear()`.

---

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│  TallieLightService  (thin orchestrator)                   │
│  - MQTT lifecycle, routes events to pure functions        │
│  - save_light_state / _restore_light_state                │
├───────────────────────────────────────────────────────────┤
│  TallieLightService methods                                │
│  - _calculate_active_event() / _apply_event_change()      │
│  - _set_active_event() / _restore_light_state()           │
│  - activate_team_light() / mute_team_light()              │
├───────────────────────────────────────────────────────────┤
│  LightController (all Tasmota/animation calls)            │
│  - set_solid() / set_animation() / clear_animation()      │
│  - add_light_change_rules() / remove_light_change_rules() │
│  - set_event_timer() / remove_event_timer()               │
└───────────────────────────────────────────────────────────┘
```

### Classes

| Class | Purpose |
|---|---|
| `ScoreboardEvent` | Parsed MQTT game update; `is_winning()`, `is_winner()`, `is_final()`, `is_in_progress()` |
| `TLConfig` | Persisted config: `team_configs`, `light_restore_mins`, `turn_on_light`, `animation_type`, `saved_light` |
| `TLSavedLight` | Light snapshot: `rgb`, `hue`, `sat`, `bri`, `power`, `end_time` |
| `TLRunState` | Volatile runtime state: `mode`, `active_event`, `pinned_slug`, `team_color_rgb`, `team_color_map`, `animation` |
| `LightController` | Hardware adapter — all `tasmota.cmd`, `light.get/set`, `animation.*` calls |
| `TallieLightService` | Top-level orchestrator — MQTT lifecycle, state machine, event routing |

### File Structure

```
src/tallielight.be
├── TL_* mode constants + sl_mode_name()
├── ScoreboardEvent
├── SLConfig
├── SLSavedLight
├── SLRunState
├── persist_read_conf() / persist_conf() / persist_saved_light()
├── LightController
└── TallieLightService

src/oa_service.be
├── OAuthService (#@ solidify:OAuthService,weak — compiled into firmware when solidified)
├── Storage layer (_get / _set_many / read_all_oauth_data)
│   ├── Persist keys: oa_at, oa_ate, oa_uid, oa_email, oa_rt
│   └── In-memory device-flow state: oa_uc, oa_vuc, oa_dc, oa_dce, oa_pi, oa_err
├── HTTP layer (_webclient_post)
├── JWT layer (_parse_jwt_payload)
├── Flow methods (initiate_authorization_flow / complete_authorization_flow / refresh_access_token_flow)
└── Status accessors (is_authorized / get_mqtt_username / get_mqtt_client_id)

src/oauth.be
└── Module wrapper — resolves OAuthService from firmware globals (solidified), falls back to
    loading oa_service.be from the .tapp archive; returns a singleton instance

src/tallielight_ui.be
├── Module-level setup (`import oauth` → global._oauth_service; `import tallielight` for service)
├── TallieLight_UI driver (Tasmota web driver lifecycle)
│   ├── init() / unload()
│   ├── web_add_config_button() — "Tallie Light" button in config menu
│   ├── web_sensor() — scoreboard rendering on main page
│   └── web_add_handler() — registers GET/POST /tl route
├── Page handler (_page_tallielight_ui / _page_tallielight_ui_handler)
│   ├── GET /tl — serves settings page (HTML + config + OAuth JSON)
│   ├── POST /tl?poll-oauth — device-flow polling endpoint
│   ├── POST /tl?get-token — returns access token JWT for JS API calls
│   └── POST /tl — handles team config, pin/mute/unpin, refresh-token, clear-all
└── Helpers (_send_oauth_json / _send_page_with_config / _get_team_scoreboard /
            _team_configs_equal / _get_away_home_teams / _is_team_winning)
```

---

## Persistence

Persist keys (snake_case, not compatible with v1):

| Key | Field | Default |
|---|---|---|
| `sl_teams` | `team_configs` | `[]` |
| `sl_restore_mins` | `light_restore_mins` | `60` |
| `sl_turn_on` | `turn_on_light` | `true` |
| `sl_anim_type` | `animation_type` | `'crenel'` |
| `sl_saved_light` | `saved_light` | `nil` |

`saved_light` is persisted as a flat map (`rgb`, `hue`, `sat`, `bri`, `power`, `end_time`), allowing restoration to survive device restarts.

---

## OAuth / MQTT Reconnection

Authentication uses the OAuth 2.0 Device Authorization Flow (RFC 8628). `OAuthService` (defined in `oa_service.be`, solidifiable into firmware) is a memory-conscious singleton: long strings (access token JWT, refresh token) stay in `persist` (Tasmota flash) and are only loaded into RAM when needed. Two small fields (`oa_uid`, `oa_ate`) are cached on the instance for zero-flash-hit access on every cron tick and MQTT reconnect. Device-flow transient state (`oa_uc`, `oa_vuc`, `oa_dc`, `oa_dce`, `oa_pi`, `oa_err`) is held in an in-memory map and never persisted. `oauth.be` is a thin module wrapper that resolves the class from firmware globals when solidified, otherwise loads it from the `.tapp` archive.

When an `OAuth=UPDATED` Tasmota rule fires, `TallieLightService` disconnects, registers device to get fresh credentials, and reconnects. In-flight events are not lost — `last_events` persists in memory across reconnects.

The settings page never receives the raw access token or refresh token on page load (`oa_has_at: bool` or `oa_has_rt: bool` is sent instead). JS fetches the access token lazily via `GET /tl?get-token=1` only when calling the backend API, and caches it until a 401 invalidates it.

---

## UI Scoreboard Indicators

Each team row in the web UI shows a colored indicator that cycles through three states on click:

| Indicator | Meaning | Click action |
|---|---|---|
| □ outline square | Team is winning but not the active event | → ■ activate (`activate-team-light`) |
| ■ filled square | Active event, light on (`TL_ANIM` / `TL_SOLID`) | → ▣ mute (`mute-team-light`) |
| ▣ square with fill | Active event, light off (`TL_MUTED`) | → □ deactivate (`unpin-team-light`) |
| _(none)_ | Team is not winning | not clickable |

All three actions POST to `/tl`.

---

## Tests

### Berry unit tests

Run off-device using the Tasmota Berry interpreter:

```
bash tests/berry/run-tests.sh
```

| File | What it covers |
|---|---|
| `tests/berry/test_data.be` | Data classes (`ScoreboardEvent`, `TLConfig`, `TLSavedLight`, `TLRunState`) and persist helpers |
| `tests/berry/test_lightcontroller.be` | `LightController` unit tests |
| `tests/berry/test_service.be` | `TallieLightService` full state machine |
| `tests/berry/test_oauth.be` | `OAuthService` unit tests (token validity, refresh, device flow, clear scopes) |
| `tests/berry/stubs/harness.be` | Stubs for `tasmota`, `light`, `mqttclient`, `webclient`, `oauth` |
| `tests/berry/stubs/animation.be` | Fake animation engine |
| `tests/berry/stubs/persist.be` | In-memory persist stub |
| `tests/berry/stubs/tallielight_env.be` | Hardcoded env constants |
| `tests/berry/stubs/uuid.be` | Fixed UUID stub for deterministic device-id tests |

### Web UI test harness

A self-contained HTML file for manually testing the UI in any browser without a device:

```
bash tests/web/build-test-page.sh
open tests/web/tallielight_ui_test.html
```

Re-fetch Tasmota CSS when the firmware version changes:

```
bash tests/web/build-test-page.sh --refresh-style
```

| File | Purpose |
|---|---|
| `tests/web/build-test-page.sh` | Entry point — fetches Tasmota CSS if missing, then builds the test page |
| `tests/web/build_test_page.py` | Python assembler and Tasmota CSS parser (called by the shell script) |
| `tests/web/test_harness.html` | Harness shell template — edit to change mock data or the test panel |
| `tests/web/tasmota_style.html` | Generated Tasmota CSS (gitignored, auto-fetched from GitHub) |
| `tests/web/tallielight_ui_test.html` | Generated output — open this in a browser (gitignored) |

### Test scenario table

#### Event filtering (winning detection)

| # | Test function | Scenario | Setup | Expected |
|---|---|---|---|---|
| 1 | `test_01_no_events` | No events received | `last_events` empty | `_calculate_active_event()` → nil; mode stays TL_IDLE |
| 2 | `test_02_scheduled_only` | Scheduled-only (pre) | A: state=pre | nil; pre is filtered |
| 3 | `test_03_losing` | In-progress losing | A: in, 1-3 | nil; not winning |
| 4 | `test_04_tied` | In-progress tied | A: in, 2-2 | nil; ties don't count (strict `>`) |
| 5 | `test_05_final_lost` | Final lost | A: post, winner=false | nil |
| 6 | `test_06_timeout_filter` | Event timed out | A: winning, `last_updated + restore_mins < now` | nil; timeout filter applies |

#### Auto event selection (priority and tier ordering)

| # | Test function | Scenario | Setup | Expected |
|---|---|---|---|---|
| 7 | `test_07_single_inprogress_winner` | Single in-progress winner, light on | A: in, 3-1; light on; turn_on_light=true | → TL_ANIM, `set_animation()` |
| 8 | `test_08_single_final_winner` | Single final winner, light on | A: post, winner=true; light on | → TL_SOLID, `set_solid()` |
| 9 | `test_09_live_priority_config_order` | Two live winners — config order wins | A pos 0, B pos 1; both winning live | A wins (lower index) → TL_ANIM with A |
| 10 | `test_10_live_beats_final` | Live beats final | A: post/winner; B: in/leading | B (live tier > final tier) → TL_ANIM with B |
| 11 | `test_11_final_priority_config_order` | Final-only winners — config order | A pos 1 final-won; B pos 0 final-won | B wins → TL_SOLID with B |

#### Pinned team

| # | Test function | Scenario | Setup | Expected |
|---|---|---|---|---|
| 12 | `test_12_pinned_overrides_priority` | Pinned beats higher-priority auto winner | A pos 0 winning; pin = B (pos 1) winning | B → TL_ANIM with B |
| 13 | `test_13_pinned_bypasses_timeout` | Pinned bypasses timeout filter | pin = A; A timed out but still winning | A still wins (pinned has no timeout gate) |
| 14 | `test_14_pinned_stops_winning` | Pinned team stops winning | pin = A; A now losing; B winning | Pin cleared, falls through to B |
| 15 | `test_15_pinned_no_event` | Pinned slug has no event | pin = A; no event A received | Pin cleared, → nil |
| 16 | `test_16_pin_during_active` | Pin set while another active | TL_ANIM with A; user pins B | → transition to B |
| 16b | `test_16b_repin_no_spurious_hsb` | Repin to different team — no spurious HSB | TL_ANIM with A; user pins B (different color) | → TL_ANIM with B; no spurious IDLE |
| 16c | `test_16c_unpin_secondary_no_spurious_hsb` | Unpin secondary — no spurious HSB | TL_ANIM with B pinned; A auto-winner; unpin | → TL_MUTED with A; no spurious IDLE |
| 17 | `test_17_unpin_with_winner_still_active` | Unpin while active event still winning | TL_ANIM with B pinned; B still winning; user unpins | → TL_MUTED with B staged |
| 17b | `test_17b_unpin_restores_when_no_winners` | Unpin with no winners | TL_ANIM with B pinned; B now losing; user unpins | → TL_IDLE, `_restore_light_state()` |
| 17c | `test_17c_unpin_muted_then_power_on_reactivates` | Unpin → TL_MUTED → power-on reactivates correct color | TL_ANIM with B pinned; unpin → TL_MUTED with A; power on | → TL_ANIM with A's color |
| 17d | `test_17d_activate_then_mute` | □→■→▣: activate then mute | A winning; pin A → TL_ANIM; mute | → TL_MUTED, pin preserved, color staged |
| 17e | `test_17e_mute_unpinned_auto_winner` | ■→▣ on unpinned auto-winner | A winning (no pin); TL_ANIM; mute | → TL_MUTED, no pin, event preserved |
| 17f | `test_17f_unpin_while_muted_restores` | ▣→□ via mute entry path | Pin A → mute → TL_MUTED; deactivate | → TL_IDLE, light restored |
| 17g | `test_17g_power_off_muted_then_unpin_restores` | ▣→□ via power-off entry path | TL_ANIM; power off → TL_MUTED; deactivate | → TL_IDLE, light restored |

#### TL_MUTED — entry paths

| # | Test function | Scenario | Setup | Expected |
|---|---|---|---|---|
| 18 | `test_18_power_off_during_anim` | User turns light off during TL_ANIM | TL_ANIM, A winning; Power1#State=0 fires | → TL_MUTED, animation stopped, event preserved |
| 19 | `test_19_power_off_during_solid` | User turns light off during TL_SOLID | TL_SOLID, A finalist; Power1#State=0 fires | → TL_MUTED, event preserved |
| 20 | `test_20_inprogress_light_off_no_auto_on` | New in-progress event, light off, turn_on_light=false | A in/winning; light off; turn_on_light=false | → TL_MUTED, color staged via `light.set()` |
| 21 | `test_21_final_light_off_no_auto_on` | New final event, light off, turn_on_light=false | A post/winner; light off; turn_on_light=false | → TL_MUTED, color staged via `light.set()` |

#### TL_MUTED — exit paths

| # | Test function | Scenario | Setup | Expected |
|---|---|---|---|---|
| 22 | `test_22_power_on_muted_inprogress` | Power-on while muted (in-progress event) | TL_MUTED, A in/winning; Power1#State=1 fires | → TL_ANIM with A |
| 22b | `test_22b_power_on_muted_updates_saved_light` | Power-on while muted updates `saved_light.power` | TL_MUTED; power-off set `saved_light.power=false`; user powers on | `saved_light.power` updated to `true` before re-activating |
| 23 | `test_23_power_on_muted_final` | Power-on while muted (final event) | TL_MUTED, A post/winner; Power1#State=1 fires | → TL_SOLID with A |
| 24 | `test_24_pin_overrides_muted` | Manual pin overrides muted | TL_MUTED; user pins B winning | user_initiated=true → TL_ANIM/TL_SOLID with B |
| 25 | `test_25_timeout_while_muted` | Event timeout while muted | TL_MUTED; timeout fires | → TL_IDLE, `_restore_light_state()` |
| 26 | `test_26_update_while_muted` | New MQTT update while muted, different winner | TL_MUTED with A; B now higher priority winner | Stays TL_MUTED, staged color updates to B |

#### Update idempotency and progression

| # | Test function | Scenario | Setup | Expected |
|---|---|---|---|---|
| 27 | `test_27_duplicate_event` | Duplicate event (same slug + timestamp) | TL_ANIM with A; receive identical event | `_event_unchanged()` → no-op |
| 28 | `test_28_newer_timestamp` | Same team, newer timestamp, same status | TL_ANIM with A; receive A with newer last_updated | Timer reset; no light change |
| 29 | `test_29_inprogress_to_final` | In-progress → final for active team | TL_ANIM with A; receive A post/winner | → TL_SOLID with A, animation cleared |

#### Manual light changes (HSB rule)

| # | Test function | Scenario | Setup | Expected |
|---|---|---|---|---|
| 30 | `test_30_hue_change` | User changes hue manually | TL_SOLID; HSBColor fires with different hue | `saved_light` cleared, → TL_IDLE (no restore) |
| 31 | `test_31_sat_change` | User changes saturation manually | TL_ANIM; HSBColor fires with different sat | Same as #30 → TL_IDLE |
| 32 | `test_32_bri_only_anim` | User changes brightness only (TL_ANIM) | TL_ANIM; HSBColor fires same hue/sat, new bri | Update `saved_light.bri`; state unchanged |
| 33 | `test_33_bri_only_solid` | User changes brightness only (TL_SOLID) | TL_SOLID; HSBColor fires same hue/sat, new bri | Update saved_light.bri; state unchanged |

#### Timeout and restore

| # | Test function | Scenario | Setup | Expected |
|---|---|---|---|---|
| 34 | `test_34_timeout_switches_team` | Timeout, another team still winning | TL_SOLID with A; A timeout fires; B still winning | → TL_ANIM/TL_SOLID with B (no full restore) |
| 35 | `test_35_timeout_no_winners` | Timeout, no winners remaining | TL_SOLID with A; A timeout fires; no other winners | → TL_IDLE, `_restore_light_state()`, saved_light cleared |

#### Saved light state (save/restore)

| # | Test function | Scenario | Setup | Expected |
|---|---|---|---|---|
| 36 | `test_36_save_light_state_first_call` | First save captures current light | light set to known state | `saved_light` populated; persist called once |
| 37 | `test_37_save_light_state_idempotent_same_endtime` | Save with same end_time is no-op | save called twice with same end_time | No extra persist call |
| 38 | `test_38_save_light_state_updates_endtime` | Save with new end_time updates | save called with 9000 then 9999 | `end_time` updated to 9999 |
| 39 | `test_39_restore_light_state_power_on` | Restore sends Backlog cmd when power was on | saved_light.power=true | `Backlog0 Color2 …; Dimmer …` sent; saved_light cleared |
| 40 | `test_40_restore_light_state_power_off_uses_lightset` | Restore uses light.set when power was off | saved_light.power=false | `light.set()` called; power stays off; saved_light cleared |
| 41 | `test_41_restore_light_state_no_saved_light` | Restore is no-op when no saved state | saved_light=nil | No cmd sent |

#### Lifecycle

| # | Test function | Scenario | Setup | Expected |
|---|---|---|---|---|
| 42 | `test_42_save_idempotent` | save_light_state idempotency via MQTT re-deliver | TL_ANIM; same event re-delivered | No extra persist call |
| 43 | `test_43_oauth_reconnect` | OAuth updated triggers MQTT reconnect | Service running; OAuth=UPDATED rule fires | `mqtt.connect()` re-called; subscriptions re-fire on `on_connect` |
| 44 | `test_44_boot_with_saved_light` | Boot with persisted saved_light, no events | Fresh service start; persist contains saved_light | mode = TL_IDLE; saved_light preserved until event or manual override |
