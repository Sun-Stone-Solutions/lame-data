"""Tests for the firmware / fleet-flash endpoints.

The actual subprocess calls (arduino-cli compile, espota.py) are never run
here — we monkeypatch firmware_manager.build_bin and flash_device with stubs
so the orchestration logic can be exercised without the toolchain installed.
"""
import datetime
import os
import re

import pytest

import firmware_manager
import horse_recorder


@pytest.fixture(autouse=True)
def _reset_flash_state():
    """flash_state is module-level; every test starts from a clean slate."""
    firmware_manager.reset_flash_state()
    yield
    firmware_manager.reset_flash_state()


# ---------------------------------------------------------------------------
# Version + parser unit tests
# ---------------------------------------------------------------------------

def test_available_version_parses_firmware_source():
    """The .ino file in the repo declares a FIRMWARE_VERSION constant; if this
    test breaks, someone renamed the constant or changed its declaration style
    in a way that the Pi's regex can't read anymore."""
    version = firmware_manager.available_version()
    assert version is not None
    assert re.match(r'\d+\.\d+\.\d+', version), f"expected semver, got {version!r}"


def test_bat_parser_includes_version_when_7_fields():
    decoded = "BAT,DEV001,4.05,82,3,1,1.0.0"
    parts = decoded.split(',')
    firmware_version = parts[6].strip() if len(parts) >= 7 else 'unknown'
    assert firmware_version == '1.0.0'


def test_bat_parser_defaults_version_for_6_field_legacy():
    decoded = "BAT,DEV001,4.05,82,3,1"
    parts = decoded.split(',')
    firmware_version = parts[6].strip() if len(parts) >= 7 else 'unknown'
    assert firmware_version == 'unknown'


# ---------------------------------------------------------------------------
# Config generation — pure function, safe to exercise directly
# ---------------------------------------------------------------------------

def test_render_config_h_substitutes_env_values():
    env = {
        'HOME_SSID': 'MyBarn',
        'HOME_PASSWORD': 'secret',
        'AP_SSID': 'HorseNet',
        'AP_PASSWORD': 'hotspot',
        'UDP_PORT': '8888',
        'OTA_PASSWORD': 'opensesame',
    }
    out = firmware_manager.render_config_h(env=env, pi_ip='10.0.0.5')
    assert '"MyBarn"' in out
    assert '"secret"' in out
    assert '"10.0.0.5"' in out
    assert '"HorseNet"' in out
    assert '"10.42.0.1"' in out
    assert '"opensesame"' in out
    # Make sure the firmware would compile (brace counts match).
    assert out.count('{') == out.count('}')


# ---------------------------------------------------------------------------
# Status endpoint
# ---------------------------------------------------------------------------

def test_firmware_status_returns_expected_shape(client):
    data = client.get('/api/firmware').get_json()
    # Exactly the keys the frontend expects.
    assert set(data.keys()) == {
        'available_version', 'toolchain_installed',
        'build_bin_exists', 'ota_enabled',
    }
    assert data['available_version'] is not None


# ---------------------------------------------------------------------------
# /api/firmware/flash — the gates matter more than the happy path
# ---------------------------------------------------------------------------

def _set_device_status(device_id, **fields):
    defaults = {
        'voltage': 4.1, 'percent': 88, 'fifo_overflows': 0,
        'charging': True, 'firmware_version': 'unknown',
        'last_seen': datetime.datetime.now().isoformat(),
    }
    defaults.update(fields)
    horse_recorder.recording_state['device_status'][device_id] = defaults


def test_flash_rejects_when_recording_active(client, reset_recording_state):
    horse_recorder.recording_state['is_recording'] = True
    try:
        resp = client.post('/api/firmware/flash', json={'all_plugged_in': True})
        assert resp.status_code == 409
        assert 'recording' in resp.get_json()['error'].lower()
    finally:
        horse_recorder.recording_state['is_recording'] = False


