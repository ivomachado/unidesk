#pragma once

#include "freertos/FreeRTOS.h"
#include "freertos/timers.h"
#include "protocol_parser.h"

class CommandHandler {
public:
    // Exposed so UsbSerial's timer callback can reference the sentinel value.
    static constexpr uint8_t SENTINEL_TIMEOUT = ProtocolParser::SENTINEL_TIMEOUT;

    static CommandHandler& instance();

    /// Process a single byte received from USB serial.
    void handle_byte(uint8_t byte);

private:
    CommandHandler();
    ~CommandHandler();

    CommandHandler(const CommandHandler&) = delete;
    CommandHandler& operator=(const CommandHandler&) = delete;

    void dispatch(const ParsedCommand& cmd);

    static void read_timeout_cb(TimerHandle_t timer);

    ProtocolParser parser_;
    TimerHandle_t  read_timer_ = nullptr;

    static constexpr TickType_t READ_TIMEOUT_MS = 100;
};
