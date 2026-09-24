# vacuumstreamer

Stream live video and two-way audio from Dreame/3iRobot vacuum cleaners running [Valetudo](https://valetudo.cloud/), with full Home Assistant integration including WebRTC camera, TTS (text-to-speech), and volume controls.

Uses the vacuum's built-in `video_monitor` binary with an `LD_PRELOAD` hook (`vacuumstreamer.so`) to intercept the Agora RTC video pipeline and redirect H.264 frames to a local TCP socket, which [go2rtc](https://github.com/AlexxIT/go2rtc) picks up for WebRTC/RTSP streaming.

Tested on: Dreame L10s Ultra (Allwinner MR813/sun50iw10, ARM64, Athena Linux).

## Features

- **Live video** — H.264 via WebRTC or RTSP, switchable quality profiles
- **Live audio** — Microphone capture from the vacuum
- **Two-way audio** — Talk through the vacuum speaker via WebRTC backchannel
- **Text-to-speech** — Google TTS HTTP endpoint, speak any text through the vacuum
- **Volume control** — Speaker and microphone volume via HTTP API
- **Vacuum controls** — Start/stop/pause/home, operation mode, fan speed, water usage
- **Manual driving** — Remote-control the vacuum with adjustable speed (velocity slider)
- **Room cleaning** — Clean specific rooms by segment ID
- **Video quality switching** — Toggle between low (864×480/15fps/600kbps) and high (864×480/15fps/2Mbps) profiles; both keep the camera's native size, which is the only one the encoder handles
- **Statistics & consumables** — Runtime stats, filter/brush/mop wear monitoring
- **Feature controls** — DND mode, carpet mode, obstacle avoidance, obstacle images, child lock, auto-empty interval
- **Quirk settings** — Carpet sensitivity, mop cleaning frequency, mop wash intensity, pre-wet mops, detergent, carpet-first mode
- **Dock actions** — Trigger dock auto-repair, drain water tank, dock cleaning process, water hookup test
- **Home Assistant integration** — Full dashboard with camera, D-pad driving controls, mode/speed/quality selectors, feature toggles, quirk settings, dock actions, TTS, and volume

## Architecture

```
video_monitor → vacuumstreamer.so (LD_PRELOAD) → TCP :6969 → go2rtc → WebRTC/RTSP
                                                               ↑
                                                    arecord (mic audio)
                                                               ↓ backchannel
                                                    play_pcm.sh → aplay → speaker

tcpsvd :6971 → tts_handler.sh → Google TTS → ffmpeg → aplay → speaker
                               → ogg123 → dmr_player → speaker
                               → amixer (volume control)
                               → Valetudo API proxy (controls, status, drive)
```

## Build

```bash
docker build -t vacuumstreamer .
./run.sh make
```

This cross-compiles `vacuumstreamer.so` for aarch64 using clang.

## Install

### 1. Core files

Copy the compiled library, `video_monitor` binary, and configuration to the vacuum:

```bash
VACUUM_IP=192.168.1.31

ssh root@${VACUUM_IP} "mkdir -p /data/vacuumstreamer"
scp -O vacuumstreamer.so root@${VACUUM_IP}:/data/vacuumstreamer/vacuumstreamer.so
scp -O dist/usr/bin/video_monitor root@${VACUUM_IP}:/data/vacuumstreamer/video_monitor
scp -Or dist/ava/conf/video_monitor/ root@${VACUUM_IP}:/data/vacuumstreamer/ava_conf_video_monitor
```

### 2. go2rtc

```bash
ssh root@${VACUUM_IP}
curl -L https://github.com/AlexxIT/go2rtc/releases/download/v1.9.9/go2rtc_linux_arm64 -o /data/vacuumstreamer/go2rtc
chmod +x /data/vacuumstreamer/go2rtc
```

### 3. ffmpeg (required for still frames and TTS)

```bash
ssh root@${VACUUM_IP}
curl -L https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz -o /tmp/ffmpeg.tar.xz
cd /tmp && tar xf ffmpeg.tar.xz
cp /tmp/ffmpeg-*-arm64-static/ffmpeg /data/vacuumstreamer/ffmpeg
chmod +x /data/vacuumstreamer/ffmpeg
rm -rf /tmp/ffmpeg*
```

### 4. Configuration files

Copy the runtime scripts and go2rtc config:

```bash
scp -O go2rtc.yaml root@${VACUUM_IP}:/data/vacuumstreamer/go2rtc.yaml
scp -O play_pcm.sh root@${VACUUM_IP}:/data/vacuumstreamer/play_pcm.sh
scp -O tts_handler.sh root@${VACUUM_IP}:/data/vacuumstreamer/tts_handler.sh
for f in vacuumstreamer_lib.sh vacuumstreamer_boot.sh go2rtc_launch.sh video_monitor_launch.sh camera_wake.sh camera_supervisor.sh camera_ctl.sh; do
    scp -O "$f" root@${VACUUM_IP}:/data/vacuumstreamer/"$f"
done
ssh root@${VACUUM_IP} "chmod +x /data/vacuumstreamer/*.sh"

# Install the switches once; later deployments keep the robot's copy
scp -O vacuumstreamer.conf root@${VACUUM_IP}:/tmp/vacuumstreamer.conf
ssh root@${VACUUM_IP} "[ -f /data/vacuumstreamer/vacuumstreamer.conf ] || mv /tmp/vacuumstreamer.conf /data/vacuumstreamer/vacuumstreamer.conf"
```

**Important:** Edit `go2rtc.yaml` and update the `candidates` IP address to match your vacuum's IP.

### 5. Certificate workaround

```bash
ssh root@${VACUUM_IP}
cp -r /mnt/private /data/vacuumstreamer/mnt_private_copy
touch /data/vacuumstreamer/mnt_private_copy/certificate.bin
```

See [#1](https://github.com/tihmstar/vacuumstreamer/issues/1) for details.

### 6. Startup script

Copy the boot script to the vacuum:

```bash
scp -O _root_postboot.sh root@${VACUUM_IP}:/data/_root_postboot.sh
ssh root@${VACUUM_IP} "chmod +x /data/_root_postboot.sh"
```

Or append the vacuumstreamer block to your existing `_root_postboot.sh` — see the file for the full contents including WiFi power management, Valetudo startup, ALSA mixer configuration, and service launches.

## Runtime Switches

`/data/vacuumstreamer/vacuumstreamer.conf` turns features on or off. Reboot the robot after changing it. A missing file, missing key or invalid value keeps the original behavior: everything on and the camera login off.

| Switch | Default | Controls |
|---|---|---|
| `CAMERA` | `on` | The camera supervisor, go2rtc and `video_monitor`, plus the Valetudo video capability and its MQTT and Home Assistant entities |
| `CAMERA_MODE` | `on_demand` | `on_demand` captures only while someone watches; `always` keeps `video_monitor` running |
| `CAMERA_IDLE_SECONDS` | `180` | Seconds without a viewer before `on_demand` stops `video_monitor` (30–86400) |
| `CAMERA_LOGIN` | `off` | A username and password for go2rtc's API and RTSP |
| `TTS` | `on` | The Valetudo text-to-speech capability |
| `MAP_MANAGEMENT` | `on` | The Valetudo floor management capability |
| `HTTP_BRIDGE` | `on` | The port 6971 bridge (`tts_handler.sh`, run by `http_bridge.sh`) |
| `HTTP_BRIDGE_ALLOW` | `any` | Addresses allowed to use the bridge, separated by spaces or commas. The robot itself is always allowed; other clients get 403. Read on every request, so no reboot is needed |

The bridge has no login, and it can start cleaning and drive the robot, so set `HTTP_BRIDGE_ALLOW` to your Home Assistant host. The most recently refused address is written to `/tmp/vacuumstreamer/bridge_denied_last`.

The scripts parse the file without executing it and log to `/tmp/vacuumstreamer.log`. The bind mounts and mixer settings apply whichever features are on, so the AVA and audio environment stays the same.

Run the script tests with `sh test/run_tests.sh dash`.

### Camera Modes and Supervision

go2rtc runs whenever the camera is on, but its video source is `camera_wake.sh`. When a viewer connects, go2rtc runs that script, which starts `video_monitor`, waits up to `CAMERA_WAKE_TIMEOUT_SECONDS` (default 15) for its stream port and hands go2rtc the address. The first frame therefore takes a few seconds longer than with a running camera.

`camera_supervisor.sh` starts at boot and checks every `CAMERA_SUPERVISE_SECONDS` (default 5). It:

- restarts go2rtc if it exits, waiting 5, 10, 30 and then 60 seconds between starts that do not last a minute
- in `on_demand` mode, stops `video_monitor` once no viewer has been connected for `CAMERA_IDLE_SECONDS`
- in `always` mode, keeps `video_monitor` running with the same backoff
- restarts `video_monitor` when a viewer is connected but go2rtc has received no video for `CAMERA_STALL_SECONDS` (default 20)

If `video_monitor` exits while someone watches, go2rtc retries its source, which wakes `video_monitor` again. Switching the camera to `always` needs only `CAMERA_MODE=always` and a reboot.

`camera_ctl.sh` is what Valetudo uses to start and stop the stream, and it works by hand too:

- `camera_ctl.sh stop` pauses the camera: go2rtc and `video_monitor` stop and stay stopped, even if a viewer retries, until `camera_ctl.sh start` or a reboot
- `camera_ctl.sh start` resumes the camera and wakes `video_monitor` immediately
- `camera_ctl.sh status` prints the camera, mode, pause, process and viewer state

Runtime state lives in `/tmp/vacuumstreamer`, so a reboot clears a pause.

go2rtc and `video_monitor` both start at nice 10 (`nice -n 10` in `go2rtc_launch.sh` and `video_monitor_launch.sh`), matching Valetudo's own self-imposed priority (`os.setPriority` in `Valetudo.js`) instead of the default nice 0 AVA runs at. On this SoC's 4 cores, a cleaning job alone can push load past 14-20; at that point scheduling order decides who gets the CPU, and video is best-effort, so it should never outrank Valetudo's API/GUI for it. Both still yield to AVA.

### Camera Login

While `CAMERA_LOGIN=off`, anything on the network can use go2rtc's API. That includes `POST /api/config`, which rewrites go2rtc's configuration, and its restart endpoint. Turn the login on unless every device on the robot's network is trusted.

go2rtc reads the credentials from files through its `CREDENTIALS_DIRECTORY` support, so they never appear in `go2rtc.yaml`, the environment or process arguments. Generate a password on your computer, for example with `openssl rand -hex 16`, and keep it in your password manager. Then, on the robot:

```bash
mkdir -p /data/vacuumstreamer/credentials
chmod 700 /data/vacuumstreamer/credentials
printf '%s\n' viewer > /data/vacuumstreamer/credentials/GO2RTC_USERNAME
cat > /data/vacuumstreamer/credentials/GO2RTC_PASSWORD   # paste the password, press Enter, then Ctrl-D
chmod 600 /data/vacuumstreamer/credentials/*
sed -i 's/^CAMERA_LOGIN=.*/CAMERA_LOGIN=on/' /data/vacuumstreamer/vacuumstreamer.conf
reboot
```

Both values may use only letters, digits, `.`, `_`, `~` and `-`, and the password needs at least 16 characters. If the credentials are missing, readable by other users or invalid, go2rtc and `video_monitor` are not started and the reason is written to `/tmp/vacuumstreamer.log`. Starting the stream from Valetudo is refused with the same reason.

Requests from the robot itself are not challenged. Other clients authenticate as follows:

- **RTSP:** `rtsp://viewer:PASSWORD@<VACUUM_IP>:8554/vacuum`
- **API, still frames, HLS and the web UI:** HTTP basic auth, for example `http://viewer:PASSWORD@<VACUUM_IP>:1984/api/frame.jpeg?src=vacuum`

Update Home Assistant's camera and WebRTC card URLs after turning the login on. Backups of `/data` contain the credentials.

## go2rtc Configuration

The `go2rtc.yaml` configures:

- **Video source** — `camera_wake.sh`, which starts `video_monitor` on demand and returns its TCP stream on port 6969
- **Audio source** — `arecord` capturing from the vacuum's microphone
- **Backchannel** — `play_pcm.sh` receives WebRTC audio and plays through the speaker via `aplay`
- **API** — Port 1984 (Web UI at `http://<VACUUM_IP>:1984`)
- **RTSP** — Port 8554 (`rtsp://<VACUUM_IP>:8554/vacuum`)
- **WebRTC** — Port 8555

## Microphone gain and recorder quality (native CLI)

`mic_gain_ctl.sh` and `recorder_quality_ctl.sh` are the native replacements for
this bridge's `/mic_volume` and `/video_quality` endpoints below, used by the
Valetudo plugin's `MicrophoneGainCapability` and `RecorderQualityCapability`.
Unlike the bridge handler, `recorder_quality_ctl.sh` restarts `video_monitor`
through `video_monitor_launch.sh` -- so it lands at Valetudo's own absolute
nice level -- and only when it is already running.

```sh
./mic_gain_ctl.sh get              # {"mic_volume":61,"raw":19}
./mic_gain_ctl.sh set 75           # {"mic_volume":74,"raw":23}

./recorder_quality_ctl.sh get      # {"profile":"low","width":864,"height":480,"framerate":15,"bitrate":600000}
./recorder_quality_ctl.sh set high # {"profile":"high","width":864,"height":480,"framerate":15,"bitrate":2000000}
```

The bridge endpoints remain for now, while Home Assistant is migrated onto
the new capabilities; see the port 6971 retirement note in the project's
`MEMORY.md`.

## TTS & Audio HTTP API

The `tts_handler.sh` script runs via `tcpsvd` on port 6971 and provides:

| Endpoint | Method | Description |
|---|---|---|
| `/say` | POST | Text-to-speech via Google Translate TTS. Body: plain text |
| `/say?text=hello` | GET | TTS via query parameter |
| `/play` | POST | Play raw PCM audio (S16_LE, 16kHz, mono) |
| `/play_ogg` | POST | Play OGG file by path (body: filepath) |
| `/test` | GET | Play the vacuum's locate sound |
| `/volume` | GET | Get speaker volume as JSON: `{"volume":93,"raw":31}` |
| `/volume/N` | GET | Set speaker volume (0–100) |
| `/mic_volume` | GET | Get mic gain as JSON: `{"mic_volume":61,"raw":19}` |
| `/mic_volume/N` | GET | Set mic gain (0–100) |
| `/status` | GET | Get vacuum state (status, battery, mode, fan speed, water usage) |
| `/start` | GET | Start cleaning |
| `/stop` | GET | Stop cleaning |
| `/pause` | GET | Pause cleaning |
| `/home` | GET | Return to dock |
| `/mode` | GET | Get current operation mode |
| `/mode/MODE` | GET | Set mode: `vacuum`, `mop`, `vacuum_and_mop` |
| `/fan_speed` | GET | Get current fan speed |
| `/fan_speed/SPEED` | GET | Set fan speed: `low`, `medium`, `high`, `max` |
| `/water_usage` | GET | Get current water usage level |
| `/water_usage/LEVEL` | GET | Set water usage: `min`, `low`, `medium`, `high`, `max` |
| `/drive/enable` | GET | Enable manual driving mode |
| `/drive/disable` | GET | Disable manual driving mode |
| `/drive/move` | POST | Move vacuum. Body: `{"velocity": -1..1, "angle": -180..180}` |
| `/segments` | GET | List map segments (rooms) |
| `/segments/clean` | POST | Clean rooms. Body: `{"segment_ids": ["1","2"], "iterations": 1}` |
| `/video_quality` | GET | Get current video profile: `{"profile":"low","width":864,"height":480,"framerate":15,"bitrate":600000}` |
| `/video_quality/PROFILE` | GET | Set video profile: `low` (864×480/15fps/600kbps) or `high` (864×480/15fps/2Mbps). Restarts video_monitor |
| `/statistics` | GET | Get vacuum runtime statistics (area, time, count, total) |
| `/consumables` | GET | Get consumable status (filter, brushes, mops, sensors) with remaining % |
| `/dnd` | GET | Get Do Not Disturb mode state |
| `/carpet_mode` | GET | Get carpet detection mode |
| `/obstacle_images` | GET | Get obstacle image capture setting |
| `/obstacle_avoidance` | GET | Get obstacle avoidance setting |
| `/child_lock` | GET | Get child lock state |
| `/auto_empty_interval` | GET | Get auto-empty dustbin interval |
| `/drive/speed` | GET | Get current drive speed (0–100) |
| `/drive/speed/N` | GET | Set drive speed (0–100), affects D-pad velocity |
| `/quirks` | GET | Get all vacuum quirk settings (JSON array) |
| `/quirk/UUID` | GET | Get individual quirk value by UUID: `{"id":"...","value":"..."}` |

### Examples

```bash
# Text-to-speech
curl -X POST -d "Hello from the vacuum" http://192.168.1.31:6971/say

# Set speaker volume to 75%
curl http://192.168.1.31:6971/volume/75

# Get current volume
curl http://192.168.1.31:6971/volume

# Play locate sound
curl http://192.168.1.31:6971/test

# Start cleaning
curl http://192.168.1.31:6971/start

# Set to mop mode
curl http://192.168.1.31:6971/mode/mop

# Manual drive: move forward
curl http://192.168.1.31:6971/drive/enable
curl -X POST -d '{"velocity": 0.3, "angle": 0}' http://192.168.1.31:6971/drive/move
curl http://192.168.1.31:6971/drive/disable

# Clean specific rooms
curl -X POST -d '{"segment_ids": ["3","4"], "iterations": 1}' http://192.168.1.31:6971/segments/clean

# Get current video quality
curl http://192.168.1.31:6971/video_quality

# Switch to high quality
curl http://192.168.1.31:6971/video_quality/high

# Switch back to low quality
curl http://192.168.1.31:6971/video_quality/low

# Get statistics
curl http://192.168.1.31:6971/statistics

# Get consumable status
curl http://192.168.1.31:6971/consumables

# Get feature states
curl http://192.168.1.31:6971/dnd
curl http://192.168.1.31:6971/carpet_mode
curl http://192.168.1.31:6971/obstacle_avoidance

# Set drive speed to 75%
curl http://192.168.1.31:6971/drive/speed/75

# Get all quirk settings
curl http://192.168.1.31:6971/quirks

# Get individual quirk (carpet sensitivity)
curl http://192.168.1.31:6971/quirk/f8cb91ab-a47a-445f-b300-0aac0d4937c0
```

## Home Assistant Integration

### Prerequisites

- [WebRTC Camera](https://github.com/AlexxIT/WebRTC) custom integration (install via HACS)
- [Generic Camera](https://www.home-assistant.io/integrations/generic/) integration (for still image)

### Generic Camera setup

Add a Generic Camera integration in HA with:
- **Still Image URL:** `http://<VACUUM_IP>:1984/api/frame.jpeg?src=vacuum`
- **Stream Source:** `rtsp://<VACUUM_IP>:8554/vacuum`

### configuration.yaml

Add the following to your Home Assistant `configuration.yaml` (replace `192.168.1.31` with your vacuum IP):

```yaml
rest_command:
  # --- Audio Commands ---
  vacuum_say:
    url: "http://192.168.1.31:6971/say"
    method: POST
    content_type: "text/plain"
    payload: "{{ message }}"
    timeout: 30

  vacuum_set_volume:
    url: "http://192.168.1.31:6971/volume/{{ volume }}"
    method: GET

  vacuum_set_mic_volume:
    url: "http://192.168.1.31:6971/mic_volume/{{ volume }}"
    method: GET

  vacuum_test_sound:
    url: "http://192.168.1.31:6971/test"
    method: GET

  vacuum_play_ogg:
    url: "http://192.168.1.31:6971/play_ogg"
    method: POST
    content_type: "text/plain"
    payload: "{{ ogg_path }}"

  # --- Vacuum Control Commands ---
  vacuum_start:
    url: "http://192.168.1.31:6971/start"
    method: GET

  vacuum_stop:
    url: "http://192.168.1.31:6971/stop"
    method: GET

  vacuum_pause:
    url: "http://192.168.1.31:6971/pause"
    method: GET

  vacuum_home:
    url: "http://192.168.1.31:6971/home"
    method: GET

  vacuum_set_mode:
    url: "http://192.168.1.31:6971/mode/{{ mode }}"
    method: GET

  vacuum_set_fan_speed:
    url: "http://192.168.1.31:6971/fan_speed/{{ speed }}"
    method: GET

  vacuum_set_water_usage:
    url: "http://192.168.1.31:6971/water_usage/{{ level }}"
    method: GET

  # --- Manual Drive Commands ---
  vacuum_drive_enable:
    url: "http://192.168.1.31:6971/drive/enable"
    method: GET

  vacuum_drive_disable:
    url: "http://192.168.1.31:6971/drive/disable"
    method: GET

  vacuum_drive_move:
    url: "http://192.168.1.31:6971/drive/move"
    method: POST
    content_type: "application/json"
    payload: >-
      {"velocity": {{ velocity }}, "angle": {{ angle }}}

  # --- Video Quality ---
  vacuum_set_video_quality:
    url: "http://192.168.1.31:6971/video_quality/{{ profile }}"
    method: GET

  # --- Room Cleaning ---
  vacuum_clean_segments:
    url: "http://192.168.1.31:6971/segments/clean"
    method: POST
    content_type: "application/json"
    payload: >-
      {"segment_ids": {{ segment_ids }}, "iterations": {{ iterations | default(1) }}}

  # --- Feature Controls ---
  vacuum_set_carpet_mode:
    url: "http://192.168.1.31:6971/carpet_mode/{{ mode }}"
    method: GET

  vacuum_set_auto_empty_interval:
    url: "http://192.168.1.31:6971/auto_empty_interval/{{ interval }}"
    method: GET

  vacuum_set_drive_speed:
    url: "http://192.168.1.31:6971/drive/speed/{{ speed }}"
    method: GET

  vacuum_toggle_obstacle_avoidance:
    url: "http://192.168.1.31:6971/obstacle_avoidance/toggle"
    method: GET

  vacuum_toggle_obstacle_images:
    url: "http://192.168.1.31:6971/obstacle_images/toggle"
    method: GET

  vacuum_toggle_child_lock:
    url: "http://192.168.1.31:6971/child_lock/toggle"
    method: GET

  # --- Quirk Controls ---
  vacuum_set_quirk:
    url: "http://192.168.1.31:6971/quirk/{{ quirk_id }}/{{ value }}"
    method: GET

# Sensors
sensor:
  - platform: rest
    name: Vacuum Speaker Volume
    resource: "http://192.168.1.31:6971/volume"
    value_template: "{{ value_json.volume }}"
    unit_of_measurement: "%"
    scan_interval: 60

  - platform: rest
    name: Vacuum Mic Volume
    resource: "http://192.168.1.31:6971/mic_volume"
    value_template: "{{ value_json.mic_volume }}"
    unit_of_measurement: "%"
    scan_interval: 60

  - platform: rest
    name: Vacuum Status
    resource: "http://192.168.1.31:6971/status"
    value_template: >-
      {% for attr in value_json if attr.__class == "StatusStateAttribute" %}{{ attr.value }}{% endfor %}
    scan_interval: 30

  - platform: rest
    name: Vacuum Battery
    resource: "http://192.168.1.31:6971/status"
    device_class: battery
    unit_of_measurement: "%"
    value_template: >-
      {% for attr in value_json if attr.__class == "BatteryStateAttribute" %}{{ attr.level }}{% endfor %}
    scan_interval: 60

  - platform: rest
    name: Vacuum Mode
    resource: "http://192.168.1.31:6971/mode"
    value_template: "{{ value_json.mode }}"
    scan_interval: 30

  - platform: rest
    name: Vacuum Fan Speed
    resource: "http://192.168.1.31:6971/fan_speed"
    value_template: "{{ value_json.fan_speed }}"
    scan_interval: 30

  - platform: rest
    name: Vacuum Water Usage
    resource: "http://192.168.1.31:6971/water_usage"
    value_template: "{{ value_json.water_usage }}"
    scan_interval: 30

  - platform: rest
    name: Vacuum Video Quality
    resource: "http://192.168.1.31:6971/video_quality"
    value_template: "{{ value_json.profile }}"
    json_attributes:
      - width
      - height
      - framerate
      - bitrate
    scan_interval: 60

  - platform: rest
    name: Vacuum Total Statistics
    resource: "http://192.168.1.31:6971/statistics"
    value_template: "{{ value_json.count }}"
    json_attributes:
      - area
      - time
      - count
    scan_interval: 300

  - platform: rest
    name: Vacuum Consumables
    resource: "http://192.168.1.31:6971/consumables"
    value_template: >-
      {% set items = value_json %}{% set low = items | selectattr('remaining_pct','lt',20) | list %}{{ 'replace' if low | length > 0 else 'ok' }}
    json_attributes:
      - filter
      - main_brush
      - side_brush
      - mop
      - sensor
    scan_interval: 300

  - platform: rest
    name: Vacuum DND
    resource: "http://192.168.1.31:6971/dnd"
    value_template: "{{ value_json.enabled }}"
    scan_interval: 300

  - platform: rest
    name: Vacuum Carpet Mode
    resource: "http://192.168.1.31:6971/carpet_mode"
    value_template: "{{ value_json.mode }}"
    scan_interval: 300

  - platform: rest
    name: Vacuum Obstacle Images
    resource: "http://192.168.1.31:6971/obstacle_images"
    value_template: "{{ value_json.enabled }}"
    scan_interval: 300

  - platform: rest
    name: Vacuum Obstacle Avoidance
    resource: "http://192.168.1.31:6971/obstacle_avoidance"
    value_template: "{{ value_json.enabled }}"
    scan_interval: 300

  - platform: rest
    name: Vacuum Child Lock
    resource: "http://192.168.1.31:6971/child_lock"
    value_template: "{{ value_json.enabled }}"
    scan_interval: 300

  - platform: rest
    name: Vacuum Auto Empty Interval
    resource: "http://192.168.1.31:6971/auto_empty_interval"
    value_template: "{{ value_json.interval }}"
    scan_interval: 300

  - platform: rest
    name: Vacuum Drive Speed
    resource: "http://192.168.1.31:6971/drive/speed"
    value_template: "{{ value_json.speed }}"
    scan_interval: 60

  # Quirk sensors (one per configurable quirk)
  - platform: rest
    name: Vacuum Carpet Sensitivity
    resource: "http://192.168.1.31:6971/quirk/f8cb91ab-a47a-445f-b300-0aac0d4937c0"
    value_template: "{{ value_json.value }}"
    scan_interval: 3600

  - platform: rest
    name: Vacuum Mop Clean Frequency
    resource: "http://192.168.1.31:6971/quirk/a6709b18-57af-4e11-8b4c-8ae33147ab34"
    value_template: "{{ value_json.value }}"
    scan_interval: 3600

  - platform: rest
    name: Vacuum Mop Wash Intensity
    resource: "http://192.168.1.31:6971/quirk/2d4ce805-ebf7-4dcf-b919-c5fe4d4f2de3"
    value_template: "{{ value_json.value }}"
    scan_interval: 3600

  - platform: rest
    name: Vacuum Pre Wet Mops
    resource: "http://192.168.1.31:6971/quirk/66adac0f-0a16-4049-b6ac-080ef702bb39"
    value_template: "{{ value_json.value }}"
    scan_interval: 3600

  - platform: rest
    name: Vacuum Detergent
    resource: "http://192.168.1.31:6971/quirk/a2a03d42-c710-45e5-b53a-4bc62778589f"
    value_template: "{{ value_json.value }}"
    scan_interval: 3600

  - platform: rest
    name: Vacuum Carpet First
    resource: "http://192.168.1.31:6971/quirk/3d6cd658-c72a-48d9-ba54-38cf2d26e2f6"
    value_template: "{{ value_json.value }}"
    scan_interval: 3600

# Input controls
input_number:
  vacuum_speaker_volume:
    name: Vacuum Speaker Volume
    min: 0
    max: 100
    step: 5
    icon: mdi:volume-high
    unit_of_measurement: "%"

  vacuum_mic_volume:
    name: Vacuum Mic Volume
    min: 0
    max: 100
    step: 5
    icon: mdi:microphone
    unit_of_measurement: "%"

input_text:
  vacuum_tts_message:
    name: Vacuum TTS Message
    max: 200
    icon: mdi:message-text

input_select:
  vacuum_mode:
    name: Vacuum Mode
    options:
      - vacuum
      - mop
      - vacuum_and_mop
    icon: mdi:robot-vacuum

  vacuum_fan_speed:
    name: Vacuum Fan Speed
    options:
      - low
      - medium
      - high
      - max
    icon: mdi:fan

  vacuum_water_usage:
    name: Vacuum Water Usage
    options:
      - min
      - low
      - medium
      - high
      - max
    icon: mdi:water

  vacuum_video_quality:
    name: Vacuum Video Quality
    options:
      - low
      - high
    icon: mdi:video

  vacuum_carpet_mode:
    name: Vacuum Carpet Mode
    options:
      - avoid
      - lift
      - ignore
    icon: mdi:rug

  vacuum_auto_empty_interval:
    name: Vacuum Auto Empty Interval
    options:
      - not_set
      - low
      - moderate
      - frequent
      - every_time
    icon: mdi:delete-empty

  vacuum_carpet_sensitivity:
    name: Vacuum Carpet Sensitivity
    options:
      - low
      - medium
      - high
    icon: mdi:signal-cellular-3

  vacuum_mop_clean_frequency:
    name: Vacuum Mop Clean Frequency
    options:
      - every_segment
      - every_5_m2
      - every_10_m2
      - every_15_m2
      - every_20_m2
      - every_25_m2
    icon: mdi:refresh

  vacuum_mop_wash_intensity:
    name: Vacuum Mop Wash Intensity
    options:
      - low
      - medium
      - high
    icon: mdi:water-pump

  vacuum_pre_wet_mops:
    name: Vacuum Pre-Wet Mops
    options:
      - Wet
      - Dry
    icon: mdi:water-outline

  vacuum_detergent:
    name: Vacuum Detergent
    options:
      - "on"
      - "off"
    icon: mdi:bottle-tonic

  vacuum_carpet_first:
    name: Vacuum Carpet First
    options:
      - "on"
      - "off"
    icon: mdi:sort-ascending

input_number:
  vacuum_drive_speed:
    name: Vacuum Drive Speed
    min: 0
    max: 100
    step: 5
    icon: mdi:speedometer
    unit_of_measurement: "%"

# Scripts
script:
  vacuum_speak:
    alias: Vacuum Speak
    sequence:
      - action: rest_command.vacuum_say
        data:
          message: "{{ message }}"

  vacuum_speak_from_input:
    alias: Vacuum Speak From Input
    sequence:
      - action: rest_command.vacuum_say
        data:
          message: "{{ states('input_text.vacuum_tts_message') }}"
```

### Automations

Create the following automations (via the HA UI or `automations.yaml`):

**Sync volume sliders → vacuum:**

```yaml
- alias: Vacuum Speaker Volume Changed
  trigger:
    - platform: state
      entity_id: input_number.vacuum_speaker_volume
  condition:
    - condition: template
      value_template: "{{ trigger.from_state.state not in ['unknown', 'unavailable'] }}"
  action:
    - action: rest_command.vacuum_set_volume
      data:
        volume: "{{ states('input_number.vacuum_speaker_volume') | int }}"

- alias: Vacuum Mic Volume Changed
  trigger:
    - platform: state
      entity_id: input_number.vacuum_mic_volume
  condition:
    - condition: template
      value_template: "{{ trigger.from_state.state not in ['unknown', 'unavailable'] }}"
  action:
    - action: rest_command.vacuum_set_mic_volume
      data:
        volume: "{{ states('input_number.vacuum_mic_volume') | int }}"
```

**Sync mode/speed/water selectors → vacuum:**

```yaml
- alias: Vacuum Mode Changed
  trigger:
    - platform: state
      entity_id: input_select.vacuum_mode
  condition:
    - condition: template
      value_template: "{{ trigger.from_state.state not in ['unknown', 'unavailable'] and trigger.from_state.state != trigger.to_state.state }}"
  action:
    - action: rest_command.vacuum_set_mode
      data:
        mode: "{{ states('input_select.vacuum_mode') }}"

- alias: Vacuum Fan Speed Changed
  trigger:
    - platform: state
      entity_id: input_select.vacuum_fan_speed
  condition:
    - condition: template
      value_template: "{{ trigger.from_state.state not in ['unknown', 'unavailable'] and trigger.from_state.state != trigger.to_state.state }}"
  action:
    - action: rest_command.vacuum_set_fan_speed
      data:
        speed: "{{ states('input_select.vacuum_fan_speed') }}"

- alias: Vacuum Water Usage Changed
  trigger:
    - platform: state
      entity_id: input_select.vacuum_water_usage
  condition:
    - condition: template
      value_template: "{{ trigger.from_state.state not in ['unknown', 'unavailable'] and trigger.from_state.state != trigger.to_state.state }}"
  action:
    - action: rest_command.vacuum_set_water_usage
      data:
        level: "{{ states('input_select.vacuum_water_usage') }}"

- alias: Vacuum Video Quality Changed
  trigger:
    - platform: state
      entity_id: input_select.vacuum_video_quality
  condition:
    - condition: template
      value_template: "{{ trigger.from_state.state not in ['unknown', 'unavailable'] and trigger.from_state.state != trigger.to_state.state }}"
  action:
    - action: rest_command.vacuum_set_video_quality
      data:
        profile: "{{ states('input_select.vacuum_video_quality') }}"

- alias: Vacuum Carpet Mode Changed
  trigger:
    - platform: state
      entity_id: input_select.vacuum_carpet_mode
  condition:
    - condition: template
      value_template: "{{ trigger.from_state.state not in ['unknown', 'unavailable'] and trigger.from_state.state != trigger.to_state.state }}"
  action:
    - action: rest_command.vacuum_set_carpet_mode
      data:
        mode: "{{ states('input_select.vacuum_carpet_mode') }}"

- alias: Vacuum Auto Empty Interval Changed
  trigger:
    - platform: state
      entity_id: input_select.vacuum_auto_empty_interval
  condition:
    - condition: template
      value_template: "{{ trigger.from_state.state not in ['unknown', 'unavailable'] and trigger.from_state.state != trigger.to_state.state }}"
  action:
    - action: rest_command.vacuum_set_auto_empty_interval
      data:
        interval: "{{ states('input_select.vacuum_auto_empty_interval') }}"

- alias: Vacuum Drive Speed Changed
  trigger:
    - platform: state
      entity_id: input_number.vacuum_drive_speed
  condition:
    - condition: template
      value_template: "{{ trigger.from_state.state not in ['unknown', 'unavailable'] }}"
  action:
    - action: rest_command.vacuum_set_drive_speed
      data:
        speed: "{{ states('input_number.vacuum_drive_speed') | int }}"
```

**Quirk sync automations** (one per configurable quirk — carpet sensitivity shown as example):

```yaml
- alias: Vacuum Carpet Sensitivity Changed
  trigger:
    - platform: state
      entity_id: input_select.vacuum_carpet_sensitivity
  condition:
    - condition: template
      value_template: "{{ trigger.from_state.state not in ['unknown', 'unavailable'] and trigger.from_state.state != trigger.to_state.state }}"
  action:
    - action: rest_command.vacuum_set_quirk
      data:
        quirk_id: "f8cb91ab-a47a-445f-b300-0aac0d4937c0"
        value: "{{ states('input_select.vacuum_carpet_sensitivity') }}"
```

Repeat the same pattern for each quirk with the corresponding UUID:

| Quirk | UUID | Options |
|---|---|---|
| Carpet Sensitivity | `f8cb91ab-a47a-445f-b300-0aac0d4937c0` | low, medium, high |
| Mop Clean Frequency | `a6709b18-57af-4e11-8b4c-8ae33147ab34` | every_segment, every_5_m2…every_25_m2 |
| Mop Wash Intensity | `2d4ce805-ebf7-4dcf-b919-c5fe4d4f2de3` | low, medium, high |
| Pre-Wet Mops | `66adac0f-0a16-4049-b6ac-080ef702bb39` | Wet, Dry |
| Detergent | `a2a03d42-c710-45e5-b53a-4bc62778589f` | on, off |
| Carpet First | `3d6cd658-c72a-48d9-ba54-38cf2d26e2f6` | on, off |

**Dock action quirks** (trigger-only, no sync needed):

| Action | UUID |
|---|---|
| Auto Repair | `ae753798-aa4f-4b35-a60c-91e7e5ae76f3` |
| Drain Water Tank | `3e1b0851-3a5a-4943-bea6-dea3d7284bff` |
| Dock Cleaning Process | `42c7db4b-2cad-4801-a526-44de8944a41f` |
| Water Hookup Test | `86094736-d66e-40c3-807c-3f5ef33cbf09` |

**Sync vacuum → sliders/selectors on startup:**

```yaml
- alias: Vacuum Controls Sync on Startup
  trigger:
    - platform: homeassistant
      event: start
  action:
    - delay:
        seconds: 30
    - action: input_number.set_value
      target:
        entity_id: input_number.vacuum_speaker_volume
      data:
        value: "{{ states('sensor.vacuum_speaker_volume') | int(50) }}"
    - action: input_number.set_value
      target:
        entity_id: input_number.vacuum_mic_volume
      data:
        value: "{{ states('sensor.vacuum_mic_volume') | int(50) }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_mode
      data:
        option: "{{ states('sensor.vacuum_mode') }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_fan_speed
      data:
        option: "{{ states('sensor.vacuum_fan_speed') }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_water_usage
      data:
        option: "{{ states('sensor.vacuum_water_usage') }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_video_quality
      data:
        option: "{{ states('sensor.vacuum_video_quality') }}"

- alias: Vacuum New Controls Sync on Startup
  trigger:
    - platform: homeassistant
      event: start
  action:
    - delay:
        seconds: 90
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_carpet_mode
      data:
        option: "{{ states('sensor.vacuum_carpet_mode') }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_auto_empty_interval
      data:
        option: "{{ states('sensor.vacuum_auto_empty_interval') }}"
    - action: input_number.set_value
      target:
        entity_id: input_number.vacuum_drive_speed
      data:
        value: "{{ states('sensor.vacuum_drive_speed') | int(50) }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_carpet_sensitivity
      data:
        option: "{{ states('sensor.vacuum_carpet_sensitivity') }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_mop_clean_frequency
      data:
        option: "{{ states('sensor.vacuum_mop_clean_frequency') }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_mop_wash_intensity
      data:
        option: "{{ states('sensor.vacuum_mop_wash_intensity') }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_pre_wet_mops
      data:
        option: "{{ states('sensor.vacuum_pre_wet_mops') }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_detergent
      data:
        option: "{{ states('sensor.vacuum_detergent') }}"
    - action: input_select.select_option
      target:
        entity_id: input_select.vacuum_carpet_first
      data:
        option: "{{ states('sensor.vacuum_carpet_first') }}"
```

### Dashboard Card

Add a vertical-stack card to your Lovelace dashboard for a full vacuum control panel:

```yaml
type: vertical-stack
cards:
  # --- Live Camera Feed ---
  - type: custom:webrtc-camera
    url: vacuum
    mode: webrtc
    media: video,audio,microphone
    server: http://192.168.1.31:1984

  # --- Status Bar ---
  - type: horizontal-stack
    cards:
      - type: custom:mushroom-entity-card
        entity: sensor.vacuum_status
        name: Status
        icon: mdi:robot-vacuum
      - type: custom:mushroom-entity-card
        entity: sensor.vacuum_battery
        name: Battery
        icon: mdi:battery
      - type: custom:mushroom-entity-card
        entity: sensor.vacuum_mode
        name: Mode
        icon: mdi:auto-fix

  # --- Vacuum Actions ---
  - type: horizontal-stack
    cards:
      - type: button
        name: Start
        icon: mdi:play
        tap_action:
          action: call-service
          service: rest_command.vacuum_start
      - type: button
        name: Pause
        icon: mdi:pause
        tap_action:
          action: call-service
          service: rest_command.vacuum_pause
      - type: button
        name: Stop
        icon: mdi:stop
        tap_action:
          action: call-service
          service: rest_command.vacuum_stop
      - type: button
        name: Home
        icon: mdi:home
        tap_action:
          action: call-service
          service: rest_command.vacuum_home

  # --- Manual Drive D-Pad ---
  - type: vertical-stack
    cards:
      - type: horizontal-stack
        cards:
          - type: button
            name: ""
            icon: ""
            tap_action:
              action: none
          - type: button
            name: Forward
            icon: mdi:arrow-up-bold
            tap_action:
              action: call-service
              service: script.vacuum_drive_forward
          - type: button
            name: ""
            icon: ""
            tap_action:
              action: none
      - type: horizontal-stack
        cards:
          - type: button
            name: Left
            icon: mdi:arrow-left-bold
            tap_action:
              action: call-service
              service: script.vacuum_drive_left
          - type: button
            name: Enable
            icon: mdi:gamepad-variant
            tap_action:
              action: call-service
              service: rest_command.vacuum_drive_enable
          - type: button
            name: Right
            icon: mdi:arrow-right-bold
            tap_action:
              action: call-service
              service: script.vacuum_drive_right
      - type: horizontal-stack
        cards:
          - type: button
            name: ""
            icon: ""
            tap_action:
              action: none
          - type: button
            name: Back
            icon: mdi:arrow-down-bold
            tap_action:
              action: call-service
              service: script.vacuum_drive_backward
          - type: button
            name: ""
            icon: ""
            tap_action:
              action: none

  # --- Mode & Speed Selectors ---
  - type: entities
    title: Vacuum Settings
    entities:
      - entity: input_select.vacuum_mode
        name: Operation Mode
      - entity: input_select.vacuum_fan_speed
        name: Fan Speed
      - entity: input_select.vacuum_water_usage
        name: Water Usage
      - entity: input_select.vacuum_video_quality
        name: Video Quality

  # --- Volume Controls ---
  - type: entities
    title: Audio Controls
    entities:
      - entity: input_number.vacuum_speaker_volume
        name: Speaker Volume
      - entity: input_number.vacuum_mic_volume
        name: Mic Volume

  # --- TTS ---
  - type: horizontal-stack
    cards:
      - type: entities
        entities:
          - entity: input_text.vacuum_tts_message
            name: Say something...
      - type: button
        name: Speak
        icon: mdi:bullhorn
        tap_action:
          action: call-service
          service: script.vacuum_speak_from_input

  # --- Quick Actions ---
  - type: horizontal-stack
    cards:
      - type: button
        name: Locate
        icon: mdi:map-marker
        tap_action:
          action: call-service
          service: rest_command.vacuum_test_sound
      - type: button
        name: Say Hello
        icon: mdi:hand-wave
        tap_action:
          action: call-service
          service: rest_command.vacuum_say
          data:
            message: Hello from Home Assistant!
```

The D-pad drive scripts should be added to your HA scripts:

```yaml
script:
  vacuum_drive_forward:
    alias: Vacuum Drive Forward
    sequence:
      - action: rest_command.vacuum_drive_move
        data:
          velocity: "0.5"
          angle: "0"

  vacuum_drive_backward:
    alias: Vacuum Drive Backward
    sequence:
      - action: rest_command.vacuum_drive_move
        data:
          velocity: "-0.5"
          angle: "0"

  vacuum_drive_left:
    alias: Vacuum Drive Left
    sequence:
      - action: rest_command.vacuum_drive_move
        data:
          velocity: "0"
          angle: "90"

  vacuum_drive_right:
    alias: Vacuum Drive Right
    sequence:
      - action: rest_command.vacuum_drive_move
        data:
          velocity: "0"
          angle: "-90"

  # --- Feature Toggle Scripts ---
  vacuum_toggle_obstacle_avoidance:
    alias: Vacuum Toggle Obstacle Avoidance
    sequence:
      - action: homeassistant.update_entity
        target:
          entity_id: sensor.vacuum_obstacle_avoidance
      - choose:
          - conditions:
              - condition: state
                entity_id: sensor.vacuum_obstacle_avoidance
                state: "True"
            sequence:
              - action: rest_command.vacuum_toggle_obstacle_avoidance
          - conditions:
              - condition: state
                entity_id: sensor.vacuum_obstacle_avoidance
                state: "False"
            sequence:
              - action: rest_command.vacuum_toggle_obstacle_avoidance

  vacuum_toggle_obstacle_images:
    alias: Vacuum Toggle Obstacle Images
    # Same pattern as above with sensor.vacuum_obstacle_images

  vacuum_toggle_child_lock:
    alias: Vacuum Toggle Child Lock
    # Same pattern as above with sensor.vacuum_child_lock

  # --- Dock Action Scripts ---
  vacuum_dock_auto_repair:
    alias: Vacuum Dock Auto Repair
    icon: mdi:wrench
    sequence:
      - action: rest_command.vacuum_set_quirk
        data:
          quirk_id: "ae753798-aa4f-4b35-a60c-91e7e5ae76f3"
          value: "action"

  vacuum_drain_water_tank:
    alias: Vacuum Drain Water Tank
    icon: mdi:water-off
    sequence:
      - action: rest_command.vacuum_set_quirk
        data:
          quirk_id: "3e1b0851-3a5a-4943-bea6-dea3d7284bff"
          value: "action"

  vacuum_dock_cleaning_process:
    alias: Vacuum Dock Cleaning Process
    icon: mdi:broom
    sequence:
      - action: rest_command.vacuum_set_quirk
        data:
          quirk_id: "42c7db4b-2cad-4801-a526-44de8944a41f"
          value: "action"

  vacuum_water_hookup_test:
    alias: Vacuum Water Hookup Test
    icon: mdi:pipe
    sequence:
      - action: rest_command.vacuum_set_quirk
        data:
          quirk_id: "86094736-d66e-40c3-807c-3f5ef33cbf09"
          value: "action"
```

The card provides:
- **Live video** with WebRTC (low latency)
- **Live audio** from the vacuum's microphone
- **Two-way audio** — click the microphone button to talk through the vacuum speaker
- **Status bar** showing current status, battery level, and operation mode
- **Action buttons** — Start, Pause, Stop, Home
- **D-pad controls** — manual drive with Forward/Back/Left/Right, Enable button, and speed slider
- **Mode selectors** — operation mode, fan speed, water usage, carpet mode, auto-empty interval dropdowns
- **Feature toggles** — obstacle avoidance, obstacle images, child lock toggle buttons
- **Feature status** — glance card showing DND, carpet mode, obstacle avoidance, child lock, auto-empty states
- **Cleaning quirks** — carpet sensitivity, mop frequency, wash intensity, pre-wet mops, detergent, carpet-first selectors
- **Dock actions** — dock auto-repair, drain tank, dock cleaning, water hookup test buttons
- **Statistics** — cleaning area, time, and run count
- **Consumable status** — filter, brushes, mops, sensor wear levels
- **Volume sliders** for speaker and microphone
- **TTS text box** with a Speak button
- **Quick actions** — Locate and Say Hello buttons

## File Reference

| File | Description |
|---|---|
| `vacuumstreamer.c` | LD_PRELOAD hook — intercepts Agora RTC calls, redirects H.264 video to TCP :6969 |
| `vacuumstreamer.so` | Compiled shared library (aarch64) |
| `go2rtc.yaml` | go2rtc configuration — streams, RTSP, WebRTC, backchannel |
| `play_pcm.sh` | WebRTC backchannel handler — pipes PCM audio to `aplay` |
| `tts_handler.sh` | HTTP server handler for TTS, audio playback, volume control, video quality switching, Valetudo API proxy (vacuum controls, manual drive, mode/speed/water, room cleaning), feature controls (DND, carpet mode, obstacle avoidance, child lock, auto-empty), statistics, consumables, drive speed, and quirk settings |
| `_root_postboot.sh` | Boot script — starts Valetudo, ALSA mixer setup, video_monitor, go2rtc, TTS server |
| `Dockerfile` | Build environment for cross-compiling vacuumstreamer.so |
| `run.sh` | Docker wrapper for running make |

## Credits

- [@tihmstar](https://github.com/tihmstar) — vacuumstreamer
- [@Uberi](https://github.com/Uberi) — research and documentation: https://anthony-zhang.me/blog/offline-robot-vacuum/
- [@dgiese](https://github.com/dgiese) — vacuum security research
- [go2rtc](https://github.com/AlexxIT/go2rtc) — WebRTC/RTSP streaming
- [Valetudo](https://valetudo.cloud/) — open-source vacuum control