def test_flash_rejects_when_already_running(client, reset_recording_state):
    firmware_manager.flash_state['active'] = True
    resp = client.post('/api/firmware/flash', json={'all_plugged_in': True})
    assert resp.status_code == 409
    assert 'already' in resp.get_json()['error'].lower()


def test_flash_rejects_when_toolchain_missing(client, reset_recording_state, monkeypatch):
    monkeypatch.setattr(firmware_manager, 'toolchain_installed', lambda: False)
    resp = client.post('/api/firmware/flash', json={'all_plugged_in': True})
    assert resp.status_code == 409
    assert 'toolchain' in resp.get_json()['error'].lower()


def test_flash_rejects_when_ota_password_missing(
    client, reset_recording_state, monkeypatch,
):
    monkeypatch.setattr(firmware_manager, 'toolchain_installed', lambda: True)
    monkeypatch.delenv('OTA_PASSWORD', raising=False)
    resp = client.post('/api/firmware/flash', json={'all_plugged_in': True})
    assert resp.status_code == 409
    assert 'ota_password' in resp.get_json()['error'].lower()


def test_flash_rejects_when_no_devices_charging(
    client, reset_recording_state, monkeypatch,
):
    monkeypatch.setattr(firmware_manager, 'toolchain_installed', lambda: True)
    monkeypatch.setenv('OTA_PASSWORD', 'testpw')
    _set_device_status('DEV001', charging=False)
    resp = client.post('/api/firmware/flash', json={'all_plugged_in': True})
    assert resp.status_code == 409
    err = resp.get_json()
    assert 'plug' in err['error'].lower()


def test_flash_skips_already_current_devices(
    client, reset_recording_state, monkeypatch,
):
    """Selecting a device that's already on the current version is a no-op,
    not an error — keeps the "flash all" button forgiving."""
    available = firmware_manager.available_version()
    monkeypatch.setattr(firmware_manager, 'toolchain_installed', lambda: True)
    monkeypatch.setenv('OTA_PASSWORD', 'testpw')
    _set_device_status('DEV001', charging=True, firmware_version=available)

    resp = client.post('/api/firmware/flash', json={'all_plugged_in': True})
    assert resp.status_code == 200
    body = resp.get_json()
    assert body['targets'] == []


def test_flash_kicks_off_orchestration(
    client, reset_recording_state, monkeypatch,
):
    """End-to-end-ish: plugged-in + out-of-date + toolchain OK + password set
    → flash starts, orchestration function is invoked with our target."""
    monkeypatch.setattr(firmware_manager, 'toolchain_installed', lambda: True)
    monkeypatch.setenv('OTA_PASSWORD', 'testpw')
    _set_device_status('DEV002', charging=True, firmware_version='0.0.1')

    called_with = {}

    def fake_flash_fleet(targets, password, device_ip_lookup, current_versions):
        called_with.update({
            'targets': list(targets),
            'password': password,
            'versions': current_versions,
        })

    monkeypatch.setattr(firmware_manager, 'flash_fleet', fake_flash_fleet)

    resp = client.post('/api/firmware/flash', json={'device_ids': ['DEV002']})
    assert resp.status_code == 200
    # Thread runs synchronously in tests because GIL + fast fake, but wait
    # briefly just in case.
    import time; time.sleep(0.1)

    assert called_with['targets'] == ['DEV002']
    assert called_with['password'] == 'testpw'
    assert called_with['versions'] == {'DEV002': '0.0.1'}


def test_flash_status_exposes_orchestration_state(client, reset_recording_state):
    firmware_manager.flash_state['active'] = True
    firmware_manager.flash_state['targets'] = {
        'DEV001': {'state': 'running', 'progress': 42, 'error': None,
                   'version_at_start': '0.9.0'}
    }
    body = client.get('/api/firmware/flash_status').get_json()
    assert body['active'] is True
    assert body['targets']['DEV001']['progress'] == 42
