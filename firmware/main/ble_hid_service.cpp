#include "ble_hid_service.h"
#include "nvs_manager.h"

#include <cstring>
#include <algorithm>

#include "esp_log.h"
#include "esp_bt.h"
#include "esp_bt_main.h"
#include "esp_bt_device.h"
#include "esp_gap_ble_api.h"
#include "esp_gatts_api.h"
#include "esp_gatt_common_api.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "BleHidService";
static const char *DEVICE_NAME = "UniDesk - Bridge";
#define HID_APP_ID 0

// UUIDs
static const uint16_t PRIMARY_SERVICE_UUID   = ESP_GATT_UUID_PRI_SERVICE;
static const uint16_t CHAR_DECL_UUID         = ESP_GATT_UUID_CHAR_DECLARE;
static const uint16_t CHAR_CCC_UUID          = ESP_GATT_UUID_CHAR_CLIENT_CONFIG;
static const uint16_t HID_SVC_UUID           = ESP_GATT_UUID_HID_SVC;
static const uint16_t HID_INFO_UUID          = ESP_GATT_UUID_HID_INFORMATION;
static const uint16_t HID_REPORT_MAP_UUID    = ESP_GATT_UUID_HID_REPORT_MAP;
static const uint16_t HID_REPORT_UUID        = ESP_GATT_UUID_HID_REPORT;
static const uint16_t HID_PROTOCOL_MODE_UUID = 0x2A4E;
static const uint16_t HID_CONTROL_POINT_UUID = 0x2A4C;
static const uint16_t REPORT_REF_UUID        = ESP_GATT_UUID_RPT_REF_DESCR;
static const uint16_t BATTERY_SVC_UUID       = ESP_GATT_UUID_BATTERY_SERVICE_SVC;
static const uint16_t BATTERY_LEVEL_UUID     = ESP_GATT_UUID_BATTERY_LEVEL;
static const uint16_t DEVINFO_SVC_UUID       = 0x180A;
static const uint16_t MANUFACTURER_NAME_UUID = 0x2A29;
static const uint16_t MODEL_NUMBER_UUID      = 0x2A24;
static const uint16_t PNP_ID_UUID            = 0x2A50;

// HID Report Map
static const uint8_t hid_report_map[] = {
    // Report ID 1: Consumer Control
    0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01,
    0x85, 0x01, 0x15, 0x00, 0x26, 0xFF, 0x03,
    0x19, 0x00, 0x2A, 0xFF, 0x03,
    0x75, 0x10, 0x95, 0x01, 0x81, 0x00,
    0xC0,
    // Report ID 2: Keyboard
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
    0x85, 0x02,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7,
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01,
    0x05, 0x07, 0x19, 0x00, 0x29, 0xFF,
    0x15, 0x00, 0x26, 0xFF, 0x00,
    0x75, 0x08, 0x95, 0x06, 0x81, 0x00,
    0xC0
};

// Static data
static const uint8_t hid_info_val[] = {0x11, 0x01, 0x00, 0x02};
static uint8_t protocol_mode_val = 1;
static uint8_t hid_control_point_val = 0;
static uint8_t battery_level_val = 100;
static const char *manufacturer_name = "UniDesk";
static const char *model_number = "UniDesk-BB-01";
static const uint8_t pnp_id_val[] = {0x02, 0x3A, 0x03, 0x01, 0x10, 0x01, 0x00};

static uint8_t consumer_ccc_val[2] = {0x00, 0x00};
static uint8_t keyboard_ccc_val[2] = {0x00, 0x00};
static uint8_t battery_ccc_val[2]  = {0x00, 0x00};
static const uint8_t consumer_report_ref[2] = {0x01, 0x01};
static const uint8_t keyboard_report_ref[2] = {0x02, 0x01};

