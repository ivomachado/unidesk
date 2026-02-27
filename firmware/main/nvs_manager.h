#pragma once

#include "esp_err.h"

class NvsManager {
public:
    /// Initialize NVS flash. Handles ESP_ERR_NVS_NO_FREE_PAGES by erasing and reinitializing.
    static esp_err_t init();

    /// Erase the BLE bonding namespace to force re-pairing.
    static esp_err_t clear_bonds();

    /// Check whether any BLE bond keys exist in NVS.
    static bool is_bonded();
};