# Serial Protocol

Communication protocol between the macOS app and the ESP32-S3 firmware over USB-CDC serial.

The ESP32-S3 appears as a CDC ACM device at `/dev/cu.usbmodem*` with VID `0x303A` (Espressif) and PID `0x4001`.

---

## Port Configuration

- **Baud rate:** 115200
- **Data bits:** 8
- **Stop bits:** 1
- **Parity:** None
- **Flow control:** None
- **DTR/RTS:** Must be explicitly asserted by the host after every `open()` call via `ioctl(TIOCSDTR)` and `ioctl(TIOCMBIS, TIOCM_RTS)`. Without this, the ESP32 USB-CDC may not process incoming bytes on reconnections.

---

## Commands (Mac → ESP32)

Commands are single bytes, except for the handshake which includes a nonce.

| Bytes                         | Command              | Description                                          |
|-------------------------------|----------------------|------------------------------------------------------|
| `0x01`                        | Brightness Up        | Send BLE HID brightness increment to paired monitor (fire-and-forget — no response) |
| `0x02`                        | Brightness Down      | Send BLE HID brightness decrement to paired monitor (fire-and-forget — no response) |
| `0x03`                        | Enter Pairing Mode   | Clear NVS bonds, restart BLE advertising             |
| `0x04` `<nonce>` `\n`         | Handshake / Ping     | Verify firmware is alive; nonce is echoed back        |
| `0x05`                        | Get Status           | Query BLE connection state and paired device name     |
| `0x06`                        | Unpair               | Clear BLE bond, disconnect if connected               |
| `0x07` `<ms_hi>` `<ms_lo2>` `<ms_lo1>` `<ms_lo0>` | Set ESC Debounce | Set and persist the ESC dismiss debounce timeout (4 bytes, big-endian uint32, milliseconds; clamped to 200–10000) |
| `0x08`                        | Get ESC Debounce     | Query the current ESC debounce timeout                |
| `0x09`                        | ESC Key              | Send HID Keyboard ESC to the monitor (fire-and-forget — no response) |
| `0x0A`                        | FiiO Volume Up       | Send quadrature volume increment to the FiiO K11 R2R DAC (fire-and-forget — no response) |
| `0x0B`                        | FiiO Volume Down     | Send quadrature volume decrement to the FiiO K11 R2R DAC (fire-and-forget — no response) |

### Set ESC Debounce Format

The set-ESC-debounce command (`0x07`) is followed by exactly **4 bytes** encoding the desired timeout in milliseconds as a big-endian unsigned 32-bit integer. No terminator byte is needed — the firmware reads exactly 4 bytes after the command byte.

```
0x07 <byte3> <byte2> <byte1> <byte0>
```

Example — set 1500 ms (0x000005DC):

```
0x07 0x00 0x00 0x05 0xDC
```

The firmware clamps the value to the range **200–10000 ms** before applying and persisting it.

---

### Handshake Format

The handshake command (`0x04`) is followed by a **4-character random hex nonce** and a newline:

```
0x04 a 3 f 2 \n
```

The nonce allows the macOS app to distinguish a fresh handshake response from stale `OK:PING:*` responses that may be buffered in the ESP32's USB-CDC from previous sessions. Without nonce matching, reconnection would require drain delays.

---

## Responses (ESP32 → Mac)

All responses are **newline-terminated ASCII strings** prefixed by a tag (`OK`, `STATUS`, or `ERR`).

| Response                                    | After Command | Description                                                        |
|---------------------------------------------|---------------|--------------------------------------------------------------------|
| `OK:PING:<nonce>\n`                         | `0x04`        | Firmware is alive; `<nonce>` matches the hex string sent by host   |
| _(none)_                                    | `0x01`        | Fire-and-forget — no response sent                                 |
| _(none)_                                    | `0x02`        | Fire-and-forget — no response sent                                 |
| _(none)_                                    | `0x09`        | Fire-and-forget — no response sent                                 |
| _(none)_                                    | `0x0A`        | Fire-and-forget — no response sent                                 |
| _(none)_                                    | `0x0B`        | Fire-and-forget — no response sent                                 |
| `OK:PAIRING\n`                              | `0x03`        | NVS cleared, BLE advertising restarted in pairing mode             |
| `OK:UNPAIRED\n`                             | `0x06`        | BLE bond cleared                                                   |
| `STATUS:<connected\|disconnected>:<name>\n` | `0x05`        | BLE state and paired device name (empty string if none paired)     |
| `OK:ESC_DEBOUNCE:<ms>\n`                    | `0x07`        | Confirms the new debounce value (clamped); `<ms>` is a decimal integer |
| `OK:ESC_DEBOUNCE:<ms>\n`                    | `0x08`        | Current debounce timeout in milliseconds                           |
| `ERR:<message>\n`                           | Any (except `0x01`, `0x02`, `0x09`, `0x0A`, `0x0B`) | Human-readable error                                |

