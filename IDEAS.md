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
