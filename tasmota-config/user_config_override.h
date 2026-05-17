/*
  user_config_override.h - user configuration overrides my_user_config.h for Tasmota

  Copyright (C) 2021  Theo Arends

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

#ifndef _USER_CONFIG_OVERRIDE_H_
#define _USER_CONFIG_OVERRIDE_H_

/*****************************************************************************************************\
 * USAGE:
 *   To modify the stock configuration without changing the my_user_config.h file:
 *   (1) copy this file to "user_config_override.h" (It will be ignored by Git)
 *   (2) define your own settings below
 *
 ******************************************************************************************************
 * ATTENTION:
 *   - Changes to SECTION1 PARAMETER defines will only override flash settings if you change define CFG_HOLDER.
 *   - Expect compiler warnings when no ifdef/undef/endif sequence is used.
 *   - You still need to update my_user_config.h for major define USE_MQTT_TLS.
 *   - All parameters can be persistent changed online using commands via MQTT, WebConsole or Serial.
\*****************************************************************************************************/

/*
Examples :

// -- Master parameter control --------------------
#undef  CFG_HOLDER
#define CFG_HOLDER        4617                   // [Reset 1] Change this value to load SECTION1 configuration parameters to flash

// -- Setup your own Wifi settings  ---------------
#undef  STA_SSID1
#define STA_SSID1         "YourSSID"             // [Ssid1] Wifi SSID

#undef  STA_PASS1
#define STA_PASS1         "YourWifiPassword"     // [Password1] Wifi password

// -- Setup your own MQTT settings  ---------------
#undef  MQTT_HOST
#define MQTT_HOST         "your-mqtt-server.com" // [MqttHost]

#undef  MQTT_PORT
#define MQTT_PORT         1883                   // [MqttPort] MQTT port (10123 on CloudMQTT)

#undef  MQTT_USER
#define MQTT_USER         "YourMqttUser"         // [MqttUser] Optional user

#undef  MQTT_PASS
#define MQTT_PASS         "YourMqttPass"         // [MqttPassword] Optional password

// You might even pass some parameters from the command line ----------------------------
// Ie:  export PLATFORMIO_BUILD_FLAGS='-DUSE_CONFIG_OVERRIDE -DMY_IP="192.168.1.99" -DMY_GW="192.168.1.1" -DMY_DNS="192.168.1.1"'

#ifdef MY_IP
#undef  WIFI_IP_ADDRESS
#define WIFI_IP_ADDRESS     MY_IP                // Set to 0.0.0.0 for using DHCP or enter a static IP address
#endif

#ifdef MY_GW
#undef  WIFI_GATEWAY
#define WIFI_GATEWAY        MY_GW                // if not using DHCP set Gateway IP address
#endif

#ifdef MY_DNS
#undef  WIFI_DNS
#define WIFI_DNS            MY_DNS               // If not using DHCP set DNS IP address (might be equal to WIFI_GATEWAY)
#endif

#ifdef MY_DNS2
#undef  WIFI_DNS2
#define WIFI_DNS2           MY_DNS2              // If not using DHCP set DNS IP address (might be equal to WIFI_GATEWAY)
#endif

// !!! Remember that your changes GOES AT THE BOTTOM OF THIS FILE right before the last #endif !!!
*/
#undef FRIENDLY_NAME
#define FRIENDLY_NAME          "Lampy"
#undef WIFI_DEFAULT_HOSTNAME
#define WIFI_DEFAULT_HOSTNAME  "tallie-%06X"         // [Hostname] Expands to tallie-<last 6 hex chars of MAC address>

#ifndef USE_MQTT_TLS
#define USE_MQTT_TLS
#endif
#ifndef USE_MQTT_AWS_IOT_LIGHT
#define USE_MQTT_AWS_IOT_LIGHT
#endif
#ifndef USE_DISCOVERY
#define USE_DISCOVERY
#endif
#ifndef USE_BERRY_ANIMATION
#define USE_BERRY_ANIMATION
#endif
#ifndef USE_I2C
#define USE_I2C
#endif
#ifndef USE_SEESAW_ENCODER
#define USE_SEESAW_ENCODER
#undef USE_MAX17043
#define SEESAW_ENCODER_LIKE_ROTARY
#define SEESAW_ENCODER_HIDE_WEB_DISPLAY
//#define DEBUG_SEESAW_ENCODER
#endif
#ifndef USE_BERRY_MQTTCLIENT
#define USE_BERRY_MQTTCLIENT
#endif
#ifndef USE_WEBCLIENT_HTTPS
#define USE_WEBCLIENT_HTTPS
#endif
#undef  OTA_URL
#define OTA_URL                "https://ota.tallielight.com/tl-tasmota32.bin"

#ifdef USE_HOME_ASSISTANT
#undef USE_HOME_ASSISTANT
#endif
#ifdef USE_DOMOTICZ
#undef USE_DOMOTICZ
#endif
#ifdef USE_KNX
#undef USE_KNX
#endif
#ifdef USE_KNX_WEB_MENU
#undef USE_KNX_WEB_MENU
#endif
#ifdef USE_TELEGRAM
#undef USE_TELEGRAM
#endif
#ifdef USE_AUTOCONF
#undef USE_AUTOCONF
#endif
#ifdef USE_GPIO_VIEWER
#undef USE_GPIO_VIEWER
#endif
#ifdef USE_ENERGY_SENSOR
#undef USE_ENERGY_SENSOR
#endif
#ifdef USE_IR_REMOTE
#undef USE_IR_REMOTE
#endif
#ifdef USE_IR_RECEIVE
#undef USE_IR_RECEIVE
#endif
#ifdef USE_EMULATION_HUE
#undef USE_EMULATION_HUE
#endif
#ifdef USE_EMULATION_WEMO
#undef USE_EMULATION_WEMO
#endif
#ifdef USE_SHUTTER
#undef USE_SHUTTER
#endif
#ifdef USE_SHELLY_DIMMER
#undef USE_SHELLY_DIMMER
#endif
#ifdef USE_SONOFF_D1
#undef USE_SONOFF_D1
#endif
#ifdef USE_SONOFF_RF
#undef USE_SONOFF_RF
#endif

#endif  // _USER_CONFIG_OVERRIDE_H_