static const uint8_t char_prop_read             = ESP_GATT_CHAR_PROP_BIT_READ;
static const uint8_t char_prop_read_notify      = ESP_GATT_CHAR_PROP_BIT_READ | ESP_GATT_CHAR_PROP_BIT_NOTIFY;
static const uint8_t char_prop_read_write_no_rsp = ESP_GATT_CHAR_PROP_BIT_READ | ESP_GATT_CHAR_PROP_BIT_WRITE_NR;
static const uint8_t char_prop_write_no_rsp     = ESP_GATT_CHAR_PROP_BIT_WRITE_NR;

// Advertising parameters
esp_ble_adv_params_t BleHidService::adv_params_ = {
    .adv_int_min       = 0x20,
    .adv_int_max       = 0x40,
    .adv_type          = ADV_TYPE_IND,
    .own_addr_type     = BLE_ADDR_TYPE_PUBLIC,
    .peer_addr         = {0},
    .peer_addr_type    = BLE_ADDR_TYPE_PUBLIC,
    .channel_map       = ADV_CHNL_ALL,
    .adv_filter_policy = ADV_FILTER_ALLOW_SCAN_ANY_CON_ANY,
};

static esp_ble_adv_data_t adv_data = {
    .set_scan_rsp        = false,
    .include_name        = true,
    .include_txpower     = true,
    .min_interval        = 0x0006,
    .max_interval        = 0x0010,
    .appearance          = ESP_BLE_APPEARANCE_HID_KEYBOARD,
    .manufacturer_len    = 0,
    .p_manufacturer_data = nullptr,
    .service_data_len    = 0,
    .p_service_data      = nullptr,
    .service_uuid_len    = 0,
    .p_service_uuid      = nullptr,
    .flag                = (ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT),
};

static esp_ble_adv_data_t scan_rsp_data = {
    .set_scan_rsp        = true,
    .include_name        = true,
    .include_txpower     = true,
    .min_interval        = 0x0006,
    .max_interval        = 0x0010,
    .appearance          = ESP_BLE_APPEARANCE_HID_KEYBOARD,
    .manufacturer_len    = 0,
    .p_manufacturer_data = nullptr,
    .service_data_len    = 0,
    .p_service_data      = nullptr,
    .service_uuid_len    = 0,
    .p_service_uuid      = nullptr,
    .flag                = (ESP_BLE_ADV_FLAG_GEN_DISC | ESP_BLE_ADV_FLAG_BREDR_NOT_SPT),
};

// ---- HID Service table ----
enum {
    IDX_HID_SVC,
    IDX_HID_INFO_CHAR, IDX_HID_INFO_VAL,
    IDX_REPORT_MAP_CHAR, IDX_REPORT_MAP_VAL,
    IDX_PROTOCOL_MODE_CHAR, IDX_PROTOCOL_MODE_VAL,
    IDX_HID_CONTROL_CHAR, IDX_HID_CONTROL_VAL,
    IDX_CONSUMER_REPORT_CHAR, IDX_CONSUMER_REPORT_VAL, IDX_CONSUMER_REPORT_CCC, IDX_CONSUMER_REPORT_REF,
    IDX_KEYBOARD_REPORT_CHAR, IDX_KEYBOARD_REPORT_VAL, IDX_KEYBOARD_REPORT_CCC, IDX_KEYBOARD_REPORT_REF,
    HID_IDX_NB,
};

// ---- Battery Service table ----
enum {
    IDX_BAT_SVC,
    IDX_BAT_LEVEL_CHAR, IDX_BAT_LEVEL_VAL, IDX_BAT_LEVEL_CCC,
    BAT_IDX_NB,
};

// ---- Device Information Service table ----
enum {
    IDX_DIS_SVC,
    IDX_DIS_MANUFACTURER_CHAR, IDX_DIS_MANUFACTURER_VAL,
    IDX_DIS_MODEL_CHAR, IDX_DIS_MODEL_VAL,
    IDX_DIS_PNP_ID_CHAR, IDX_DIS_PNP_ID_VAL,
    DIS_IDX_NB,
};

