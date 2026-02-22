cmake_minimum_required(VERSION 3.10)
project(dart_monty_desktop_library VERSION 0.1.0 LANGUAGES C)

set(PLUGIN_LIB "${CMAKE_CURRENT_SOURCE_DIR}/libdart_monty_native.so")

install(FILES ${PLUGIN_LIB}
        DESTINATION "${CMAKE_INSTALL_PREFIX}/lib")
