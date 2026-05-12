cmake_minimum_required(VERSION 3.16)
project(unidesk_firmware_tests CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(test_protocol_parser
    test_protocol_parser.cpp
    ../main/protocol_parser.cpp
)
target_include_directories(test_protocol_parser PRIVATE ../main)

enable_testing()
add_test(NAME protocol_parser COMMAND test_protocol_parser)
