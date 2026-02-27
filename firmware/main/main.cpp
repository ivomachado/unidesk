#include "nvs_manager.h"
#include "ble_hid_service.h"
#include "usb_serial.h"
#include "command_handler.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "main";

extern "C" void app_main(void) {
    ESP_LOGI(TAG, "VF9 Brightness Bridge starting...");

    // 1. Initialize NVS (must be first — BLE bonding depends on it)
    ESP_ERROR_CHECK(NvsManager::init());

    // 2. Initialize BLE stack and HOGP service
    ESP_ERROR_CHECK(BleHidService::instance().init());

    // 3. Start BLE advertising
    BleHidService::instance().start_advertising();

    // 4. Initialize USB-CDC serial
    ESP_ERROR_CHECK(UsbSerial::instance().init());

    // 5. Wire USB serial → CommandHandler
    UsbSerial::instance().set_rx_callback([](uint8_t byte) {
        CommandHandler::instance().handle_byte(byte);
    });

    ESP_LOGI(TAG, "VF9 Brightness Bridge ready");

    // 6. Idle loop — all work is event/callback driven
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}