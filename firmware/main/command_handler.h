#pragma once

#include <cstdint>
#include <string>
#include "freertos/FreeRTOS.h"
#include "freertos/timers.h"

class CommandHandler {
public:
    // Command byte constants
    static constexpr uint8_t CMD_BRIGHTNESS_UP      = 0x01;
    static constexpr uint8_t CMD_BRIGHTNESS_DOWN    = 0x02;
    static constexpr uint8_t CMD_PAIRING_MODE       = 0x03;
    static constexpr uint8_t CMD_PING               = 0x04;
    static constexpr uint8_t CMD_STATUS             = 0x05;
    static constexpr uint8_t CMD_UNPAIR             = 0x06;
    static constexpr uint8_t CMD_SET_ESC_DEBOUNCE   = 0x07;
    static constexpr uint8_t CMD_GET_ESC_DEBOUNCE   = 0x08;

    static CommandHandler& instance();

    /// Process a single byte received from USB serial.
    /// Handles multi-byte commands (nonce ping) via internal state machine.
    void handle_byte(uint8_t byte);

private:
    CommandHandler();
    ~CommandHandler();

    // Disallow copy
    CommandHandler(const CommandHandler&) = delete;
    CommandHandler& operator=(const CommandHandler&) = delete;

    /// Dispatch a simple single-byte command immediately.
    void dispatch_simple_command(uint8_t cmd);

    /// Complete the ping command with whatever nonce has been accumulated.
    void complete_ping();

    /// Complete the set-ESC-debounce command with the 4 bytes accumulated.
    void complete_set_esc_debounce();

    /// Timer callback for nonce read timeout.
    static void nonce_timeout_cb(TimerHandle_t timer);

    enum class State {
        IDLE,                  // Waiting for a command byte
        READING_NONCE,         // Received 0x04, buffering nonce chars until '\n' or timeout
        READING_ESC_DEBOUNCE,  // Received 0x07, reading 4 big-endian bytes for the ms value
    };

    State state_ = State::IDLE;
    std::string nonce_buf_;
    uint8_t debounce_buf_[4] = {};
    uint8_t debounce_bytes_read_ = 0;
    TimerHandle_t nonce_timer_ = nullptr;

    static constexpr size_t MAX_NONCE_LEN = 16;
    static constexpr TickType_t NONCE_TIMEOUT_MS = 100;
};