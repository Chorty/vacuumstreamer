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

# 4. Reboot, gate again, and roll back all three files on failure
tools/deploy_reboot_gate.sh <artifact-sha256> <valetudo-commit> <deploy-id>
```

Each stage refuses to run until the previous one has passed. The deploy ID names the on-robot rollback copies: `/data/valetudo.predeploy_<id>`, `/data/_root_postboot.sh.predeploy_<id>` and `/data/vacuumstreamer/go2rtc.yaml.predeploy_<id>`.

| Tool | Purpose |
|---|---|
| `backup_ssh.sh PKG` | Mac SSH key and config, `known_hosts`, robot dropbear host keys and `authorized_keys`, verified against on-robot hashes |
| `backup_robot.sh PKG` | `/data`, `/mnt/private` and `/mnt/misc` archive verified file by file against an on-robot SHA-256 manifest, plus the decrypted `/dev/mapper/private` image |
| `backup_hardware.sh PKG` | Raw images of every named partition except `UDISK`, U-Boot environment, sunxi chip information and the dm-crypt mapping |
| `build_valetudo.sh COMMIT [PKG]` | Clean detached clone, OpenAPI schema, lint, type checks, tests, frontend and ARM64 build; checks the embedded commit and pkg warnings |
| `seal_package.sh PKG` | `BACKUP_INFO.txt` and `SHA256SUMS.txt`, then re-verifies every file |
| `deploy_binary.sh ARTIFACT ID PKG` | Candidate upload with hash check and on-robot health gate with rollback |
| `deploy_native.sh COMMIT ID` | Installs native runtime files from a commit with hash and BusyBox syntax checks |
| `deploy_reboot_gate.sh SHA COMMIT ID` | Reboot, 12 consecutive health checks, full rollback and second reboot on failure |
| `camera_checks.sh` | Idle stop, cold wake, pause and resume through Valetudo, crash and stall recovery while an RTSP viewer watches |
| `profiles.sh PREFIX` | Docked 10-minute profiles: nobody watching, an RTSP viewer, and `CAMERA_MODE=always`; restores the original mode |
| `compare_profiles.py RUNS` | Applies the CLAUDE.md gates against the 2026-07-25 baselines |
| `integration_local.sh` | Mac-only end-to-end test of the camera scripts with a local go2rtc and ffmpeg standing in for `video_monitor` |

## Requirements

- Mac: `ssh vacuum` configured, Python 3, `shasum`, `ffmpeg` and `ffprobe` for camera tools, `lsof` for `integration_local.sh`
- `build_valetudo.sh`: the Valetudo checkout with `build_dependencies/pkg`, and plugin commits reachable in its local plugin repository
- `integration_local.sh`: a go2rtc binary for macOS in `GO2RTC_BIN`, for example built from the `v1.9.9` tag with `go build`

## Validation

- `compare_profiles.py` and `docked_idle.py` are tested locally; `integration_local.sh` passed locally after parameterization.
- The robot-facing scripts keep the commands that ran against the robot on 2026-09-13, but they have not been re-run against the robot since paths, commits and hashes became arguments. Read a script before using it for a deployment.

## Lessons built in

- BusyBox `flock` has no `-w`; the robot clock starts at 1970; remote `ps` searches use bracket patterns so they cannot match their own shell.
- `ssh` inside `while read` loops uses `ssh -n`, or it consumes the loop's input.
- Valetudo state JSON is parsed, because `metaData` sits between `__class` and `value`.
- Builds come from a clean detached clone with `npm run build_openapi_schema`, or the binary reports commit `unknown` and loses API validation.
