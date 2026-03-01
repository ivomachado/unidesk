#include "brightness_control.h"
#include "ble_hid_service.h"
#include "nvs_manager.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include <algorithm>

static const char *TAG = "BrightnessCtrl";

static const uint16_t USAGE_BRIGHTNESS_UP   = 0x006F;
static const uint16_t USAGE_BRIGHTNESS_DOWN = 0x0070;
static const uint16_t USAGE_RELEASE         = 0x0000;
static const uint8_t  KEY_ESC               = 0x29;

BrightnessControl& BrightnessControl::instance() {
    static BrightnessControl inst;
    return inst;
}

BrightnessControl::BrightnessControl() {
    esc_debounce_ms_ = NvsManager::get_esc_debounce_ms();

    esc_timer_ = xTimerCreate(
        "esc_debounce",
        pdMS_TO_TICKS(esc_debounce_ms_),
        pdFALSE,  // one-shot
        this,
        &BrightnessControl::esc_timer_cb
    );
    if (!esc_timer_) {
        ESP_LOGE(TAG, "Failed to create ESC debounce timer");
    }

    BaseType_t ret = xTaskCreate(
        &BrightnessControl::esc_task_fn,
        "esc_dismiss",
        ESC_TASK_STACK,
        this,
        ESC_TASK_PRIORITY,
        &esc_task_
    );
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create ESC dismiss task");
        esc_task_ = nullptr;
    }
}

BrightnessControl::~BrightnessControl() {
    if (esc_timer_) {
        xTimerDelete(esc_timer_, 0);
    }
    if (esc_task_) {
        vTaskDelete(esc_task_);
    }
}

// Timer callback — runs in timer daemon task, must NOT block or call BLE APIs.
// Just notifies the dedicated ESC task.
void BrightnessControl::esc_timer_cb(TimerHandle_t timer) {
    auto *self = reinterpret_cast<BrightnessControl*>(pvTimerGetTimerID(timer));
    ESP_LOGI(TAG, "ESC debounce timer fired — notifying ESC task");
    if (self->esc_task_) {
        xTaskNotifyGive(self->esc_task_);
    }
}

// Dedicated task that waits for a notification and then sends ESC press/release.
// Safe to call vTaskDelay and BLE GATT APIs from here.
void BrightnessControl::esc_task_fn(void *arg) {
    auto *self = reinterpret_cast<BrightnessControl*>(arg);
    ESP_LOGI(TAG, "ESC dismiss task started");

    while (true) {
        // Block until the timer callback notifies us
        ulTaskNotifyTake(pdTRUE, portMAX_DELAY);
        self->send_esc_dismiss();
    }
}

bool BrightnessControl::send_brightness_report(uint16_t usage_code, const char *direction) {
    auto &ble = BleHidService::instance();

    if (!ble.is_connected()) {
        ESP_LOGW(TAG, "[%s] Aborted — BLE not connected", direction);
        return false;
    }

    ESP_LOGI(TAG, "[%s] Sending consumer control press (usage=0x%04X)", direction, usage_code);
    if (!ble.send_consumer_report(usage_code)) {
        ESP_LOGE(TAG, "[%s] FAILED: consumer control press", direction);
        return false;
    }
    vTaskDelay(pdMS_TO_TICKS(20));

    ESP_LOGI(TAG, "[%s] Sending consumer control release", direction);
    if (!ble.send_consumer_report(USAGE_RELEASE)) {
        ESP_LOGE(TAG, "[%s] FAILED: consumer control release", direction);
        return false;
    }

    ESP_LOGI(TAG, "[%s] Consumer report sent — scheduling deferred ESC dismiss (%lu ms)", direction, (unsigned long)esc_debounce_ms_);
    schedule_esc_dismiss();

    return true;
}

void BrightnessControl::set_esc_debounce_ms(uint32_t ms) {
    ms = std::max(NvsManager::ESC_DEBOUNCE_MIN_MS, std::min(NvsManager::ESC_DEBOUNCE_MAX_MS, ms));
    esc_debounce_ms_ = ms;
    if (esc_timer_) {
        xTimerChangePeriod(esc_timer_, pdMS_TO_TICKS(ms), 0);
    }
    ESP_LOGI(TAG, "ESC debounce updated to %lu ms", (unsigned long)ms);
}

void BrightnessControl::schedule_esc_dismiss() {
    if (!esc_timer_) {
        ESP_LOGW(TAG, "No ESC timer — sending ESC immediately as fallback");
        send_esc_dismiss();
        return;
    }

    // Reset the timer. If it's already running, this restarts the countdown.
    // This is the debounce: only the last brightness command in a burst triggers ESC.
    if (xTimerIsTimerActive(esc_timer_)) {
        ESP_LOGD(TAG, "ESC timer already active — resetting debounce window");
    }
    xTimerReset(esc_timer_, 0);
}

void BrightnessControl::send_esc_dismiss() {
    auto &ble = BleHidService::instance();

    if (!ble.is_connected()) {
        ESP_LOGW(TAG, "ESC dismiss skipped — BLE not connected");
        return;
    }

    ESP_LOGI(TAG, "Sending ESC key press (keycode=0x%02X)", KEY_ESC);
    uint8_t keycodes[6] = {KEY_ESC, 0, 0, 0, 0, 0};
    if (!ble.send_keyboard_report(0, keycodes)) {
        ESP_LOGE(TAG, "FAILED: ESC key press");
        return;
    }
    vTaskDelay(pdMS_TO_TICKS(20));

    ESP_LOGI(TAG, "Sending keyboard release");
    if (!ble.send_keyboard_release()) {
        ESP_LOGE(TAG, "FAILED: keyboard release");
        return;
    }

    ESP_LOGI(TAG, "OSD dismissed successfully");
}

bool BrightnessControl::brightness_up() {
    ESP_LOGI(TAG, ">>> Brightness UP requested");
    bool result = send_brightness_report(USAGE_BRIGHTNESS_UP, "UP");
    ESP_LOGI(TAG, ">>> Brightness UP result: %s", result ? "SUCCESS" : "FAILED");
    return result;
}

bool BrightnessControl::brightness_down() {
    ESP_LOGI(TAG, ">>> Brightness DOWN requested");
    bool result = send_brightness_report(USAGE_BRIGHTNESS_DOWN, "DOWN");
    ESP_LOGI(TAG, ">>> Brightness DOWN result: %s", result ? "SUCCESS" : "FAILED");
    return result;
}