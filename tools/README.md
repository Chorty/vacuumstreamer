# VacuumStreamer maintenance tools

Scripts for backing up the robot, building and deploying Valetudo with the VacuumStreamer runtime, and measuring the camera. They were used for the 2026-09-13 runtime-switches deployment and then parameterized; see "Validation" before relying on them.

All tools run on the Mac, reach the robot over `ssh vacuum`, write logs to `~/.cache/vacuumstreamer-tools`, and read settings from environment variables documented in `lib.sh` (`VACUUM_SSH`, `VACUUM_IP`, `VALETUDO_REPO`, `BACKUP_ROOT`, `PROFILE_ROOT`, `WORK_DIR`). Keep the robot docked and idle; none of them start cleaning or move the robot.

## Deployment flow

```bash
PKG=~/Documents/ValetudoBackups/valetudo_<commit>_<date>

# 1. Backups, then seal the package
tools/backup_ssh.sh "$PKG"
tools/backup_robot.sh "$PKG"
tools/backup_hardware.sh "$PKG"
tools/build_valetudo.sh <valetudo-commit> "$PKG"      # clean detached clone
tools/seal_package.sh "$PKG"

# 2. Binary through the on-robot 60 s health gate with automatic rollback
tools/deploy_binary.sh "$PKG/artifact_<short>/valetudo-aarch64" <deploy-id> "$PKG"

# 3. Native runtime scripts from a committed native revision
tools/deploy_native.sh <native-commit> <deploy-id>

# 4. Reboot, gate again, and restore the binary and preserved native files on failure
tools/deploy_reboot_gate.sh <artifact-sha256> <valetudo-commit> <deploy-id>
```

Each stage refuses to run until the previous one has passed.

For a native-only change, run the backups and `seal_package.sh` as usual (skip `build_valetudo.sh`), then replace step 2 with:

```bash
tools/deploy_keep_binary.sh <deploy-id> "$PKG"
```

It checks the same preconditions and leaves the same `/data/valetudo.predeploy_<id>` copy and markers as `deploy_binary.sh`, without touching `/data/valetudo`. Then run `deploy_native.sh`. A script that runs only per request (such as `mic_gain_ctl.sh`) takes effect immediately; verify it over REST. A long-running script (the supervisor, launchers, boot script) or `go2rtc.yaml` takes effect only after a reboot, so run `deploy_reboot_gate.sh` with the active binary's SHA-256 and running Valetudo commit. The deploy ID names the on-robot rollback copies: `/data/valetudo.predeploy_<id>`, `/data/_root_postboot.sh.predeploy_<id>` and `/data/vacuumstreamer/go2rtc.yaml.predeploy_<id>`.

| Tool | Purpose |
|---|---|
| `backup_ssh.sh PKG` | Mac SSH key and config, `known_hosts`, robot dropbear host keys and `authorized_keys`, verified against on-robot hashes |
| `backup_robot.sh PKG` | `/data`, `/mnt/private` and `/mnt/misc` archive verified file by file against an on-robot SHA-256 manifest, plus the decrypted `/dev/mapper/private` image |
| `backup_hardware.sh PKG` | Raw images of every named partition except `UDISK`, U-Boot environment, sunxi chip information and the dm-crypt mapping |
| `build_valetudo.sh COMMIT [PKG]` | Clean detached clone, OpenAPI schema, lint, type checks, tests, frontend and ARM64 build; checks the embedded commit and pkg warnings |
| `seal_package.sh PKG` | `BACKUP_INFO.txt` and `SHA256SUMS.txt`, then re-verifies every file |
| `deploy_binary.sh ARTIFACT ID PKG` | Candidate upload with hash check and on-robot health gate with rollback |
| `deploy_keep_binary.sh ID PKG` | Native-only stage 1: keeps the active binary, preserves it as the rollback copy and writes the markers the later stages need |
| `deploy_native.sh COMMIT ID` | Installs native runtime files from a commit with hash and BusyBox syntax checks |
| `deploy_reboot_gate.sh SHA COMMIT ID` | Reboot, 12 consecutive health checks, full rollback and second reboot on failure |
| `install_caddy.sh CADDY ID` | Install the pinned official Caddy v2.11.4 ARM64 binary without enabling HTTPS |
| `camera_checks.sh` | Idle stop, cold wake, pause and resume through Valetudo, crash and stall recovery while an RTSP viewer watches |
| `migrate_ha_https.py SOURCE OUTPUT` | Prepare a mode-0600 Home Assistant config with exactly 25 commands and 16 sensors moved to verified HTTPS |
| `profiles.sh PREFIX` | Docked 10-minute profiles: nobody watching, an RTSP viewer, and `CAMERA_MODE=always`; restores the original mode |
| `compare_profiles.py RUNS` | Applies the CLAUDE.md gates against the 2026-07-25 baselines |
| `integration_local.sh` | Mac-only end-to-end test of the camera scripts with a local go2rtc and ffmpeg standing in for `video_monitor` |

