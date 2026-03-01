#include "command_handler.h"
#include "brightness_control.h"
#include "ble_hid_service.h"
#include "nvs_manager.h"
#include "usb_serial.h"

#include "esp_log.h"

static const char *TAG = "CommandHandler";

CommandHandler& CommandHandler::instance() {
    static CommandHandler inst;
    return inst;
}

CommandHandler::CommandHandler() {
    nonce_timer_ = xTimerCreate(
        "nonce_timeout",
        pdMS_TO_TICKS(NONCE_TIMEOUT_MS),
        pdFALSE,  // one-shot
        this,
        &CommandHandler::nonce_timeout_cb
    );
    if (!nonce_timer_) {
        ESP_LOGE(TAG, "Failed to create nonce timeout timer");
    }
}

CommandHandler::~CommandHandler() {
    if (nonce_timer_) {
        xTimerDelete(nonce_timer_, 0);
    }
}

void CommandHandler::nonce_timeout_cb(TimerHandle_t timer) {
    auto *self = reinterpret_cast<CommandHandler*>(pvTimerGetTimerID(timer));
    if (self->state_ == State::READING_NONCE) {
        ESP_LOGW(TAG, "Nonce timeout after %dms, completing ping without nonce", (int)NONCE_TIMEOUT_MS);
        self->nonce_buf_.clear();
        self->complete_ping();
    }
}

void CommandHandler::handle_byte(uint8_t byte) {
    ESP_LOGI(TAG, "Received byte: 0x%02x (state=%d)", byte, (int)state_);

    switch (state_) {
        case State::IDLE: {
            if (byte == CMD_PING) {
                state_ = State::READING_NONCE;
                nonce_buf_.clear();
                if (nonce_timer_) {
                    xTimerReset(nonce_timer_, 0);
                }
                ESP_LOGI(TAG, "CMD: Ping received, waiting for nonce...");
            } else if (byte == CMD_SET_ESC_DEBOUNCE) {
                state_ = State::READING_ESC_DEBOUNCE;
                debounce_bytes_read_ = 0;
                ESP_LOGI(TAG, "CMD: SetEscDebounce received, waiting for 4-byte value...");
            } else {
                dispatch_simple_command(byte);
            }
            break;
        }
        case State::READING_NONCE: {
            if (byte == '\n') {
                if (nonce_timer_) {
                    xTimerStop(nonce_timer_, 0);
                }
                ESP_LOGI(TAG, "Nonce complete: \"%s\"", nonce_buf_.c_str());
                complete_ping();
            } else if (nonce_buf_.size() < MAX_NONCE_LEN) {
                nonce_buf_ += (char)byte;
            } else {
                ESP_LOGW(TAG, "Nonce exceeded max length (%d), completing", (int)MAX_NONCE_LEN);
                if (nonce_timer_) {
                    xTimerStop(nonce_timer_, 0);
                }
                complete_ping();
            }
            break;
        }
        case State::READING_ESC_DEBOUNCE: {
            debounce_buf_[debounce_bytes_read_++] = byte;
            if (debounce_bytes_read_ == 4) {
                complete_set_esc_debounce();
            }
            break;
        }
    }
}

void CommandHandler::complete_ping() {
    auto &serial = UsbSerial::instance();
    state_ = State::IDLE;

    if (nonce_buf_.empty()) {
        ESP_LOGI(TAG, "CMD: Ping -> OK:PING (no nonce)");
        serial.send_response("OK:PING");
    } else {
        std::string response = "OK:PING:" + nonce_buf_;
        ESP_LOGI(TAG, "CMD: Ping -> %s", response.c_str());
        serial.send_response(response);
    }
    nonce_buf_.clear();
}

void CommandHandler::complete_set_esc_debounce() {
    auto &serial = UsbSerial::instance();
    state_ = State::IDLE;

    // Big-endian decode
    uint32_t ms = ((uint32_t)debounce_buf_[0] << 24)
                | ((uint32_t)debounce_buf_[1] << 16)
                | ((uint32_t)debounce_buf_[2] <<  8)
                |  (uint32_t)debounce_buf_[3];

    ESP_LOGI(TAG, "CMD: SetEscDebounce %lu ms", (unsigned long)ms);

    auto &bc = BrightnessControl::instance();
    bc.set_esc_debounce_ms(ms);

    esp_err_t err = NvsManager::set_esc_debounce_ms(bc.get_esc_debounce_ms());
    if (err == ESP_OK) {
        char buf[32];
        snprintf(buf, sizeof(buf), "OK:ESC_DEBOUNCE:%lu", (unsigned long)bc.get_esc_debounce_ms());
        serial.send_response(buf);
    } else {
        serial.send_response("ERR:NVS_WRITE_FAILED");
    }
}

void CommandHandler::dispatch_simple_command(uint8_t byte) {
    auto &serial = UsbSerial::instance();
    auto &ble = BleHidService::instance();

    switch (byte) {
        case CMD_BRIGHTNESS_UP: {
            ESP_LOGI(TAG, "CMD: Brightness Up (BLE %s)", ble.is_connected() ? "connected" : "disconnected");
            BrightnessControl::instance().brightness_up();
            break;
        }
        case CMD_BRIGHTNESS_DOWN: {
            ESP_LOGI(TAG, "CMD: Brightness Down (BLE %s)", ble.is_connected() ? "connected" : "disconnected");
            BrightnessControl::instance().brightness_down();
            break;
        }
        case CMD_PAIRING_MODE: {
            ESP_LOGI(TAG, "CMD: Enter Pairing Mode");
            ble.enter_pairing_mode();
            ESP_LOGI(TAG, "-> OK:PAIRING");
            serial.send_response("OK:PAIRING");
            break;
        }
        case CMD_STATUS: {
            std::string state = ble.is_connected() ? "connected" : "disconnected";
            std::string name = ble.get_peer_name();
            std::string response = "STATUS:" + state + ":" + name;
            ESP_LOGI(TAG, "CMD: Get Status -> %s", response.c_str());
            serial.send_response(response);
            break;
        }
        case CMD_UNPAIR: {
            ESP_LOGI(TAG, "CMD: Unpair");
            ble.unpair();
            ESP_LOGI(TAG, "-> OK:UNPAIRED");
            serial.send_response("OK:UNPAIRED");
            break;
        }
        case CMD_GET_ESC_DEBOUNCE: {
            uint32_t ms = BrightnessControl::instance().get_esc_debounce_ms();
            char buf[32];
            snprintf(buf, sizeof(buf), "OK:ESC_DEBOUNCE:%lu", (unsigned long)ms);
            ESP_LOGI(TAG, "CMD: GetEscDebounce -> %s", buf);
            serial.send_response(buf);
            break;
        }
        default: {
            ESP_LOGW(TAG, "Unknown command byte: 0x%02x -> ERR:UNKNOWN_CMD", byte);
            serial.send_response("ERR:UNKNOWN_CMD");
            break;
        }
    }
}