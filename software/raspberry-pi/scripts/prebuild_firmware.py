"""Pre-build the firmware .bin and cache it on disk.

Called from install.sh and upgrade.sh so the first fleet-flash request after
a Pi upgrade doesn't have to wait through arduino-cli compile —
firmware_manager.build_bin() finds the cached .bin already in place and
skips straight to the espota push.

Best-effort: if the toolchain isn't installed yet, or compile fails, we
print and exit 0 (toolchain absent) or 1 (real failure) but the calling
shell script tolerates either — pre-build is a warm-up cache, not a gate.
"""
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PI_DIR = SCRIPT_DIR.parent
sys.path.insert(0, str(PI_DIR))

from dotenv import load_dotenv
load_dotenv(PI_DIR / '.env')

import firmware_manager  # noqa: E402

if not firmware_manager.toolchain_installed():
    print("  arduino-cli + m5stack:esp32 core not installed; skipping prebuild.")
    sys.exit(0)

print(f"  Pre-building firmware v{firmware_manager.available_version()}...")
try:
    firmware_manager.build_bin()
except RuntimeError as e:
    print(f"  Prebuild failed (non-fatal): {e}")
    sys.exit(1)

if firmware_manager.FIRMWARE_BIN.exists():
    size_kb = firmware_manager.FIRMWARE_BIN.stat().st_size // 1024
    print(f"  Built {firmware_manager.FIRMWARE_BIN.name} ({size_kb} KB) — fleet flashes will skip the build phase.")
else:
    print("  Build completed but FIRMWARE_BIN missing; the next flash will rebuild.")
    sys.exit(1)