## Valetudo login

When Valetudo Basic Auth is on, every request needs the login, including ones the tools send from the robot itself. The tools read it from the Mac keychain: service `valetudo-basic-auth` (override with `VALETUDO_AUTH_SERVICE`), account = username. Create it with:

```bash
security add-generic-password -U -a <username> -s valetudo-basic-auth -w   # prompts for the password
```

The login reaches curl only on stdin (`curl -K -`), never in process arguments. An absent keychain entry is allowed only if an unauthenticated preflight receives HTTP 200 from Valetudo. With Basic Auth on and no entry, or if the keychain read fails, deployment aborts **before activation or reboot**. Each deploy stage caches one validated login, so a later keychain failure cannot turn a healthy post-reboot check into a rollback. The detached binary gate uses a unique mode-0700 directory under `/tmp`, holds its curl config at mode 0600, and removes the directory on exit; the Mac removes it if upload or launch fails.

## Home Assistant HTTPS rollout

As of 2026-09-26, the robot name resolves to `192.168.1.31` from public and LAN resolvers. The separate Let's Encrypt app issued the robot-only certificate expiring 2026-12-25. HA's Advanced SSH & Web Terminal app already existed; its `/config/.ssh/valetudo_https_ed25519` private key is mode 0600 and its known-host entry is pinned. The restricted public key is in persistent `/mnt/misc/authorized_keys` and active `/tmp/.ssh/authorized_keys` (Dropbear copies the former to the latter on boot). The issued certificate and key are installed on the robot; `HTTPS_PROXY=on` passed 12/12 after reboot. HA's 25 REST commands and 16 REST sensors use verified HTTPS, with both daily certificate automations enabled. The procedure and recovery order are:

1. Register `mattjoslin-valetudo.duckdns.org` in the existing DuckDNS account and set **only that name's** A record to `192.168.1.31`. Check that Home Assistant resolves it to that address. Do not add it to the existing Duck DNS app's dynamic public-IP list. If the LAN resolver filters private answers, override this name locally while keeping the certificate name the same.
2. Configure the separate official Let's Encrypt app for a **robot-only** certificate: domain `mattjoslin-valetudo.duckdns.org`, `challenge: dns`, `dns.provider: dns-duckdns`, `dns.duckdns_token` from the existing account, `certfile: valetudo-fullchain.pem`, and `keyfile: valetudo-privkey.pem`. Use the owner's ACME contact email and accept the app's terms. Start it once; confirm the private files under `/ssl/`. Do not reuse Home Assistant's own fullchain/key. The app stops after each check, so schedule `hassio.app_start` for `core_letsencrypt` daily at 02:00.
3. Back up the robot. Download Caddy v2.11.4 from the official release: `caddy_2.11.4_linux_arm64.tar.gz` has SHA-256 `52d42ae12b3462097e9868da6dfed3c9648ae12edd3b3638102312af84cb6904`; its extracted `caddy` has SHA-256 `e1f904038fc11ca897ac5a12fdacfb2a7add02a8720c426d562a37f6fdad2afe`. Run `tools/install_caddy.sh <extracted-caddy> <deploy-id>`; the tool checks the extracted hash and remote copy.
4. Deploy the native scripts, including `https_proxy.sh`, `https_cert_install.sh`, and `https_proxy.Caddyfile`, through the normal native-only stages. On Home Assistant OS, generate a dedicated key at `/config/.ssh/valetudo_https_ed25519`, with mode 0600 and a pinned robot host key in `/config/.ssh/known_hosts`. Add its public key to the robot's persistent `authorized_keys` with `no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty,command="/data/vacuumstreamer/https_cert_install.sh"`. Dropbear v2020.81 does not support `from=`, so the fixed installer rejects any source other than the server-reported Home Assistant address `192.168.1.106` before writing files. Confirm the forced command and source check on the robot before relying on them.
5. Copy `tools/ha_https_cert_sync.sh` to `/config/valetudo_https_cert_sync.sh` at mode 0700. Add `shell_command.valetudo_https_cert_sync` to run that fixed script. It sends the PEM files on SSH stdin; the forced command accepts only `cert`, `key`, and `activate`, checks hostname, expiry and matching public keys, validates Caddy's config, then restarts the proxy. `tools/ha_https_automations.yaml` contains the separate daily renewal check and 03:00 install attempt. The latter inspects `returncode`, continues after an action error, and creates a persistent notification on failure. A certificate within 14 days of expiry makes activation fail and therefore alerts.
6. Set `HTTPS_PROXY=on` and run the reboot gate. Verify from Home Assistant that the name resolves to `192.168.1.31`, the certificate chain and name validate, wrong credentials get 401, and the correct login gets 200 over HTTPS. Verify non-HA LAN sources receive 403. Only then use `migrate_ha_https.py` to prepare a private config, back up HA's current file, validate the exact 41 URL changes, apply it, run HA's configuration check, reload the REST command/sensor integrations, and confirm the controls and sensors. Keep the existing mic/video automation guards.

