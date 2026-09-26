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

optional tcpsvd :6971 → tts_handler.sh → Google TTS → ffmpeg → aplay → speaker
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

`/data/vacuumstreamer/vacuumstreamer.conf` turns features on or off. Reboot the robot after changing it. A missing file, missing key, or invalid value uses the defaults below; HTTPS stays off by default.

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
| `HTTPS_PROXY` | `off` | Supervised Caddy entry point on port 443 for Home Assistant; requires a dedicated certificate and the pinned Caddy binary |

The bridge has no login, and it can start cleaning and drive the robot. It is **off on the deployed robot** since 2026-09-24. If enabled on another install, restrict `HTTP_BRIDGE_ALLOW` to the Home Assistant host. The most recently refused address is written to `/tmp/vacuumstreamer/bridge_denied_last`.

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

Home Assistant now uses the native capabilities, and the deployed bridge is
off. The bridge endpoints below remain available for installs that opt in to
`HTTP_BRIDGE=on`.

## Home Assistant HTTPS entry point

Valetudo itself still serves HTTP on port 80. The optional `HTTPS_PROXY=on`
starts a supervised Caddy proxy on port 443 with a certificate for
`mattjoslin-valetudo.duckdns.org`. Its Caddyfile accepts only
`192.168.1.106` (Home Assistant) and robot localhost, then forwards the
original Basic Auth header to Valetudo. It has no credential-bearing access
log. The DNS name may resolve to the robot's private address; DNS-01
certificate issuance does not require an inbound internet port.

Keep this switch off until the separate certificate and key are installed in
`credentials/https-fullchain.pem` and `credentials/https-privkey.pem`, the
official pinned Caddy binary is installed, and Home Assistant has verified the
HTTPS endpoint. `tools/README.md` documents installation, renewal, and the
restricted SSH certificate installer. The Mac deployment tools and MCP still
use HTTP to the robot on the LAN; only Home Assistant's REST traffic is planned
for this HTTPS route.

As of 2026-09-25, the native scripts and pinned Caddy binary are installed on
the robot, while `HTTPS_PROXY=off`. Home Assistant has issued the robot
certificate, but it has not yet been installed on the robot; the HA REST URL
migration is also pending.

## TTS & Audio HTTP API

When `HTTP_BRIDGE=on`, `tts_handler.sh` runs via `tcpsvd` on port 6971 and provides:

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

### Deployment status

The port 6971 bridge is disabled on the deployed robot (`HTTP_BRIDGE=off`).
The endpoint table above documents the optional bridge implementation; its
former curl and Home Assistant configuration examples do not describe the
current installation.

## Home Assistant Integration

Home Assistant uses Valetudo MQTT discovery for the native microphone gain,
recorder quality, TTS, video switch, and robot controls. The 25 REST commands
and 16 REST sensors currently use Valetudo's port 80 with Basic Auth stored in
Home Assistant `secrets.yaml`. The old port 6971 REST definitions were removed
on 2026-09-24. The Generic Camera integration uses authenticated go2rtc media;
its credentials are separate from the Valetudo Basic Auth login.

The separate verified HTTPS route for Home Assistant is staged but inactive.
Follow `tools/README.md` for the robot certificate, restricted SSH installer,
reboot gate, and exact REST URL migration. Keep the existing mic and video
automation loop guards.

## File Reference

| File | Description |
|---|---|
| `vacuumstreamer.c` | LD_PRELOAD hook — intercepts Agora RTC calls, redirects H.264 video to TCP :6969 |
| `vacuumstreamer.so` | Compiled shared library (aarch64) |
| `go2rtc.yaml` | go2rtc configuration — streams, RTSP, WebRTC, backchannel |
| `play_pcm.sh` | WebRTC backchannel handler — pipes PCM audio to `aplay` |
| `tts_handler.sh` | HTTP server handler for TTS, audio playback, volume control, video quality switching, Valetudo API proxy (vacuum controls, manual drive, mode/speed/water, room cleaning), feature controls (DND, carpet mode, obstacle avoidance, child lock, auto-empty), statistics, consumables, drive speed, and quirk settings |
| `_root_postboot.sh` | Boot script — starts Valetudo, ALSA setup, and enabled native supervisors; the bridge and HTTPS proxy start only when their switches are on |
| `Dockerfile` | Build environment for cross-compiling vacuumstreamer.so |
| `run.sh` | Docker wrapper for running make |

## Credits

- [@tihmstar](https://github.com/tihmstar) — vacuumstreamer
- [@Uberi](https://github.com/Uberi) — research and documentation: https://anthony-zhang.me/blog/offline-robot-vacuum/
- [@dgiese](https://github.com/dgiese) — vacuum security research
- [go2rtc](https://github.com/AlexxIT/go2rtc) — WebRTC/RTSP streaming
- [Valetudo](https://valetudo.cloud/) — open-source vacuum control
