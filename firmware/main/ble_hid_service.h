#pragma once

#include <string>
#include <functional>

#include "esp_err.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"

class BleHidService {
public:
    static BleHidService& instance();

    /// Initialize the BLE stack, register GATT services, and start advertising.
    esp_err_t init();

    /// Start BLE advertising (directed if bonded, undirected otherwise).
    void start_advertising();

    /// Stop BLE advertising.
    void stop_advertising();

    /// Send a Consumer Control HID report (Report ID 1).
    /// @param usage_code 16-bit usage code (e.g. 0x006F for brightness up, 0x0000 for release).
    /// @return true if the report was sent successfully.
    bool send_consumer_report(uint16_t usage_code);

    /// Send a Keyboard HID report (Report ID 2).
    /// @param modifier Modifier byte (bit flags for Ctrl, Shift, etc.).
    /// @param keycodes Array of up to 6 keycodes. Pass nullptr for release (all zeros).
    /// @return true if the report was sent successfully.
    bool send_keyboard_report(uint8_t modifier, const uint8_t keycodes[6]);

    /// Send a keyboard release (all zeros) on Report ID 2.
    bool send_keyboard_release();

    /// Whether a BLE client (monitor) is currently connected.
    bool is_connected() const;

    /// Get the name of the connected/bonded peer device.
    std::string get_peer_name() const;

    /// Clear bonds and restart undirected advertising for new pairing.
    void enter_pairing_mode();

    /// Clear bonds and disconnect if connected.
    void unpair();

private:
    BleHidService() = default;
    ~BleHidService() = default;
    BleHidService(const BleHidService&) = delete;
    BleHidService& operator=(const BleHidService&) = delete;

    // GAP event handler
    static void gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param);

    // GATTS event handler
    static void gatts_event_handler(esp_gatts_cb_event_t event, esp_gatt_if_t gatts_if,
                                    esp_ble_gatts_cb_param_t *param);

    // GATTS profile event handler for our app
    void handle_gatts_event(esp_gatts_cb_event_t event, esp_gatt_if_t gatts_if,
                            esp_ble_gatts_cb_param_t *param);

    // Register the HID service and characteristics
    void register_hid_service();

    // Configure BLE security parameters
    void configure_security();

    // Internal state
    bool connected_ = false;
    bool service_registered_ = false;
    uint16_t conn_id_ = 0;
    esp_gatt_if_t gatts_if_ = ESP_GATT_IF_NONE;
    std::string peer_name_;

    // GATT attribute handles
    uint16_t hid_svc_handle_ = 0;
    uint16_t hid_info_handle_ = 0;
    uint16_t report_map_handle_ = 0;
    uint16_t protocol_mode_handle_ = 0;

    // Consumer Control report (Report ID 1)
    uint16_t consumer_report_handle_ = 0;
    uint16_t consumer_report_ccc_handle_ = 0;
    uint16_t consumer_report_ref_handle_ = 0;

    // Keyboard report (Report ID 2)
    uint16_t keyboard_report_handle_ = 0;
    uint16_t keyboard_report_ccc_handle_ = 0;
    uint16_t keyboard_report_ref_handle_ = 0;

    // Battery Service handles
    uint16_t battery_svc_handle_ = 0;
    uint16_t battery_level_handle_ = 0;
    uint16_t battery_level_ccc_handle_ = 0;

    // Device Information Service handles
    uint16_t devinfo_svc_handle_ = 0;
    uint16_t manufacturer_handle_ = 0;
    uint16_t model_handle_ = 0;
    uint16_t pnp_id_handle_ = 0;

    // Advertising data
    static esp_ble_adv_params_t adv_params_;
};