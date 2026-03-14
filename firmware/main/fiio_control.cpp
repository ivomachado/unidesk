#include "fiio_control.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "FiiOControl";

FiiOControl& FiiOControl::instance() {
    static FiiOControl inst;
    return inst;
}

FiiOControl::FiiOControl() {
    // -------------------------------------------------------------------------
    // GPIO initialisation — must happen before the task starts so pins are
    // in a safe state before any sequence can run.
    // -------------------------------------------------------------------------
    gpio_config_t io_conf = {};
    io_conf.pin_bit_mask = (1ULL << GPIO_VOL_UP)
                         | (1ULL << GPIO_VOL_DOWN)
                         | (1ULL << GPIO_POWER);
    io_conf.mode         = GPIO_MODE_OUTPUT;
    io_conf.pull_up_en   = GPIO_PULLUP_DISABLE;
    io_conf.pull_down_en = GPIO_PULLDOWN_DISABLE;
    io_conf.intr_type    = GPIO_INTR_DISABLE;
    ESP_ERROR_CHECK(gpio_config(&io_conf));

    // Drive all outputs LOW — safe default, optocouplers open.
    gpio_set_level(GPIO_VOL_UP,   0);
    gpio_set_level(GPIO_VOL_DOWN, 0);
    gpio_set_level(GPIO_POWER,    0);

    ESP_LOGI(TAG, "GPIOs %d/%d/%d configured OUTPUT LOW",
             (int)GPIO_VOL_UP, (int)GPIO_VOL_DOWN, (int)GPIO_POWER);

    // -------------------------------------------------------------------------
    // Action queue and task
    // -------------------------------------------------------------------------
    action_queue_ = xQueueCreate(QUEUE_DEPTH, sizeof(Action));
    if (!action_queue_) {
        ESP_LOGE(TAG, "Failed to create action queue");
        return;
    }

    BaseType_t ret = xTaskCreate(
        &FiiOControl::task_fn,
        "fiio_ctrl",
        TASK_STACK,
        this,
        TASK_PRIORITY,
        &task_
    );
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create fiio_ctrl task");
        task_ = nullptr;
    } else {
        ESP_LOGI(TAG, "fiio_ctrl task started");
    }
}

FiiOControl::~FiiOControl() {
    if (task_) {
        vTaskDelete(task_);
    }
    if (action_queue_) {
        vQueueDelete(action_queue_);
    }
    // Return pins to a safe state.
    gpio_set_level(GPIO_VOL_UP,   0);
    gpio_set_level(GPIO_VOL_DOWN, 0);
    gpio_set_level(GPIO_POWER,    0);
}

// -----------------------------------------------------------------------------
// Task
// -----------------------------------------------------------------------------

void FiiOControl::task_fn(void* arg) {
    auto* self = reinterpret_cast<FiiOControl*>(arg);
    ESP_LOGI(TAG, "fiio_ctrl task running");

    Action action;
    while (true) {
        // Block indefinitely until an action is enqueued.
        if (xQueueReceive(self->action_queue_, &action, portMAX_DELAY) == pdTRUE) {
            switch (action) {
                case Action::VOLUME_UP:
                    self->execute_volume_up();
                    break;
                case Action::VOLUME_DOWN:
                    self->execute_volume_down();
                    break;
                case Action::TOGGLE_OUTPUT:
                    self->execute_toggle_output();
                    break;
            }
        }
    }
}

// -----------------------------------------------------------------------------
// Quadrature sequences
// -----------------------------------------------------------------------------

