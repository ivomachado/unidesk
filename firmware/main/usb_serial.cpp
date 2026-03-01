#include "usb_serial.h"

#include "esp_log.h"
#include "tinyusb.h"
#include "tusb_cdc_acm.h"
#include "tusb.h"
#include "esp_mac.h"

// Custom USB device descriptor
static const tusb_desc_device_t custom_device_descriptor = {
    .bLength            = sizeof(tusb_desc_device_t),
    .bDescriptorType    = TUSB_DESC_DEVICE,
    .bcdUSB             = 0x0200,
    .bDeviceClass       = TUSB_CLASS_MISC,
    .bDeviceSubClass    = MISC_SUBCLASS_COMMON,
    .bDeviceProtocol    = MISC_PROTOCOL_IAD,
    .bMaxPacketSize0    = CFG_TUD_ENDPOINT0_SIZE,
    .idVendor           = 0x303A,   // Espressif VID
    .idProduct          = 0x4001,   // TinyUSB CDC default — matches macOS app discovery
    .bcdDevice          = 0x0100,
    .iManufacturer      = 0x01,
    .iProduct           = 0x02,
    .iSerialNumber      = 0x03,
    .bNumConfigurations = 0x01,
};

static const char *custom_string_descriptors[] = {
    [0] = "",                          // Language (handled by TinyUSB)
    [1] = "VF9 Project",              // Manufacturer
    [2] = "VF9 Brightness Bridge",    // Product
    [3] = "000001",                    // Serial number
};

static const char *TAG = "UsbSerial";

UsbSerial& UsbSerial::instance() {
    static UsbSerial inst;
    return inst;
}

// Called from TinyUSB task context — just enqueue bytes, don't process here
void UsbSerial::cdc_rx_callback(int itf, cdcacm_event_t *event) {
    auto &self = instance();
    uint8_t buf[64];
    size_t rx_size = 0;

    esp_err_t ret = tinyusb_cdcacm_read((tinyusb_cdcacm_itf_t)itf, buf, sizeof(buf), &rx_size);
    if (ret == ESP_OK && rx_size > 0) {
        ESP_LOGI(TAG, "USB RX: %d byte(s)", (int)rx_size);
        for (size_t i = 0; i < rx_size; i++) {
            ESP_LOGI(TAG, "USB RX byte[%d]: 0x%02x", (int)i, buf[i]);
            if (self.rx_queue_) {
                if (xQueueSend(self.rx_queue_, &buf[i], 0) != pdTRUE) {
                    ESP_LOGW(TAG, "USB RX queue full, dropping byte 0x%02x", buf[i]);
                }
            }
        }
    } else if (ret != ESP_OK) {
        ESP_LOGW(TAG, "USB RX read error: %s", esp_err_to_name(ret));
    }
}

void UsbSerial::cdc_line_state_callback(int itf, cdcacm_event_t *event) {
    auto &self = instance();
    bool prev_dtr = self.dtr_active_;
    bool dtr = event->line_state_changed_data.dtr;
    bool rts = event->line_state_changed_data.rts;
    self.dtr_active_ = dtr;
    ESP_LOGI(TAG, "USB line state changed: DTR=%d RTS=%d", dtr, rts);

    // DTR 0→1: new host connection — flush stale RX bytes
    if (!prev_dtr && dtr) {
        ESP_LOGI(TAG, "New host connection detected (DTR 0->1), flushing stale RX queue");
        if (self.rx_queue_) {
            uint8_t discard;
            int flushed = 0;
            while (xQueueReceive(self.rx_queue_, &discard, 0) == pdTRUE) {
                flushed++;
            }
            if (flushed > 0) {
                ESP_LOGW(TAG, "Flushed %d stale byte(s) from RX queue", flushed);
            }
        }
    }
}

// Separate FreeRTOS task: reads bytes from queue and dispatches via rx_callback_
void UsbSerial::process_task(void *arg) {
    auto &self = *reinterpret_cast<UsbSerial*>(arg);
    uint8_t byte;

    ESP_LOGI(TAG, "Command processing task started");

    while (true) {
        if (xQueueReceive(self.rx_queue_, &byte, portMAX_DELAY) == pdTRUE) {
            if (self.rx_callback_) {
                self.rx_callback_(byte);
            }
        }
    }
}