static uint16_t hid_handle_table[HID_IDX_NB];
static uint16_t bat_handle_table[BAT_IDX_NB];
static uint16_t dis_handle_table[DIS_IDX_NB];

static uint8_t consumer_report_val[2] = {0};
static uint8_t keyboard_report_val[8] = {0};

// Track which service tables have been created (for sequential registration)
static int services_created = 0;

static const esp_gatts_attr_db_t hid_gatt_db[HID_IDX_NB] = {
    [IDX_HID_SVC] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&PRIMARY_SERVICE_UUID, ESP_GATT_PERM_READ, 2, 2, (uint8_t*)&HID_SVC_UUID}},
    [IDX_HID_INFO_CHAR] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_DECL_UUID, ESP_GATT_PERM_READ, 1, 1, (uint8_t*)&char_prop_read}},
    [IDX_HID_INFO_VAL]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&HID_INFO_UUID, ESP_GATT_PERM_READ, sizeof(hid_info_val), sizeof(hid_info_val), (uint8_t*)hid_info_val}},
    [IDX_REPORT_MAP_CHAR] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_DECL_UUID, ESP_GATT_PERM_READ, 1, 1, (uint8_t*)&char_prop_read}},
    [IDX_REPORT_MAP_VAL]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&HID_REPORT_MAP_UUID, ESP_GATT_PERM_READ, sizeof(hid_report_map), sizeof(hid_report_map), (uint8_t*)hid_report_map}},
    [IDX_PROTOCOL_MODE_CHAR] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_DECL_UUID, ESP_GATT_PERM_READ, 1, 1, (uint8_t*)&char_prop_read_write_no_rsp}},
    [IDX_PROTOCOL_MODE_VAL]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&HID_PROTOCOL_MODE_UUID, ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, 1, 1, &protocol_mode_val}},
    [IDX_HID_CONTROL_CHAR] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_DECL_UUID, ESP_GATT_PERM_READ, 1, 1, (uint8_t*)&char_prop_write_no_rsp}},
    [IDX_HID_CONTROL_VAL]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&HID_CONTROL_POINT_UUID, ESP_GATT_PERM_WRITE, 1, 1, &hid_control_point_val}},
    [IDX_CONSUMER_REPORT_CHAR] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_DECL_UUID, ESP_GATT_PERM_READ, 1, 1, (uint8_t*)&char_prop_read_notify}},
    [IDX_CONSUMER_REPORT_VAL]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&HID_REPORT_UUID, ESP_GATT_PERM_READ, sizeof(consumer_report_val), sizeof(consumer_report_val), consumer_report_val}},
    [IDX_CONSUMER_REPORT_CCC]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_CCC_UUID, ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, 2, 2, consumer_ccc_val}},
    [IDX_CONSUMER_REPORT_REF]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&REPORT_REF_UUID, ESP_GATT_PERM_READ, sizeof(consumer_report_ref), sizeof(consumer_report_ref), (uint8_t*)consumer_report_ref}},
    [IDX_KEYBOARD_REPORT_CHAR] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_DECL_UUID, ESP_GATT_PERM_READ, 1, 1, (uint8_t*)&char_prop_read_notify}},
    [IDX_KEYBOARD_REPORT_VAL]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&HID_REPORT_UUID, ESP_GATT_PERM_READ, sizeof(keyboard_report_val), sizeof(keyboard_report_val), keyboard_report_val}},
    [IDX_KEYBOARD_REPORT_CCC]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_CCC_UUID, ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, 2, 2, keyboard_ccc_val}},
    [IDX_KEYBOARD_REPORT_REF]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&REPORT_REF_UUID, ESP_GATT_PERM_READ, sizeof(keyboard_report_ref), sizeof(keyboard_report_ref), (uint8_t*)keyboard_report_ref}},
};

