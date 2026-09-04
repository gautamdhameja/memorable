cmake_minimum_required(VERSION 3.20)
project(MemorableSentencePiece LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(SPM_ENABLE_SHARED OFF CACHE BOOL "" FORCE)
set(SPM_ENABLE_TCMALLOC OFF CACHE BOOL "" FORCE)
set(SPM_BUILD_TEST OFF CACHE BOOL "" FORCE)
set(SPM_ABSL_PROVIDER package CACHE STRING "" FORCE)
find_package(absl REQUIRED)
# Upstream calls its iOS toolchain helper even with CMake's native iOS support.
# These properties concern CLI targets (which we do not build), not inference.
function(set_xcode_property target property value variant)
    set_property(TARGET ${target} PROPERTY XCODE_ATTRIBUTE_${property} "${value}")
endfunction()
add_subdirectory("${SENTENCEPIECE_SOURCE}" sentencepiece)
add_library(MemorableSentencePieceBridge STATIC Bridge/SentencePieceNative.cc)
target_include_directories(MemorableSentencePieceBridge PRIVATE
    Bridge/include "${SENTENCEPIECE_SOURCE}/src" "${SENTENCEPIECE_SOURCE}")
target_link_libraries(MemorableSentencePieceBridge PRIVATE sentencepiece-static absl::status)
