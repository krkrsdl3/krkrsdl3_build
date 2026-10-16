cmake_minimum_required(VERSION 3.24)

# BPG uses a modified, older HEVC decoder. It must never resolve symbols from
# the application's FFmpeg, even when both libraries are linked statically.
include(FetchContent)
FetchContent_Declare(krkr_bpg_upstream
    URL https://bellard.org/bpg/libbpg-0.9.8.tar.gz
    URL_HASH SHA512=2d5f7a035033d8b969c2765a4f1368e1a2c8c5ace12aec5d449ca5cc4ef5eb89431a75f2d6d03fd7117b548801b5554503411f499f497da69ff33ca6e714553d
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(krkr_bpg_upstream)

set(bpg_private "${CMAKE_CURRENT_BINARY_DIR}/private")
file(GLOB_RECURSE bpg_files RELATIVE "${krkr_bpg_upstream_SOURCE_DIR}"
    "${krkr_bpg_upstream_SOURCE_DIR}/libavcodec/*.c"
    "${krkr_bpg_upstream_SOURCE_DIR}/libavcodec/*.h"
    "${krkr_bpg_upstream_SOURCE_DIR}/libavutil/*.c"
    "${krkr_bpg_upstream_SOURCE_DIR}/libavutil/*.h"
)
list(APPEND bpg_files config.h libbpg.c libbpg.h)
foreach(file IN LISTS bpg_files)
    file(READ "${krkr_bpg_upstream_SOURCE_DIR}/${file}" text)
    # Rewrite identifiers in definitions, references AND token-pasting macros.
    # A short list of renamed API functions leaves data and internal helpers
    # exposed to symbol interposition by another FFmpeg version.
    string(REGEX REPLACE "(^|[^A-Za-z0-9_])(av_|avcodec_|avpriv_|ff_)"
        "\\1krkr_bpg_\\2" text "${text}")
    if(file STREQUAL "config.h")
        if(MSVC)
            string(REPLACE "#define HAVE_ATOMICS_GCC 1" "#define HAVE_ATOMICS_GCC 0" text "${text}")
            string(REPLACE "#define HAVE_ATOMICS_WIN32 0" "#define HAVE_ATOMICS_WIN32 1" text "${text}")
        endif()
        if(CMAKE_C_BYTE_ORDER STREQUAL "BIG_ENDIAN")
            string(REPLACE "#define HAVE_BIGENDIAN 0" "#define HAVE_BIGENDIAN 1" text "${text}")
        endif()
    elseif(file STREQUAL "libavutil/internal.h")
        # These MSVC linker directives reference unused libc replacements that
        # are deliberately absent from the reduced BPG decoder.
        string(REGEX REPLACE "#pragma comment\\(linker,[^\n]*" "" text "${text}")
    elseif(file STREQUAL "libavcodec/hevcdsp.c")
        string(REPLACE "    if (ARCH_X86)\n        krkr_bpg_ff_hevc_dsp_init_x86(hevcdsp, bit_depth);"
            "#if ARCH_X86\n    krkr_bpg_ff_hevc_dsp_init_x86(hevcdsp, bit_depth);\n#endif" text "${text}")
    endif()
    get_filename_component(dir "${bpg_private}/${file}" DIRECTORY)
    file(MAKE_DIRECTORY "${dir}")
    # Avoid recompiling the decoder on unrelated CMake reconfigurations.
    file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/prepared" "${text}")
    configure_file("${CMAKE_CURRENT_BINARY_DIR}/prepared" "${bpg_private}/${file}" COPYONLY)
endforeach()
file(REMOVE "${CMAKE_CURRENT_BINARY_DIR}/prepared")

set(bpg_sources
    libavcodec/hevc_cabac.c libavcodec/hevc_filter.c libavcodec/hevc.c
    libavcodec/hevcpred.c libavcodec/hevc_refs.c libavcodec/hevcdsp.c
    libavcodec/hevc_mvs.c libavcodec/hevc_ps.c libavcodec/hevc_sei.c
    libavcodec/utils.c libavcodec/cabac.c libavcodec/golomb.c libavcodec/videodsp.c
    libavutil/mem.c libavutil/buffer.c libavutil/log2_tab.c libavutil/frame.c
    libavutil/pixdesc.c libavutil/md5.c libbpg.c
)
list(TRANSFORM bpg_sources PREPEND "${bpg_private}/")
add_library(krkr_bpg STATIC ${bpg_sources})
set_target_properties(krkr_bpg PROPERTIES
    C_STANDARD 99 POSITION_INDEPENDENT_CODE ON C_VISIBILITY_PRESET hidden)
target_compile_definitions(krkr_bpg PRIVATE HAVE_AV_CONFIG_H USE_VAR_BIT_DEPTH USE_PRED)
# Upstream also has a few global helpers without an av_/ff_ prefix. Keep
# these names private too; definitions here do not alter #include filenames.
foreach(symbol get_bits get_bits1 get_bits_long get_se_golomb_long get_ue_golomb_long
        show_bits show_bits1 skip_bits skip_bits1 hevc_transform_init intra_pred)
    target_compile_definitions(krkr_bpg PRIVATE "${symbol}=krkr_bpg_${symbol}")
endforeach()
target_include_directories(krkr_bpg PRIVATE "${bpg_private}")
# Only libbpg.h is public. Never expose the bundled libav* headers to the app.
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/include")
configure_file("${krkr_bpg_upstream_SOURCE_DIR}/libbpg.h"
    "${CMAKE_CURRENT_BINARY_DIR}/include/libbpg.h" COPYONLY)
target_include_directories(krkr_bpg INTERFACE "${CMAKE_CURRENT_BINARY_DIR}/include")
if(MSVC)
    target_compile_options(krkr_bpg PRIVATE /wd4996)
elseif(NOT WIN32)
    target_link_libraries(krkr_bpg PRIVATE m)
endif()
