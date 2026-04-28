# Ideas

Parking lot for features and refactors that aren't ready to implement yet. Move an entry into a commit (or delete it) when you act on it.

---

## Promote device config to `/devices`, slim down `/settings`

**Status:** not started

**Motivation:** The settings page mixes three unrelated things — theme (a knob), device-to-position assignments (a domain entity with live state), and system actions (upgrade/reboot/shutdown). The device config section is the biggest part of the page and has its own polling loop for battery/connection. It's not config in the set-and-forget sense; it's a live management view for the sensor fleet.

**Sketch:**
- New route `/devices` serving a new `templates/devices.html`. Lift sections:
  - `<article>` "Device Configuration" (lines ~105–110 of current settings.html) and the supporting JS (loadDeviceConfig / renderDeviceGrid / removeDevice / saveDeviceConfig / updateDeviceStatus).
- Settings.html ends up with just Theme + System articles.
- Make the horse-diagram cells on the Recorder clickable → `/devices`. Each `.horse-pos` cell wraps in an `<a>`. Natural discovery path: sensor shows red/yellow, tap it, go fix it.
- Same nav pattern as Protocols: no top-nav link, reachable via the Recorder. Settings keeps its nav link since theme/system are still there.

**Tests:** extend `tests/test_startup.py` with `/devices` in `EXPECTED_ROUTES`. No new API surface, so no contract tests needed.

**Tradeoff:** the horse diagram on the Recorder becomes an interactive element, not just a status display. Mildly more complex HTML but it's the discovery path the user would want anyway.

---

## Fill in the user-facing doc stubs

**Status:** not started

**Motivation:** Three files under `docs/` are stubs — `getting-started.md` is 17 lines that defer to "individual component READMEs", and `field-usage.md` and `troubleshooting.md` are TODO placeholders. New users landing on the repo from `README.md` hit dead ends. The content needed is real onboarding and barn-side operation writing, not a quick 15-minute pass.

**Sketch:**
- `docs/getting-started.md` — walk through: flashing an M5StickC (cross-link to `hardware/m5stickc/README.md`), provisioning the Pi (`install.sh`), first WiFi pairing, opening the recorder and seeing a live horse diagram. Include a screenshot or two.
- `docs/field-usage.md` — the actual barnside workflow: powering on sensors, confirming connection on the diagram, running a protocol vs. manual recording, what the iteration counter means, downloading/uploading sessions afterward.
- `docs/troubleshooting.md` — sensor won't connect (WiFi handoff, battery), data not recording (UDP port, `systemctl status horse-recorder`), upgrade failures (how to read the test-gate output, rolling back), missing sessions (DATA_DIR permissions).
- After writing, update root `README.md` "What works today" list to reflect reality (protocols, themes, multi-sensor, test gate).

**Tradeoff:** it's a real writing project, not a code pass — best done in one focused session with enough barnside context to draw on, not interleaved with feature work.

---

## Firmware unit test harness (PlatformIO + Unity)

**Status:** not started

**Motivation:** Today the M5StickC firmware at `hardware/m5stickc/horse_sensor/horse_sensor.ino` has zero test coverage. That's been fine while the file was small and rarely touched, but as features accumulate (USB detection, charging state machine, future sleep modes, etc.) the risk of a silent regression grows. The Pi side has a strong test gate; firmware should too — ideally before the first bug slips through to a deployed stick.

**Sketch:**
- Migrate the project to PlatformIO (`platformio.ini` next to the `.ino`, or convert to a proper `src/main.cpp`). Keeps Arduino IDE compatibility.
- Refactor the state machine pieces (display mode, sync handling, batch buffering) into pure functions or small classes that don't directly touch `M5.Axp` / `M5.Lcd`. Hardware calls stay in the `.ino` entry points.
- Add PlatformIO `test_native` environment with Unity. Write tests for:
  - Display state transitions (plug in → on, unplug → timer reset, button press → on-with-timeout).
  - BAT message formatting (extend/contract the trailing fields).
  - Sync offset calculation.
- CI: add a second job to `.github/workflows/test.yml` running `pio test -e native`.

**Tests / Verification:** the refactor itself is the risky part — verify by running on the real sticks before/after and confirming identical UDP output for a 60s sample window.

**Tradeoff:** ~4 hours of setup + refactor. Pays off once firmware has ~2-3 more features layered on; premature today given the file is 400 lines and stable. Revisit when the next non-trivial change (e.g. sleep modes, multi-protocol support, sensor self-test) comes up.

---

## Auto-flash USB-tethered sticks (udev daemon)

**Status:** not started — manual fallback exists at `software/raspberry-pi/scripts/flash-stick.sh`.

**Motivation:** Two related pain points solved by the same mechanism. (1) If an OTA flash fails partway through (WiFi hiccup, power glitch), the stick is bricked until someone manually plugs it in and runs the flash script — defeats the point of going OTA-only. (2) A brand-new stick out of the box has no firmware and no WiFi credentials, so it can't participate in OTA at all; today this requires a manual flash. If the Pi could detect a USB-connected ESP32 and automatically flash whatever's currently checked into the firmware source, both cases collapse into "just plug it into the Pi's USB hub" — recovery and provisioning become invisible.

**Sketch:**
- udev rule (or `pyudev` watcher inside `horse_recorder`) fires on `/dev/ttyUSB*` arrival.
- Daemon checks an opt-in setting (`AUTO_USB_FLASH=true` in `.env`) before doing anything — don't want a random ESP32 plugged into the Pi getting silently reflashed.
- Optionally: probe the connected device's current firmware via serial (add a `VERSION?` command to the .ino's setup) and skip if already current. Without that probe, always reflash.
- Reuse `firmware_manager.build_bin()` to produce the .bin, then invoke the same `arduino-cli compile --upload` that `scripts/flash-stick.sh` runs.
- UI surface: when a USB device is detected, a row appears in the Settings device-config section like "New stick on /dev/ttyUSB2 — auto-flashing v1.0.4..." with a progress bar.
- First-boot provisioning falls out for free: the `config.h` Pi generates from `.env` already includes WiFi creds, so any freshly-flashed stick automatically joins the fleet.

**Tests / Verification:** unit-test the version-probe parser with a mocked serial. Real verification is manual — deliberately interrupt an OTA mid-stream to brick a stick, plug it into the Pi's USB hub, confirm it auto-recovers within ~30s and rejoins over WiFi.

**Tradeoff:** the Pi gains a background udev watcher and write permissions on `/dev/ttyUSB*` (already covered — install.sh adds the user to `dialout`). The bigger concern is "silently reflash anything plugged in" surprise, which the opt-in env flag addresses. Worth doing once OTA proves reliable enough that *failures* (rather than initial provisioning) are the primary use case — until then the manual script is fine.
