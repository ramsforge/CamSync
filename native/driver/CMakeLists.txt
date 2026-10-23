cmake_minimum_required(VERSION 3.20)
project(CamSyncVirtualCam CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_definitions(-DUNICODE -D_UNICODE -DWIN32_LEAN_AND_MEAN)

set(SOURCES
    DllMain.cpp
    CamSyncFilter.cpp
    CamSyncPin.cpp
    CamSyncVirtualCam.def
)

set(HEADERS
    CamSyncGuids.h
    CamSyncFilter.h
    CamSyncPin.h
    ../shared/CamSyncSharedBuffer.h
)

add_library(CamSyncVirtualCam SHARED ${SOURCES} ${HEADERS})

target_link_libraries(CamSyncVirtualCam PRIVATE
    ole32
    oleaut32
    strmiids
    uuid
    advapi32
    shlwapi
)

set_target_properties(CamSyncVirtualCam PROPERTIES
    LINK_FLAGS "/DEF:${CMAKE_CURRENT_SOURCE_DIR}/CamSyncVirtualCam.def"
    OUTPUT_NAME "CamSyncVirtualCam"
)
