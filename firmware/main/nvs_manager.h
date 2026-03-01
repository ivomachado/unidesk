#pragma once

#include "esp_err.h"
#include <cstdint>

class NvsManager {
public:
    static constexpr uint32_t ESC_DEBOUNCE_DEFAULT_MS = 2000;
    static constexpr uint32_t ESC_DEBOUNCE_MIN_MS     = 200;
    static constexpr uint32_t ESC_DEBOUNCE_MAX_MS     = 10000;

    /// Initialize NVS flash. Handles ESP_ERR_NVS_NO_FREE_PAGES by erasing and reinitializing.
    static esp_err_t init();

    /// Erase the BLE bonding namespace to force re-pairing.
    static esp_err_t clear_bonds();

    /// Check whether any BLE bond keys exist in NVS.
    static bool is_bonded();

    /// Read the ESC debounce timeout from NVS. Returns the default if not set.
    static uint32_t get_esc_debounce_ms();

    /// Persist the ESC debounce timeout to NVS. Clamps to [ESC_DEBOUNCE_MIN_MS, ESC_DEBOUNCE_MAX_MS].
    static esp_err_t set_esc_debounce_ms(uint32_t ms);
};