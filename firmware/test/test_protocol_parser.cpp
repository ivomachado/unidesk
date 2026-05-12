#include <cstdio>
#include <cstring>
#include <string>

#include "protocol_parser.h"

// ---- minimal test framework ------------------------------------------------

static int s_total = 0, s_failed = 0;
static const char *s_test = "?";

static void check(bool ok, const char *expr, int line) {
    s_total++;
    if (!ok) {
        printf("\n    FAIL [%s] line %d: %s", s_test, line, expr);
        s_failed++;
    }
}

#define EXPECT(e)         check(!!(e),               #e,         __LINE__)
#define EXPECT_EQ(a, b)   check((a) == (b),          #a "==" #b, __LINE__)
#define EXPECT_STR(a, b)  check(std::string(a) == std::string(b), #a "==" #b, __LINE__)

#define RUN(fn) do { \
    s_test = #fn; \
    printf("  %-60s", #fn " ..."); fflush(stdout); \
    int _pre = s_failed; \
    fn(); \
    puts(_pre == s_failed ? "ok" : ""); \
} while(0)

using T = ParsedCommand::Type;

// ---- test cases ------------------------------------------------------------

static void test_single_byte_commands() {
    struct { uint8_t cmd; T expected; } cases[] = {
        {0x01, T::BrightnessUp},
        {0x02, T::BrightnessDown},
        {0x03, T::PairingMode},
        {0x05, T::Status},
        {0x06, T::Unpair},
        {0x08, T::GetEscDebounce},
        {0x09, T::Esc},
        {0x0A, T::FiiOVolumeUp},
        {0x0B, T::FiiOVolumeDown},
    };
    for (auto &c : cases) {
        ProtocolParser p;
        ParseResult r = p.handle_byte(c.cmd);
        EXPECT_EQ(r.command.type, c.expected);
        EXPECT(!r.start_timeout);
        EXPECT(!r.stop_timeout);
    }
}

static void test_unknown_command_returns_error() {
    ProtocolParser p;
    ParseResult r = p.handle_byte(0x0C);
    EXPECT_EQ(r.command.type, T::Error);
    EXPECT_STR(r.command.str_payload, "UNKNOWN_CMD");
}

static void test_sentinel_in_idle_is_ignored() {
    ProtocolParser p;
    ParseResult r = p.handle_byte(ProtocolParser::SENTINEL_TIMEOUT);
    EXPECT_EQ(r.command.type, T::None);
    EXPECT(!r.start_timeout);
    // Subsequent commands still work
    r = p.handle_byte(0x01);
    EXPECT_EQ(r.command.type, T::BrightnessUp);
}

static void test_ping_starts_timeout() {
    ProtocolParser p;
    ParseResult r = p.handle_byte(ProtocolParser::CMD_PING);
    EXPECT_EQ(r.command.type, T::None);
    EXPECT(r.start_timeout);
    EXPECT(!r.stop_timeout);
}

static void test_ping_with_nonce() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_PING);
    p.handle_byte('a');
    p.handle_byte('b');
    p.handle_byte('1');
    EXPECT_EQ(p.handle_byte('2').command.type, T::None); // still accumulating

    ParseResult r = p.handle_byte('\n');
    EXPECT_EQ(r.command.type, T::Ping);
    EXPECT_STR(r.command.str_payload, "ab12");
    EXPECT(r.stop_timeout);
    EXPECT(!r.start_timeout);
}

static void test_ping_empty_nonce() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_PING);
    ParseResult r = p.handle_byte('\n');
    EXPECT_EQ(r.command.type, T::Ping);
    EXPECT_STR(r.command.str_payload, "");
    EXPECT(r.stop_timeout);
}

static void test_ping_timeout_discards_partial_nonce() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_PING);
    p.handle_byte('x');
    p.handle_byte('y');
    ParseResult r = p.handle_byte(ProtocolParser::SENTINEL_TIMEOUT);
    EXPECT_EQ(r.command.type, T::Ping);
    EXPECT_STR(r.command.str_payload, ""); // partial nonce discarded on timeout
    EXPECT(!r.stop_timeout);              // timer already fired, do not stop it
}

static void test_ping_nonce_max_length_overflow() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_PING);
    // Feed exactly MAX_NONCE_LEN chars — all should accumulate without completing
    for (size_t i = 0; i < ProtocolParser::MAX_NONCE_LEN; i++) {
        EXPECT_EQ(p.handle_byte('a' + (uint8_t)(i % 26)).command.type, T::None);
    }
    // The (MAX+1)th byte triggers completion; the overflow byte itself is discarded
    ParseResult r = p.handle_byte('!');
    EXPECT_EQ(r.command.type, T::Ping);
    EXPECT_EQ(r.command.str_payload.size(), ProtocolParser::MAX_NONCE_LEN);
    EXPECT(r.stop_timeout);
}

static void test_set_esc_debounce_starts_timeout() {
    ProtocolParser p;
    ParseResult r = p.handle_byte(ProtocolParser::CMD_SET_ESC_DEBOUNCE);
    EXPECT_EQ(r.command.type, T::None);
    EXPECT(r.start_timeout);
    EXPECT(!r.stop_timeout);
}

