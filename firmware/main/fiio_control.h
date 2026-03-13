#pragma once

#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "driver/gpio.h"

/// Controls the FiiO K11 R2R DAC volume via optocoupler-isolated GPIO lines.
///
/// The FiiO's internal MCU (GigaDevice GD32) exposes raw rotary encoder pads
/// (VOL_UP / VOL_DOWN). Volume changes are signalled by emulating a 2-bit
/// quadrature (Gray Code) phase sequence on those pads.
///
/// Hardware mapping (ESP32-S3 → optocoupler → FiiO test pad):
///   GPIO 12  —  Phase A  (VOL_UP  pad)
///   GPIO 13  —  Phase B  (VOL_DOWN pad)
///   GPIO 14  —  Power / Selection (reserved, not used)
///
/// All signals are active-HIGH on the ESP32 side (HIGH closes the optocoupler
/// circuit on the FiiO side).
///
/// Thread safety: `volume_up()` and `volume_down()` are safe to call from any
/// task — they enqueue an action and return immediately. The actual GPIO
/// sequence runs on a dedicated FreeRTOS task, guaranteeing that only one
/// sequence executes at a time (atomicity).
class FiiOControl {
public:
    static FiiOControl& instance();

    /// Enqueue one quadrature step-up (volume increment).
    /// Returns immediately; the step executes asynchronously on the fiio_ctrl task.
    /// Logs a warning if the action queue is full.
    void volume_up();

    /// Enqueue one quadrature step-down (volume decrement).
    /// Returns immediately; the step executes asynchronously on the fiio_ctrl task.
    /// Logs a warning if the action queue is full.
    void volume_down();

private:
    FiiOControl();
    ~FiiOControl();

    // Non-copyable
    FiiOControl(const FiiOControl&) = delete;
    FiiOControl& operator=(const FiiOControl&) = delete;

    enum class Action : uint8_t { VOLUME_UP, VOLUME_DOWN };

    /// FreeRTOS task entry point.
    static void task_fn(void* arg);

    /// Execute the 4-step quadrature sequence for volume up.
    /// Runs on the fiio_ctrl task — safe to call vTaskDelay() here.
    void execute_volume_up();

    /// Execute the 4-step quadrature sequence for volume down.
    /// Runs on the fiio_ctrl task — safe to call vTaskDelay() here.
    void execute_volume_down();

    QueueHandle_t action_queue_ = nullptr;
    TaskHandle_t  task_         = nullptr;

    // -------------------------------------------------------------------------
    // GPIO pin assignments (ESP32-S3 GPIO numbers)
    // -------------------------------------------------------------------------
    static constexpr gpio_num_t GPIO_VOL_UP   = GPIO_NUM_12;  // Phase A — VOL_UP pad
    static constexpr gpio_num_t GPIO_VOL_DOWN = GPIO_NUM_13;  // Phase B — VOL_DOWN pad
    static constexpr gpio_num_t GPIO_POWER    = GPIO_NUM_14;  // Reserved — PWR_ON pad

    // -------------------------------------------------------------------------
    // Timing
    // -------------------------------------------------------------------------
    /// Delay between each of the 4 quadrature steps (milliseconds).
    /// Range: 10–20 ms. Increase if the FiiO MCU fails to register steps.
    static constexpr uint32_t STEP_INTERVAL_MS = 10;

    // -------------------------------------------------------------------------
    // Task / queue sizing
    // -------------------------------------------------------------------------
    static constexpr size_t        QUEUE_DEPTH    = 8;
    static constexpr size_t        TASK_STACK     = 4096;
    static constexpr UBaseType_t   TASK_PRIORITY  = 5;
};
