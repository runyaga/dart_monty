cmake_minimum_required(VERSION 3.10)
project(dart_monty_native_library VERSION 0.1.0 LANGUAGES C)

# Multi-arch support: check arch-specific subdirectories first,
# then fall back to the flat directory (backwards-compatible).
if(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
  set(_arch_subdir "arm64")
else()
  set(_arch_subdir "x64")
endif()

if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_arch_subdir}/libdart_monty_native.so")
  set(dart_monty_native_bundled_libraries
    "${CMAKE_CURRENT_SOURCE_DIR}/${_arch_subdir}/libdart_monty_native.so"
    PARENT_SCOPE
  )
else()
  # Fallback: flat layout (pre-0.8.0 packages)
  set(dart_monty_native_bundled_libraries
    "${CMAKE_CURRENT_SOURCE_DIR}/libdart_monty_native.so"
    PARENT_SCOPE
  )
endif()
