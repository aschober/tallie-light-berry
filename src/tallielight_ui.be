import strict
import string
import introspect
import webserver
import tallielight_env
import json

# Use solidified OAuthService if available in firmware, otherwise fall back to .tapp module
# Store in global so references can be nil'd out during unload to free memory
var _oa_class = introspect.get(global, 'OAuthService')
if _oa_class != nil
  # FOR DEBUG: override oauth service in fw with local .tapp version
  # global._oauth_service = introspect.module("oauth", true)
  global._oauth_service = _oa_class()
else
  global._oauth_service = introspect.module("oauth", true)
end
global._tallielight_service = introspect.module("tallielight", true)

# Capture .tapp archive path for loading template files at runtime
var _wd = tasmota.wd

# Lightweight module returned to autoexec.be - only holds get_driver
var tallielight_ui = module('tallielight_ui')

# TallieLight_UI: Tasmota Driver that defines the web UI and configuration
class TallieLight_UI
  # Pre-built format strings for web_sensor() scoreboard rendering (allocated once at class definition)
  # The non-clickable version (_pre_plain) is a <pre> with monospace font
  static _pre_plain = "<pre style='margin:0;font-family:monospace;font-size:14px;display:inline-block;'>%s</pre>"
  # The clickable version (_pre_click) cycles the indicator through three states:
  # □ = inactive           → activate-team-light  → ■
  # ■ = active+on          → mute-team-light      → ▣
  # ▣ = muted(active+off)  → unpin-team-light     → □
  static _pre_click = "<pre data-slug='%s' onclick=\"var sl=this.dataset.slug,si=this.querySelector('.si'),cur=si?si.innerHTML:'',b;if(cur=='\\u25a0'){b='mute-team-light='+sl;if(si)si.innerHTML='\\u25a3'}else if(cur=='\\u25a3'){b='unpin-team-light=1';document.querySelectorAll('.si').forEach(function(e){e.innerHTML='\\u25a1'})}else{document.querySelectorAll('.si').forEach(function(e){e.innerHTML='\\u25a1'});b='activate-team-light='+sl;if(si)si.innerHTML='\\u25a0'}fetch('/tl',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:b})\" style='margin:0;font-family:monospace;font-size:14px;display:inline-block;cursor:pointer;'>%s</pre>"

  def init()

    # register driver and call web_add_handler
    tasmota.add_driver(self)
    self.web_add_handler()

    # Start TallieLight service if time is initialized
    var rtc = tasmota.rtc()
    # print(format("SPU: RTC at init: %s", rtc))
    if (rtc["utc"] != nil && rtc["utc"] > 1000000000)
      # RTC initialized, safe to start service
      tasmota.defer(def () global._tallielight_service.run_from_conf() end)
    else
      # RTC not initialized yet, add rule to start service once time is ready
      tasmota.add_rule_once("Time#Initialized", def ()
        global._tallielight_service.run_from_conf()
      end, "tallielight_run")
    end
  end

  ##############################################################################
  # Called when the extension is unloaded from memory
  # Required for proper extension lifecycle management
  ##############################################################################
  def unload()
    print("SPU: TallieLight extension unloading…")

    # Remove the Time#Initialized rule if it exists (in case unload before time init)
    tasmota.remove_rule("Time#Initialized", "tallielight_run")

    # Stop the TallieLight service
    global._tallielight_service.unload()
    # Stop the OAuth service
    global._oauth_service.unload()

    # Remove web handlers
    webserver.remove_route("/tl", webserver.HTTP_GET)
    webserver.remove_route("/tl", webserver.HTTP_POST)

    # Remove this driver
    tasmota.remove_driver(self)

    # Clear all global references to allow GC to free module memory
    global._tallielight_ui = nil
    global._tallielight = nil
    global._oauth_service = nil
    global._tallielight_service = nil

    print("SPU: TallieLight extension unloaded")
  end

  ##############################################################################
  # Callback method for adding a button to the main menu
  # The button redirects to '/tl?'
  ##############################################################################
  # def web_add_main_button()
  #   webserver.content_send("<p></p><form id=sl action='tl' style='display: block;' method='get'><button>Sports Settings</button></form>")
  # end

  ##############################################################################
  # Callback method for adding a button to the config menu
  # The button redirects to '/tl?'
  ##############################################################################
  def web_add_config_button()
    webserver.content_send("<p></p><form id=sl_conf action='tl' style='display: block;' method='get'><button>Tallie Light</button></form>")
  end
  
  ##############################################################################
  # Callback method to add a badge to top right of home page
  ##############################################################################
  # def web_status_line_right()
  #   if (global._oauth_service.is_authorized(false))
  #       webserver.content_status_sticker("SPORTS")
  #   end
  # end

  ##############################################################################
  # Callback method to display sensor information on the main Web UI
  ##############################################################################
  def web_sensor()
    if (global._tallielight == nil)
      self._send_centered_message("Tallie Light not running")
      return
    end

    # Check OAuth authorization status
    var is_oauth_authorized = global._oauth_service.is_authorized(false)
    var is_mqtt_connected = (global._tallielight.mqtt != nil && global._tallielight.mqtt.connected())

    # Handle OAuth/connection status
    if !is_oauth_authorized
      self._send_centered_message("Not Logged In")
      return
    end

    if !is_mqtt_connected
      self._send_centered_message("No Connection")
      return
    end

    # Get all configured teams and their scoreboard displays
    var team_configs = global._tallielight.config.team_configs

    if team_configs == nil || team_configs.size() == 0
      self._send_centered_message("No Teams Configured")
      return
    end

    # Store active slug on table element for JS click handlers to initialize from
    var active_slug = (global._tallielight.state.active_event != nil) ? global._tallielight.state.active_event.competitor_slug : ''

    # Start the scoreboard table
    webserver.content_send(format("<table id='slt' data-active-slug='%s' style='width:100%%'>", active_slug))

    var row_count = 0
    var teams_per_row = 2

    # First pass: collect teams with events to determine total count
    var teams_with_events = []
    for i: 0..team_configs.size()-1
      var team_slug = team_configs[i]['teamSlug']
      if global._tallielight.last_events.contains(team_slug)
        teams_with_events.push(i)
      end
    end

    var total_teams_to_display = teams_with_events.size()

    # Second pass: display only teams with events
    for idx: 0..total_teams_to_display-1
      var i = teams_with_events[idx]
      var team_slug = team_configs[i]['teamSlug']
      var team_color = team_configs[i].find('selectedColor', '#000000')

      # Get the team event (we know it exists since we filtered in first pass)
      var team_event = global._tallielight.last_events[team_slug]
      var team_league = team_event.league_short_display_name != nil ? team_event.league_short_display_name : ''

      var is_winning = (team_event != nil && team_event.is_winning())
      var is_active_event = (global._tallielight.state.active_event != nil &&
                             global._tallielight.state.active_event.competitor_slug == team_slug)

      # ■ (&#9632) filled square = active + light on (TL_SOLID/TL_ANIM)
      # ▣ (&#9635) square with fill = active + light off (TL_MUTED)
      # □ (&#9633) outline square = winning but not active
      var indicator_color = nil
      var indicator_char = nil
      if is_active_event
        indicator_color = team_color
        var mode = global._tallielight.state.mode
        indicator_char = (mode == global._tallielight_service.TL_MUTED) ? "&#9635;" : "&#9632;"
      elif is_winning
        indicator_color = team_color
        indicator_char = "&#9633;"
      end

      # Create a scoreboard for this team event
      var scoreboard = self._get_team_scoreboard(team_event, team_league, indicator_color, indicator_char)

      # Start new row if needed
      if row_count % teams_per_row == 0
        webserver.content_send("<tr>")
      end

      # Determine text alignment and padding based on column position
      var padding = "0px"
      var text_align = "center"
      var colspan = ""
      if total_teams_to_display == 1
        # Single game - center it by spanning both columns
        colspan = " colspan='2'"
      else
        # Multiple games - use standard two-column layout
        var is_right_column = (row_count % teams_per_row == 1)
        padding = is_right_column ? "0px 0px 0px 6px" : "0px 6px 0px 0px"
        text_align = is_right_column ? "left" : "right"
      end
      # Add team cell
      webserver.content_send(format("<td style='padding: %s; vertical-align: middle; width: 50%%; text-align: %s;'%s>", padding, text_align, colspan))

      # Wrap with _pre_click if active or winning, otherwise just _pre_plain
      if is_active_event || is_winning
        webserver.content_send(format(self._pre_click, team_slug, scoreboard))
      else
        webserver.content_send(format(self._pre_plain, scoreboard))
      end
      webserver.content_send("</td>")

      row_count += 1
      # Close row if we've reached teams_per_row or this is the last team
      if row_count % teams_per_row == 0 || idx == total_teams_to_display - 1
        # Fill empty cell if odd number of teams on last row (but not for single centered game)
        if idx == total_teams_to_display - 1 && row_count % teams_per_row != 0 && total_teams_to_display != 1
          webserver.content_send("<td></td>")
        end
        webserver.content_send("</tr>")
      end
    end

    # Show helpful message if no teams have scheduled games
    if total_teams_to_display == 0
      webserver.content_send("<tr><td colspan='2' style='text-align: center; padding: 20px;'><p>No Upcoming Games</p></td></tr>")
    end

    # Add a horizontal rule after all teams
    webserver.content_send("<tr><td colspan='2' style='font-size:2px'><hr></td></tr>")
    webserver.content_send("</table>")
  end

  ##############################################################################
  # Called at Tasmota start-up, once Wifi/Eth is up and web server is running
  ##############################################################################
  def web_add_handler()
    # we need to register a closure that captures the current instance
    webserver.on("/tl", / -> self._page_tallielight_ui(), webserver.HTTP_GET)
    webserver.on("/tl", / -> self._page_tallielight_ui_handler(), webserver.HTTP_POST)
  end

  ##############################################################################
  # Stream the oauth object as JSON one field at a time. Avoids building the full
  # map dump on the heap.
  ##############################################################################
  def _send_oauth_json(oauth_data)
    webserver.content_send("{")
    var first = true
    for k : oauth_data.keys()
      var v = oauth_data[k]
      if v == nil continue end
      if !first webserver.content_send(",") end
      webserver.content_send(format("\"%s\":", k))
      if type(v) == 'string'
        webserver.content_send(format("\"%s\"", v))
      else
        webserver.content_send(str(v))
      end
      first = false
    end
    webserver.content_send("}")
  end

  ##############################################################################
  # Helper method to send config values and HTML template file
  # Send config values as inline <script> then stream HTML file (but skip line 1)
  ##############################################################################
  def _send_page_with_config(filename, conf, oauth_data, api_url)
    # send conf as single JSON dump but oauth_data as streamed field-by-field.
    # GC between the two so per-field fragments don't pile up.
    webserver.content_send("<script>let conf=")
    webserver.content_send(conf.toJson())
    tasmota.gc()
    webserver.content_send(",oauth=")
    self._send_oauth_json(oauth_data)
    webserver.content_send(';const apiUrl="')
    webserver.content_send(api_url)
    webserver.content_send('";</script>')

    # Prefix with .tapp archive path for accessing files within the archive
    var filepath = filename
    if _wd != nil && size(_wd) > 0
      filepath = _wd + filename
    end
    # print(format("SPU: Loading template from %s", filepath))

    # Stream the HTML file in small chunks to avoid large string allocations
    # Minified HTML has long multi-KB lines.
    try
      var file = open(filepath, "r")
      var chunk = file.readbytes(256)
      while size(chunk) > 0
        webserver.content_send(chunk.asstring())
        chunk = file.readbytes(256)
      end
      file.close()
    except .. as e, m
      print(format("SPU: Error loading template %s: %s - %s", filename, e, m))
      webserver.content_send(format("<p>Error loading template: %s</p>", filename))
      return
    end
  end

  ##############################################################################
  # Helper method to display a centered error/status message
  ##############################################################################
  def _send_centered_message(message)
    webserver.content_send(format("<div style='text-align: center; padding: 20px;'><p>%s</p></div>", message))
    webserver.content_send("<div style='font-size:2px'><hr></div>")
  end

  ##############################################################################
  # Helper method to generate an ASCII scoreboard for a team event
  # event: the TallieLightEvent object to display
  # league: display string of the league shown at top (e.g., "NBA", "NFL")
  # indicatorColor: if not nil, adds a colored square next to competitor's team
  # indicatorChar: HTML entity for the indicator (&#9632; filled or &#9633; outline)
  ##############################################################################
  def _get_team_scoreboard(event, league, indicator_color, indicator_char)
    var comp_home_away = event.competitor_home_away

    # Prepare the square indicator column (always 2 chars visible: space + square or two spaces)
    var comp_indicator = (indicator_color != nil && indicator_char != nil) ?
      format(" <span class='si' style='color:%s;'>%s</span>", indicator_color, indicator_char) : "  "
    var opp_indicator = "  "

    # Determine which team gets the indicator (common to all branches)
    var away_indicator = (comp_home_away == false) ? comp_indicator : opp_indicator
    var home_indicator = (comp_home_away == true) ? comp_indicator : opp_indicator

    # Shared border string used for top (if league is empty) and bottom
    var full_border = "+--------------+"
    # Create top border with league name, falling back to plain border if league is empty
    var top_border = size(league) > 0 ? format("+ %s %s+", league, "-" * (12 - size(league))) : full_border

    # Build the middle line and team lines based on game status
    var middle_line
    var away_line
    var home_line
    var has_scores = (event.is_in_progress() || event.is_final())

    if has_scores
      var teams = self._get_away_home_teams(comp_home_away, event.competitor_abbreviation, event.opponent_abbreviation, event.competitor_score, event.opponent_score, true)
      var away_team = teams[0]
      var away_score = teams[1]
      var home_team = teams[2]
      var home_score = teams[3]
      away_line = away_team + away_indicator + (" " * (7 - size(away_team))) + format("%3s", away_score)
      home_line = home_team + home_indicator + (" " * (7 - size(home_team))) + format("%3s", home_score)
      var comp_status_detail = event.competition_status_short_detail
      middle_line = (" " * (12 - size(comp_status_detail))) + "<b>" + comp_status_detail + "</b>"
      # Bold winner and gray out loser for final games
      if event.is_final()
        if away_score > home_score
          away_line = "<b>" + away_line + "</b>"
          home_line = "<span style='color:#666'>" + home_line + "</span>"
        elif home_score > away_score
          home_line = "<b>" + home_line + "</b>"
          away_line = "<span style='color:#666'>" + away_line + "</span>"
        end
      end
    else
      # No scores — scheduled, postponed, or other status
      var teams = self._get_away_home_teams(comp_home_away, event.competitor_abbreviation, event.opponent_abbreviation, event.competitor_score, event.opponent_score, false)
      away_line = teams[0] + away_indicator + (" " * (10 - size(teams[0])))
      home_line = teams[1] + home_indicator + (" " * (10 - size(teams[1])))

      if event.is_scheduled()
        # Show date/time for scheduled games
        var rtc = tasmota.rtc()
        var current_local_time = tasmota.time_dump(rtc['local'])
        var timezone_offset = rtc['timezone']
        var comp_date_epoch = event.competition_date['epoch'] + (timezone_offset * 60)
        var comp_date = tasmota.time_dump(comp_date_epoch)
        var date_string = format("%2d/%2d", comp_date['month'], comp_date['day'])
        if (comp_date['year'] == current_local_time['year'] &&
            comp_date['month'] == current_local_time['month'] &&
            comp_date['day'] == current_local_time['day'])
          date_string = tasmota.strftime("%l:%M %p", comp_date_epoch)
        end
        middle_line = (" " * (12 - size(date_string))) + "<b>" + date_string + "</b>"
      else
        middle_line = format("%12s", event.competition_status_short_detail)
      end
    end

    return format("%s\n| %s |\n| %s |\n| %s |\n%s",
      top_border, middle_line, away_line, home_line, full_border)
  end

  ##############################################################################
  # Structural equality check for two team_configs lists.
  # Avoids the json.dump-then-string-compare pattern (which would allocate two
  # multi-hundred-byte strings on the heap just to throw them away). Each entry
  # is a flat map of string fields, so a per-key comparison is enough.
  ##############################################################################
  def _team_configs_equal(a, b)
    if a == nil || b == nil return a == b end
    if size(a) != size(b) return false end
    var keys = ["league", "teamSlug", "teamAbbrev", "teamName", "selectedColor"]
    for i: 0..size(a) - 1
      var ea = a[i]
      var eb = b[i]
      for k : keys
        if ea.find(k, nil) != eb.find(k, nil) return false end
      end
    end
    return true
  end

  ##############################################################################
  # Helper method to determine away/home teams based on competitor home/away boolean
  # Returns [awayTeam, homeTeam] if showScores is false
  # Returns [awayTeam, awayScore, homeTeam, homeScore] if showScores is true
  ##############################################################################
  def _get_away_home_teams(comp_home_away, comp_abbrev, opp_abbrev, comp_score, opp_score, show_scores)
    if show_scores
      if comp_home_away == false
        return [comp_abbrev, comp_score, opp_abbrev, opp_score]
      else
        return [opp_abbrev, opp_score, comp_abbrev, comp_score]
      end
    else
      if comp_home_away == false
        return [comp_abbrev, opp_abbrev]
      else
        return [opp_abbrev, comp_abbrev]
      end
    end
  end

  #######################################################################
  # Display the page on `/sl`
  #######################################################################
  def _page_tallielight_ui()
    if !webserver.check_privileged_access() return nil end

    # if TallieLightService is not running, try to start it
    if (global._tallielight == nil)
      global._tallielight_service.run_from_conf()
    end

    # Compact heap before sending page to minimize fragmentation
    tasmota.gc()

    # title of the web page
    webserver.content_start("Tallie Light")
    # send standard Tasmota styles
    webserver.content_send_style()

    # read configuration
    var conf = global._tallielight.config
    if conf == nil
      webserver.content_send("<div style='text-align: center; padding: 20px;'><p>Error: Unable to read Tallie Light configuration</p></div>")
      # webserver.content_button(webserver.BUTTON_CONFIGURATION)
      webserver.content_button(webserver.BUTTON_MAIN)
      webserver.content_stop()
      return
    end

    # get oauth data
    # Drop the long oa_at JWT and replace it with oa_has_at bool so the
    # page payload stays small. JS fetches the actual token lazily via
    # POST /sl with body=get-token=1 only when it needs to call the backend API.
    var oauth_data = global._oauth_service.read_all_oauth_data()
    oauth_data["oa_has_at"] = oauth_data["oa_at"] != nil
    oauth_data.remove("oa_at")
    var access_token_expiry_time = oauth_data["oa_ate"]
    var current_time = tasmota.rtc()["utc"]
    oauth_data["is_token_valid"] = access_token_expiry_time != nil && access_token_expiry_time > current_time

    print(format("SPU: mem pre-conf: %s", tasmota.memory().find("heap_free", "?")))
    self._send_page_with_config("tallielight_ui_min.html", conf, oauth_data, tallielight_env.BACKEND_URL)
    print(format("SPU: mem post-html: %s", tasmota.memory().find("heap_free", "?")))
    # button back to previous page
    # webserver.content_button(webserver.BUTTON_CONFIGURATION)
    webserver.content_button(webserver.BUTTON_MAIN)

    # end of web page
    webserver.content_stop()

    # do a gc and print memory debug information
    print(format("SPU: memory pre-gc: %s", tasmota.memory()))
    tasmota.gc()
    print(format("SPU: memory post-gc: %s", tasmota.memory()))

  end

  #######################################################################
  # Handle POST actions from `/sl`
  #######################################################################
  def _page_tallielight_ui_handler()
    if !webserver.check_privileged_access() return nil end

    try
      # Lazy access-token fetch from JavaScript. The page render no longer sends the
      # long JWT token inline; JS calls this only when it actually needs to authorize
      # a backend API request and then the token is gc'd. Returns 401 when no valid token.
      if webserver.has_arg("get-token")
        if !global._oauth_service.is_authorized(false)
          webserver.content_open(401, "application/json")
          webserver.content_send('{"error":"unauthorized"}')
          webserver.content_close()
          return
        end
        var token = global._oauth_service.read_all_oauth_data().find("oa_at")
        webserver.content_open(200, "application/json")
        webserver.content_send(format("{\"oa_at\":\"%s\"}", token))
        webserver.content_close()
        token = nil
        tasmota.gc()
        return
      end

      # Handle polling check from JavaScript (acts as proxy to avoid CORS)
      # Returns JSON with updated OAuth state instead of page redirect
      if webserver.has_arg("poll-oauth")
        print("SPU: Polling OAuth status check")
        # Only poll oauth if a device-flow is actually pending. Without
        # this guard, a stale JS poll arriving after auth completed would
        # call /oauth2/token with no device_code and write a misleading
        # "missing device_code" error to oa_err.
        var snapshot = global._oauth_service.read_all_oauth_data()
        if snapshot.find("oa_dc") != nil
          global._oauth_service.complete_authorization_flow()
        end

        # Build a fresh small response map. The JS only needs to know whether
        # an access token now exists (to trigger reload); never ship the full
        # JWT down this path. The page render uses the same oa_has_at bool.
        var oauth_data = global._oauth_service.read_all_oauth_data()
        var access_token_expiry_time = oauth_data.find("oa_ate")
        var current_time = tasmota.rtc()["utc"]
        var resp = {
          "oa_has_at": oauth_data.find("oa_at") != nil,
          "oa_ate": access_token_expiry_time,
          "oa_uc": oauth_data.find("oa_uc"),
          "oa_vuc": oauth_data.find("oa_vuc"),
          "oa_pi": oauth_data.find("oa_pi"),
          "oa_err": oauth_data.find("oa_err"),
          "oa_email": oauth_data.find("oa_email"),
          "is_token_valid": access_token_expiry_time != nil && access_token_expiry_time > current_time,
        }

        webserver.content_open(200, "application/json")
        webserver.content_send(json.dump(resp))
        webserver.content_close()
        return
      end

      # Handle scoreboard click to unpin team light
      if webserver.has_arg("unpin-team-light")
        if global._tallielight != nil
          global._tallielight.activate_team_light(nil)
        end
        webserver.redirect("/")
        return
      end

      # Handle scoreboard click to mute team light (■ → ▣)
      if webserver.has_arg("mute-team-light")
        if global._tallielight != nil
          global._tallielight.mute_team_light()
        end
        webserver.redirect("/")
        return
      end

      # Handle scoreboard click to activate team light
      if webserver.has_arg("activate-team-light")
        var team_slug = webserver.arg("activate-team-light")
        if global._tallielight != nil
          global._tallielight.activate_team_light(team_slug)
        end
        webserver.redirect("/")
        return
      end

      # Handle Tallie Light configuration update
      if webserver.has_arg("update-config")
        print("SPU: Update Config")
        var existing_conf = global._tallielight.config
        var updated_conf = global._tallielight_service.TLConfig()
        if webserver.has_arg("team-configs")
          try
            updated_conf.team_configs = json.load(webserver.arg("team-configs"))
          except ..
            print("SPU: Invalid JSON in team-configs, keeping existing config")
            updated_conf.team_configs = existing_conf.team_configs
          end
        else
          updated_conf.team_configs = existing_conf.team_configs
        end
        var lrm_raw = webserver.has_arg("light-restore") ? webserver.arg("light-restore") : nil
        var lrm
        if lrm_raw != nil
          try lrm = int(lrm_raw) except .. lrm = existing_conf.light_restore_mins end
        else
          lrm = existing_conf.light_restore_mins
        end
        if lrm < 1  lrm = 1 end
        if lrm > 1440  lrm = 1440 end
        updated_conf.light_restore_mins = lrm
        updated_conf.turn_on_light = webserver.has_arg("turn-on-light") ? (webserver.arg("turn-on-light") == 'true' || webserver.arg("turn-on-light") == 'on') : existing_conf.turn_on_light
        updated_conf.animation_type = webserver.has_arg("animation-type") ? webserver.arg("animation-type") : existing_conf.animation_type
        updated_conf.saved_light = existing_conf.saved_light

        # Detect changes — scalars first (cheap), team_configs last (allocates nothing).
        var changed = (updated_conf.light_restore_mins != existing_conf.light_restore_mins ||
                       updated_conf.turn_on_light != existing_conf.turn_on_light ||
                       updated_conf.animation_type != existing_conf.animation_type ||
                       !self._team_configs_equal(updated_conf.team_configs, existing_conf.team_configs))
        if changed
          print("SPU: Config changed, updating…")
          # print(format("%s", updatedConf.tostring()))
          global._tallielight_service.persist_conf(updated_conf)
          global._tallielight_service.unload()
          global._tallielight_service.run_from_conf()
        else
          print("SPU: No changes detected in config")
        end

        webserver.redirect("/cn?")
        return # Important to exit after redirect
      end

      # Handle OAuth actions
      if webserver.has_arg("oa-action")
        var action = webserver.arg("oa-action")
        print(format("SPU: Action Start - %s", action))
        if (action == "initiate")
          global._oauth_service.initiate_authorization_flow()
        elif (action == "complete")
          global._oauth_service.complete_authorization_flow()
        elif (action == "refresh")
          global._oauth_service.refresh_access_token_flow()
        elif (action == "clear_pending")
          global._oauth_service.clear_pending_oauth_data()
        elif (action == "clear_all")
          if global._tallielight != nil
            global._tallielight._stop()
          end
          global._oauth_service.delete_all_oauth_data()
        else
          print(format("SPU: Unknown action '%s'", str(action)))
        end
        print(format("SPU: Action Finish - %s", action))
        
        # tallielight_html = nil # Reset HTML template to force reload
        webserver.redirect("/tl")
        return # Important to exit after redirect
      end

      raise "value_error", "Unknown command"

    except .. as e, m
      print(format("SPU: Exception> '%s' - %s", e, m))
      # display error page with sanitized exception messages
      var se = string.replace(string.replace(str(e), "&", "&amp;"), "<", "&lt;")
      var sm = string.replace(string.replace(str(m), "&", "&amp;"), "<", "&lt;")
      webserver.content_start("Tallie Light Error")
      webserver.content_send_style()
      webserver.content_send(format("<p style='width:340px;'><b>Exception:</b><br>'%s'<br>%s</p>", se, sm))
      webserver.content_button(webserver.BUTTON_CONFIGURATION)
      webserver.content_stop()
    end
  end
end

# Get or create the driver instance for extension registration
tallielight_ui.get_driver = def ()
  if global._tallielight_ui == nil
    global._tallielight_ui = TallieLight_UI()
  end
  return global._tallielight_ui
end

# For standalone use (not as extension), create driver immediately
if tasmota && tasmota.wd == nil
  tallielight_ui.get_driver()
end

return tallielight_ui