static void test_set_esc_debounce_big_endian_decode() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_SET_ESC_DEBOUNCE);
    // 2000 ms = 0x000007D0
    p.handle_byte(0x00);
    p.handle_byte(0x00);
    p.handle_byte(0x07);
    ParseResult r = p.handle_byte(0xD0);
    EXPECT_EQ(r.command.type, T::SetEscDebounce);
    EXPECT_EQ(r.command.uint_payload, 2000u);
    EXPECT(r.stop_timeout);
    EXPECT(!r.start_timeout);
}

static void test_set_esc_debounce_protocol_max() {
    // Max valid debounce per NvsManager is 10000 ms = 0x00002710.
    // 0xFF is reserved as SENTINEL_TIMEOUT so it cannot appear as a data byte.
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_SET_ESC_DEBOUNCE);
    p.handle_byte(0x00);
    p.handle_byte(0x00);
    p.handle_byte(0x27);
    ParseResult r = p.handle_byte(0x10);
    EXPECT_EQ(r.command.type, T::SetEscDebounce);
    EXPECT_EQ(r.command.uint_payload, 10000u);
}

static void test_set_esc_debounce_returns_none_while_accumulating() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_SET_ESC_DEBOUNCE);
    EXPECT_EQ(p.handle_byte(0x00).command.type, T::None);
    EXPECT_EQ(p.handle_byte(0x00).command.type, T::None);
    EXPECT_EQ(p.handle_byte(0x00).command.type, T::None);
    EXPECT_EQ(p.handle_byte(0x01).command.type, T::SetEscDebounce);
}

static void test_set_esc_debounce_timeout_mid_stream() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_SET_ESC_DEBOUNCE);
    p.handle_byte(0x00);
    p.handle_byte(0x00); // only 2 of 4 bytes received
    ParseResult r = p.handle_byte(ProtocolParser::SENTINEL_TIMEOUT);
    EXPECT_EQ(r.command.type, T::Error);
    EXPECT_STR(r.command.str_payload, "TIMEOUT");
    EXPECT(!r.stop_timeout);
}

static void test_back_to_back_single_byte_commands() {
    ProtocolParser p;
    EXPECT_EQ(p.handle_byte(0x01).command.type, T::BrightnessUp);
    EXPECT_EQ(p.handle_byte(0x02).command.type, T::BrightnessDown);
    EXPECT_EQ(p.handle_byte(0x05).command.type, T::Status);
}

static void test_ping_then_single_byte() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_PING);
    p.handle_byte('x');
    ParseResult r1 = p.handle_byte('\n');
    EXPECT_EQ(r1.command.type, T::Ping);
    EXPECT_STR(r1.command.str_payload, "x");

    // Parser back in IDLE
    ParseResult r2 = p.handle_byte(0x05);
    EXPECT_EQ(r2.command.type, T::Status);
}

static void test_debounce_then_ping() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_SET_ESC_DEBOUNCE);
    p.handle_byte(0x00); p.handle_byte(0x00); p.handle_byte(0x00);
    ParseResult r1 = p.handle_byte(0x64); // 100 decimal
    EXPECT_EQ(r1.command.type, T::SetEscDebounce);
    EXPECT_EQ(r1.command.uint_payload, 100u);

    // Parser back in IDLE
    p.handle_byte(ProtocolParser::CMD_PING);
    p.handle_byte('z');
    ParseResult r2 = p.handle_byte('\n');
    EXPECT_EQ(r2.command.type, T::Ping);
    EXPECT_STR(r2.command.str_payload, "z");
}

static void test_reset_clears_mid_nonce_state() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_PING);
    p.handle_byte('a');
    p.reset();
    EXPECT_EQ(p.handle_byte(0x01).command.type, T::BrightnessUp);
}

static void test_reset_clears_mid_debounce_state() {
    ProtocolParser p;
    p.handle_byte(ProtocolParser::CMD_SET_ESC_DEBOUNCE);
    p.handle_byte(0x00);
    p.reset();
    EXPECT_EQ(p.handle_byte(0x02).command.type, T::BrightnessDown);
}

// ---- main ------------------------------------------------------------------

int main() {
    puts("Protocol Parser Tests");
    puts("=====================");

    RUN(test_single_byte_commands);
    RUN(test_unknown_command_returns_error);
    RUN(test_sentinel_in_idle_is_ignored);
    RUN(test_ping_starts_timeout);
    RUN(test_ping_with_nonce);
    RUN(test_ping_empty_nonce);
    RUN(test_ping_timeout_discards_partial_nonce);
    RUN(test_ping_nonce_max_length_overflow);
    RUN(test_set_esc_debounce_starts_timeout);
    RUN(test_set_esc_debounce_big_endian_decode);
    RUN(test_set_esc_debounce_protocol_max);
    RUN(test_set_esc_debounce_returns_none_while_accumulating);
    RUN(test_set_esc_debounce_timeout_mid_stream);
    RUN(test_back_to_back_single_byte_commands);
    RUN(test_ping_then_single_byte);
    RUN(test_debounce_then_ping);
    RUN(test_reset_clears_mid_nonce_state);
    RUN(test_reset_clears_mid_debounce_state);

    printf("\n%d/%d passed\n", s_total - s_failed, s_total);
    return s_failed > 0 ? 1 : 0;
}