esp_err_t UsbSerial::init() {
    ESP_LOGI(TAG, "Initializing USB CDC");

    // Create the RX byte queue
    rx_queue_ = xQueueCreate(RX_QUEUE_SIZE, sizeof(uint8_t));
    if (!rx_queue_) {
        ESP_LOGE(TAG, "Failed to create RX queue");
        return ESP_FAIL;
    }

    const tinyusb_config_t tusb_cfg = {
        .device_descriptor = &custom_device_descriptor,
        .string_descriptor = custom_string_descriptors,
        .string_descriptor_count = sizeof(custom_string_descriptors) / sizeof(custom_string_descriptors[0]),
        .external_phy = false,
        .configuration_descriptor = nullptr,
        .self_powered = false,
        .vbus_monitor_io = -1,
    };

    ESP_ERROR_CHECK(tinyusb_driver_install(&tusb_cfg));

    tinyusb_config_cdcacm_t acm_cfg = {
        .usb_dev = TINYUSB_USBDEV_0,
        .cdc_port = TINYUSB_CDC_ACM_0,
        .rx_unread_buf_sz = 256,
        .callback_rx = &UsbSerial::cdc_rx_callback,
        .callback_rx_wanted_char = nullptr,
        .callback_line_state_changed = &UsbSerial::cdc_line_state_callback,
        .callback_line_coding_changed = nullptr,
    };

    ESP_ERROR_CHECK(tusb_cdc_acm_init(&acm_cfg));

    // Start the command processing task
    BaseType_t ret = xTaskCreate(
        &UsbSerial::process_task,
        "usb_cmd_proc",
        PROCESS_TASK_STACK,
        this,
        PROCESS_TASK_PRIORITY,
        &process_task_
    );
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create processing task");
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "USB CDC initialized");
    return ESP_OK;
}

void UsbSerial::set_rx_callback(RxCallback cb) {
    rx_callback_ = cb;
}

void UsbSerial::send_response(const std::string& response) {
    ESP_LOGI(TAG, "USB TX: \"%s\"", response.c_str());

    // Quick check — if CDC not connected, skip immediately
    if (!tud_cdc_n_connected(0)) {
        ESP_LOGW(TAG, "USB TX skipped: CDC not connected");
        return;
    }

    std::string msg = response + "\n";

    // tinyusb_cdcacm_write_queue returns size_t (bytes queued), NOT esp_err_t.
    // Loop with offset tracking to ensure the full message is queued before flushing.
    const int max_retries = 3;
    const int retry_delay_ms = 10;

    for (int attempt = 0; attempt < max_retries; attempt++) {
        // Queue all bytes, advancing through the buffer on partial writes
        size_t total_queued = 0;
        bool queue_failed = false;
        while (total_queued < msg.size()) {
            size_t queued = tinyusb_cdcacm_write_queue(
                TINYUSB_CDC_ACM_0,
                (const uint8_t*)msg.c_str() + total_queued,
                msg.size() - total_queued);
            if (queued == 0) {
                ESP_LOGW(TAG, "USB TX queue returned 0 bytes at offset %d/%d (attempt %d/%d)",
                         (int)total_queued, (int)msg.size(), attempt + 1, max_retries);
                queue_failed = true;
                break;
            }
            total_queued += queued;
        }

        if (queue_failed) {
            if (attempt < max_retries - 1) {
                vTaskDelay(pdMS_TO_TICKS(retry_delay_ms));
            }
            continue;
        }

        esp_err_t flush_ret = tinyusb_cdcacm_write_flush(TINYUSB_CDC_ACM_0, pdMS_TO_TICKS(50));
        if (flush_ret == ESP_OK) {
            ESP_LOGI(TAG, "USB TX sent successfully (%d bytes)", (int)total_queued);
            return;
        }
        ESP_LOGW(TAG, "USB TX flush failed (attempt %d/%d): %s", attempt + 1, max_retries, esp_err_to_name(flush_ret));

        if (attempt < max_retries - 1) {
            vTaskDelay(pdMS_TO_TICKS(retry_delay_ms));
        }
    }

    ESP_LOGW(TAG, "USB TX failed after %d attempts", max_retries);
}