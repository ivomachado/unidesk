#include "nvs_manager.h"

#include <cstring>
#include "esp_log.h"
#include "nvs_flash.h"
#include "nvs.h"

static const char *TAG = "NvsManager";

// Bluedroid stores BLE bonding keys under this NVS namespace
static const char *BLE_BOND_NVS_NAMESPACE = "bt_config";

esp_err_t NvsManager::init() {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "NVS partition truncated or version mismatch, erasing...");
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    if (err == ESP_OK) {
        ESP_LOGI(TAG, "NVS initialized successfully");
    } else {
        ESP_LOGE(TAG, "NVS init failed: %s", esp_err_to_name(err));
    }
    return err;
}

esp_err_t NvsManager::clear_bonds() {
    ESP_LOGI(TAG, "Clearing BLE bond data from NVS");

    nvs_handle_t handle;
    esp_err_t err = nvs_open(BLE_BOND_NVS_NAMESPACE, NVS_READWRITE, &handle);
    if (err == ESP_OK) {
        err = nvs_erase_all(handle);
        if (err == ESP_OK) {
            err = nvs_commit(handle);
            ESP_LOGI(TAG, "Bond data cleared successfully");
        } else {
            ESP_LOGE(TAG, "Failed to erase bond data: %s", esp_err_to_name(err));
        }
        nvs_close(handle);
    } else if (err == ESP_ERR_NVS_NOT_FOUND) {
        // Namespace doesn't exist yet — no bonds to clear
        ESP_LOGI(TAG, "No bond namespace found, nothing to clear");
        err = ESP_OK;
    } else {
        ESP_LOGE(TAG, "Failed to open bond namespace: %s", esp_err_to_name(err));
    }
    return err;
}

bool NvsManager::is_bonded() {
    nvs_handle_t handle;
    esp_err_t err = nvs_open(BLE_BOND_NVS_NAMESPACE, NVS_READONLY, &handle);
    if (err != ESP_OK) {
        // Namespace doesn't exist — no bonds
        return false;
    }

    // Iterate over entries in the namespace to see if any keys exist
    nvs_iterator_t it = nullptr;
    err = nvs_entry_find_in_handle(handle, NVS_TYPE_ANY, &it);
    bool has_entries = (err == ESP_OK && it != nullptr);

    if (it != nullptr) {
        nvs_release_iterator(it);
    }

    nvs_close(handle);
    return has_entries;
}