cmake_minimum_required(VERSION 3.10)

project(profanity2)

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include_directories(include/)
aux_source_directory(src/ SOURCES)

set(PROFANITY2_TARGET profanity2.x64)
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})

add_executable(${PROFANITY2_TARGET} ${SOURCES})

if(APPLE)
  target_link_libraries(${PROFANITY2_TARGET} PRIVATE "-framework OpenCL")
  target_compile_options(${PROFANITY2_TARGET} PRIVATE -std=c++11 -Wall -mmmx
                                                      -O2)
else()
  find_package(OpenCL REQUIRED)
  target_link_options(${PROFANITY2_TARGET} PRIVATE -s -mcmodel=large)
  target_compile_options(${PROFANITY2_TARGET} PRIVATE -std=c++11 -Wall -mmmx
                                                      -O2 -mcmodel=large)
  target_link_libraries(${PROFANITY2_TARGET} PRIVATE OpenCL)
endif()