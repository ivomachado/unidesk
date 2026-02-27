#pragma once

#include <functional>
#include <string>
#include "esp_err.h"
#include "tusb_cdc_acm.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

class UsbSerial {
public:
    using RxCallback = std::function<void(uint8_t byte)>;

    static UsbSerial& instance();

    /// Initialize TinyUSB CDC and start the command processing task.
    esp_err_t init();

    /// Set callback for received bytes (called from processing task, not ISR).
    void set_rx_callback(RxCallback cb);

    /// Send a newline-terminated ASCII response.
    /// Will wait for DTR and retry if needed.
    void send_response(const std::string& response);

    /// Returns true if the host has the port open (DTR asserted).
    bool is_host_connected() const { return dtr_active_; }

private:
    UsbSerial() = default;
    RxCallback rx_callback_;
    volatile bool dtr_active_ = false;

    QueueHandle_t rx_queue_ = nullptr;
    TaskHandle_t process_task_ = nullptr;

    static constexpr size_t RX_QUEUE_SIZE = 64;
    static constexpr size_t PROCESS_TASK_STACK = 4096;
    static constexpr UBaseType_t PROCESS_TASK_PRIORITY = 5;

    static void cdc_rx_callback(int itf, cdcacm_event_t *event);
    static void cdc_line_state_callback(int itf, cdcacm_event_t *event);
    static void process_task(void *arg);
};