static const esp_gatts_attr_db_t bat_gatt_db[BAT_IDX_NB] = {
    [IDX_BAT_SVC] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&PRIMARY_SERVICE_UUID, ESP_GATT_PERM_READ, 2, 2, (uint8_t*)&BATTERY_SVC_UUID}},
    [IDX_BAT_LEVEL_CHAR] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_DECL_UUID, ESP_GATT_PERM_READ, 1, 1, (uint8_t*)&char_prop_read_notify}},
    [IDX_BAT_LEVEL_VAL]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&BATTERY_LEVEL_UUID, ESP_GATT_PERM_READ, 1, 1, &battery_level_val}},
    [IDX_BAT_LEVEL_CCC]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_CCC_UUID, ESP_GATT_PERM_READ | ESP_GATT_PERM_WRITE, 2, 2, battery_ccc_val}},
};

static const esp_gatts_attr_db_t dis_gatt_db[DIS_IDX_NB] = {
    [IDX_DIS_SVC] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&PRIMARY_SERVICE_UUID, ESP_GATT_PERM_READ, 2, 2, (uint8_t*)&DEVINFO_SVC_UUID}},
    [IDX_DIS_MANUFACTURER_CHAR] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_DECL_UUID, ESP_GATT_PERM_READ, 1, 1, (uint8_t*)&char_prop_read}},
    [IDX_DIS_MANUFACTURER_VAL]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&MANUFACTURER_NAME_UUID, ESP_GATT_PERM_READ, 32, 3, (uint8_t*)manufacturer_name}},
    [IDX_DIS_MODEL_CHAR] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_DECL_UUID, ESP_GATT_PERM_READ, 1, 1, (uint8_t*)&char_prop_read}},
    [IDX_DIS_MODEL_VAL]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&MODEL_NUMBER_UUID, ESP_GATT_PERM_READ, 32, 9, (uint8_t*)model_number}},
    [IDX_DIS_PNP_ID_CHAR] = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&CHAR_DECL_UUID, ESP_GATT_PERM_READ, 1, 1, (uint8_t*)&char_prop_read}},
    [IDX_DIS_PNP_ID_VAL]  = {{ESP_GATT_AUTO_RSP}, {ESP_UUID_LEN_16, (uint8_t*)&PNP_ID_UUID, ESP_GATT_PERM_READ, sizeof(pnp_id_val), sizeof(pnp_id_val), (uint8_t*)pnp_id_val}},
};

// ============================================================================
// Singleton
// ============================================================================
BleHidService& BleHidService::instance() {
    static BleHidService inst;
    return inst;
}

// ============================================================================
// GAP Event Handler
// ============================================================================
void BleHidService::gap_event_handler(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t *param) {
    // Track whether both adv data and scan response data have been configured.
    // Only start advertising once both are set to avoid a spurious double-start.
    static bool adv_data_set = false;
    static bool scan_rsp_set = false;

    switch (event) {
        case ESP_GAP_BLE_ADV_DATA_SET_COMPLETE_EVT:
            adv_data_set = true;
            if (scan_rsp_set) {
                esp_ble_gap_start_advertising(&adv_params_);
            }
            break;
        case ESP_GAP_BLE_SCAN_RSP_DATA_SET_COMPLETE_EVT:
            scan_rsp_set = true;
            if (adv_data_set) {
                esp_ble_gap_start_advertising(&adv_params_);
            }
            break;
        case ESP_GAP_BLE_ADV_START_COMPLETE_EVT:
            if (param->adv_start_cmpl.status == ESP_BT_STATUS_SUCCESS) {
                ESP_LOGI(TAG, "Advertising started");
            } else {
                ESP_LOGE(TAG, "Advertising start failed: %d", param->adv_start_cmpl.status);
            }
            break;
        case ESP_GAP_BLE_ADV_STOP_COMPLETE_EVT:
            ESP_LOGI(TAG, "Advertising stopped");
            break;
        case ESP_GAP_BLE_SEC_REQ_EVT:
            esp_ble_gap_security_rsp(param->ble_security.ble_req.bd_addr, true);
            break;
        case ESP_GAP_BLE_AUTH_CMPL_EVT: {
            auto &auth = param->ble_security.auth_cmpl;
            if (auth.success) {
                char bda_str[18];
                snprintf(bda_str, sizeof(bda_str), "%02X:%02X:%02X:%02X:%02X:%02X",
                    auth.bd_addr[0], auth.bd_addr[1], auth.bd_addr[2],
                    auth.bd_addr[3], auth.bd_addr[4], auth.bd_addr[5]);
                instance().peer_name_ = bda_str;
                ESP_LOGI(TAG, "BLE auth complete - bonded with %s", bda_str);
            } else {
                ESP_LOGW(TAG, "BLE auth failed, reason: 0x%x", auth.fail_reason);
            }
            break;
        }
        default:
            break;
    }
}

