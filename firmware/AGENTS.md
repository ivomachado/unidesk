# Firmware — Agent Landmines

- Console output must be routed to **UART0** (`CONFIG_ESP_CONSOLE_UART_DEFAULT=y`), not USB. The native USB port is used for CDC serial communication with the macOS app — routing console logs there causes conflicts and garbled data.
- The ESC key sent after brightness Consumer Control reports must be **debounced** (400ms timeout). During rapid brightness adjustments (key held down), only a single ESC should be sent after the burst settles. Without this, the monitor's OSD flickers on every keystroke.
- NVS init must handle `ESP_ERR_NVS_NO_FREE_PAGES` by erasing and reinitializing. Without this, the firmware crashes on first boot after a flash erase.
- BLE task stack sizes must be at least **4096 bytes**. BLE callbacks (GAP, GATT, SMP) consume significant stack — smaller sizes cause silent stack overflows and random crashes.
- The HID Report Map must declare Consumer Control with a **16-bit usage range** (not 8-bit). The ViewFinity S9 ignores reports with an 8-bit descriptor.
- Brightness press/release timing: **20ms** between press and release, **50ms** before sending ESC. Too fast and the monitor ignores the report; too slow and it may auto-repeat.
- BLE and USB coexist without resource conflicts (radio vs USB peripheral), but they must be initialized in order: NVS → BLE → USB-CDC.
- Bond storage is limited to ~10 devices by default in ESP-IDF. For this use case only 1 bond (the monitor) is needed. Pairing mode (`0x03`) clears all bonds before re-advertising.