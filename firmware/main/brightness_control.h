#pragma once

#include "freertos/FreeRTOS.h"
#include "freertos/timers.h"
#include "freertos/task.h"

class BrightnessControl {
public:
    static BrightnessControl& instance();

    /// Send brightness up consumer control report.
    /// ESC dismiss is deferred and debounced — only fires once after a burst of commands.
    /// Returns true if BLE was connected and the consumer report was sent.
    bool brightness_up();

    /// Send brightness down consumer control report.
    /// ESC dismiss is deferred and debounced.
    bool brightness_down();

    /// How long to wait after the last brightness command before sending ESC (ms).
    static constexpr uint32_t ESC_DEBOUNCE_MS = 2000;

private:
    BrightnessControl();
    ~BrightnessControl();

    BrightnessControl(const BrightnessControl&) = delete;
    BrightnessControl& operator=(const BrightnessControl&) = delete;

    /// Send consumer control press + release only (no ESC).
    bool send_brightness_report(uint16_t usage_code, const char *direction);

    /// Schedule (or reschedule) the deferred ESC dismiss.
    void schedule_esc_dismiss();

    /// Send the ESC press/release sequence. Called from the dedicated ESC task.
    void send_esc_dismiss();

    /// FreeRTOS timer callback — notifies the ESC task instead of doing work directly.
    static void esc_timer_cb(TimerHandle_t timer);

    /// Dedicated task that waits for a notification and sends ESC.
    static void esc_task_fn(void *arg);

    TimerHandle_t esc_timer_ = nullptr;
    TaskHandle_t esc_task_ = nullptr;

    static constexpr size_t ESC_TASK_STACK = 3072;
    static constexpr UBaseType_t ESC_TASK_PRIORITY = 5;
};