// ============================================================================
// GATTS Event Handler
// ============================================================================
void BleHidService::gatts_event_handler(esp_gatts_cb_event_t event, esp_gatt_if_t gatts_if,
                                        esp_ble_gatts_cb_param_t *param) {
    if (event == ESP_GATTS_REG_EVT) {
        if (param->reg.status == ESP_GATT_OK) {
            instance().gatts_if_ = gatts_if;
        } else {
            ESP_LOGE(TAG, "GATTS registration failed: %d", param->reg.status);
            return;
        }
    }
    if (gatts_if == ESP_GATT_IF_NONE || gatts_if == instance().gatts_if_) {
        instance().handle_gatts_event(event, gatts_if, param);
    }
}

void BleHidService::handle_gatts_event(esp_gatts_cb_event_t event, esp_gatt_if_t gatts_if,
                                       esp_ble_gatts_cb_param_t *param) {
    switch (event) {
        case ESP_GATTS_REG_EVT: {
            ESP_LOGI(TAG, "GATTS registered, setting device name");
            esp_ble_gap_set_device_name(DEVICE_NAME);
            configure_security();
            esp_ble_gap_config_adv_data(&adv_data);
            esp_ble_gap_config_adv_data(&scan_rsp_data);
            register_hid_service();
            break;
        }
        case ESP_GATTS_CREAT_ATTR_TAB_EVT: {
            if (param->add_attr_tab.status != ESP_GATT_OK) {
                ESP_LOGE(TAG, "Create attr table failed: 0x%x", param->add_attr_tab.status);
                break;
            }
            uint8_t svc_id = param->add_attr_tab.svc_inst_id;
            services_created++;

            if (svc_id == 0) { // HID service (inst_id 0)
                memcpy(hid_handle_table, param->add_attr_tab.handles, sizeof(hid_handle_table));
                consumer_report_handle_ = hid_handle_table[IDX_CONSUMER_REPORT_VAL];
                consumer_report_ccc_handle_ = hid_handle_table[IDX_CONSUMER_REPORT_CCC];
                keyboard_report_handle_ = hid_handle_table[IDX_KEYBOARD_REPORT_VAL];
                keyboard_report_ccc_handle_ = hid_handle_table[IDX_KEYBOARD_REPORT_CCC];
                esp_ble_gatts_start_service(hid_handle_table[IDX_HID_SVC]);
                ESP_LOGI(TAG, "HID service started");
                // Chain: create Battery service next
                esp_ble_gatts_create_attr_tab(bat_gatt_db, gatts_if_, BAT_IDX_NB, 1);
            } else if (svc_id == 1) { // Battery service (inst_id 1)
                memcpy(bat_handle_table, param->add_attr_tab.handles, sizeof(bat_handle_table));
                battery_level_handle_ = bat_handle_table[IDX_BAT_LEVEL_VAL];
                esp_ble_gatts_start_service(bat_handle_table[IDX_BAT_SVC]);
                ESP_LOGI(TAG, "Battery service started");
                // Chain: create Device Info service next
                esp_ble_gatts_create_attr_tab(dis_gatt_db, gatts_if_, DIS_IDX_NB, 2);
            } else if (svc_id == 2) { // Device Info service (inst_id 2)
                memcpy(dis_handle_table, param->add_attr_tab.handles, sizeof(dis_handle_table));
                esp_ble_gatts_start_service(dis_handle_table[IDX_DIS_SVC]);
                service_registered_ = true;
                ESP_LOGI(TAG, "Device Info service started — all services ready");
            } else {
                ESP_LOGE(TAG, "Unexpected svc_inst_id: %d", svc_id);
            }
            break;
        }
        case ESP_GATTS_CONNECT_EVT: {
            connected_ = true;
            conn_id_ = param->connect.conn_id;
            memcpy(peer_bda_, param->connect.remote_bda, sizeof(esp_bd_addr_t));
            ESP_LOGI(TAG, "Client connected, conn_id=%d", conn_id_.load());
            esp_ble_set_encryption(param->connect.remote_bda, ESP_BLE_SEC_ENCRYPT_MITM);
            esp_ble_conn_update_params_t conn_params = {};
            memcpy(conn_params.bda, param->connect.remote_bda, sizeof(esp_bd_addr_t));
            conn_params.latency = 0;
            conn_params.max_int = 0x0C;
            conn_params.min_int = 0x06;
            conn_params.timeout = 400;
            esp_ble_gap_update_conn_params(&conn_params);
            break;
        }
        case ESP_GATTS_DISCONNECT_EVT: {
            connected_ = false;
            conn_id_ = 0;
            memset(peer_bda_, 0, sizeof(peer_bda_));
            peer_name_.clear();
            ESP_LOGI(TAG, "Client disconnected, reason=0x%x", param->disconnect.reason);
            start_advertising();
            break;
        }
        default:
            break;
    }
}

