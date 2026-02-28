# Firmware Security Review

**Date:** 2025-01-20
**Scope:** ESP32-S3 firmware for VF9 Brightness Bridge

---

## Findings

### 🔴 S-01: BLE Advertising on Boot (Unverified)

**File:** `main/main.cpp` L21, `main/ble_hid_service.cpp` L78–87, L386–389

The firmware calls `start_advertising()` on boot with `ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY` and `ESP_IO_CAP_NONE` ("Just Works" pairing). If advertising is indeed active, any BLE device in range can connect and bond without user interaction.

The `ESP_BLE_SEC_ENCRYPT_MITM` flag set on connect is misleading — MITM protection is impossible with `IO_CAP_NONE`.

> **Status:** Needs verification. Initial testing showed the device does not appear in phone BLE scans, but this may be due to phone-side filtering. Verify with nRF Connect after a fresh boot, before any USB command is sent.

**Recommendation:**
- If pairing should only happen on explicit USB trigger, do **not** advertise on boot. Only call `start_advertising()` after `CMD_PAIRING_MODE`, and stop advertising once a bond is established.
- Alternatively, after bonding, switch to `ADV_FILTER_ALLOW_SCAN_WLST_CON_WLST` to reject new connections from unknown devices.
- Remove `ESP_BLE_SEC_ENCRYPT_MITM` from the connect handler or document that "Just Works" provides no MITM protection.

---

### 🔴 S-02: USB Serial Commands Have No Authentication

**File:** `main/command_handler.cpp` L99–130

Any process on the host that opens the USB CDC port can send destructive commands (`CMD_UNPAIR` 0x06, `CMD_PAIRING_MODE` 0x03) without authentication. This allows a rogue application to wipe BLE bonds or force re-pairing.

The ping nonce is echoed back verbatim — it is not a challenge-response mechanism and provides no security.

**Recommendation:**
- Add a shared-secret or challenge-response handshake before accepting `CMD_UNPAIR` and `CMD_PAIRING_MODE`.
- At minimum, require a confirmation sequence (e.g., send command twice within a window) to prevent accidental triggers.

---

### 🟡 S-03: NVS Not Encrypted

**File:** `sdkconfig` (CONFIG_NVS_ENCRYPTION is not set)

BLE bonding keys (LTK, IRK) are stored in NVS in plaintext. With physical access to the ESP32, an attacker can dump flash and extract bond keys to impersonate the device or the paired monitor.

**Recommendation:**
- Enable `CONFIG_NVS_ENCRYPTION=y` in sdkconfig.
- This requires a separate NVS key partition and flash encryption to be fully effective (see S-04).

---

### 🟡 S-04: No Secure Boot or Flash Encryption

**File:** `sdkconfig` L453–454

Neither Secure Boot nor flash encryption is enabled. Firmware can be read, modified, or replaced via UART or JTAG. Combined with unencrypted NVS, full key extraction and firmware tampering are trivial with physical access.

**Recommendation:**
- Enable Secure Boot v2 and flash encryption for production builds.
- Note: Once enabled, these are **irreversible** on most ESP32 variants. Test thoroughly in a development cycle before committing.

---

### 🟡 S-05: Hardcoded USB Serial Number

**File:** `main/usb_serial.cpp` L29–34

All devices use the same USB serial number `"000001"`. This prevents the host from distinguishing between multiple boards and can cause driver conflicts.

**Recommendation:**
- Derive a unique serial number from the chip's MAC address using `esp_efuse_mac_get_default()`.

---

### 🟢 S-06: Race Condition in CommandHandler

**File:** `main/command_handler.cpp` L37–43

The `nonce_timeout_cb` timer callback runs in the FreeRTOS timer daemon task, while `handle_byte` runs in the `usb_cmd_proc` task. Both read and mutate `state_` and `nonce_buf_` without synchronization. This is a potential race condition that could corrupt state or cause double-dispatch.

**Recommendation:**
- Protect `state_` and `nonce_buf_` with a mutex, or post the timeout event to the same queue consumed by `process_task` so all state mutations happen on a single task.

---

### 🟢 S-07: Verbose Logging in Production

**Files:** `main/usb_serial.cpp`, `main/command_handler.cpp`, `main/brightness_control.cpp`

Every received byte, command dispatch, and BLE operation is logged at `ESP_LOGI` level. This information is emitted over the UART console and reveals operational state to anyone with physical access.

**Recommendation:**
- Change byte-level and per-command tracing from `ESP_LOGI` to `ESP_LOGD`.
- Consider adding a build-time flag to strip verbose logs in release firmware.

---

## Summary

| ID   | Severity | Finding                          | Effort |
|------|----------|----------------------------------|--------|
| S-01 | 🔴 High  | BLE advertising on boot          | Medium |
| S-02 | 🔴 High  | USB commands unauthenticated     | Medium |
| S-03 | 🟡 Med   | NVS not encrypted                | Low    |
| S-04 | 🟡 Med   | No secure boot / flash encrypt   | High   |
| S-05 | 🟡 Med   | Hardcoded USB serial number      | Low    |
| S-06 | 🟢 Low   | Timer/task race condition        | Low    |
| S-07 | 🟢 Low   | Verbose logging leaks state      | Low    |

### Suggested Priority

1. **S-01** — Verify advertising behavior; restrict if confirmed.
2. **S-02** — Add authentication for destructive USB commands.
3. **S-05** — Use unique serial numbers (quick fix).
4. **S-06** — Add mutex or unify task context.
5. **S-07** — Reduce log verbosity.
6. **S-03 / S-04** — Enable NVS encryption and secure boot for production.