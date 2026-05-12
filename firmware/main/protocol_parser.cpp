#include "protocol_parser.h"

void ProtocolParser::reset() {
    state_ = State::IDLE;
    nonce_buf_.clear();
    debounce_bytes_read_ = 0;
}

ParseResult ProtocolParser::handle_byte(uint8_t byte) {
    ParseResult r;

    switch (state_) {
        case State::IDLE: {
            if (byte == SENTINEL_TIMEOUT) break; // silently ignore in IDLE
            switch (byte) {
                case CMD_PING:
                    state_ = State::READING_NONCE;
                    nonce_buf_.clear();
                    r.start_timeout = true;
                    break;
                case CMD_SET_ESC_DEBOUNCE:
                    state_ = State::READING_ESC_DEBOUNCE;
                    debounce_bytes_read_ = 0;
                    r.start_timeout = true;
                    break;
                case CMD_BRIGHTNESS_UP:    r.command.type = ParsedCommand::Type::BrightnessUp;   break;
                case CMD_BRIGHTNESS_DOWN:  r.command.type = ParsedCommand::Type::BrightnessDown; break;
                case CMD_PAIRING_MODE:     r.command.type = ParsedCommand::Type::PairingMode;    break;
                case CMD_STATUS:           r.command.type = ParsedCommand::Type::Status;         break;
                case CMD_UNPAIR:           r.command.type = ParsedCommand::Type::Unpair;         break;
                case CMD_GET_ESC_DEBOUNCE: r.command.type = ParsedCommand::Type::GetEscDebounce; break;
                case CMD_ESC:              r.command.type = ParsedCommand::Type::Esc;            break;
                case CMD_FIIO_VOLUME_UP:   r.command.type = ParsedCommand::Type::FiiOVolumeUp;   break;
                case CMD_FIIO_VOLUME_DOWN: r.command.type = ParsedCommand::Type::FiiOVolumeDown; break;
                default:
                    r.command.type = ParsedCommand::Type::Error;
                    r.command.str_payload = "UNKNOWN_CMD";
                    break;
            }
            break;
        }

        case State::READING_NONCE: {
            if (byte == SENTINEL_TIMEOUT) {
                // Timeout: complete with empty nonce (matches original behaviour)
                state_ = State::IDLE;
                r.command.type = ParsedCommand::Type::Ping;
                // str_payload left empty — partial nonce is discarded
                nonce_buf_.clear();
                // stop_timeout intentionally false: timer already fired
            } else if (byte == '\n') {
                state_ = State::IDLE;
                r.command.type = ParsedCommand::Type::Ping;
                r.command.str_payload = nonce_buf_;
                nonce_buf_.clear();
                r.stop_timeout = true;
            } else if (nonce_buf_.size() < MAX_NONCE_LEN) {
                nonce_buf_ += static_cast<char>(byte);
            } else {
                // Buffer full — complete with accumulated nonce, discard overflow byte
                state_ = State::IDLE;
                r.command.type = ParsedCommand::Type::Ping;
                r.command.str_payload = nonce_buf_;
                nonce_buf_.clear();
                r.stop_timeout = true;
            }
            break;
        }

        case State::READING_ESC_DEBOUNCE: {
            if (byte == SENTINEL_TIMEOUT) {
                state_ = State::IDLE;
                debounce_bytes_read_ = 0;
                r.command.type = ParsedCommand::Type::Error;
                r.command.str_payload = "TIMEOUT";
                // stop_timeout intentionally false: timer already fired
            } else {
                debounce_buf_[debounce_bytes_read_++] = byte;
                if (debounce_bytes_read_ == 4) {
                    state_ = State::IDLE;
                    r.command.type = ParsedCommand::Type::SetEscDebounce;
                    r.command.uint_payload =
                        ((uint32_t)debounce_buf_[0] << 24) |
                        ((uint32_t)debounce_buf_[1] << 16) |
                        ((uint32_t)debounce_buf_[2] <<  8) |
                         (uint32_t)debounce_buf_[3];
                    debounce_bytes_read_ = 0;
                    r.stop_timeout = true;
                }
            }
            break;
        }
    }

    return r;
}
