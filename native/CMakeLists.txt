cmake_minimum_required(VERSION 3.20)
project(CamSyncNative CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_subdirectory(driver)

add_library(camsync_native SHARED
    bridge/CamSyncBridge.cpp
    bridge/CamSyncBridge.h
    shared/CamSyncSharedBuffer.h
)
target_link_libraries(camsync_native PRIVATE kernel32 user32 ole32 mfplat mfuuid)

add_executable(camsync_feeder tools/dummy_feeder.cpp shared/CamSyncSharedBuffer.h)
target_link_libraries(camsync_feeder PRIVATE kernel32 user32)

add_executable(camsync_list_devices tools/list_devices.cpp)
target_link_libraries(camsync_list_devices PRIVATE ole32 oleaut32 strmiids)