This route encrypts HA's REST requests. The Mac deployment tools and MCP still use Basic Auth over HTTP on the LAN and remain a separate transport risk. `camera_checks.sh` uses an SSH-local RTSP tunnel so ffmpeg receives a credential-free URL.

## Requirements

- Mac: `ssh vacuum` configured, Python 3, `shasum`, `ffmpeg` and `ffprobe` for camera tools, `lsof` for `integration_local.sh`
- `build_valetudo.sh`: the Valetudo checkout with `build_dependencies/pkg`, and plugin commits reachable in its local plugin repository
- `integration_local.sh`: a go2rtc binary for macOS in `GO2RTC_BIN`, for example built from the `v1.9.9` tag with `go build`

## Validation

- `compare_profiles.py` and `docked_idle.py` are tested locally; `integration_local.sh` passed locally after parameterization.
- `build_valetudo.sh`, `backup_ssh.sh`, `backup_robot.sh`, `backup_hardware.sh`, `seal_package.sh`, `deploy_binary.sh`, `deploy_native.sh` and `deploy_reboot_gate.sh` ran against the robot for the 2026-09-24 `preset0924` deployment, with the reboot gate passing with `HTTP_BRIDGE=off`. On 2026-09-25, `deploy_keep_binary.sh`, `deploy_native.sh eb596b9 gatefix0925`, and `deploy_reboot_gate.sh` completed a native-only rollout from a new sealed backup. The reboot gate passed 12/12 with `HTTP_BRIDGE=off`, `HTTPS_PROXY=off`, Valetudo `261bf1ff`, and an idle camera. The pinned Caddy v2.11.4 binary was installed and hash-verified. On 2026-09-26, the restricted HA key installed the certificate, `HTTPS_PROXY=on` passed the 12/12 reboot gate, and HA Core restarted with 41 verified HTTPS URLs and both daily automations. From HA, DNS resolves to the robot, no/wrong Basic Auth gets 401, and the stored login gets 200; an untrusted certificate is rejected. An authenticated Mac client gets 403. All 16 migrated REST sensors were available, and HA Core's certificate-sync action returned 0. `ha core check` in its separate check container reported an existing `/media/recording` mount as missing; the running Core's `/api/config/core/check_config` returned `valid` before restart. The gate and source restriction plus the new isolated TTS high-profile regression test passed 306 tests in both dash and sh. `camera_checks.sh` passed live on 2026-09-25 through a credential-free SSH RTSP tunnel. On 2026-09-26, low and high each decoded 45 H.264 frames at 864x480, the high frame had no green smear, the retired TTS high-profile branch passed an isolated on-robot test, and low was restored. `profiles.sh` has not run since 2026-09-13. Read a script before using it for a deployment.
- Source `lib.sh` only from bash: it locates helpers through `BASH_SOURCE`, which zsh does not set.

## Lessons built in

- BusyBox `flock` has no `-w`; the robot clock starts at 1970; remote `ps` searches use bracket patterns so they cannot match their own shell.
- `ssh` inside `while read` loops uses `ssh -n`, or it consumes the loop's input.
- Valetudo state JSON is parsed, because `metaData` sits between `__class` and `value`.
- Builds come from a clean detached clone with `npm run build_openapi_schema`, or the binary reports commit `unknown` and loses API validation.