void BleHidService::register_hid_service() {
    services_created = 0;
    // Start chain: HID first, then Battery and DevInfo are created in CREAT_ATTR_TAB_EVT
    esp_err_t err = esp_ble_gatts_create_attr_tab(hid_gatt_db, gatts_if_, HID_IDX_NB, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to create HID attr table: %s", esp_err_to_name(err));
    }
}

void BleHidService::configure_security() {
    esp_ble_auth_req_t auth_req = ESP_LE_AUTH_BOND;
    esp_ble_io_cap_t iocap = ESP_IO_CAP_NONE;
    uint8_t key_size = 16;
    uint8_t init_key = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    uint8_t rsp_key = ESP_BLE_ENC_KEY_MASK | ESP_BLE_ID_KEY_MASK;
    uint32_t passkey = 0;
    uint8_t auth_option = ESP_BLE_ONLY_ACCEPT_SPECIFIED_AUTH_DISABLE;
    uint8_t oob_support = ESP_BLE_OOB_DISABLE;

    esp_ble_gap_set_security_param(ESP_BLE_SM_SET_STATIC_PASSKEY, &passkey, sizeof(uint32_t));
    esp_ble_gap_set_security_param(ESP_BLE_SM_AUTHEN_REQ_MODE, &auth_req, sizeof(auth_req));
    esp_ble_gap_set_security_param(ESP_BLE_SM_IOCAP_MODE, &iocap, sizeof(iocap));
    esp_ble_gap_set_security_param(ESP_BLE_SM_MAX_KEY_SIZE, &key_size, sizeof(key_size));
    esp_ble_gap_set_security_param(ESP_BLE_SM_ONLY_ACCEPT_SPECIFIED_SEC_AUTH, &auth_option, sizeof(auth_option));
    esp_ble_gap_set_security_param(ESP_BLE_SM_OOB_SUPPORT, &oob_support, sizeof(oob_support));
    esp_ble_gap_set_security_param(ESP_BLE_SM_SET_INIT_KEY, &init_key, sizeof(init_key));
    esp_ble_gap_set_security_param(ESP_BLE_SM_SET_RSP_KEY, &rsp_key, sizeof(rsp_key));
}

