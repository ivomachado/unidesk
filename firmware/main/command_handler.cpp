#include "command_handler.h"
#include "brightness_control.h"
#include "ble_hid_service.h"
#include "nvs_manager.h"
#include "usb_serial.h"
#include "fiio_control.h"
#include "esp_log.h"

static const char *TAG = "CommandHandler";

CommandHandler& CommandHandler::instance() {
    static CommandHandler inst;
    return inst;
}

CommandHandler::CommandHandler() {
    read_timer_ = xTimerCreate(
        "read_timeout",
        pdMS_TO_TICKS(READ_TIMEOUT_MS),
        pdFALSE,  // one-shot
        this,
        &CommandHandler::read_timeout_cb
    );
    if (!read_timer_) {
        ESP_LOGE(TAG, "Failed to create read timeout timer");
    }
}

CommandHandler::~CommandHandler() {
    if (read_timer_) {
        xTimerDelete(read_timer_, 0);
    }
}

// Timer callback — runs in the FreeRTOS timer daemon task.
// Posts a sentinel to the RX queue so all state mutations stay on usb_cmd_proc task.
void CommandHandler::read_timeout_cb(TimerHandle_t timer) {
    ESP_LOGW(TAG, "Read timeout after %dms, posting sentinel to RX queue", (int)READ_TIMEOUT_MS);
    QueueHandle_t rx_queue = UsbSerial::instance().get_rx_queue();
    if (rx_queue) {
        uint8_t sentinel = ProtocolParser::SENTINEL_TIMEOUT;
        xQueueSend(rx_queue, &sentinel, 0);
    }
}

void CommandHandler::handle_byte(uint8_t byte) {
    ESP_LOGI(TAG, "Received byte: 0x%02x", byte);

    ParseResult pr = parser_.handle_byte(byte);

    if (pr.start_timeout && read_timer_) {
        xTimerReset(read_timer_, 0);
    } else if (pr.stop_timeout && read_timer_) {
        xTimerStop(read_timer_, 0);
    }

    if (pr.command.type != ParsedCommand::Type::None) {
        dispatch(pr.command);
    }
}

void CommandHandler::dispatch(const ParsedCommand& cmd) {
    auto &serial = UsbSerial::instance();
    auto &ble    = BleHidService::instance();

    switch (cmd.type) {
        case ParsedCommand::Type::BrightnessUp:
            ESP_LOGI(TAG, "CMD: Brightness Up (BLE %s)", ble.is_connected() ? "connected" : "disconnected");
            BrightnessControl::instance().brightness_up();
            break;

        case ParsedCommand::Type::BrightnessDown:
            ESP_LOGI(TAG, "CMD: Brightness Down (BLE %s)", ble.is_connected() ? "connected" : "disconnected");
            BrightnessControl::instance().brightness_down();
            break;

        case ParsedCommand::Type::PairingMode:
            ESP_LOGI(TAG, "CMD: Enter Pairing Mode -> OK:PAIRING");
            ble.enter_pairing_mode();
            serial.send_response("OK:PAIRING");
            break;

        case ParsedCommand::Type::Ping: {
            std::string response = cmd.str_payload.empty()
                ? "OK:PING"
                : "OK:PING:" + cmd.str_payload;
            ESP_LOGI(TAG, "CMD: Ping -> %s", response.c_str());
            serial.send_response(response);
            break;
        }

        case ParsedCommand::Type::Status: {
            std::string state = ble.is_connected() ? "connected" : "disconnected";
            std::string response = "STATUS:" + state + ":" + ble.get_peer_name();
            ESP_LOGI(TAG, "CMD: Get Status -> %s", response.c_str());
            serial.send_response(response);
            break;
        }

        case ParsedCommand::Type::Unpair:
            ESP_LOGI(TAG, "CMD: Unpair -> OK:UNPAIRED");
            ble.unpair();
            serial.send_response("OK:UNPAIRED");
            break;

        case ParsedCommand::Type::SetEscDebounce: {
            auto &bc = BrightnessControl::instance();
            bc.set_esc_debounce_ms(cmd.uint_payload);
            esp_err_t err = NvsManager::set_esc_debounce_ms(bc.get_esc_debounce_ms());
            if (err == ESP_OK) {
                char buf[32];
                snprintf(buf, sizeof(buf), "OK:ESC_DEBOUNCE:%lu", (unsigned long)bc.get_esc_debounce_ms());
                serial.send_response(buf);
            } else {
                serial.send_response("ERR:NVS_WRITE_FAILED");
            }
            break;
        }

        case ParsedCommand::Type::GetEscDebounce: {
            uint32_t ms = BrightnessControl::instance().get_esc_debounce_ms();
            char buf[32];
            snprintf(buf, sizeof(buf), "OK:ESC_DEBOUNCE:%lu", (unsigned long)ms);
            ESP_LOGI(TAG, "CMD: GetEscDebounce -> %s", buf);
            serial.send_response(buf);
            break;
        }

        case ParsedCommand::Type::Esc:
            ESP_LOGI(TAG, "CMD: ESC (BLE %s)", ble.is_connected() ? "connected" : "disconnected");
            BrightnessControl::instance().send_esc();
            break;

        case ParsedCommand::Type::FiiOVolumeUp:
            ESP_LOGI(TAG, "CMD: FiiO Volume Up");
            FiiOControl::instance().volume_up();
            break;

        case ParsedCommand::Type::FiiOVolumeDown:
            ESP_LOGI(TAG, "CMD: FiiO Volume Down");
            FiiOControl::instance().volume_down();
            break;

        case ParsedCommand::Type::Error:
            ESP_LOGW(TAG, "Protocol error: %s -> ERR:%s", cmd.str_payload.c_str(), cmd.str_payload.c_str());
            serial.send_response("ERR:" + cmd.str_payload);
            break;

        case ParsedCommand::Type::None:
            break;
    }
}
