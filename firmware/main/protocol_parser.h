#pragma once

#include <cstdint>
#include <string>

struct ParsedCommand {
    enum class Type {
        None,
        BrightnessUp,
        BrightnessDown,
        PairingMode,
        Status,
        Unpair,
        Esc,
        FiiOVolumeUp,
        FiiOVolumeDown,
        Ping,           // str_payload = nonce (empty if none or timed out)
        SetEscDebounce, // uint_payload = raw ms value (caller is responsible for clamping)
        GetEscDebounce,
        Error,          // str_payload = error code, without "ERR:" prefix
    };

    Type        type         = Type::None;
    std::string str_payload;
    uint32_t    uint_payload = 0;
};

struct ParseResult {
    ParsedCommand command;
    bool start_timeout = false; // true when entering a multi-byte read state
    bool stop_timeout  = false; // true when completing normally (timer should be cancelled)
    // Both are false when SENTINEL_TIMEOUT triggers completion — timer already fired.
};

// Pure protocol parser — no FreeRTOS, no ESP-IDF, no singletons.
// Feed bytes one at a time; command.type == None means still accumulating.
class ProtocolParser {
public:
    static constexpr uint8_t CMD_BRIGHTNESS_UP      = 0x01;
    static constexpr uint8_t CMD_BRIGHTNESS_DOWN    = 0x02;
    static constexpr uint8_t CMD_PAIRING_MODE       = 0x03;
    static constexpr uint8_t CMD_PING               = 0x04;
    static constexpr uint8_t CMD_STATUS             = 0x05;
    static constexpr uint8_t CMD_UNPAIR             = 0x06;
    static constexpr uint8_t CMD_SET_ESC_DEBOUNCE   = 0x07;
    static constexpr uint8_t CMD_GET_ESC_DEBOUNCE   = 0x08;
    static constexpr uint8_t CMD_ESC                = 0x09;
    static constexpr uint8_t CMD_FIIO_VOLUME_UP     = 0x0A;
    static constexpr uint8_t CMD_FIIO_VOLUME_DOWN   = 0x0B;

    // Sentinel posted by the read-timeout timer. Must not collide with valid commands.
    // Consequence: 0xFF cannot appear as a data byte in multi-byte payloads (e.g.
    // the 4-byte ESC debounce value). The macOS app must avoid sending debounce
    // values whose big-endian encoding contains a 0xFF byte.
    static constexpr uint8_t SENTINEL_TIMEOUT = 0xFF;

    static constexpr size_t MAX_NONCE_LEN = 16;

    ParseResult handle_byte(uint8_t byte);
    void reset();

private:
    enum class State { IDLE, READING_NONCE, READING_ESC_DEBOUNCE };

    State       state_               = State::IDLE;
    std::string nonce_buf_;
    uint8_t     debounce_buf_[4]     = {};
    uint8_t     debounce_bytes_read_ = 0;
};
