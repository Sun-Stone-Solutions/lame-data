#!/bin/bash
# Flash a USB-connected M5StickC with the current firmware version.
#
# Two scenarios this handles:
#   1. Initial OTA-bootstrap: a brand-new stick (or one with the wrong
#      partition table) needs one USB flash before OTA can take over.
#   2. Recovery: an OTA flash failed and left a stick in a non-bootable
#      state. Plug it into the Pi over USB, run this, back to working.
#
# Usage:
#   ./flash-stick.sh                  # auto-detect single connected stick
#   PORT=/dev/ttyUSB1 ./flash-stick.sh   # explicit port
#
# Compile flags match firmware_manager.py exactly so OTA and USB flashes
# produce identical partition tables.

set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FW_SRC="$REPO_ROOT/hardware/m5stickc/horse_sensor"

FQBN="${FIRMWARE_FQBN:-m5stack:esp32:m5stack_stickc_plus}"
PARTITIONS="${FIRMWARE_PARTITIONS:-min_spiffs}"
RECORDER_URL="${RECORDER_URL:-http://127.0.0.1:5000}"

# --- Locate the USB serial port ---------------------------------------------
PORT="${PORT:-}"
if [ -z "$PORT" ]; then
    mapfile -t PORTS < <(ls /dev/ttyUSB* 2>/dev/null || true)
    case ${#PORTS[@]} in
        0)
            echo "ERROR: no /dev/ttyUSB* found." >&2
            echo "       Plug an M5StickC into the Pi via USB and retry." >&2
            exit 1
            ;;
        1)
            PORT="${PORTS[0]}"
            ;;
        *)
            echo "Multiple USB serial devices detected:" >&2
            for p in "${PORTS[@]}"; do echo "  $p" >&2; done
            echo "Re-run with: PORT=/dev/ttyUSBN $0" >&2
            exit 1
            ;;
    esac
fi

# --- Sanity-check the toolchain --------------------------------------------
if ! command -v arduino-cli >/dev/null 2>&1; then
    echo "ERROR: arduino-cli not installed." >&2
    echo "       Run 'sudo $REPO_ROOT/install.sh' to install the firmware toolchain." >&2
    exit 1
fi

# --- Read the version we're about to flash ---------------------------------
VERSION=$(grep 'FIRMWARE_VERSION' "$FW_SRC/horse_sensor.ino" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$VERSION" ]; then
    echo "ERROR: could not parse FIRMWARE_VERSION from $FW_SRC/horse_sensor.ino" >&2
    exit 1
fi

# --- Refuse to flash while a recording is active (matches OTA gate) ---------
if curl -s --max-time 2 "$RECORDER_URL/api/status" 2>/dev/null \
    | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('is_recording') else 1)" 2>/dev/null; then
    echo "ERROR: a recording is currently active. Stop it before flashing." >&2
    exit 1
fi

echo "============================================="
echo "  Flashing $PORT"
echo "  Firmware:   v$VERSION"
echo "  FQBN:       $FQBN"
echo "  Partitions: $PARTITIONS"
echo "============================================="
echo

arduino-cli compile --fqbn "$FQBN" \
    --build-property "build.partitions=$PARTITIONS" \
    --upload --port "$PORT" \
    "$FW_SRC"

echo
echo "Flash complete. Waiting 25s for the stick to reconnect via WiFi..."
sleep 25

# --- Verify it landed ------------------------------------------------------
echo
echo "Sticks currently reporting v$VERSION on the recorder:"
curl -s --max-time 3 "$RECORDER_URL/api/status" 2>/dev/null \
    | python3 -c "
import json, sys
target = '$VERSION'
data = json.load(sys.stdin)
hits = [(id, s) for id, s in data.get('device_status', {}).items()
        if s.get('connected') and s.get('firmware_version') == target]
if not hits:
    print('  (none — check the stick LCD; it may still be reconnecting)')
else:
    for id, s in sorted(hits):
        print(f'  {id}: battery={s.get(\"percent\")}%  charging={s.get(\"charging\")}')
" 2>/dev/null || echo "  (could not reach $RECORDER_URL/api/status)"
