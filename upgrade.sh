#!/bin/bash
# Lame Data - Upgrade Script
# Pulls latest code, runs tests, and restarts the recorder service.
#
# Safe to run without sudo (tests still run; service won't be restarted).
# The re-exec block below means any upgrade.sh changes in the pulled commit
# take effect immediately — you can change the upgrade steps themselves and
# the NEXT upgrade will already be using the new logic.

set -eu -o pipefail

# Guard against being sourced. `exec bash "$0"` below would otherwise replace
# the user's login shell — disastrous when the only way back in is SSH.
if [ "${BASH_SOURCE[0]:-$0}" != "$0" ]; then
    echo "upgrade.sh must be executed, not sourced." >&2
    return 1 2>/dev/null || exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_DIR="$SCRIPT_DIR/software/raspberry-pi"
VENV_DIR="$PI_DIR/venv"

# Files the running app mutates at runtime. These are gitignored, but we
# belt-and-suspenders backup-restore them around `git pull` so that:
#   1. The first upgrade that brings in the untrack commit still preserves
#      the user's current state (the pull deletes the tracked file from
#      disk; restore brings it back).
#   2. Any locally-modified tracked file we accidentally re-commit in the
#      future can't block an upgrade — we wipe local diffs before pull and
#      restore afterwards.
# The user's runtime state always wins over upstream — that's the right
# call for per-Pi config. The "Restore defaults" button on /protocols is
# the escape hatch when they want seeds back.
RUNTIME_STATE_FILES=(
    "$PI_DIR/protocols.json"
    "$PI_DIR/device_config.json"
)

# Make any non-zero exit visually unambiguous. The systemd service is NOT
# touched until the very last step, so any failure before then leaves the
# Pi running the previous working version.
trap 'rc=$?; if [ $rc -ne 0 ]; then
        echo ""
        echo "==================================="
        echo "  Upgrade ABORTED (exit $rc)"
        echo "  Previous service is still running."
        echo "==================================="
    fi' EXIT

echo "==================================="
echo "  Lame Data - Upgrade"
echo "==================================="
echo ""

# Check for uncommitted changes before touching the working tree.
if ! git -C "$SCRIPT_DIR" diff --quiet 2>/dev/null; then
    echo "Warning: You have local changes that may be overwritten."
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Upgrade cancelled."
        exit 1
    fi
fi

# [1/5] Pull latest code FIRST so the re-exec below picks up any changes to
# this script itself.
echo "[1/5] Pulling latest code..."

# Snapshot runtime-state files so they survive the pull no matter what git
# does (deletes via an untrack commit, modifies via a new seed, etc.).
for f in "${RUNTIME_STATE_FILES[@]}"; do
    if [ -f "$f" ]; then
        cp "$f" "$f.upgrade-backup"
    fi
done

# Clear any git diff on runtime-state files so pull isn't blocked. Ignore
# errors — file may be untracked already, which is the steady state.
for f in "${RUNTIME_STATE_FILES[@]}"; do
    rel="${f#$SCRIPT_DIR/}"
    git -C "$SCRIPT_DIR" checkout HEAD -- "$rel" 2>/dev/null || true
done

git -C "$SCRIPT_DIR" pull

# Restore runtime state from the pre-pull snapshot.
for f in "${RUNTIME_STATE_FILES[@]}"; do
    if [ -f "$f.upgrade-backup" ]; then
        mv "$f.upgrade-backup" "$f"
    fi
done
echo "  Done"

# Re-exec into the just-pulled version of this script so that changes to
# the upgrade flow (new steps, new gate logic) take effect on this very run,
# not just the next one. The sentinel env var breaks the loop — the child
# invocation sees UPGRADE_REEXEC=1 and skips this block.
#
# We syntax-check the new script first. A malformed upgrade.sh caught here
# leaves the running service untouched; without this check, `exec bash` on
# a broken file would error partway through and could leave us in a weird
# state.
if [ -z "${UPGRADE_REEXEC:-}" ]; then
    if ! bash -n "$0"; then
        echo "Pulled upgrade.sh has a syntax error — aborting before re-exec." >&2
        exit 1
    fi
    export UPGRADE_REEXEC=1
    exec bash "$0" "$@"
fi

# [2/5] Update dependencies.
echo ""
echo "[2/5] Updating dependencies..."
"$VENV_DIR/bin/pip" install -q -r "$PI_DIR/requirements.txt"
"$VENV_DIR/bin/pip" install -q -r "$PI_DIR/requirements-dev.txt"
echo "  Done"

# [3/5] Run tests BEFORE touching the running service — a bad pull should
# leave the Pi on the previous working version rather than a broken one.
echo ""
echo "[3/5] Running tests..."
if ! "$VENV_DIR/bin/pytest" -x --tb=short "$PI_DIR/tests"; then
    echo ""
    echo "  Tests failed. Keeping existing service running."
    echo "  Inspect the failure above, fix, commit, and re-run upgrade.sh."
    exit 1
fi
echo "  Passed"

# [4/5] Pre-build the firmware so fleet-flash clicks skip the ~30s arduino-cli
# compile. Best-effort: if it fails (toolchain missing, compile error), the
# next flash will rebuild on demand. We don't want a firmware glitch to
# block a Pi software upgrade.
echo ""
echo "[4/5] Pre-building firmware (so fleet flashes are instant later)..."
"$VENV_DIR/bin/python" "$PI_DIR/scripts/prebuild_firmware.py" || \
    echo "  (continuing despite prebuild failure)"

# [5/5] Restart services.
echo ""
echo "[5/5] Restarting services..."
if [ "$EUID" -eq 0 ]; then
    systemctl restart horse-recorder
    echo "  horse-recorder restarted"
else
    echo "  Run with sudo to restart services, or manually run:"
    echo "    sudo systemctl restart horse-recorder"
fi

echo ""
echo "==================================="
echo "  Upgrade Complete!"
echo "==================================="
echo ""