// Volume increment (step up):
//   GPIO 13 HIGH → wait → GPIO 12 HIGH → wait → GPIO 13 LOW → wait → GPIO 12 LOW
void FiiOControl::execute_volume_up() {
    ESP_LOGI(TAG, "Quadrature step UP (step_interval=%lu ms)", (unsigned long)STEP_INTERVAL_MS);

    gpio_set_level(GPIO_VOL_DOWN, 1);
    vTaskDelay(pdMS_TO_TICKS(STEP_INTERVAL_MS));

    gpio_set_level(GPIO_VOL_UP, 1);
    vTaskDelay(pdMS_TO_TICKS(STEP_INTERVAL_MS));

    gpio_set_level(GPIO_VOL_DOWN, 0);
    vTaskDelay(pdMS_TO_TICKS(STEP_INTERVAL_MS));

    gpio_set_level(GPIO_VOL_UP, 0);

    ESP_LOGI(TAG, "Quadrature step UP complete");
}

// Volume decrement (step down):
//   GPIO 12 HIGH → wait → GPIO 13 HIGH → wait → GPIO 12 LOW → wait → GPIO 13 LOW
void FiiOControl::execute_volume_down() {
    ESP_LOGI(TAG, "Quadrature step DOWN (step_interval=%lu ms)", (unsigned long)STEP_INTERVAL_MS);

    gpio_set_level(GPIO_VOL_UP, 1);
    vTaskDelay(pdMS_TO_TICKS(STEP_INTERVAL_MS));

    gpio_set_level(GPIO_VOL_DOWN, 1);
    vTaskDelay(pdMS_TO_TICKS(STEP_INTERVAL_MS));

    gpio_set_level(GPIO_VOL_UP, 0);
    vTaskDelay(pdMS_TO_TICKS(STEP_INTERVAL_MS));

    gpio_set_level(GPIO_VOL_DOWN, 0);

    ESP_LOGI(TAG, "Quadrature step DOWN complete");
}

// Power-button double-click to toggle active output:
//   GPIO 14 HIGH (press) → wait POWER_PRESS_MS → GPIO 14 LOW (release)
//   → wait POWER_GAP_MS →
//   GPIO 14 HIGH (press) → wait POWER_PRESS_MS → GPIO 14 LOW (release)
void FiiOControl::execute_toggle_output() {
    ESP_LOGI(TAG, "Toggle output: double-click power button (press=%lu ms, gap=%lu ms)",
             (unsigned long)POWER_PRESS_MS, (unsigned long)POWER_GAP_MS);

    // First click
    gpio_set_level(GPIO_POWER, 1);
    vTaskDelay(pdMS_TO_TICKS(POWER_PRESS_MS));
    gpio_set_level(GPIO_POWER, 0);

    // Gap between clicks
    vTaskDelay(pdMS_TO_TICKS(POWER_GAP_MS));

    // Second click
    gpio_set_level(GPIO_POWER, 1);
    vTaskDelay(pdMS_TO_TICKS(POWER_PRESS_MS));
    gpio_set_level(GPIO_POWER, 0);

    ESP_LOGI(TAG, "Toggle output: double-click complete");
}

// -----------------------------------------------------------------------------
// Public API — enqueue actions (non-blocking, safe from any task)
// -----------------------------------------------------------------------------

void FiiOControl::volume_up() {
    if (!action_queue_) {
        ESP_LOGE(TAG, "volume_up: queue not initialised");
        return;
    }
    Action action = Action::VOLUME_UP;
    if (xQueueSend(action_queue_, &action, 0) != pdTRUE) {
        ESP_LOGW(TAG, "volume_up: action queue full — command dropped");
    }
}

void FiiOControl::volume_down() {
    if (!action_queue_) {
        ESP_LOGE(TAG, "volume_down: queue not initialised");
        return;
    }
    Action action = Action::VOLUME_DOWN;
    if (xQueueSend(action_queue_, &action, 0) != pdTRUE) {
        ESP_LOGW(TAG, "volume_down: action queue full — command dropped");
    }
}

void FiiOControl::toggle_output() {
    if (!action_queue_) {
        ESP_LOGE(TAG, "toggle_output: queue not initialised");
        return;
    }
    Action action = Action::TOGGLE_OUTPUT;
    if (xQueueSend(action_queue_, &action, 0) != pdTRUE) {
        ESP_LOGW(TAG, "toggle_output: action queue full — command dropped");
    }
}