### Known Error Messages

| Error               | Meaning                                          |
|----------------------|--------------------------------------------------|
| `ERR:NOT_CONNECTED`  | BLE not connected to monitor; can't send HID     |
| `ERR:UNKNOWN_CMD`    | Unrecognized command byte                         |

---

## Response Parsing

The macOS app reads bytes until `\n`, then parses:

1. Split on the first `:` to get the **tag** (`OK`, `STATUS`, `ERR`).
2. For `OK` responses, split the remainder to get the sub-tag (`PING`, `UP`, `DOWN`, `PAIRING`, `UNPAIRED`).
3. For `OK:PING:<nonce>`, compare the nonce against the expected value. Discard if it doesn't match (stale response).
4. For `STATUS`, split the remainder on `:` to get the connection state and device name.
5. For `ERR`, the remainder is the error message.

---

## Stale Response Handling

The ESP32 USB-CDC buffers data across sessions. When the macOS app reopens the port and sends the first byte, the ESP32 may process and emit previously buffered responses from earlier sessions. Acting on those stale messages would be incorrect.

The handshake nonce solves this: after opening the port the app sends `0x04` with a random nonce and discards incoming responses until it sees `OK:PING:<matching-nonce>`. No drain delays or timing heuristics are needed — the handshake ensures the host only acts on fresh messages for the current session.

Unsolicited status messages (OSD)
The firmware may emit unsolicited newline-terminated status messages at any time (for example `OK:OSD:1` when the monitor OSD becomes visible, and `OK:OSD:0` when it is hidden). When the serial port is open the macOS app continuously reads incoming lines, but by default the app correlates lines to outstanding requests and ignores unsolicited responses.

To support OSD-driven behavior, the host must explicitly handle unsolicited `OK:OSD:1/0` messages and update local state (for example, a published `osdActive: Bool`). Important rules for correct behavior:

- Only act on unsolicited OSD messages after the handshake completes for the current session, so stale buffered OSD flags are not applied. The handshake already provides this protection.
- Treat `OK:OSD:1` / `OK:OSD:0` as fire-and-forget notifications from the firmware; they do not require a request from the host.
- The macOS app should update a published flag (e.g. `osdActive`) when it receives these messages while connected.
- `KeyInterceptor` (or `BrightnessRouter`) should consult `osdActive` and the active screen; if `osdActive == true` and the cursor is over the target monitor, the event tap may swallow the Esc event (return `nil`) to prevent local delivery.
- Make this feature opt-in and gated by connection state; do not queue or persist OSD notifications while disconnected.

This approach is feasible because the firmware already sends newline-terminated responses via USB-CDC and the host already reads them while the port is open; the only required change is to stop treating unsolicited lines as inert logs and instead parse and handle the `OSD` status messages.

---

## Timing

| Parameter             | Value   | Notes                                                   |
|-----------------------|---------|---------------------------------------------------------|
| Handshake timeout     | 2–3 s   | If no matching `OK:PING` arrives, report firmware error |
| Command timeout       | 5 s     | For brightness/pairing/status commands                  |
| Reconnect delay       | 2 s     | Wait before retrying after a disconnect                 |

---

## Connection Lifecycle

1. **Discovery:** macOS app enumerates `/dev/cu.usbmodem*` and matches ESP32-S3 by VID/PID via IOKit.
2. **Open:** POSIX `open()` on the serial port, configure `termios`, assert DTR/RTS.
3. **Handshake:** Send `0x04` + nonce + `\n`, wait for `OK:PING:<nonce>`.
4. **Status query:** Send `0x05`, parse `STATUS:` response to get BLE state.
5. **Normal operation:** Send `0x01`/`0x02` for brightness, `0x0A`/`0x0B` for FiiO volume commands as needed.
6. **Disconnect detection:** Read returns 0 or error → mark disconnected, attempt reconnect after delay.
7. **Sleep/wake:** On `NSWorkspace.didWakeNotification`, close and reopen the port, re-handshake.
8. **USB plug/unplug:** Detected via `IOServiceAddMatchingNotification` for automatic connect/disconnect.