// ============================================================================
// Public API
// ============================================================================
esp_err_t BleHidService::init() {
    ESP_LOGI(TAG, "Initializing BLE HID Service");

    ESP_ERROR_CHECK(esp_bt_controller_mem_release(ESP_BT_MODE_CLASSIC_BT));

    esp_bt_controller_config_t bt_cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&bt_cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BLE));
    ESP_ERROR_CHECK(esp_bluedroid_init());
    ESP_ERROR_CHECK(esp_bluedroid_enable());

    ESP_ERROR_CHECK(esp_ble_gatts_register_callback(gatts_event_handler));
    ESP_ERROR_CHECK(esp_ble_gap_register_callback(gap_event_handler));
    ESP_ERROR_CHECK(esp_ble_gatts_app_register(HID_APP_ID));

    esp_ble_gatt_set_local_mtu(256);

    ESP_LOGI(TAG, "BLE HID init complete");
    return ESP_OK;
}

void BleHidService::start_advertising() {
    ESP_LOGI(TAG, "Starting advertising");
    esp_ble_gap_start_advertising(&adv_params_);
}

void BleHidService::stop_advertising() {
    esp_ble_gap_stop_advertising();
}

bool BleHidService::send_consumer_report(uint16_t usage_code) {
    if (!connected_) {
        ESP_LOGW(TAG, "Cannot send consumer report: not connected");
        return false;
    }
    uint8_t report[2];
    report[0] = usage_code & 0xFF;
    report[1] = (usage_code >> 8) & 0xFF;

    esp_err_t err = esp_ble_gatts_send_indicate(gatts_if_, conn_id_, consumer_report_handle_,
                                                 sizeof(report), report, false);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to send consumer report: %s", esp_err_to_name(err));
        return false;
    }
    return true;
}

bool BleHidService::send_keyboard_report(uint8_t modifier, const uint8_t keycodes[6]) {
    if (!connected_) {
        ESP_LOGW(TAG, "Cannot send keyboard report: not connected");
        return false;
    }
    uint8_t report[8] = {0};
    report[0] = modifier;
    if (keycodes) {
        memcpy(&report[2], keycodes, 6);
    }

    esp_err_t err = esp_ble_gatts_send_indicate(gatts_if_, conn_id_, keyboard_report_handle_,
                                                 sizeof(report), report, false);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to send keyboard report: %s", esp_err_to_name(err));
        return false;
    }
    return true;
}

bool BleHidService::send_keyboard_release() {
    return send_keyboard_report(0, nullptr);
}

bool BleHidService::is_connected() const {
    return connected_;
}

std::string BleHidService::get_peer_name() const {
    return peer_name_;
}

void BleHidService::clear_all_bonds() {
    int dev_num = esp_ble_get_bond_device_num();
    if (dev_num > 0) {
        esp_ble_bond_dev_t *dev_list = (esp_ble_bond_dev_t*)malloc(sizeof(esp_ble_bond_dev_t) * dev_num);
        if (dev_list) {
            esp_ble_get_bond_device_list(&dev_num, dev_list);
            for (int i = 0; i < dev_num; i++) {
                esp_ble_remove_bond_device(dev_list[i].bd_addr);
            }
            free(dev_list);
        } else {
            ESP_LOGE(TAG, "Failed to allocate bond device list (%d entries)", dev_num);
        }
    }
    NvsManager::clear_bonds();
}

void BleHidService::enter_pairing_mode() {
    ESP_LOGI(TAG, "Entering pairing mode");
    stop_advertising();
    if (connected_) {
        esp_ble_gap_disconnect(peer_bda_);
    }
    clear_all_bonds();
    connected_ = false;
    memset(peer_bda_, 0, sizeof(peer_bda_));
    peer_name_.clear();
    vTaskDelay(pdMS_TO_TICKS(100));
    start_advertising();
}

void BleHidService::unpair() {
    ESP_LOGI(TAG, "Unpairing");
    if (connected_) {
        esp_ble_gap_disconnect(peer_bda_);
    }
    clear_all_bonds();
    connected_ = false;
    memset(peer_bda_, 0, sizeof(peer_bda_));
    peer_name_.clear();
}
