cmake_minimum_required(VERSION 3.10)
project(dart_monty_native_library VERSION 0.1.0 LANGUAGES C)

set(dart_monty_native_bundled_libraries
  "${CMAKE_CURRENT_SOURCE_DIR}/libdart_monty_native.so"
  PARENT_SCOPE
)
